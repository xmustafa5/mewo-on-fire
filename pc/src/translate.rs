//! Claude's questions in plain Arabic, for the phone (PROTOCOL.md v3.7).
//!
//! The same one-shot Claude Code the Mewo Session window runs for its
//! translate panel (`mewo-session`'s `translate`): no settings, hooks, tools
//! or saved session, Haiku, so it is quick. The phone sends the questions it
//! shows; the answer has, for each, the question in simple Arabic, what it
//! really asks, every option's label and description in Arabic, the option(s)
//! to pick and why.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::paths;
use crate::runner;

/// Longest a translation may take before the phone hears it failed.
const TIMEOUT: Duration = Duration::from_secs(120);

/// What the phone shows when there is no translation.
const FAILED: &str = "The translation did not come back.";

const SYSTEM: &str = "You translate questions an AI coding assistant asks its user into Arabic for a reader who finds English hard. \
The input is a JSON list of questions with their options. Reply with JSON only, no code fence, in this shape: \
{\"questions\":[{\"question\":\"...\",\"explain\":\"...\",\"options\":[{\"label\":\"...\",\"description\":\"...\"}],\"best\":[0],\"why\":\"...\"}]}. \
Same number and order of questions and of options as the input. \
question: the question in simple, everyday Modern Standard Arabic. \
explain: one or two short sentences in simple Arabic saying what is really being asked and what the choice changes, as you would to someone who is not a programmer. \
options: each label and description in simple Arabic; a description always, written by you when the input has none. \
best: the zero-based index of the option you recommend (several only when multiSelect is true); prefer an option marked Recommended, else the safest and most common choice. \
why: one short Arabic sentence giving the reason. \
Keep file names, code, commands, product names and technical terms that have no common Arabic word in English.";

/// The questions as the model gets them: header, text, multiSelect and the
/// options' labels and descriptions, nothing else.
fn asked(questions: &Value) -> Vec<Value> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    questions
        .as_array()
        .map(|qs| {
            qs.iter()
                .map(|q| {
                    let options: Vec<Value> = q
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|os| os.iter().map(|o| json!({"label": s(o, "label"), "description": s(o, "description")})).collect())
                        .unwrap_or_default();
                    json!({
                        "header": s(q, "header"),
                        "question": s(q, "question"),
                        "multiSelect": q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                        "options": options,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The translated questions out of Claude Code's `--output-format json`
/// answer: its `result` text holds one JSON object, maybe with words around
/// it. None unless there is one entry per question asked.
fn parse(stdout: &str, n: usize) -> Option<Value> {
    let out: Value = serde_json::from_str(stdout.trim()).ok()?;
    let text = out.get("result").and_then(Value::as_str)?;
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end < start {
        return None;
    }
    let data: Value = serde_json::from_str(&text[start..=end]).ok()?;
    let qs = data.get("questions")?.as_array()?;
    (qs.len() == n).then(|| Value::Array(qs.clone()))
}

/// Runs the translation: the questions in Arabic, or why there are none.
pub async fn translate(questions: &Value) -> Result<Value, String> {
    let asked = asked(questions);
    if asked.is_empty() {
        return Err("There is no question to translate.".to_string());
    }
    let claude = runner::claude_bin().unwrap_or_else(|| PathBuf::from("claude"));
    let cwd = paths::state_dir();
    let _ = std::fs::create_dir_all(&cwd);
    let mut child = Command::new(&claude)
        .args([
            "-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config", "--tools", "",
            "--no-session-persistence", "--system-prompt", SYSTEM, "--output-format", "json",
        ])
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| {
            eprintln!("mewo: translate: could not start {}: {e}", claude.display());
            "Claude Code could not be started on the PC.".to_string()
        })?;
    let input = serde_json::to_string(&asked).unwrap_or_default();
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }
    let out = match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            eprintln!("mewo: translate: {e}");
            return Err(FAILED.to_string());
        }
        Err(_) => {
            eprintln!("mewo: translate: no answer in {}s", TIMEOUT.as_secs());
            return Err(FAILED.to_string());
        }
    };
    parse(&String::from_utf8_lossy(&out.stdout), asked.len()).ok_or_else(|| FAILED.to_string())
}

/// `translate` → `translate_result`: `ok` and `questions`, or `error`.
pub async fn reply(client_id: String, questions: Value) -> Value {
    match translate(&questions).await {
        Ok(qs) => json!({"type": "translate_result", "client_id": client_id, "ok": true, "questions": qs}),
        Err(error) => json!({"type": "translate_result", "client_id": client_id, "ok": false, "error": error}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_only_what_the_model_needs() {
        let q = json!([{"header": "Auth", "question": "Which?", "multiSelect": true, "extra": 1,
            "options": [{"label": "A", "description": "first", "preview": "x"}, {"label": "B"}]}]);
        let a = asked(&q);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0]["options"][1], json!({"label": "B", "description": ""}));
        assert_eq!(a[0]["multiSelect"], json!(true));
        assert!(a[0].get("extra").is_none());
        assert!(asked(&json!(null)).is_empty());
    }

    #[test]
    fn reads_the_result_with_words_around_it() {
        let inner = r#"Here: {"questions":[{"question":"أي؟","best":[0]}]} done"#;
        let stdout = json!({"type": "result", "result": inner}).to_string();
        let qs = parse(&stdout, 1).unwrap();
        assert_eq!(qs[0]["question"], json!("أي؟"));
        assert!(parse(&stdout, 2).is_none());
        assert!(parse("not json", 1).is_none());
        assert!(parse(&json!({"result": "no object"}).to_string(), 1).is_none());
    }
}

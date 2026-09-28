//! `ccnotify ask` — Claude Code PermissionRequest hook (PROTOCOL.md v1.1).
//! Forwards the prompt to the daemon, blocks until a phone answers and prints
//! the hook decision. Always exits 0; prints nothing (normal prompt flow)
//! unless a phone answered. The original `tool_input` and
//! `permission_suggestions` never leave this process: the decision is built
//! here from the hook input + the phone's answer.

use std::io::{Read, Write};
use std::time::Duration;

use anyhow::Result;
use serde_json::{json, Map, Value};

use crate::control;
use crate::hook;

pub const MAX_DETAIL_CHARS: usize = 4000;
/// Cap for file contents / edit strings inside `detail`.
const MAX_SNIPPET_CHARS: usize = 1500;
/// Bounds sending the request; the reply itself is awaited without a timeout.
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const DEFAULT_DENY_MESSAGE: &str = "Denied from phone (ccnotify)";
const DEFAULT_REJECT_MESSAGE: &str = "Plan rejected from phone (ccnotify)";

pub fn run() -> ! {
    // Nothing but the final decision may reach stdout, even on panic.
    std::panic::set_hook(Box::new(|_| {}));
    if let Ok(Some(out)) = std::panic::catch_unwind(try_run) {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(out.as_bytes());
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();
    }
    std::process::exit(0);
}

fn try_run() -> Option<String> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).ok()?;
    let hook_input: Value = serde_json::from_str(&input).ok()?;
    let request = map_request(&hook_input);
    let resp = ask_daemon(&request).ok()?;
    let answer = reply_answer(&resp)?;
    let output = hook_output(&hook_input, answer)?;
    serde_json::to_string(&output).ok()
}

/// Send `{"cmd":"ask"}` and block (no read timeout) until the daemon replies.
pub fn ask_daemon(request: &Value) -> Result<Value> {
    control::request_blocking(&json!({"cmd": "ask", "request": request}), WRITE_TIMEOUT)
}

/// The phone's answer in an `ask` reply, if there is one.
pub fn reply_answer(resp: &Value) -> Option<&Value> {
    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    resp.get("answer").filter(|a| a.is_object())
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

pub fn request_kind(tool: &str) -> &'static str {
    match tool {
        "AskUserQuestion" => "question",
        "ExitPlanMode" => "plan",
        _ => "permission",
    }
}

/// Map a PermissionRequest hook payload to a protocol Request (without id/ts).
pub fn map_request(v: &Value) -> Value {
    let tool = str_of(v, "tool_name");
    let empty = Value::Object(Map::new());
    let input = v
        .get("tool_input")
        .filter(|i| i.is_object())
        .unwrap_or(&empty);
    let kind = request_kind(tool);
    let (title, summary, detail) = describe(tool, input);

    let can_allow_always = kind == "permission"
        && v.get("permission_suggestions")
            .and_then(Value::as_array)
            .map(|a| !a.is_empty())
            .unwrap_or(false);
    let questions: Vec<Value> = if kind == "question" {
        input
            .get("questions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    let mut cwd = str_of(v, "cwd").to_string();
    if cwd.is_empty() {
        cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
    }
    let session: String = str_of(v, "session_id").chars().take(8).collect();

    json!({
        "kind": kind,
        "project": hook::project_name(&cwd),
        "session": session,
        "tool": tool,
        "title": title,
        "summary": hook::clean_message(&summary),
        "detail": truncate_chars(&detail, MAX_DETAIL_CHARS),
        "can_allow_always": can_allow_always,
        "questions": questions,
    })
}

/// (title, summary, detail) for a tool call; PROTOCOL.md "Request".
fn describe(tool: &str, input: &Value) -> (String, String, String) {
    match tool {
        "Bash" => {
            let command = str_of(input, "command");
            (
                "Run a command".to_string(),
                command.to_string(),
                join_nonempty(&[command, str_of(input, "description")]),
            )
        }
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
            let path = first_nonempty(str_of(input, "file_path"), str_of(input, "notebook_path"));
            (
                "Edit a file".to_string(),
                path.to_string(),
                edit_detail(path, input),
            )
        }
        "WebFetch" => {
            let url = str_of(input, "url");
            (
                "Fetch a URL".to_string(),
                url.to_string(),
                join_nonempty(&[url, str_of(input, "prompt")]),
            )
        }
        "WebSearch" => {
            let query = str_of(input, "query");
            (
                "Search the web".to_string(),
                query.to_string(),
                query.to_string(),
            )
        }
        "ExitPlanMode" => {
            let plan = str_of(input, "plan");
            (
                "Approve the plan".to_string(),
                first_line(plan).to_string(),
                plan.to_string(),
            )
        }
        "AskUserQuestion" => {
            let texts: Vec<&str> = input
                .get("questions")
                .and_then(Value::as_array)
                .map(|qs| {
                    qs.iter()
                        .map(|q| str_of(q, "question"))
                        .filter(|t| !t.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            (
                "Claude has a question".to_string(),
                texts.first().copied().unwrap_or("").to_string(),
                texts.join("\n\n"),
            )
        }
        _ => {
            let title = if tool.is_empty() {
                "Use a tool".to_string()
            } else {
                format!("Use {tool}")
            };
            (
                title,
                serde_json::to_string(input).unwrap_or_default(),
                serde_json::to_string_pretty(input).unwrap_or_default(),
            )
        }
    }
}

/// `file_path` + the change: old → new for each edit, else the start of the
/// new content.
fn edit_detail(path: &str, input: &Value) -> String {
    let mut parts: Vec<String> = vec![path.to_string()];
    if let Some(edits) = input.get("edits").and_then(Value::as_array) {
        for e in edits {
            parts.push(replace_text(str_of(e, "old_string"), str_of(e, "new_string")));
        }
    } else if input.get("old_string").is_some() || input.get("new_string").is_some() {
        parts.push(replace_text(
            str_of(input, "old_string"),
            str_of(input, "new_string"),
        ));
    } else {
        let content = first_nonempty(str_of(input, "content"), str_of(input, "new_source"));
        parts.push(truncate_chars(content, MAX_SNIPPET_CHARS));
    }
    let parts: Vec<&str> = parts.iter().map(String::as_str).collect();
    join_nonempty(&parts)
}

fn replace_text(old: &str, new: &str) -> String {
    format!(
        "{}\n→\n{}",
        truncate_chars(old, MAX_SNIPPET_CHARS),
        truncate_chars(new, MAX_SNIPPET_CHARS)
    )
}

fn first_nonempty<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.is_empty() {
        b
    } else {
        a
    }
}

/// Join the non-empty parts with a blank line.
fn join_nonempty(parts: &[&str]) -> String {
    parts
        .iter()
        .copied()
        .filter(|p| !p.trim().is_empty())
        .collect::<Vec<&str>>()
        .join("\n\n")
}

/// First non-empty line, without a leading markdown heading marker.
fn first_line(s: &str) -> &str {
    s.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| l.trim_start_matches('#').trim())
        .unwrap_or("")
}

/// Keep at most `max` chars (char-safe). When truncated, the last kept char
/// is an ellipsis.
pub fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// The PermissionRequest hook stdout for a phone answer (PROTOCOL.md
/// "Answer"). None if the answer does not fit the request kind.
pub fn hook_output(hook_input: &Value, answer: &Value) -> Option<Value> {
    let tool = str_of(hook_input, "tool_name");
    let tool_input = hook_input
        .get("tool_input")
        .cloned()
        .unwrap_or_else(|| Value::Object(Map::new()));
    let action = str_of(answer, "action");

    let decision = match request_kind(tool) {
        "question" => {
            if matches!(action, "deny" | "reject") {
                deny(answer, DEFAULT_DENY_MESSAGE)
            } else {
                let answers = answer.get("answers").filter(|a| a.is_object())?.clone();
                let mut updated = match tool_input {
                    Value::Object(map) => map,
                    _ => Map::new(),
                };
                updated.insert("answers".to_string(), answers);
                json!({"behavior": "allow", "updatedInput": Value::Object(updated)})
            }
        }
        "plan" => match action {
            "approve" | "allow" => json!({"behavior": "allow", "updatedInput": tool_input}),
            "reject" | "deny" => deny(answer, DEFAULT_REJECT_MESSAGE),
            _ => return None,
        },
        _ => match action {
            "allow" => json!({"behavior": "allow"}),
            "allow_always" => match hook_input.get("permission_suggestions") {
                Some(suggestions)
                    if suggestions.as_array().map(|a| !a.is_empty()).unwrap_or(false) =>
                {
                    json!({"behavior": "allow", "updatedPermissions": suggestions})
                }
                // Nothing to persist: plain allow.
                _ => json!({"behavior": "allow"}),
            },
            "deny" | "reject" => deny(answer, DEFAULT_DENY_MESSAGE),
            _ => return None,
        },
    };

    Some(json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }))
}

fn deny(answer: &Value, default_message: &str) -> Value {
    let message = str_of(answer, "message").trim();
    let message = if message.is_empty() {
        default_message
    } else {
        message
    };
    json!({"behavior": "deny", "message": message})
}

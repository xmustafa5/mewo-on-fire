//! `mewo ask` — Claude Code PermissionRequest hook (PROTOCOL.md v1.1).
//! Forwards the prompt to the daemon, blocks until a phone answers and prints
//! the hook decision. Always exits 0; prints nothing (normal prompt flow)
//! unless a phone answered. The original `tool_input` and
//! `permission_suggestions` never leave this process: the decision is built
//! here from the hook input + the phone's answer.
//!
//! Claude Code does not kill the hook when the prompt is answered on the PC,
//! so a transcript watcher thread exits the process (silently) once the
//! transcript shows the prompt was answered there.

use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::Result;
use serde_json::{json, Map, Value};

use crate::control;
use crate::hook;
use crate::transcript;

pub const MAX_DETAIL_CHARS: usize = 4000;
/// Cap for file contents / edit strings inside `detail`.
const MAX_SNIPPET_CHARS: usize = 1500;
/// Bounds sending the request; the reply itself is awaited without a timeout.
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const DEFAULT_DENY_MESSAGE: &str = "Denied from phone (Mewo on Fire)";
const DEFAULT_REJECT_MESSAGE: &str = "Plan rejected from phone (Mewo on Fire)";
/// Transcript watcher: how much of the transcript tail is searched for the
/// prompt's tool_use, and how often the file is re-checked.
const WATCH_TAIL_BYTES: u64 = 2 * 1024 * 1024;
const WATCH_INTERVAL: Duration = Duration::from_secs(1);

/// Set by whoever ends the process first: the main thread (right before it
/// prints a phone answer, or exits silently) or the transcript watcher
/// (prompt answered on the PC). The other one must not exit / print.
static FINISHED: AtomicBool = AtomicBool::new(false);

pub fn run() -> ! {
    // Nothing but the final decision may reach stdout, even on panic.
    std::panic::set_hook(Box::new(|_| {}));
    let out = std::panic::catch_unwind(try_run);
    if FINISHED.swap(true, Ordering::SeqCst) {
        // The watcher is exiting the process (no output): wait for it.
        loop {
            std::thread::park();
        }
    }
    if let Ok(Some(out)) = out {
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
    spawn_watcher(&hook_input);
    let resp = ask_daemon(&request, str_of(&hook_input, "agent_id")).ok()?;
    let answer = reply_answer(&resp)?;
    let output = hook_output(&hook_input, answer)?;
    serde_json::to_string(&output).ok()
}

/// Send `{"cmd":"ask"}` and block (no read timeout) until the daemon replies.
/// `agent_id` (private, never forwarded to phones) is set for prompts from a
/// subagent.
pub fn ask_daemon(request: &Value, agent_id: &str) -> Result<Value> {
    control::request_blocking(
        &json!({"cmd": "ask", "request": request, "agent_id": agent_id}),
        WRITE_TIMEOUT,
    )
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

// ---------------------------------------------------------------------------
// Transcript watcher (PROTOCOL.md v1.1)
// ---------------------------------------------------------------------------

/// What the watcher waits for in the lines appended to the transcript.
enum Target {
    /// The tool_result of the prompt's tool_use (this id).
    ToolUse(String),
    /// The prompt's tool_use is not in the transcript yet: Claude Code can
    /// start the hook before it flushes that line, so it is adopted from the
    /// appended lines.
    Pending,
}

struct Watcher {
    path: String,
    tool: String,
    input: Value,
    /// Watching a subagent transcript: its lines are all sidechain lines.
    sidechain: bool,
}

/// Start the transcript watcher thread. Skipped for subagent prompts unless
/// the input names the subagent's own transcript.
fn spawn_watcher(hook_input: &Value) {
    let mut path = str_of(hook_input, "transcript_path");
    let mut sidechain = false;
    if !str_of(hook_input, "agent_id").is_empty() {
        let agent_path = str_of(hook_input, "agent_transcript_path");
        if agent_path.is_empty() || agent_path == path {
            return;
        }
        path = agent_path;
        sidechain = true;
    }
    if path.is_empty() {
        return;
    }
    let watcher = Watcher {
        path: path.to_string(),
        tool: str_of(hook_input, "tool_name").to_string(),
        input: hook_input.get("tool_input").cloned().unwrap_or(Value::Null),
        sidechain,
    };
    let _ = std::thread::Builder::new()
        .name("transcript-watcher".to_string())
        .spawn(move || watcher.run());
}

impl Watcher {
    /// Find the prompt's tool_use, then poll the appended lines until the
    /// prompt is gone; then exit the process with code 0 and no output
    /// (unless the main thread got there first).
    fn run(self) {
        let (tail, mut offset) = match read_tail(&self.path, WATCH_TAIL_BYTES) {
            Ok(x) => x,
            Err(_) => return,
        };
        let cut = complete_len(&tail);
        let mut target = self.find_target(&tail[..cut]);
        // A partial last line, completed by the next read.
        let mut carry: Vec<u8> = tail[cut..].to_vec();

        loop {
            std::thread::sleep(WATCH_INTERVAL);
            if FINISHED.load(Ordering::SeqCst) {
                return;
            }
            let mut file = match File::open(&self.path) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let len = match file.metadata() {
                Ok(m) => m.len(),
                Err(_) => continue,
            };
            if len < offset {
                // Rewritten: start over.
                offset = 0;
                carry.clear();
            }
            if len == offset {
                continue;
            }
            let mut appended = Vec::new();
            if file.seek(SeekFrom::Start(offset)).is_err()
                || file.read_to_end(&mut appended).is_err()
            {
                continue;
            }
            offset += appended.len() as u64;
            carry.extend_from_slice(&appended);
            let cut = complete_len(&carry);
            if cut == 0 {
                continue;
            }
            let gone = self.prompt_gone(&carry[..cut], &mut target);
            carry.drain(..cut);
            if gone {
                if !FINISHED.swap(true, Ordering::SeqCst) {
                    std::process::exit(0);
                }
                return;
            }
        }
    }

    /// Main-chain line (or any line of a subagent transcript).
    fn in_chain(&self, v: &Value) -> bool {
        self.sidechain || !flag(v, "isSidechain")
    }

    /// The prompt's tool_use in the transcript tail: the most recent
    /// `tool_name` call without a tool_result, preferring one whose input
    /// equals the hook's `tool_input`.
    fn find_target(&self, bytes: &[u8]) -> Target {
        // (tool_use id, input equals tool_input), oldest first.
        let mut calls: Vec<(String, bool)> = Vec::new();
        let mut answered: HashSet<String> = HashSet::new();
        for v in json_lines(bytes) {
            if !self.in_chain(&v) {
                continue;
            }
            match str_of(&v, "type") {
                "assistant" => {
                    for b in content_blocks(&v) {
                        let id = str_of(b, "id");
                        if str_of(b, "type") == "tool_use"
                            && str_of(b, "name") == self.tool
                            && !id.is_empty()
                        {
                            calls.push((id.to_string(), b.get("input") == Some(&self.input)));
                        }
                    }
                }
                "user" => answered.extend(tool_result_ids(&v).map(str::to_string)),
                _ => {}
            }
        }
        calls.retain(|(id, _)| !answered.contains(id));
        let best = calls
            .iter()
            .rev()
            .find(|(_, same_input)| *same_input)
            .or_else(|| calls.last());
        match best {
            Some((id, _)) => Target::ToolUse(id.clone()),
            None => Target::Pending,
        }
    }

    /// The id of this assistant line's `tool_name` call, preferring one whose
    /// input equals the hook's `tool_input`.
    fn matching_call(&self, v: &Value) -> Option<String> {
        let mut fallback = None;
        for b in content_blocks(v) {
            let id = str_of(b, "id");
            if str_of(b, "type") != "tool_use" || str_of(b, "name") != self.tool || id.is_empty() {
                continue;
            }
            if b.get("input") == Some(&self.input) {
                return Some(id.to_string());
            }
            fallback = Some(id.to_string());
        }
        fallback
    }

    /// True if the appended lines show the prompt is gone: its tool_result
    /// (answered on the PC) or a new user prompt (the session moved on).
    /// While the tool_use is still `Pending`, it is adopted from these lines.
    fn prompt_gone(&self, bytes: &[u8], target: &mut Target) -> bool {
        for v in json_lines(bytes) {
            if !self.in_chain(&v) {
                continue;
            }
            match str_of(&v, "type") {
                "assistant" => {
                    if matches!(target, Target::Pending) {
                        if let Some(id) = self.matching_call(&v) {
                            *target = Target::ToolUse(id);
                        }
                    }
                }
                "user" => {
                    if let Target::ToolUse(id) = &*target {
                        if tool_result_ids(&v).any(|r| r == id.as_str()) {
                            return true;
                        }
                    }
                    if !flag(&v, "isMeta") && is_prompt(&v) {
                        return true;
                    }
                }
                _ => {}
            }
        }
        false
    }
}

/// The last `max` bytes of the file (without the first, partial line when
/// the file is longer) and the offset they end at.
fn read_tail(path: &str, max: u64) -> std::io::Result<(Vec<u8>, u64)> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(max);
    file.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    let end = start + buf.len() as u64;
    if start > 0 {
        match buf.iter().position(|&b| b == b'\n') {
            Some(nl) => {
                buf.drain(..=nl);
            }
            None => buf.clear(),
        }
    }
    Ok((buf, end))
}

/// Length of the complete lines at the start of `bytes` (up to and
/// including the last newline).
fn complete_len(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .rposition(|&b| b == b'\n')
        .map(|p| p + 1)
        .unwrap_or(0)
}

/// The JSON lines of a JSONL chunk (bad lines are skipped).
fn json_lines(bytes: &[u8]) -> impl Iterator<Item = Value> + '_ {
    bytes
        .split(|&b| b == b'\n')
        .filter(|line| !line.iter().all(u8::is_ascii_whitespace))
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// `message.content` blocks of a transcript line.
fn content_blocks(v: &Value) -> &[Value] {
    v.get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

/// `tool_use_id`s of the tool_result blocks of a transcript line.
fn tool_result_ids(v: &Value) -> impl Iterator<Item = &str> + '_ {
    content_blocks(v)
        .iter()
        .filter(|b| str_of(b, "type") == "tool_result")
        .map(|b| str_of(b, "tool_use_id"))
}

/// A user line with typed text (after stripping the usual wrappers); tool
/// results and task notifications (background tasks, rewakes) do not count.
fn is_prompt(v: &Value) -> bool {
    let content = v.get("message").and_then(|m| m.get("content"));
    let texts: Vec<&str> = match content {
        Some(Value::String(s)) => vec![s.as_str()],
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| str_of(b, "type") == "text")
            .map(|b| str_of(b, "text"))
            .collect(),
        _ => Vec::new(),
    };
    texts.iter().any(|text| {
        let text = transcript::strip_wrappers(text);
        let text = text.trim();
        !text.is_empty() && !text.starts_with("<task-notification>")
    })
}

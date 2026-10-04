//! `ccnotify hook` — invoked by Claude Code with the hook JSON on stdin.
//! Always exits 0 and never blocks long (daemon down = drop). It prints
//! nothing, except for UserPromptSubmit with `suggestions` on: then the
//! request for a suggestion line (suggest.rs), which Claude Code adds to the
//! prompt.

use std::io::Read;
use std::path::Path;
use std::time::Duration;

use serde_json::{json, Value};

use crate::control;
use crate::suggest;

pub const MAX_MESSAGE_CHARS: usize = 200;

pub fn run() -> ! {
    // Never print anything, even on panic.
    std::panic::set_hook(Box::new(|_| {}));
    let _ = std::panic::catch_unwind(|| {
        let _ = try_run();
    });
    std::process::exit(0);
}

fn try_run() -> Option<()> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).ok()?;
    let v: Value = serde_json::from_str(&input).ok()?;
    if v.get("hook_event_name").and_then(Value::as_str) == Some("UserPromptSubmit")
        && crate::config::suggestions_enabled()
    {
        println!(
            "{}",
            json!({
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": suggest::INSTRUCTION,
                }
            })
        );
    }
    let req = map_request(&v)?;
    control::request(&req, Duration::from_secs(1)).ok()?;
    Some(())
}

fn field(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// The control request for a hook payload: `session_state` (working) for
/// UserPromptSubmit, else `emit` with the private session fields
/// (PROTOCOL.md v1.2; never forwarded to phones). None for hook events we do
/// not forward.
pub fn map_request(v: &Value) -> Option<Value> {
    let name = v.get("hook_event_name")?.as_str()?;
    let session_id = field(v, "session_id");
    let transcript_path = field(v, "transcript_path");
    let effort = effort_level(v);
    if name == "UserPromptSubmit" {
        return Some(json!({
            "cmd": "session_state",
            "session_id": session_id,
            "cwd": hook_cwd(v),
            "transcript_path": transcript_path,
            "effort": effort,
            "state": "working",
        }));
    }
    let event = map_event(v)?;
    Some(json!({
        "cmd": "emit",
        "event": event,
        "session_id": session_id,
        "transcript_path": transcript_path,
        "effort": effort,
    }))
}

/// `effort.level` from the hook input ("" if absent).
fn effort_level(v: &Value) -> String {
    match v.get("effort") {
        Some(Value::String(level)) => level.trim().to_string(),
        Some(effort) => field(effort, "level").trim().to_string(),
        None => String::new(),
    }
}

/// `cwd` from the hook input, else the current directory.
fn hook_cwd(v: &Value) -> String {
    let cwd = field(v, "cwd");
    if !cwd.is_empty() {
        return cwd;
    }
    std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Map a Claude Code hook payload to a protocol event (without id/ts).
/// Returns None for hook events we do not forward.
pub fn map_event(v: &Value) -> Option<Value> {
    let name = v.get("hook_event_name")?.as_str()?;
    let (kind, message, detail) = match name {
        // Without the suggestion line: this is the notification's text.
        "Stop" => (
            "stop",
            suggest::split(&field(v, "last_assistant_message")).0,
            String::new(),
        ),
        "Notification" => (
            "needs_input",
            field(v, "message"),
            field(v, "notification_type"),
        ),
        "SessionEnd" => ("session_end", String::new(), field(v, "reason")),
        _ => return None,
    };

    let cwd = hook_cwd(v);
    let project = project_name(&cwd);
    let session_id = field(v, "session_id");
    let session: String = session_id.chars().take(8).collect();

    Some(json!({
        "kind": kind,
        "project": project,
        "cwd": cwd,
        "session": session,
        "message": clean_message(&message),
        "detail": detail,
        "session_id": session_id,
    }))
}

/// Basename of cwd.
pub fn project_name(cwd: &str) -> String {
    Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| cwd.to_string())
}

/// Collapse all whitespace runs to single spaces and keep at most 200 chars
/// (char-safe). When truncated, the 200th char is an ellipsis.
pub fn clean_message(s: &str) -> String {
    let collapsed = s.split_whitespace().collect::<Vec<&str>>().join(" ");
    if collapsed.chars().count() <= MAX_MESSAGE_CHARS {
        return collapsed;
    }
    let mut out: String = collapsed.chars().take(MAX_MESSAGE_CHARS - 1).collect();
    let trimmed_len = out.trim_end().len();
    out.truncate(trimmed_len);
    out.push('…');
    out
}

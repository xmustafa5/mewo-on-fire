//! `ccnotify listen` — Claude Code Stop hook with `asyncRewake` (PROTOCOL.md
//! v1.2). Runs in the background after every reply and waits for a message
//! from the phone: exit 2 with the message on stderr wakes Claude; anything
//! else exits 0 silently. Never prints to stdout.

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::control;

/// Bounds sending the request; the reply itself is awaited without a timeout.
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// When the daemon is unreachable or drops the connection (restarting, e.g.
/// after `ccnotify install`), keep trying to re-register for this long.
const RECONNECT_WINDOW: Duration = Duration::from_secs(15);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const MESSAGE_PREFIX: &str = "The user sent this message from their phone (via ccnotify). Treat it exactly as if they had typed it in this session:\n\n";

pub fn run() -> ! {
    // Exit code 0 or 2 only, even on panic.
    std::panic::set_hook(Box::new(|_| {}));
    let code = match std::panic::catch_unwind(try_run) {
        Ok(Some(text)) => {
            let mut stderr = std::io::stderr().lock();
            let _ = stderr.write_all(MESSAGE_PREFIX.as_bytes());
            let _ = stderr.write_all(text.as_bytes());
            let _ = stderr.flush();
            2
        }
        _ => 0,
    };
    std::process::exit(code);
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn try_run() -> Option<String> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).ok()?;
    let v: Value = serde_json::from_str(&input).ok()?;
    let session_id = str_of(&v, "session_id");
    if session_id.is_empty() {
        return None;
    }
    let mut cwd = str_of(&v, "cwd").to_string();
    if cwd.is_empty() {
        cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
    }
    let req = json!({
        "cmd": "listen",
        "session_id": session_id,
        "cwd": cwd,
        "transcript_path": str_of(&v, "transcript_path"),
    });
    wait_for_message(&req)
}

/// Send `listen` and block (no read timeout) until the daemon replies. The
/// phone's text, or None for any other reply.
fn wait_for_message(req: &Value) -> Option<String> {
    let mut give_up_at: Option<Instant> = None;
    loop {
        match control::request_blocking(req, WRITE_TIMEOUT) {
            Ok(resp) => return reply_text(&resp),
            Err(_) => {
                let deadline =
                    *give_up_at.get_or_insert_with(|| Instant::now() + RECONNECT_WINDOW);
                if Instant::now() >= deadline {
                    return None;
                }
                std::thread::sleep(RECONNECT_DELAY);
            }
        }
    }
}

fn reply_text(resp: &Value) -> Option<String> {
    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let text = resp.get("text").and_then(Value::as_str)?;
    if text.trim().is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

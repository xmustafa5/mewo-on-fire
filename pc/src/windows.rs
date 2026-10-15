//! v3.2: the Mewo Session windows open on this computer. Each keeps
//! `<state>/windows/<pid>.json` (`pid`, `folder`, `session_id`) while it is
//! open and comes forward on SIGUSR1, so the console can offer "Show the
//! session" on a session that has one. Since v3.3 a chat session's entry is
//! its host's (mewo-session-host, `socket` added): the host brings its tab
//! forward in the chat window, opening the window again when none is open.
//! Linux only: there is no such window on a Mac.

use std::fs;
use std::path::PathBuf;

use serde_json::Value;

use crate::paths;

fn dir() -> PathBuf {
    paths::state_dir().join("windows")
}

/// A pid that is a Mewo Session window right now.
fn is_window(pid: u32) -> bool {
    fs::read(format!("/proc/{pid}/cmdline")).map(|c| String::from_utf8_lossy(&c).contains("mewo-session")).unwrap_or(false)
}

/// `(pid, folder, session id)` of every window that is open.
fn open() -> Vec<(u32, String, String)> {
    let Ok(rd) = fs::read_dir(dir()) else { return Vec::new() };
    let mut out = Vec::new();
    for e in rd.flatten() {
        let path = e.path();
        if path.extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        let Some(v) = fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { continue };
        let pid = v.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32;
        if pid == 0 || !is_window(pid) {
            // Left by a window that did not close cleanly.
            let _ = fs::remove_file(&path);
            continue;
        }
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        out.push((pid, s("folder"), s("session_id")));
    }
    out
}

/// Sets `window` (the window's pid) on the sessions that have one: by the
/// Claude Code session the window runs, or, for a terminal window (which
/// does not know it), on the live session in its folder.
pub fn tag(sessions: &mut Value) {
    let Some(list) = sessions.as_array_mut() else { return };
    let windows = open();
    if windows.is_empty() {
        return;
    }
    for s in list {
        let get = |k: &str| s.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        if !get("pc_name").is_empty() {
            continue;
        }
        let (id, cwd, state) = (get("id"), get("cwd"), get("state"));
        let found = windows.iter().find(|(_, _, sid)| !sid.is_empty() && *sid == id).or_else(|| {
            windows.iter().find(|(_, folder, sid)| sid.is_empty() && state != "ended" && !folder.is_empty() && (cwd == *folder || cwd.starts_with(&format!("{folder}/"))))
        });
        if let (Some((pid, _, _)), Some(obj)) = (found, s.as_object_mut()) {
            obj.insert("window".to_string(), Value::from(*pid));
        }
    }
}

/// Asks a window to come forward. From here there is no click to hand
/// over, so the shell may only mark it as wanting attention; the console
/// app sends the click's token itself (mewo-console, `show_session`).
pub fn show(pid: u32) -> Result<(), String> {
    if !open().iter().any(|(p, _, _)| *p == pid) {
        return Err("That session has no window open on this PC".to_string());
    }
    let ok = std::process::Command::new("kill").args(["-USR1", &pid.to_string()]).status().map(|s| s.success()).unwrap_or(false);
    if ok { Ok(()) } else { Err("Could not reach the window".to_string()) }
}

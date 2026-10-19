//! v3.2: the Mewo Session windows open on this computer. Each keeps
//! `<state>/windows/<pid>.json` (`pid`, `folder`, `session_id`) while it is
//! open and comes forward on SIGUSR1, so the console can offer "Show the
//! session" on a session that has one. Since v3.3 a chat session's entry is
//! its host's (mewo-session-host, `socket` added): the host brings its tab
//! forward in the chat window, opening the window again when none is open.
//! Linux only: there is no such window on a Mac.
//!
//! v3.4: the phones see the window too. A host's entry carries what its
//! header shows (`title`, `goal`, `workspace`, `branch`, `model_label`,
//! `mode`, `started`) and stays, marked `ended`, while its tab is still
//! open after Claude Code ended; `list` joins each entry with its
//! session for the phone's Windows tab, `stop` closes a tab from there.

use std::fs;
use std::io::Write;
use std::path::PathBuf;

use serde_json::{json, Value};

use crate::paths;
use crate::sessions::Session;

fn dir() -> PathBuf {
    paths::state_dir().join("windows")
}

/// A pid that is a Mewo Session window right now.
fn is_window(pid: u32) -> bool {
    fs::read(format!("/proc/{pid}/cmdline")).map(|c| String::from_utf8_lossy(&c).contains("mewo-session")).unwrap_or(false)
}

/// The entry of every window that is open, as its file holds it.
fn entries() -> Vec<Value> {
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
        out.push(v);
    }
    out
}

/// `(pid, folder, session id)` of every window that is open.
fn open() -> Vec<(u32, String, String)> {
    entries()
        .into_iter()
        .map(|v| {
            let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            (v.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32, s("folder"), s("session_id"))
        })
        .collect()
}

/// v3.4: every window (a chat tab's host, or a terminal window) with its
/// session, for the phones: what the header of each tab shows, whether
/// Claude Code has ended in it, and the session's state and last reply.
/// Plan session order, then the time each started.
pub fn list(sessions: &[Session]) -> Vec<Value> {
    let mut out: Vec<Value> = entries()
        .into_iter()
        .map(|v| {
            let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            let (sid, folder) = (s("session_id"), s("folder"));
            let ended = v.get("ended").and_then(Value::as_bool).unwrap_or(false);
            // A chat tab knows its session; a terminal window only its folder.
            let session = sessions.iter().find(|x| !sid.is_empty() && x.id == sid).or_else(|| {
                sessions.iter().find(|x| sid.is_empty() && !ended && x.state != "ended" && !folder.is_empty() && (x.cwd == folder || x.cwd.starts_with(&format!("{folder}/"))))
            });
            // `n` is a number from the daemon's info file, a string from an older host.
            let n = v.get("n").and_then(|n| n.as_u64().or_else(|| n.as_str().and_then(|t| t.parse().ok()))).unwrap_or(0);
            json!({
                "pid": v.get("pid").and_then(Value::as_u64).unwrap_or(0),
                "folder": folder,
                "session_id": sid,
                "n": n,
                "feature": s("feature"),
                "workspace": s("workspace"),
                "title": s("title"),
                "goal": s("goal"),
                "branch": s("branch"),
                "model_label": s("model_label"),
                "mode": if s("mode").is_empty() { "chat".to_string() } else { s("mode") },
                "started": v.get("started").and_then(Value::as_u64).unwrap_or(0),
                "ended": ended,
                "exit_code": v.get("exit_code").cloned().unwrap_or(Value::Null),
                "session": session.map(|x| serde_json::to_value(x).unwrap_or(Value::Null)).unwrap_or(Value::Null),
            })
        })
        .collect();
    out.sort_by_key(|w| (w["n"].as_u64().unwrap_or(0), w["started"].as_u64().unwrap_or(0), w["pid"].as_u64().unwrap_or(0)));
    out
}

/// v3.4: closes a tab from a phone, as its close button does: the host
/// ends Claude Code (`stop`). A terminal window has no host to ask.
pub fn stop(pid: u32) -> Result<(), String> {
    let Some(entry) = entries().into_iter().find(|v| v.get("pid").and_then(Value::as_u64) == Some(pid as u64)) else {
        return Err("That session has no window open on this PC".to_string());
    };
    let socket = entry.get("socket").and_then(Value::as_str).unwrap_or("").to_string();
    if socket.is_empty() {
        return Err("That session runs in a terminal window: close it on the PC".to_string());
    }
    let mut stream = std::os::unix::net::UnixStream::connect(&socket).map_err(|_| "Could not reach the session's host".to_string())?;
    let _ = stream.set_write_timeout(Some(std::time::Duration::from_secs(3)));
    stream.write_all(b"{\"t\": \"stop\"}\n").map_err(|_| "Could not reach the session's host".to_string())
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

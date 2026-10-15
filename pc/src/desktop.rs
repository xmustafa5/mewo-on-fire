//! Claude Desktop's own record of its sessions: one JSON per session under
//! ~/Library/Application Support/Claude/claude-code-sessions on macOS,
//! ~/.config/Claude/claude-code-sessions on Linux, with the app's id (`sessionId`, `local_…`) and Claude Code's
//! (`cliSessionId`). Read to tag sessions the hooks did not (started before
//! the daemon knew about it), so the console can open them in the app.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

const TTL: Duration = Duration::from_secs(30);

static CACHE: Mutex<Option<(Instant, HashMap<String, String>)>> = Mutex::new(None);

fn store_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    if cfg!(target_os = "macos") {
        return Some(PathBuf::from(home).join("Library/Application Support/Claude/claude-code-sessions"));
    }
    let config = std::env::var("XDG_CONFIG_HOME").ok().filter(|d| !d.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(&home).join(".config"));
    Some(config.join("Claude/claude-code-sessions"))
}

/// What a message calls this computer.
const HERE: &str = if cfg!(target_os = "macos") { "this Mac" } else { "this PC" };

/// Claude Desktop is here: the app on macOS, the `claude://` handler on Linux.
fn installed() -> bool {
    if cfg!(target_os = "macos") {
        let home = std::env::var("HOME").unwrap_or_default();
        return std::path::Path::new("/Applications/Claude.app").exists()
            || std::path::Path::new(&format!("{home}/Applications/Claude.app")).exists();
    }
    std::process::Command::new("xdg-mime")
        .args(["query", "default", "x-scheme-handler/claude"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false)
}

/// Claude Code session id → Desktop session id.
pub fn map() -> HashMap<String, String> {
    if let Some((at, m)) = CACHE.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
        if at.elapsed() < TTL {
            return m.clone();
        }
    }
    let m = scan();
    *CACHE.lock().unwrap_or_else(|p| p.into_inner()) = Some((Instant::now(), m.clone()));
    m
}

fn scan() -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Some(root) = store_dir() else { return out };
    // <account>/<organization>/local_<id>.json
    let Ok(accounts) = fs::read_dir(&root) else { return out };
    for account in accounts.flatten() {
        let Ok(orgs) = fs::read_dir(account.path()) else { continue };
        for org in orgs.flatten() {
            let Ok(files) = fs::read_dir(org.path()) else { continue };
            for f in files.flatten() {
                let path = f.path();
                let name = f.file_name().to_string_lossy().into_owned();
                if !name.starts_with("local_") || !name.ends_with(".json") {
                    continue;
                }
                if let Some((cli, desktop)) = read_ids(&path) {
                    out.insert(cli, desktop);
                }
            }
        }
    }
    out
}

fn read_ids(path: &std::path::Path) -> Option<(String, String)> {
    let text = fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let cli = v.get("cliSessionId")?.as_str()?.trim().to_string();
    let desktop = v.get("sessionId")?.as_str()?.trim().to_string();
    if cli.is_empty() || !desktop.starts_with("local_") {
        return None;
    }
    Some((cli, desktop))
}

/// Fills `desktop` on sessions that have none.
pub fn tag(sessions: &mut Value) {
    let Some(list) = sessions.as_array_mut() else { return };
    if list.is_empty() {
        return;
    }
    let m = map();
    if m.is_empty() {
        return;
    }
    for s in list {
        let has = s.get("desktop").and_then(Value::as_str).map(|d| !d.is_empty()).unwrap_or(false);
        if has {
            continue;
        }
        let Some(id) = s.get("id").and_then(Value::as_str) else { continue };
        if let Some(d) = m.get(id) {
            if let Some(obj) = s.as_object_mut() {
                obj.insert("desktop".to_string(), Value::String(d.clone()));
            }
        }
    }
}

/// Starts a new Claude Code session in Claude Desktop (v1.6) with [prompt]
/// as its first message, in [cwd] when Desktop honours the folder. The app
/// owns the `claude://` scheme, so this is one `open` on macOS, one
/// `xdg-open` on Linux.
pub fn open_new_session(cwd: &str, prompt: &str) -> Result<(), String> {
    let prompt = prompt.trim();
    if prompt.is_empty() {
        return Err("The first message is empty".to_string());
    }
    if !installed() {
        return Err(format!("Claude Desktop is not installed on {HERE}"));
    }
    let mut url = format!("claude://code/new?q={}&source=mewo", percent(prompt));
    let cwd = cwd.trim();
    if !cwd.is_empty() {
        if !std::path::Path::new(cwd).is_dir() {
            return Err(format!("No such folder on {HERE}: {cwd}"));
        }
        url.push_str(&format!("&folder={}", percent(cwd)));
    }
    let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    let status = std::process::Command::new(opener)
        .arg(&url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("could not run {opener}: {e}"))?;
    if status.success() {
        eprintln!("mewo: new session asked of Claude Desktop ({} chars{})", prompt.chars().count(), if cwd.is_empty() { String::new() } else { format!(", in {cwd}") });
        Ok(())
    } else {
        Err("Claude Desktop did not take the link".to_string())
    }
}

/// Percent-encoding for a query value (RFC 3986 unreserved stay as they are).
fn percent(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

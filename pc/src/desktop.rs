//! Claude Desktop's own record of its sessions (macOS): one JSON per
//! session under ~/Library/Application Support/Claude/claude-code-sessions,
//! with the app's id (`sessionId`, `local_…`) and Claude Code's
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
    if !cfg!(target_os = "macos") {
        return None;
    }
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join("Library/Application Support/Claude/claude-code-sessions"))
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

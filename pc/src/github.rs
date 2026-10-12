//! v2.6: one GitHub account for everything the daemon and its sessions
//! do, whatever account `gh` has active at the moment: other sessions on
//! this computer switch it. The account's token (from `gh auth token
//! --user`) goes into the environment of every git, gh and session
//! process as `GH_TOKEN`, which gh and its git credential helper honour
//! over the active account.

use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static USER: Mutex<String> = Mutex::new(String::new());
/// `(fetched, user, token)`.
static CACHE: Mutex<Option<(Instant, String, String)>> = Mutex::new(None);

pub fn set_user(user: &str) {
    *USER.lock().unwrap_or_else(|p| p.into_inner()) = user.trim().to_string();
    *CACHE.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

pub fn user() -> String {
    USER.lock().unwrap_or_else(|p| p.into_inner()).clone()
}

/// The account's token, from gh's own store; cached ten minutes.
pub fn token() -> Option<String> {
    let user = user();
    if user.is_empty() {
        return None;
    }
    if let Some((at, u, t)) = CACHE.lock().unwrap_or_else(|p| p.into_inner()).clone() {
        if u == user && at.elapsed() < Duration::from_secs(600) {
            return Some(t);
        }
    }
    let gh = crate::prs::gh_path()?;
    let out = Command::new(gh).args(["auth", "token", "--user", &user]).stdin(Stdio::null()).stderr(Stdio::null()).env_remove("GH_TOKEN").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let t = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if t.is_empty() {
        return None;
    }
    *CACHE.lock().unwrap_or_else(|p| p.into_inner()) = Some((Instant::now(), user, t.clone()));
    Some(t)
}

/// Environment for a git, gh or session process: `GH_TOKEN` when an
/// account is set and signed in to gh, nothing otherwise.
pub fn envs() -> Vec<(String, String)> {
    token().map(|t| vec![("GH_TOKEN".to_string(), t)]).unwrap_or_default()
}

/// Whether the set account is usable, in one line.
pub fn status() -> serde_json::Value {
    let user = user();
    serde_json::json!({"user": user, "signed_in": !user.is_empty() && token().is_some()})
}

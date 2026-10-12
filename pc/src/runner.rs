//! v2.6: headless Claude Code sessions for the build autopilot. Claude
//! Desktop's deep link only types the prompt in and waits for Enter; the
//! command-line tool runs it to the end by itself. The hooks still report
//! the session, so it shows on the console and the phones like any other.

use std::collections::HashMap;
use std::fs::{self, File};
use std::path::PathBuf;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Mutex;

use crate::{config::now_ms, paths};

/// Exit codes of the runs that finished, by pid.
static EXITS: Mutex<Option<HashMap<u32, i32>>> = Mutex::new(None);

/// Where the Claude Code command is on this Mac, when it is installed.
pub fn claude_bin() -> Option<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/.local/bin/claude"),
        "/opt/homebrew/bin/claude".to_string(),
        "/usr/local/bin/claude".to_string(),
        format!("{home}/.claude/local/claude"),
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|p| p.is_file())
}

/// Signed in? The command keeps its sign-in in the login keychain under
/// "Claude Code-credentials"; without it every run stops at once.
pub fn signed_in() -> bool {
    Command::new("security").args(["find-generic-password", "-s", "Claude Code-credentials"]).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
}

/// What stands in the way of a headless run, in one line; nothing when
/// it can run.
pub fn ready() -> Result<(), String> {
    if claude_bin().is_none() {
        return Err("Claude Code is not installed on this Mac: run the installer from claude.ai (curl -fsSL https://claude.ai/install.sh | bash)".to_string());
    }
    if !signed_in() {
        return Err("Claude Code is installed but not signed in: run `claude` in a terminal, then `/login`, once".to_string());
    }
    Ok(())
}

/// The model for a plan tier: the account's default for Tier 1, Sonnet
/// for Tier 2, Haiku for Tier 3 (policy 9.1 moves a repeat one tier up).
pub fn model_for(tier: u8) -> Option<&'static str> {
    match tier {
        2 => Some("sonnet"),
        3 => Some("haiku"),
        _ => None,
    }
}

/// Starts a session in `folder` that runs `prompt` to the end with
/// permissions skipped (the Mewo guard hook still refuses pushes to
/// main). Returns its pid; its output goes to `<state>/runs/<tag>-<ts>.log`.
pub fn spawn(folder: &str, prompt: &str, model: Option<&str>, tag: &str) -> Result<u32, String> {
    ready()?;
    let bin = claude_bin().ok_or_else(|| "Claude Code is not installed on this Mac".to_string())?;
    if !std::path::Path::new(folder).is_dir() {
        return Err(format!("No such folder on this Mac: {folder}"));
    }
    let dir = paths::state_dir().join("runs");
    let _ = fs::create_dir_all(&dir);
    let safe: String = tag.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let log = dir.join(format!("{safe}-{}.log", now_ms()));
    let out = File::create(&log).map_err(|e| e.to_string())?;
    let err = File::create(log.with_extension("err")).map_err(|e| e.to_string())?;
    let home = std::env::var("HOME").unwrap_or_default();
    let path = format!("{home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Library/Developer/CommandLineTools/usr/bin:{}", std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".to_string()));
    let mut cmd = Command::new(bin);
    cmd.current_dir(folder).arg("-p").arg(prompt).arg("--dangerously-skip-permissions").arg("--output-format").arg("text");
    if let Some(m) = model {
        cmd.arg("--model").arg(m);
    }
    cmd.env("PATH", path).env("MEWO_HEADLESS", "1").stdin(Stdio::null()).stdout(out).stderr(err);
    // Its own process group: a daemon restart must not take the session down.
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|e| format!("could not start claude: {e}"))?;
    let pid = child.id();
    // Reap it when it ends, and remember how it ended.
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        let mut g = EXITS.lock().unwrap_or_else(|p| p.into_inner());
        g.get_or_insert_with(HashMap::new).insert(pid, code);
    });
    Ok(pid)
}

/// Still running?
pub fn alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    if EXITS.lock().unwrap_or_else(|p| p.into_inner()).as_ref().map(|m| m.contains_key(&pid)).unwrap_or(false) {
        return false;
    }
    Command::new("kill").arg("-0").arg(pid.to_string()).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
}

/// How a run ended, when it did.
pub fn exit_code(pid: u32) -> Option<i32> {
    EXITS.lock().unwrap_or_else(|p| p.into_inner()).as_ref().and_then(|m| m.get(&pid).copied())
}

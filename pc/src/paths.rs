//! Well-known file locations (see PROTOCOL.md "PC files") and small fs helpers.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// `~/.config/ccnotify`
pub fn config_dir() -> PathBuf {
    home().join(".config").join("ccnotify")
}

/// `~/.local/state/ccnotify`
pub fn state_dir() -> PathBuf {
    home().join(".local").join("state").join("ccnotify")
}

pub fn config_file() -> PathBuf {
    config_dir().join("config.json")
}

pub fn cert_file() -> PathBuf {
    config_dir().join("cert.der")
}

pub fn key_file() -> PathBuf {
    config_dir().join("key.der")
}

pub fn devices_file() -> PathBuf {
    config_dir().join("devices.json")
}

pub fn events_file() -> PathBuf {
    state_dir().join("events.json")
}

pub fn sessions_file() -> PathBuf {
    state_dir().join("sessions.json")
}

/// `/tmp/ccnotify-$USER.sock`
fn tmp_socket_path() -> PathBuf {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| "user".to_string());
    PathBuf::from(format!("/tmp/ccnotify-{user}.sock"))
}

/// `$XDG_RUNTIME_DIR/ccnotify.sock`, fallback `/tmp/ccnotify-$USER.sock`.
#[cfg(not(target_os = "macos"))]
pub fn socket_path() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("ccnotify.sock"),
        _ => tmp_socket_path(),
    }
}

/// macOS: `~/.local/state/ccnotify/ccnotify.sock`. The daemon (launchd), the
/// CLI (a terminal) and the hooks (Claude Code in a terminal, or the Claude
/// desktop app) all run with different environments, so the path depends on
/// the home directory only. Fallback `/tmp/ccnotify-$USER.sock` when the home
/// path does not fit a socket address.
#[cfg(target_os = "macos")]
pub fn socket_path() -> PathBuf {
    /// `sockaddr_un.sun_path` holds 104 bytes including the NUL.
    const MAX_SOCKET_PATH_BYTES: usize = 103;
    let path = state_dir().join("ccnotify.sock");
    if path.as_os_str().len() <= MAX_SOCKET_PATH_BYTES {
        path
    } else {
        tmp_socket_path()
    }
}

/// `~/.local/bin/ccnotify`
pub fn installed_bin() -> PathBuf {
    home().join(".local").join("bin").join("ccnotify")
}

/// launchd label of the daemon's LaunchAgent.
#[cfg(target_os = "macos")]
pub const LAUNCHD_LABEL: &str = "com.torchcorp.ccnotify";

/// `~/Library/LaunchAgents/com.torchcorp.ccnotify.plist`
#[cfg(target_os = "macos")]
pub fn launch_agent() -> PathBuf {
    home()
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{LAUNCHD_LABEL}.plist"))
}

/// `~/Library/Logs/ccnotify.log` (the daemon's output under launchd).
#[cfg(target_os = "macos")]
pub fn log_file() -> PathBuf {
    home().join("Library").join("Logs").join("ccnotify.log")
}

/// `~/.config/systemd/user/ccnotify.service`
#[cfg(not(target_os = "macos"))]
pub fn systemd_unit() -> PathBuf {
    home()
        .join(".config")
        .join("systemd")
        .join("user")
        .join("ccnotify.service")
}

/// `~/.local/share/applications/ccnotify-tray.desktop`: the tray icon in the
/// desktop's application menu.
#[cfg(target_os = "linux")]
pub fn launcher_entry() -> PathBuf {
    home()
        .join(".local")
        .join("share")
        .join("applications")
        .join("ccnotify-tray.desktop")
}

/// `~/.config/autostart/ccnotify-tray.desktop`: starts the tray icon at login.
#[cfg(target_os = "linux")]
pub fn autostart_entry() -> PathBuf {
    home()
        .join(".config")
        .join("autostart")
        .join("ccnotify-tray.desktop")
}

/// `~/.claude/settings.json`
pub fn claude_settings() -> PathBuf {
    home().join(".claude").join("settings.json")
}

/// Write `data` to `path` atomically (temp file + rename) with the given mode.
/// Creates the parent directory if needed.
pub fn write_atomic(path: &Path, data: &[u8], mode: u32) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string());
    let tmp = path.with_file_name(format!(".{file_name}.tmp"));
    {
        let mut f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .open(&tmp)?;
        f.write_all(data)?;
        f.flush()?;
    }
    fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
    fs::rename(&tmp, path)
}

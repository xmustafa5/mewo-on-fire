//! Well-known file locations (see PROTOCOL.md "PC files") and small fs helpers.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"))
}

/// `~/.config/mewo-on-fire`
pub fn config_dir() -> PathBuf {
    home().join(".config").join("mewo-on-fire")
}

/// `~/.local/state/mewo-on-fire`
pub fn state_dir() -> PathBuf {
    home().join(".local").join("state").join("mewo-on-fire")
}

/// v3.1: true on the daemon's first start after the computer restarted
/// (the boot it remembers in `<state>/boot` is not this one). False when
/// it cannot tell: the first run, or a system that does not say.
pub fn restarted_since_last_start() -> bool {
    let now = if cfg!(target_os = "macos") {
        std::process::Command::new("sysctl").args(["-n", "kern.boottime"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
    } else {
        std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map(|s| s.trim().to_string()).unwrap_or_default()
    };
    if now.is_empty() {
        return false;
    }
    let file = state_dir().join("boot");
    let before = std::fs::read_to_string(&file).map(|s| s.trim().to_string()).unwrap_or_default();
    if before != now {
        let _ = std::fs::create_dir_all(state_dir());
        let _ = std::fs::write(&file, &now);
    }
    !before.is_empty() && before != now
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

pub fn console_file() -> PathBuf {
    state_dir().join("console.json")
}

/// `/tmp/mewo-on-fire-$USER.sock`
fn tmp_socket_path() -> PathBuf {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| "user".to_string());
    PathBuf::from(format!("/tmp/mewo-on-fire-{user}.sock"))
}

/// `$XDG_RUNTIME_DIR/mewo-on-fire.sock`, fallback `/tmp/mewo-on-fire-$USER.sock`.
#[cfg(not(target_os = "macos"))]
pub fn socket_path() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("mewo-on-fire.sock"),
        _ => tmp_socket_path(),
    }
}

/// macOS: `~/.local/state/mewo-on-fire/mewo-on-fire.sock`. The daemon (launchd), the
/// CLI (a terminal) and the hooks (Claude Code in a terminal, or the Claude
/// desktop app) all run with different environments, so the path depends on
/// the home directory only. Fallback `/tmp/mewo-on-fire-$USER.sock` when the home
/// path does not fit a socket address.
#[cfg(target_os = "macos")]
pub fn socket_path() -> PathBuf {
    /// `sockaddr_un.sun_path` holds 104 bytes including the NUL.
    const MAX_SOCKET_PATH_BYTES: usize = 103;
    let path = state_dir().join("mewo-on-fire.sock");
    if path.as_os_str().len() <= MAX_SOCKET_PATH_BYTES {
        path
    } else {
        tmp_socket_path()
    }
}

/// `~/.local/bin/mewo`
pub fn installed_bin() -> PathBuf {
    home().join(".local").join("bin").join("mewo")
}

/// launchd label of the daemon's LaunchAgent.
#[cfg(target_os = "macos")]
pub const LAUNCHD_LABEL: &str = "com.torchcorp.mewo-on-fire";

/// `~/Library/LaunchAgents/com.torchcorp.mewo-on-fire.plist`
#[cfg(target_os = "macos")]
pub fn launch_agent() -> PathBuf {
    home()
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{LAUNCHD_LABEL}.plist"))
}

/// `~/Library/Logs/mewo-on-fire.log` (the daemon's output under launchd).
#[cfg(target_os = "macos")]
pub fn log_file() -> PathBuf {
    home().join("Library").join("Logs").join("mewo-on-fire.log")
}

/// `~/.config/systemd/user/mewo-on-fire.service`
#[cfg(not(target_os = "macos"))]
pub fn systemd_unit() -> PathBuf {
    home()
        .join(".config")
        .join("systemd")
        .join("user")
        .join("mewo-on-fire.service")
}

/// `~/.local/share/applications/mewo-on-fire-tray.desktop`: the tray icon in the
/// desktop's application menu.
#[cfg(target_os = "linux")]
pub fn launcher_entry() -> PathBuf {
    home()
        .join(".local")
        .join("share")
        .join("applications")
        .join("mewo-on-fire-tray.desktop")
}

/// `~/.config/autostart/mewo-on-fire-tray.desktop`: starts the tray icon at login.
#[cfg(target_os = "linux")]
pub fn autostart_entry() -> PathBuf {
    home()
        .join(".config")
        .join("autostart")
        .join("mewo-on-fire-tray.desktop")
}

/// `~/.claude/settings.json`
pub fn claude_settings() -> PathBuf {
    home().join(".claude").join("settings.json")
}

// ---------------------------------------------------------------------------
// Before v0.2 the program was called ccnotify: where `mewo install` finds such
// an installation to move it over.
// ---------------------------------------------------------------------------

/// The old name of the command, the service and the folders.
pub const LEGACY_NAME: &str = "ccnotify";

/// `~/.config/ccnotify`
pub fn legacy_config_dir() -> PathBuf {
    home().join(".config").join(LEGACY_NAME)
}

/// `~/.local/state/ccnotify`
pub fn legacy_state_dir() -> PathBuf {
    home().join(".local").join("state").join(LEGACY_NAME)
}

/// `~/.local/bin/ccnotify`
pub fn legacy_installed_bin() -> PathBuf {
    home().join(".local").join("bin").join(LEGACY_NAME)
}

/// `~/.config/systemd/user/ccnotify.service`
#[cfg(not(target_os = "macos"))]
pub fn legacy_systemd_unit() -> PathBuf {
    systemd_unit().with_file_name(format!("{LEGACY_NAME}.service"))
}

#[cfg(target_os = "macos")]
pub const LEGACY_LAUNCHD_LABEL: &str = "com.torchcorp.ccnotify";

/// `~/Library/LaunchAgents/com.torchcorp.ccnotify.plist`
#[cfg(target_os = "macos")]
pub fn legacy_launch_agent() -> PathBuf {
    launch_agent().with_file_name(format!("{LEGACY_LAUNCHD_LABEL}.plist"))
}

/// `~/.local/share/applications/ccnotify-tray.desktop`
#[cfg(target_os = "linux")]
pub fn legacy_launcher_entry() -> PathBuf {
    launcher_entry().with_file_name(format!("{LEGACY_NAME}-tray.desktop"))
}

/// `~/.config/autostart/ccnotify-tray.desktop`
#[cfg(target_os = "linux")]
pub fn legacy_autostart_entry() -> PathBuf {
    autostart_entry().with_file_name(format!("{LEGACY_NAME}-tray.desktop"))
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

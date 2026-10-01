//! `ccnotify install` / `ccnotify uninstall`: binary, background service
//! (systemd user unit on Linux, launchd LaunchAgent on macOS) and Claude Code
//! hooks in ~/.claude/settings.json.

use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};

use crate::config;
use crate::paths;

const NOTIFICATION_MATCHER: &str =
    "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog";
/// `ccnotify hook` (async). UserPromptSubmit: PROTOCOL.md v1.2 session state.
const HOOK_EVENTS: [&str; 4] = ["Stop", "Notification", "SessionEnd", "UserPromptSubmit"];
/// PROTOCOL.md v1.1: answer prompts from the phone (`ccnotify ask`, blocking).
const ASK_EVENT: &str = "PermissionRequest";
const ASK_TIMEOUT_SECS: u64 = 86_400;
/// PROTOCOL.md v1.2: continue the session from the phone (`ccnotify listen`,
/// async + asyncRewake Stop hook).
const LISTEN_EVENT: &str = "Stop";
const LISTEN_TIMEOUT_SECS: u64 = 86_400;

#[cfg(not(target_os = "macos"))]
const UNIT_FILE: &str = "[Unit]
Description=ccnotify - Claude Code notifications to your phone over LAN

[Service]
Type=simple
ExecStart=%h/.local/bin/ccnotify daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
";

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

pub fn install() -> Result<()> {
    let (bin, replaced) = install_binary()?;
    install_service(replaced)?;
    install_hooks(&bin)?;
    #[cfg(target_os = "linux")]
    match crate::tray::install_launcher(&bin) {
        Ok(()) => println!(
            "Tray:     \"ccnotify\" added to the application menu (or run `ccnotify tray`)"
        ),
        Err(e) => println!("Tray:     skipped ({e:#})"),
    }

    println!();
    print_firewall_hint(config::configured_port());
    println!();
    println!("Next: run `ccnotify pair`");
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn print_firewall_hint(port: u16) {
    println!("Firewall: if the phone cannot connect, allow the port:");
    println!("  ufw:        sudo ufw allow {port}/tcp");
    println!(
        "  firewalld:  sudo firewall-cmd --permanent --add-port={port}/tcp --add-service=mdns && sudo firewall-cmd --reload"
    );
}

#[cfg(target_os = "macos")]
fn print_firewall_hint(port: u16) {
    let bin = paths::installed_bin();
    let bin = bin.display();
    println!("Firewall: if the phone cannot connect (TCP port {port}) and the macOS firewall is on");
    println!("  (System Settings > Network > Firewall), allow incoming connections:");
    println!("  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add {bin}");
    println!("  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp {bin}");
    println!("If macOS asks whether ccnotify may find devices on your local network, allow it.");
}

/// Copy the running executable to ~/.local/bin/ccnotify (skipped when it is
/// already that file). Returns (installed path, whether it was replaced).
fn install_binary() -> Result<(PathBuf, bool)> {
    let dst = paths::installed_bin();
    let src = std::env::current_exe().context("locating the current executable")?;

    let same = match (fs::canonicalize(&src), fs::canonicalize(&dst)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    };
    if same {
        println!("Binary:   {} (already in place)", dst.display());
        return Ok((dst, false));
    }

    let dir = dst
        .parent()
        .ok_or_else(|| anyhow!("invalid install path {}", dst.display()))?;
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    // Copy to a temp file then rename, so replacing a running binary works.
    let tmp = dir.join(".ccnotify.install.tmp");
    fs::copy(&src, &tmp)
        .with_context(|| format!("copying {} to {}", src.display(), tmp.display()))?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))?;
    fs::rename(&tmp, &dst).with_context(|| format!("installing {}", dst.display()))?;
    println!("Binary:   installed {}", dst.display());

    if let Some(path_var) = std::env::var_os("PATH") {
        let on_path = std::env::split_paths(&path_var).any(|p| p.as_path() == dir);
        if !on_path {
            println!(
                "          note: {} is not on your PATH; use the full path or add it.",
                dir.display()
            );
        }
    }
    Ok((dst, true))
}

// ---------------------------------------------------------------------------
// service: systemd (Linux)
// ---------------------------------------------------------------------------

/// Shell command that starts the installed service (for hints).
#[cfg(not(target_os = "macos"))]
pub fn start_command() -> String {
    "systemctl --user start ccnotify".to_string()
}

/// Shell command that restarts the installed service (for hints).
#[cfg(not(target_os = "macos"))]
pub fn restart_command() -> String {
    "systemctl --user restart ccnotify".to_string()
}

/// Run `systemctl --user <args>`. Err(NotFound) if systemctl is missing.
#[cfg(not(target_os = "macos"))]
fn systemctl(args: &[&str]) -> std::io::Result<bool> {
    let status = Command::new("systemctl").arg("--user").args(args).status()?;
    Ok(status.success())
}

#[cfg(not(target_os = "macos"))]
fn print_manual_daemon_hint() {
    println!("          Run the daemon manually instead (e.g. from your session autostart):");
    println!("            {} daemon", paths::installed_bin().display());
}

/// Starting the service returns before the daemon binds its socket, so poll
/// `status` for up to 3 s; otherwise an immediate `ccnotify pair` races it.
fn wait_for_daemon() -> bool {
    let timeout = std::time::Duration::from_millis(300);
    for _ in 0..30 {
        if crate::control::request(&json!({"cmd": "status"}), timeout).is_ok() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    false
}

#[cfg(not(target_os = "macos"))]
fn install_service(binary_replaced: bool) -> Result<()> {
    let unit = paths::systemd_unit();
    paths::write_atomic(&unit, UNIT_FILE.as_bytes(), 0o644)
        .with_context(|| format!("writing {}", unit.display()))?;
    println!("Service:  wrote {}", unit.display());

    match systemctl(&["daemon-reload"]) {
        Err(e) if e.kind() == ErrorKind::NotFound => {
            println!("Service:  systemctl not found; the service was not started.");
            print_manual_daemon_hint();
            return Ok(());
        }
        Err(e) => {
            println!("Service:  could not run systemctl ({e}); the service was not started.");
            print_manual_daemon_hint();
            return Ok(());
        }
        Ok(false) => {
            println!("Service:  `systemctl --user daemon-reload` failed (no user systemd session?).");
            print_manual_daemon_hint();
            return Ok(());
        }
        Ok(true) => {}
    }

    match systemctl(&["enable", "--now", "ccnotify"]) {
        Ok(true) => {
            if binary_replaced {
                // Make an already-running daemon pick up the new binary.
                let _ = systemctl(&["restart", "ccnotify"]);
            }
            if wait_for_daemon() {
                println!("Service:  enabled and started (systemctl --user status ccnotify)");
            } else {
                println!("Service:  enabled, but the daemon is not answering yet.");
                println!("          Check: journalctl --user -u ccnotify");
            }
        }
        _ => {
            println!("Service:  `systemctl --user enable --now ccnotify` failed.");
            println!("          Check: journalctl --user -u ccnotify");
            print_manual_daemon_hint();
        }
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn uninstall_service() -> Result<()> {
    let unit = paths::systemd_unit();
    match systemctl(&["disable", "--now", "ccnotify"]) {
        Ok(true) => println!("Service:  stopped and disabled"),
        Ok(false) => println!("Service:  was not enabled/running (nothing to stop)"),
        Err(e) if e.kind() == ErrorKind::NotFound => {
            println!("Service:  systemctl not found; stop any `ccnotify daemon` you started manually.")
        }
        Err(e) => println!("Service:  could not run systemctl ({e})"),
    }
    if unit.exists() {
        fs::remove_file(&unit).with_context(|| format!("removing {}", unit.display()))?;
        println!("Service:  removed {}", unit.display());
    }
    let _ = systemctl(&["daemon-reload"]);
    Ok(())
}

// ---------------------------------------------------------------------------
// service: launchd LaunchAgent (macOS)
// ---------------------------------------------------------------------------

/// The user's GUI launchd domain: `gui/<uid>`.
#[cfg(target_os = "macos")]
fn launchd_domain() -> String {
    // SAFETY: getuid() has no preconditions and cannot fail.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// `gui/<uid>/com.torchcorp.ccnotify`
#[cfg(target_os = "macos")]
fn launchd_target() -> String {
    format!("{}/{}", launchd_domain(), paths::LAUNCHD_LABEL)
}

/// Shell command that starts the installed service (for hints).
#[cfg(target_os = "macos")]
pub fn start_command() -> String {
    format!("launchctl kickstart {}", launchd_target())
}

/// Shell command that restarts the installed service (for hints).
#[cfg(target_os = "macos")]
pub fn restart_command() -> String {
    format!("launchctl kickstart -k {}", launchd_target())
}

#[cfg(target_os = "macos")]
fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The LaunchAgent: start at login, restart after a crash (not after a clean
/// exit), output appended to ~/Library/Logs/ccnotify.log.
#[cfg(target_os = "macos")]
fn launch_agent_plist() -> String {
    let bin = xml_escape(&paths::installed_bin().to_string_lossy());
    let log = xml_escape(&paths::log_file().to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{bin}</string>
		<string>daemon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#,
        label = paths::LAUNCHD_LABEL,
    )
}

/// Run `launchctl <args>` quietly. Ok(()) on success, else its error output.
#[cfg(target_os = "macos")]
fn launchctl(args: &[&str]) -> std::result::Result<(), String> {
    let out = Command::new("/bin/launchctl")
        .args(args)
        .output()
        .map_err(|e| format!("could not run launchctl: {e}"))?;
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let reason = stderr.lines().map(str::trim).find(|l| !l.is_empty());
    Err(match reason {
        Some(line) => line.to_string(),
        None => format!("launchctl exited with {}", out.status),
    })
}

#[cfg(target_os = "macos")]
fn launchd_loaded(target: &str) -> bool {
    launchctl(&["print", target]).is_ok()
}

/// `launchctl bootout` returns before the service is gone, and a `bootstrap`
/// that races it fails: wait for up to 5 s.
#[cfg(target_os = "macos")]
fn wait_unloaded(target: &str) {
    for _ in 0..50 {
        if !launchd_loaded(target) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

#[cfg(target_os = "macos")]
fn install_service(binary_replaced: bool) -> Result<()> {
    let plist = paths::launch_agent();
    let text = launch_agent_plist();
    let changed = fs::read_to_string(&plist).map(|old| old != text).unwrap_or(true);
    if changed {
        paths::write_atomic(&plist, text.as_bytes(), 0o644)
            .with_context(|| format!("writing {}", plist.display()))?;
        println!("Service:  wrote {}", plist.display());
    } else {
        println!("Service:  {} (already in place)", plist.display());
    }
    // launchd does not create the directory of the log file.
    if let Some(dir) = paths::log_file().parent() {
        let _ = fs::create_dir_all(dir);
    }

    let domain = launchd_domain();
    let target = launchd_target();
    let started = if launchd_loaded(&target) && !changed {
        // Loaded from this plist: start it if it is not running; `-k` makes
        // an already-running daemon pick up the new binary.
        if binary_replaced {
            launchctl(&["kickstart", "-k", &target])
        } else {
            launchctl(&["kickstart", &target])
        }
    } else {
        if launchd_loaded(&target) {
            let _ = launchctl(&["bootout", &target]);
            wait_unloaded(&target);
        }
        // An earlier `launchctl disable` would make bootstrap fail.
        let _ = launchctl(&["enable", &target]);
        launchctl(&["bootstrap", &domain, &plist.to_string_lossy()])
    };

    match started {
        Ok(()) => {
            if wait_for_daemon() {
                println!("Service:  loaded and started (launchctl print {target})");
            } else {
                println!("Service:  loaded, but the daemon is not answering yet.");
            }
            println!("          Log: {}", paths::log_file().display());
        }
        Err(reason) => {
            println!("Service:  launchctl could not start the LaunchAgent ({reason}).");
            println!("          It is loaded at your next desktop login. Until then, run the daemon yourself:");
            println!("            {} daemon", paths::installed_bin().display());
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn uninstall_service() -> Result<()> {
    let target = launchd_target();
    if launchd_loaded(&target) {
        match launchctl(&["bootout", &target]) {
            Ok(()) => println!("Service:  stopped and unloaded"),
            Err(reason) => println!("Service:  launchctl bootout failed ({reason})"),
        }
    } else {
        println!("Service:  was not loaded (nothing to stop)");
    }
    let plist = paths::launch_agent();
    if plist.exists() {
        fs::remove_file(&plist).with_context(|| format!("removing {}", plist.display()))?;
        println!("Service:  removed {}", plist.display());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// ~/.claude/settings.json
// ---------------------------------------------------------------------------

/// `<bin> <subcommand>`, quoting the binary path if it contains whitespace.
pub(crate) fn bin_command(bin: &Path, subcommand: &str) -> String {
    let p = bin.to_string_lossy();
    if p.chars().any(char::is_whitespace) {
        format!("\"{p}\" {subcommand}")
    } else {
        format!("{p} {subcommand}")
    }
}

/// True if `cmd` runs `ccnotify <subcommand>`.
fn command_runs(cmd: &str, subcommand: &str) -> bool {
    cmd.contains(&format!("ccnotify {subcommand}"))
        || cmd.contains(&format!("ccnotify\" {subcommand}"))
}

fn is_ccnotify_command(cmd: &str) -> bool {
    command_runs(cmd, "hook") || command_runs(cmd, "ask") || command_runs(cmd, "listen")
}

fn hook_command_str(hook: &Value) -> &str {
    hook.get("command").and_then(Value::as_str).unwrap_or("")
}

fn hook_is_ccnotify(hook: &Value) -> bool {
    is_ccnotify_command(hook_command_str(hook))
}

/// True if the group has a hook running `ccnotify <subcommand>`.
fn group_runs(group: &Value, subcommand: &str) -> bool {
    group
        .get("hooks")
        .and_then(Value::as_array)
        .map(|hooks| {
            hooks
                .iter()
                .any(|h| command_runs(hook_command_str(h), subcommand))
        })
        .unwrap_or(false)
}

/// Read settings.json (missing or empty file → `{}`).
fn read_settings(path: &Path) -> Result<(Value, bool)> {
    match fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Ok((json!({}), true)),
        Ok(text) => {
            let v: Value = serde_json::from_str(&text).with_context(|| {
                format!("{} is not valid JSON; fix it and retry", path.display())
            })?;
            if !v.is_object() {
                bail!("{} is not a JSON object", path.display());
            }
            Ok((v, true))
        }
        Err(e) if e.kind() == ErrorKind::NotFound => Ok((json!({}), false)),
        Err(e) => Err(anyhow!("reading {}: {e}", path.display())),
    }
}

/// Back up the existing settings file, then write the new content
/// (preserving the original file mode).
fn write_settings(path: &Path, settings: &Value, existed: bool) -> Result<()> {
    let mut mode = 0o644;
    if existed {
        let backup = path.with_file_name("settings.json.bak-ccnotify");
        fs::copy(path, &backup)
            .with_context(|| format!("backing up {} to {}", path.display(), backup.display()))?;
        println!("Hooks:    backup saved to {}", backup.display());
        if let Ok(meta) = fs::metadata(path) {
            mode = meta.permissions().mode() & 0o777;
        }
    }
    let mut text = serde_json::to_string_pretty(settings)?;
    text.push('\n');
    paths::write_atomic(path, text.as_bytes(), mode)
        .with_context(|| format!("writing {}", path.display()))
}

/// Append our hook groups (idempotent per event and subcommand: an event that
/// already runs that subcommand is left alone). Returns what was added.
fn merge_hooks(settings: &mut Value, bin: &Path) -> Result<Vec<&'static str>> {
    let hook_cmd = bin_command(bin, "hook");
    let ask_cmd = bin_command(bin, "ask");
    let listen_cmd = bin_command(bin, "listen");
    let root = settings
        .as_object_mut()
        .ok_or_else(|| anyhow!("settings.json is not a JSON object"))?;
    let hooks = root
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    let hooks = hooks
        .as_object_mut()
        .ok_or_else(|| anyhow!("\"hooks\" in settings.json is not an object"))?;

    let mut added = Vec::new();
    for event in HOOK_EVENTS {
        let groups = hooks
            .entry(event)
            .or_insert_with(|| Value::Array(Vec::new()));
        let groups = groups
            .as_array_mut()
            .ok_or_else(|| anyhow!("\"hooks.{event}\" in settings.json is not an array"))?;
        if groups.iter().any(|g| group_runs(g, "hook")) {
            continue;
        }
        let mut group = Map::new();
        if event == "Notification" {
            group.insert("matcher".to_string(), json!(NOTIFICATION_MATCHER));
        }
        group.insert(
            "hooks".to_string(),
            json!([{"type": "command", "command": hook_cmd, "async": true}]),
        );
        groups.push(Value::Object(group));
        added.push(event);
    }

    // Not async: Claude Code waits for the phone's decision.
    let groups = hooks
        .entry(ASK_EVENT)
        .or_insert_with(|| Value::Array(Vec::new()));
    let groups = groups
        .as_array_mut()
        .ok_or_else(|| anyhow!("\"hooks.{}\" in settings.json is not an array", ASK_EVENT))?;
    if !groups.iter().any(|g| group_runs(g, "ask")) {
        let mut group = Map::new();
        group.insert("matcher".to_string(), json!("*"));
        group.insert(
            "hooks".to_string(),
            json!([{"type": "command", "command": ask_cmd, "timeout": ASK_TIMEOUT_SECS}]),
        );
        groups.push(Value::Object(group));
        added.push(ASK_EVENT);
    }

    // Runs in the background; exit code 2 wakes Claude with the phone's message.
    let groups = hooks
        .entry(LISTEN_EVENT)
        .or_insert_with(|| Value::Array(Vec::new()));
    let groups = groups.as_array_mut().ok_or_else(|| {
        anyhow!("\"hooks.{}\" in settings.json is not an array", LISTEN_EVENT)
    })?;
    if !groups.iter().any(|g| group_runs(g, "listen")) {
        groups.push(json!({
            "hooks": [{
                "type": "command",
                "command": listen_cmd,
                "async": true,
                "asyncRewake": true,
                "timeout": LISTEN_TIMEOUT_SECS,
            }]
        }));
        added.push("Stop (listen)");
    }
    Ok(added)
}

/// Remove every hook whose command runs `ccnotify hook`, `ccnotify ask` or
/// `ccnotify listen`.
/// Groups that become empty are dropped, then event keys that become empty
/// arrays.
fn remove_hooks(settings: &mut Value) -> usize {
    let hooks = match settings.get_mut("hooks").and_then(Value::as_object_mut) {
        Some(h) => h,
        None => return 0,
    };
    let mut removed_total = 0usize;
    let keys: Vec<String> = hooks.keys().cloned().collect();
    for key in keys {
        let mut emptied_by_us = false;
        if let Some(groups) = hooks.get_mut(&key).and_then(Value::as_array_mut) {
            let mut changed = false;
            groups.retain_mut(|group| {
                let inner = match group.get_mut("hooks").and_then(Value::as_array_mut) {
                    Some(inner) => inner,
                    None => return true,
                };
                let before = inner.len();
                inner.retain(|h| !hook_is_ccnotify(h));
                let removed = before - inner.len();
                if removed == 0 {
                    return true;
                }
                removed_total += removed;
                changed = true;
                !inner.is_empty()
            });
            emptied_by_us = changed && groups.is_empty();
        }
        if emptied_by_us {
            hooks.shift_remove(key.as_str());
        }
    }
    removed_total
}

/// ~/.claude/settings.json, following a symlink (dotfile managers) so the
/// real file is edited instead of being replaced.
fn settings_path() -> PathBuf {
    let path = paths::claude_settings();
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_symlink() => fs::canonicalize(&path).unwrap_or(path),
        _ => path,
    }
}

fn install_hooks(bin: &Path) -> Result<()> {
    let path = settings_path();
    let (mut settings, existed) = read_settings(&path)?;
    let added = merge_hooks(&mut settings, bin)?;
    if added.is_empty() {
        println!("Hooks:    already present in {}", path.display());
        return Ok(());
    }
    write_settings(&path, &settings, existed)?;
    println!(
        "Hooks:    added {} to {} (commands: {} / {} / {})",
        added.join(", "),
        path.display(),
        bin_command(bin, "hook"),
        bin_command(bin, "ask"),
        bin_command(bin, "listen")
    );
    Ok(())
}

// ---------------------------------------------------------------------------
// uninstall
// ---------------------------------------------------------------------------

pub fn uninstall() -> Result<()> {
    // Hooks first, so Claude Code stops calling us even if the service part fails.
    let path = settings_path();
    match read_settings(&path) {
        Ok((mut settings, true)) => {
            let removed = remove_hooks(&mut settings);
            if removed > 0 {
                write_settings(&path, &settings, true)?;
                println!("Hooks:    removed {removed} ccnotify hook(s) from {}", path.display());
            } else {
                println!("Hooks:    none found in {}", path.display());
            }
        }
        Ok((_, false)) => println!("Hooks:    {} does not exist", path.display()),
        Err(e) => println!("Hooks:    skipped ({e:#})"),
    }

    uninstall_service()?;
    #[cfg(target_os = "linux")]
    for path in crate::tray::remove_entries() {
        println!("Tray:     removed {}", path.display());
    }

    println!();
    println!("Kept (delete manually for a full removal):");
    println!("  config + pairing: {}", paths::config_dir().display());
    println!("  event history:    {}", paths::state_dir().display());
    println!("  binary:           {}", paths::installed_bin().display());
    Ok(())
}

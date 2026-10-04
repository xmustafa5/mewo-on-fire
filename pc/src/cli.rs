//! User-facing CLI commands that talk to the running daemon.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use qrcode::render::unicode::Dense1x2;
use qrcode::{EcLevel, QrCode};
use serde_json::{json, Value};

use crate::ask;
use crate::config::now_ms;
use crate::control;
use crate::install;
use crate::paths;

const CLI_TIMEOUT: Duration = Duration::from_secs(3);
/// `sessions` / `chat` may read transcripts (up to 4 MB each).
const TRANSCRIPT_TIMEOUT: Duration = Duration::from_secs(15);
const PAIR_WAIT: Duration = Duration::from_secs(300);
const CHAT_ITEMS: u64 = 20;

fn not_running_hint() -> String {
    format!(
        "The Mewo on Fire daemon is not running (no answer on {}).\n\
         Start it with:   {}\n\
         Or install it:   mewo install\n\
         Or run it in a terminal:   mewo daemon",
        paths::socket_path().display(),
        install::start_command()
    )
}

fn too_old_hint() -> String {
    format!(
        "the running daemon is too old for this; restart it: {}",
        install::restart_command()
    )
}

/// Send a request to the daemon; turn transport errors into a friendly hint and
/// `{"ok":false}` into an error.
fn call(req: &Value) -> Result<Value> {
    call_with(req, CLI_TIMEOUT)
}

fn call_with(req: &Value, timeout: Duration) -> Result<Value> {
    let resp = control::request(req, timeout)
        .map_err(|e| anyhow!("{}\n({e:#})", not_running_hint()))?;
    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        let err = resp
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        if err == "unknown_cmd" {
            bail!("{}", too_old_hint());
        }
        bail!("daemon error: {err}");
    }
    Ok(resp)
}

fn str_field<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn u64_field(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn device_ids(resp: &Value) -> HashSet<String> {
    resp.get("devices")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|d| str_field(d, "id").to_string())
                .collect()
        })
        .unwrap_or_default()
}

fn render_qr(payload: &str) -> Result<String> {
    let code = QrCode::with_error_correction_level(payload.as_bytes(), EcLevel::L)?;
    // Inverted: light modules (and the quiet zone) are drawn as blocks so the
    // code scans on dark terminal backgrounds.
    Ok(code
        .render::<Dense1x2>()
        .dark_color(Dense1x2::Light)
        .light_color(Dense1x2::Dark)
        .quiet_zone(true)
        .build())
}

pub fn pair() -> Result<()> {
    let before = device_ids(&call(&json!({"cmd": "devices"}))?);
    let resp = call(&json!({"cmd": "pair"}))?;
    let payload = str_field(&resp, "qr").to_string();
    if payload.is_empty() {
        bail!("daemon returned an empty pairing payload");
    }

    let qr = render_qr(&payload)?;
    println!();
    println!("Scan this QR code with the Mewo on Fire app:");
    println!();
    println!("{qr}");
    println!();
    println!("Or paste this into the app:");
    println!("{payload}");
    println!();

    if let Ok(parsed) = serde_json::from_str::<Value>(&payload) {
        let hosts: Vec<&str> = parsed
            .get("hosts")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        if hosts.is_empty() {
            println!("Warning: no LAN IPv4 address found; the phone will have to find this PC via mDNS.");
        } else {
            println!("PC addresses: {}", hosts.join(", "));
        }
    }
    let expires = u64_field(&resp, "expires_in").max(1);
    println!(
        "Code expires in {} minutes. Waiting for the phone to pair... (Ctrl+C to cancel)",
        expires.div_ceil(60)
    );

    let deadline = Instant::now() + PAIR_WAIT.min(Duration::from_secs(expires));
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(1));
        let resp = match control::request(&json!({"cmd": "devices"}), CLI_TIMEOUT) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let new: Vec<&Value> = resp
            .get("devices")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter(|d| !before.contains(str_field(d, "id")))
                    .collect()
            })
            .unwrap_or_default();
        if let Some(dev) = new.first() {
            println!();
            println!(
                "Paired with {} (device id {})",
                str_field(dev, "name"),
                str_field(dev, "id")
            );
            return Ok(());
        }
    }
    bail!("pairing code expired; run `mewo pair` again")
}

pub fn devices() -> Result<()> {
    let resp = call(&json!({"cmd": "devices"}))?;
    let list = resp
        .get("devices")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        println!("No paired devices. Run `mewo pair` to add one.");
        return Ok(());
    }
    let name_width = list
        .iter()
        .map(|d| str_field(d, "name").chars().count())
        .max()
        .unwrap_or(4)
        .max(4);
    println!("{:<10}{:<w$}  PAIRED", "ID", "NAME", w = name_width);
    for d in &list {
        println!(
            "{:<10}{:<w$}  {}",
            str_field(d, "id"),
            str_field(d, "name"),
            format_ms(u64_field(d, "created")),
            w = name_width
        );
    }
    println!();
    println!("Revoke a device with: mewo revoke <ID>");
    Ok(())
}

pub fn revoke(id: &str) -> Result<()> {
    let resp = control::request(&json!({"cmd": "revoke", "id": id}), CLI_TIMEOUT)
        .map_err(|e| anyhow!("{}\n({e:#})", not_running_hint()))?;
    if resp.get("ok").and_then(Value::as_bool) == Some(true) {
        println!("Revoked device {id}. It will be disconnected and can no longer connect.");
        return Ok(());
    }
    match str_field(&resp, "error") {
        "not_found" => bail!("no paired device with id {id} (see `mewo devices`)"),
        other => bail!("daemon error: {other}"),
    }
}

pub fn status() -> Result<()> {
    let resp = call(&json!({"cmd": "status"}))?;
    let hosts: Vec<String> = resp
        .get("hosts")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    // The relay is listed with the addresses for the phones; here it gets a
    // line of its own.
    let hosts: Vec<String> = hosts.into_iter().filter(|h| !h.contains("://")).collect();
    println!("Mewo on Fire daemon: running");
    println!(
        "  PC name:      {} (id {})",
        str_field(&resp, "name"),
        str_field(&resp, "pc_id")
    );
    println!("  Port:         {}", u64_field(&resp, "port"));
    println!(
        "  Addresses:    {}",
        if hosts.is_empty() {
            "(none found)".to_string()
        } else {
            hosts.join(", ")
        }
    );
    let relay = str_field(&resp, "relay");
    if !relay.is_empty() {
        let up = resp.get("relay_up").and_then(Value::as_bool).unwrap_or(false);
        println!(
            "  Relay:        {relay} ({})",
            if up { "connected" } else { "not connected" }
        );
    }
    println!("  Cert SHA-256: {}", str_field(&resp, "fp"));
    println!(
        "  Devices:      {} paired, {} connected",
        u64_field(&resp, "devices"),
        u64_field(&resp, "connected")
    );
    println!("  Last event:   #{}", u64_field(&resp, "last_id"));
    println!(
        "  Pending:      {} request(s) waiting for an answer",
        u64_field(&resp, "pending")
    );
    println!(
        "  Sessions:     {} known, {} listening for phone messages",
        u64_field(&resp, "sessions"),
        u64_field(&resp, "listening")
    );
    println!("  Socket:       {}", paths::socket_path().display());
    Ok(())
}

/// `mewo relay <url>` / `mewo relay off`: where phones outside the
/// LAN connect through. Paired phones learn it the next time they connect.
pub fn relay(url: &str) -> Result<()> {
    let off = matches!(url, "off" | "none" | "");
    if !off && !(url.starts_with("wss://") || url.starts_with("ws://")) {
        bail!("a relay address starts with wss:// (got {url})");
    }
    let cfg = crate::config::set_relay(if off { "" } else { url })?;
    if off {
        println!("Relay removed: phones connect on the local network only.");
    } else {
        println!("Relay set to {}.", cfg.relay);
    }
    // The daemon reads its config when it starts.
    let restart = install::restart_command();
    let restarted = std::process::Command::new("sh")
        .arg("-c")
        .arg(&restart)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if restarted {
        println!("Daemon restarted. `mewo status` shows the relay.");
    } else {
        println!("Restart the daemon to apply it: {restart}");
    }
    Ok(())
}

/// `mewo suggestions on|off`. The hooks read the setting on every
/// prompt, so it applies from the next one.
pub fn suggestions(on: bool) -> Result<()> {
    crate::config::set_suggestions(on)?;
    if on {
        println!("Suggestions on: Claude ends its replies with suggested next messages,");
        println!("which the app shows as buttons. It applies from your next prompt.");
    } else {
        println!("Suggestions off.");
    }
    Ok(())
}

pub fn test() -> Result<()> {
    let cwd = std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let event = json!({
        "kind": "stop",
        "project": "mewo-on-fire",
        "cwd": cwd,
        "session": "test",
        "message": "Test notification from Mewo on Fire",
        "detail": "",
    });
    call(&json!({"cmd": "emit", "event": event}))?;
    let connected = call(&json!({"cmd": "status"}))
        .map(|s| u64_field(&s, "connected"))
        .unwrap_or(0);
    println!("Sent test notification ({connected} device(s) connected right now).");
    Ok(())
}

/// Send a fake Bash permission request through the same path as the `ask`
/// hook, wait for the phone's answer and print it with the hook output it
/// would produce.
pub fn test_ask() -> Result<()> {
    let cwd = std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let hook_input = json!({
        "hook_event_name": "PermissionRequest",
        "session_id": "test",
        "cwd": cwd,
        "tool_name": "Bash",
        "tool_input": {
            "command": "echo hello from Mewo on Fire",
            "description": "Test request from `mewo test-ask`",
        },
        "permission_suggestions": [{
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "echo hello from Mewo on Fire"}],
            "behavior": "allow",
            "destination": "localSettings",
        }],
    });
    let request = ask::map_request(&hook_input);

    println!("Sending a test permission request (Bash: echo hello from Mewo on Fire)...");
    println!("Answer it on the phone (Ctrl+C to cancel).");
    let resp = ask::ask_daemon(&request, "")
        .map_err(|e| anyhow!("{}\n({e:#})", not_running_hint()))?;

    if let Some(answer) = ask::reply_answer(&resp) {
        println!("Answer:      {answer}");
        match ask::hook_output(&hook_input, answer) {
            Some(out) => println!("Hook output: {out}"),
            None => println!("Hook output: (none; the answer does not fit, Claude Code would show its prompt)"),
        }
        return Ok(());
    }
    match str_field(&resp, "error") {
        "no_devices" => {
            println!("No phone connected; the hook would fall back to the normal prompt.");
            Ok(())
        }
        "unknown_cmd" => bail!("{}", too_old_hint()),
        "" => bail!("daemon error: unknown error"),
        other => bail!("daemon error: {other}"),
    }
}

/// List the Claude Code sessions the daemon knows (PROTOCOL.md v1.2).
pub fn sessions() -> Result<()> {
    let resp = call_with(&json!({"cmd": "sessions"}), TRANSCRIPT_TIMEOUT)?;
    let list = resp
        .get("sessions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        println!("No sessions yet. They appear after the next prompt or reply in Claude Code");
        println!("(run `mewo install` once so the v1.2 hooks are in place).");
        return Ok(());
    }
    let now = now_ms();
    let mut any_read_only = false;
    println!(
        "{:<10}{:<10}{:<8}{:<8}{:<10}PROJECT / TITLE",
        "SESSION", "STATE", "LISTEN", "QUEUED", "ACTIVE"
    );
    for s in &list {
        let mut state = str_field(s, "state").to_string();
        if s.get("read_only").and_then(Value::as_bool) == Some(true) {
            state.push('*');
            any_read_only = true;
        }
        let listening = s.get("listening").and_then(Value::as_bool) == Some(true);
        println!(
            "{:<10}{:<10}{:<8}{:<8}{:<10}{} / {}",
            str_field(s, "short"),
            state,
            if listening { "yes" } else { "-" },
            u64_field(s, "queued"),
            ago(now, u64_field(s, "last_ts")),
            str_field(s, "project"),
            str_field(s, "title")
        );
    }
    println!();
    if any_read_only {
        println!("* read-only: Claude is running agents at high effort");
    }
    println!("Show a session's chat with: mewo chat <SESSION>");
    Ok(())
}

/// Print the last chat items of the session whose id starts with `prefix`.
pub fn chat(prefix: &str) -> Result<()> {
    let resp = control::request(
        &json!({"cmd": "chat", "session": prefix, "limit": CHAT_ITEMS}),
        TRANSCRIPT_TIMEOUT,
    )
    .map_err(|e| anyhow!("{}\n({e:#})", not_running_hint()))?;
    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        match str_field(&resp, "error") {
            "not_found" => bail!("no session id starts with {prefix} (see `mewo sessions`)"),
            "ambiguous" => bail!("{prefix} matches several sessions; use more characters"),
            "unknown_cmd" => bail!("{}", too_old_hint()),
            "" => bail!("daemon error: unknown error"),
            other => bail!("daemon error: {other}"),
        }
    }
    let empty = json!({});
    let session = resp.get("session").unwrap_or(&empty);
    let mut flags: Vec<String> = Vec::new();
    if session.get("listening").and_then(Value::as_bool) == Some(true) {
        flags.push("listening".to_string());
    }
    if session.get("read_only").and_then(Value::as_bool) == Some(true) {
        flags.push("read-only".to_string());
    }
    let queued = u64_field(session, "queued");
    if queued > 0 {
        flags.push(format!("{queued} queued"));
    }
    println!(
        "{} ({} · {})",
        str_field(session, "title"),
        str_field(session, "project"),
        str_field(session, "id")
    );
    println!(
        "State: {}{}",
        str_field(session, "state"),
        if flags.is_empty() {
            String::new()
        } else {
            format!(" ({})", flags.join(", "))
        }
    );
    println!();

    let items = resp
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if items.is_empty() {
        println!("(no messages)");
        return Ok(());
    }
    for item in &items {
        let time = format_hm(u64_field(item, "ts"));
        let text = str_field(item, "text");
        let who = match str_field(item, "role") {
            "user" => "you",
            "assistant" => "claude",
            "phone" => "you (phone)",
            "tool" => {
                println!("{time}  [{}] {}", str_field(item, "tool"), text);
                continue;
            }
            other => other,
        };
        println!("{time}  {who}:");
        for line in text.lines() {
            println!("    {line}");
        }
        let images = item.get("images").and_then(Value::as_array).map_or(0, Vec::len);
        if images > 0 && str_field(item, "role") == "phone" {
            println!("    [{images} image(s)]");
        }
    }
    println!();
    println!("(times in UTC)");
    Ok(())
}

/// "12s ago", "5m ago", "3h ago", "2d ago".
pub(crate) fn ago(now: u64, ms: u64) -> String {
    if ms == 0 {
        return "-".to_string();
    }
    let secs = now.saturating_sub(ms) / 1000;
    if secs < 60 {
        format!("{secs}s ago")
    } else if secs < 3600 {
        format!("{}m ago", secs / 60)
    } else if secs < 86_400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86_400)
    }
}

/// Unix ms → "HH:MM" (UTC).
fn format_hm(ms: u64) -> String {
    if ms == 0 {
        return "--:--".to_string();
    }
    let rem = (ms / 1000) % 86_400;
    format!("{:02}:{:02}", rem / 3600, (rem % 3600) / 60)
}

/// Unix ms → "YYYY-MM-DD HH:MM UTC" (no timezone database needed).
fn format_ms(ms: u64) -> String {
    if ms == 0 {
        return "-".to_string();
    }
    let secs = ms / 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02} UTC",
        rem / 3600,
        (rem % 3600) / 60
    )
}

/// Howard Hinnant's days-from-civil inverse.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

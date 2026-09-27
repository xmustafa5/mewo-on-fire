//! User-facing CLI commands that talk to the running daemon.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use qrcode::render::unicode::Dense1x2;
use qrcode::{EcLevel, QrCode};
use serde_json::{json, Value};

use crate::control;
use crate::paths;

const CLI_TIMEOUT: Duration = Duration::from_secs(3);
const PAIR_WAIT: Duration = Duration::from_secs(300);

fn not_running_hint() -> String {
    format!(
        "The ccnotify daemon is not running (no answer on {}).\n\
         Start it with:   systemctl --user start ccnotify\n\
         Or install it:   ccnotify install\n\
         Or run it in a terminal:   ccnotify daemon",
        paths::socket_path().display()
    )
}

/// Send a request to the daemon; turn transport errors into a friendly hint and
/// `{"ok":false}` into an error.
fn call(req: &Value) -> Result<Value> {
    let resp = control::request(req, CLI_TIMEOUT)
        .map_err(|e| anyhow!("{}\n({e:#})", not_running_hint()))?;
    if resp.get("ok").and_then(Value::as_bool) != Some(true) {
        let err = resp
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
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
    println!("Scan this QR code with the ccnotify app:");
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
    bail!("pairing code expired; run `ccnotify pair` again")
}

pub fn devices() -> Result<()> {
    let resp = call(&json!({"cmd": "devices"}))?;
    let list = resp
        .get("devices")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        println!("No paired devices. Run `ccnotify pair` to add one.");
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
    println!("Revoke a device with: ccnotify revoke <ID>");
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
        "not_found" => bail!("no paired device with id {id} (see `ccnotify devices`)"),
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
    println!("ccnotify daemon: running");
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
    println!("  Cert SHA-256: {}", str_field(&resp, "fp"));
    println!(
        "  Devices:      {} paired, {} connected",
        u64_field(&resp, "devices"),
        u64_field(&resp, "connected")
    );
    println!("  Last event:   #{}", u64_field(&resp, "last_id"));
    println!("  Socket:       {}", paths::socket_path().display());
    Ok(())
}

pub fn test() -> Result<()> {
    let cwd = std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let event = json!({
        "kind": "stop",
        "project": "ccnotify",
        "cwd": cwd,
        "session": "test",
        "message": "Test notification from ccnotify",
        "detail": "",
    });
    call(&json!({"cmd": "emit", "event": event}))?;
    let connected = call(&json!({"cmd": "status"}))
        .map(|s| u64_field(&s, "connected"))
        .unwrap_or(0);
    println!("Sent test notification ({connected} device(s) connected right now).");
    Ok(())
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

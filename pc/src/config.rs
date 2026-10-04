//! config.json, TLS identity (cert.der/key.der), devices.json.

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::paths;

pub const DEFAULT_PORT: u16 = 47821;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub pc_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_port")]
    pub port: u16,
    /// More addresses for the phones to try, after the ones found on the
    /// network interfaces: a VPN address or a DNS name that reaches this PC
    /// from outside the LAN.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_hosts: Vec<String>,
    /// Relay for phones outside the LAN (`wss://…`, set with
    /// `ccnotify relay <url>`); empty = none.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub relay: String,
    /// Secret that keeps this PC's place on the relay.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub relay_key: String,
    /// Ask Claude for suggested next messages (`ccnotify suggestions on`,
    /// see suggest.rs).
    #[serde(default, skip_serializing_if = "is_false")]
    pub suggestions: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub token: String,
    #[serde(default)]
    pub created: u64,
}

/// Self-signed certificate + PKCS#8 key (both DER) and the cert fingerprint.
pub struct Identity {
    pub cert_der: Vec<u8>,
    pub key_der: Vec<u8>,
    pub fp: String,
}

/// Current unix time in milliseconds.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// `nbytes` random bytes, lowercase hex encoded (so 2*nbytes chars).
pub fn random_hex(nbytes: usize) -> String {
    let mut buf = vec![0u8; nbytes];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(buf)
}

#[cfg(not(target_os = "macos"))]
pub fn hostname() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "linux-pc".to_string())
}

/// macOS: the computer name from System Settings ("Sam's MacBook Pro"), else
/// the Bonjour host name, else the kernel host name without its domain.
#[cfg(target_os = "macos")]
pub fn hostname() -> String {
    fn output_of(program: &str, args: &[&str]) -> Option<String> {
        let out = std::process::Command::new(program).args(args).output().ok()?;
        if !out.status.success() {
            return None;
        }
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    }
    output_of("/usr/sbin/scutil", &["--get", "ComputerName"])
        .or_else(|| output_of("/usr/sbin/scutil", &["--get", "LocalHostName"]))
        .or_else(|| output_of("/bin/hostname", &["-s"]))
        .unwrap_or_else(|| "mac".to_string())
}

/// Lowercase hex SHA-256 of the certificate DER bytes.
pub fn fingerprint(cert_der: &[u8]) -> String {
    hex::encode(Sha256::digest(cert_der))
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.chars().all(|c| c.is_ascii_hexdigit())
}

/// Sets (or with an empty `url` removes) the relay; the daemon reads it when
/// it starts. The key is made once and kept, so the place on a relay stays
/// this PC's.
pub fn set_relay(url: &str) -> Result<Config> {
    let mut cfg = load_or_create()?;
    cfg.relay = url.trim().trim_end_matches('/').to_string();
    if !cfg.relay.is_empty() && cfg.relay_key.is_empty() {
        cfg.relay_key = random_hex(24);
    }
    save_config(&cfg)?;
    Ok(cfg)
}

/// Whether the hooks should ask Claude for suggestions. Read by the hooks on
/// every prompt, so it only looks at the file (never creates it).
pub fn suggestions_enabled() -> bool {
    fs::read_to_string(paths::config_file())
        .ok()
        .and_then(|text| serde_json::from_str::<Config>(&text).ok())
        .is_some_and(|cfg| cfg.suggestions)
}

pub fn set_suggestions(on: bool) -> Result<()> {
    let mut cfg = load_or_create()?;
    cfg.suggestions = on;
    save_config(&cfg)
}

fn save_config(cfg: &Config) -> Result<()> {
    let text = serde_json::to_string_pretty(cfg)?;
    let path = paths::config_file();
    paths::write_atomic(&path, format!("{text}\n").as_bytes(), 0o644)
        .with_context(|| format!("writing {}", path.display()))
}

/// Load `config.json`, creating it (random pc_id, hostname, default port) if missing.
pub fn load_or_create() -> Result<Config> {
    let path = paths::config_file();
    match fs::read_to_string(&path) {
        Ok(text) => {
            let mut cfg: Config = serde_json::from_str(&text)
                .with_context(|| format!("invalid JSON in {}", path.display()))?;
            let mut dirty = false;
            if !is_hex(&cfg.pc_id, 16) {
                cfg.pc_id = random_hex(8);
                dirty = true;
            }
            if cfg.name.trim().is_empty() {
                cfg.name = hostname();
                dirty = true;
            }
            if cfg.port == 0 {
                cfg.port = DEFAULT_PORT;
                dirty = true;
            }
            if dirty {
                save_config(&cfg)?;
            }
            Ok(cfg)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let cfg = Config {
                pc_id: random_hex(8),
                name: hostname(),
                port: DEFAULT_PORT,
                extra_hosts: Vec::new(),
                relay: String::new(),
                relay_key: String::new(),
                suggestions: false,
            };
            save_config(&cfg)?;
            Ok(cfg)
        }
        Err(e) => Err(anyhow!("reading {}: {e}", path.display())),
    }
}

/// Port from an existing config.json (never creates the file), else the default.
pub fn configured_port() -> u16 {
    fs::read_to_string(paths::config_file())
        .ok()
        .and_then(|t| serde_json::from_str::<Config>(&t).ok())
        .map(|c| c.port)
        .filter(|p| *p != 0)
        .unwrap_or(DEFAULT_PORT)
}

/// Load cert.der/key.der, generating a new self-signed pair on first run.
pub fn load_or_create_identity() -> Result<Identity> {
    let cert_path = paths::cert_file();
    let key_path = paths::key_file();

    if let (Ok(cert_der), Ok(key_der)) = (fs::read(&cert_path), fs::read(&key_path)) {
        if !cert_der.is_empty() && !key_der.is_empty() {
            let fp = fingerprint(&cert_der);
            return Ok(Identity {
                cert_der,
                key_der,
                fp,
            });
        }
    }

    let certified = rcgen::generate_simple_self_signed(vec![
        "ccnotify".to_string(),
        "localhost".to_string(),
    ])
    .map_err(|e| anyhow!("generating self-signed certificate: {e}"))?;
    let cert_der: Vec<u8> = certified.cert.der().to_vec();
    let key_der: Vec<u8> = certified.key_pair.serialize_der();

    paths::write_atomic(&key_path, &key_der, 0o600)
        .with_context(|| format!("writing {}", key_path.display()))?;
    paths::write_atomic(&cert_path, &cert_der, 0o644)
        .with_context(|| format!("writing {}", cert_path.display()))?;

    let fp = fingerprint(&cert_der);
    eprintln!("ccnotify: generated new TLS certificate (fp {fp})");
    Ok(Identity {
        cert_der,
        key_der,
        fp,
    })
}

/// Load devices.json. A missing file means no devices; a corrupt file is moved
/// aside (devices.json.corrupt) so it is not silently overwritten.
pub fn load_devices() -> Vec<Device> {
    let path = paths::devices_file();
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    if text.trim().is_empty() {
        return Vec::new();
    }
    match serde_json::from_str::<Vec<Device>>(&text) {
        Ok(devs) => devs,
        Err(e) => {
            let aside = path.with_file_name("devices.json.corrupt");
            eprintln!(
                "ccnotify: warning: {} is invalid ({e}); moved to {}",
                path.display(),
                aside.display()
            );
            let _ = fs::rename(&path, &aside);
            Vec::new()
        }
    }
}

/// Save devices.json with mode 600.
pub fn save_devices(devices: &[Device]) -> Result<()> {
    let path = paths::devices_file();
    let text = serde_json::to_string_pretty(devices)?;
    paths::write_atomic(&path, format!("{text}\n").as_bytes(), 0o600)
        .with_context(|| format!("writing {}", path.display()))
}

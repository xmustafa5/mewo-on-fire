//! `mewo dashboard`: an operations console in the browser. This process
//! serves one page on localhost and feeds it from the daemon over the
//! control socket (a legacy `ccnotify` daemon works too, with a thinner
//! feed). Nothing listens beyond 127.0.0.1.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::config::now_ms;
use crate::{artifacts, control, desktop, paths};

const HTML: &str = include_str!("../dashboard/index.html");
pub const DEFAULT_PORT: u16 = 47824;
const CACHE: Duration = Duration::from_millis(1000);
const TIMEOUT: Duration = Duration::from_secs(3);

type Cache = Mutex<Option<(Instant, String)>>;

pub fn run(port: u16, open: bool) -> Result<()> {
    let listener = TcpListener::bind(("127.0.0.1", port))
        .with_context(|| format!("binding 127.0.0.1:{port} (another dashboard running? `mewo dashboard <port>`)"))?;
    let url = format!("http://127.0.0.1:{port}");
    println!("Mewo on Fire operations console: {url}");
    match sockets().into_iter().find(|(p, _)| p.exists()) {
        Some((p, legacy)) => println!(
            "Reading the daemon at {}{}",
            p.display(),
            if legacy { " (legacy ccnotify daemon: no event feed until `mewo install`)" } else { "" }
        ),
        None => println!("No daemon found yet; the page keeps trying."),
    }
    println!("Press Ctrl+C to stop.");
    if open {
        open_browser(&url);
    }
    let cache: Arc<Cache> = Arc::new(Mutex::new(None));
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let cache = cache.clone();
        std::thread::spawn(move || {
            let _ = handle(stream, &cache);
        });
    }
    Ok(())
}

fn open_browser(url: &str) {
    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") {
        ("open", vec![url])
    } else {
        ("xdg-open", vec![url])
    };
    let _ = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn handle(mut stream: TcpStream, cache: &Cache) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut content_length = 0usize;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h)? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = v.trim().parse().unwrap_or(0).min(65536);
        }
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/").split('?').next().unwrap_or("/");
    let (status, ctype, body): (&str, &str, Vec<u8>) = match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => ("200 OK", "text/html; charset=utf-8", HTML.as_bytes().to_vec()),
        ("GET", "/api/state") => ("200 OK", "application/json; charset=utf-8", state_json(cache).into_bytes()),
        // A copy the daemon kept of what a session published (v1.6).
        ("GET", p) if p.starts_with("/artifact/") => {
            let rest = &p["/artifact/".len()..];
            let (id, rel) = rest.split_once('/').unwrap_or((rest, "index.html"));
            match artifacts::file(id, &unpercent(rel)) {
                Some((mime, bytes)) => ("200 OK", mime, bytes),
                None => ("404 Not Found", "text/plain; charset=utf-8", b"not found".to_vec()),
            }
        }
        // v1.7: the policy commands, forwarded to the daemon.
        ("POST", "/api/daemon") => {
            let mut raw = vec![0u8; content_length];
            std::io::Read::read_exact(&mut reader, &mut raw)?;
            let req: Value = serde_json::from_slice(&raw).unwrap_or(Value::Null);
            let reply = forward(&req);
            ("200 OK", "application/json; charset=utf-8", reply.to_string().into_bytes())
        }
        ("POST", "/api/new_session") => {
            let mut raw = vec![0u8; content_length];
            std::io::Read::read_exact(&mut reader, &mut raw)?;
            let req: Value = serde_json::from_slice(&raw).unwrap_or(Value::Null);
            let cwd = req.get("cwd").and_then(Value::as_str).unwrap_or("");
            let prompt = req.get("prompt").and_then(Value::as_str).unwrap_or("");
            let reply = new_session(cwd, prompt);
            ("200 OK", "application/json; charset=utf-8", reply.to_string().into_bytes())
        }
        _ => ("404 Not Found", "text/plain; charset=utf-8", b"not found".to_vec()),
    };
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(&body)?;
    stream.flush()
}

/// `%20` and friends in a path.
fn unpercent(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"), 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn state_json(cache: &Cache) -> String {
    if let Some((at, s)) = cache.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
        if at.elapsed() < CACHE {
            return s.clone();
        }
    }
    let s = collect().to_string();
    *cache.lock().unwrap_or_else(|p| p.into_inner()) = Some((Instant::now(), s.clone()));
    s
}

/// A control request of the page, to this daemon only, commands the page
/// is meant to send.
fn forward(req: &Value) -> Value {
    let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("");
    if !matches!(cmd, "features" | "sign" | "plan_status" | "scan" | "set_check" | "start_session" | "request_sign" | "flow_next" | "flow_set" | "estimate" | "estimates_done" | "export_handoff" | "uat_user" | "release" | "close_branches" | "new_feature" | "set_role" | "rollback" | "unsign" | "peers" | "peer_scan" | "peer_pair" | "peer_remove" | "new_session") {
        return json!({"ok": false, "error": "not a console command"});
    }
    for (path, legacy) in sockets() {
        if !path.exists() || legacy {
            continue;
        }
        match control::request_at(&path, req, Duration::from_secs(20)) {
            Ok(v) => return v,
            Err(e) => return json!({"ok": false, "error": e.to_string()}),
        }
    }
    json!({"ok": false, "error": "The daemon is not running"})
}

/// The console's "New session": through the daemon when it is this one
/// (so its log sees it), else straight from here (a legacy daemon has no
/// such command).
fn new_session(cwd: &str, prompt: &str) -> Value {
    for (path, legacy) in sockets() {
        if !path.exists() || legacy {
            continue;
        }
        if let Ok(v) = control::request_at(&path, &json!({"cmd": "new_session", "cwd": cwd, "prompt": prompt}), TIMEOUT) {
            return v;
        }
    }
    match desktop::open_new_session(cwd, prompt) {
        Ok(()) => json!({"ok": true}),
        Err(e) => json!({"ok": false, "error": e}),
    }
}

/// Control sockets to try: this daemon's, then a legacy `ccnotify` one.
fn sockets() -> Vec<(PathBuf, bool)> {
    let user = std::env::var("USER").unwrap_or_else(|_| "user".to_string());
    let mut out = vec![
        (paths::socket_path(), false),
        (paths::legacy_state_dir().join("ccnotify.sock"), true),
        (PathBuf::from(format!("/tmp/ccnotify-{user}.sock")), true),
    ];
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            out.push((PathBuf::from(dir).join("ccnotify.sock"), true));
        }
    }
    out
}

fn field(path: &std::path::Path, cmd: Value, key: &str) -> Value {
    control::request_at(path, &cmd, TIMEOUT)
        .ok()
        .and_then(|v| v.get(key).cloned())
        .unwrap_or(Value::Array(Vec::new()))
}

/// Everything the page shows, from the first daemon that answers.
fn collect() -> Value {
    let mut err = String::new();
    for (path, legacy) in sockets() {
        if !path.exists() {
            continue;
        }
        match control::request_at(&path, &json!({"cmd": "status"}), TIMEOUT) {
            Ok(status) => {
                let mut sessions = field(&path, json!({"cmd": "sessions"}), "sessions");
                desktop::tag(&mut sessions);
                let events = field(&path, json!({"cmd": "events", "limit": 120}), "events");
                let requests = field(&path, json!({"cmd": "requests"}), "requests");
                let features_all = if legacy { Value::Null } else { control::request_at(&path, &json!({"cmd": "features"}), Duration::from_secs(20)).unwrap_or(Value::Null) };
                let features = features_all.get("features").cloned().unwrap_or(Value::Array(Vec::new()));
                let features_meta = json!({"roles": features_all.get("roles").cloned().unwrap_or(json!({})), "apps": features_all.get("apps").cloned().unwrap_or(json!({})), "role_names": features_all.get("role_names").cloned().unwrap_or(json!([])), "workspaces": features_all.get("workspaces").cloned().unwrap_or(json!([]))});
                return json!({
                    "ok": true,
                    "daemon": status,
                    "sessions": sessions,
                    "events": events,
                    "requests": requests,
                    "features": features,
                    "features_meta": features_meta,
                    "peers": if legacy { Value::Array(Vec::new()) } else { field(&path, json!({"cmd": "peers"}), "peers") },
                    "legacy": legacy,
                    "socket": path,
                    "now": now_ms(),
                    "version": env!("CARGO_PKG_VERSION"),
                });
            }
            Err(e) => err = format!("{e:#}"),
        }
    }
    json!({
        "ok": false,
        "error": if err.is_empty() {
            "No daemon found. Is Mewo on Fire installed and running? (`mewo status`)".to_string()
        } else {
            err
        },
        "now": now_ms(),
        "version": env!("CARGO_PKG_VERSION"),
    })
}

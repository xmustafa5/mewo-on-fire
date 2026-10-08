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
use crate::{control, paths};

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
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h)? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/").split('?').next().unwrap_or("/");
    let (status, ctype, body) = match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => ("200 OK", "text/html; charset=utf-8", HTML.to_string()),
        ("GET", "/api/state") => ("200 OK", "application/json; charset=utf-8", state_json(cache)),
        _ => ("404 Not Found", "text/plain; charset=utf-8", "not found".to_string()),
    };
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
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
                let sessions = field(&path, json!({"cmd": "sessions"}), "sessions");
                let events = field(&path, json!({"cmd": "events", "limit": 120}), "events");
                let requests = field(&path, json!({"cmd": "requests"}), "requests");
                return json!({
                    "ok": true,
                    "daemon": status,
                    "sessions": sessions,
                    "events": events,
                    "requests": requests,
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

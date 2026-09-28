//! Local control socket: newline-delimited JSON, one request per connection.
//! Daemon side (tokio) + a small blocking client used by the CLI and the hook.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

use crate::ask;
use crate::daemon::AppState;
use crate::hook;
use crate::paths;
use crate::requests::Request;
use crate::store::Event;

const MAX_REQUEST_BYTES: u64 = 1 << 20;

// ---------------------------------------------------------------------------
// Client (blocking)
// ---------------------------------------------------------------------------

/// Send one request and read one response line. `timeout` applies to both
/// the write and the read.
pub fn request(req: &Value, timeout: Duration) -> Result<Value> {
    request_with(req, Some(timeout), timeout)
}

/// Like `request`, but waits for the reply with no read timeout (`ccnotify
/// ask` blocks until a phone answers). `write_timeout` bounds the send.
pub fn request_blocking(req: &Value, write_timeout: Duration) -> Result<Value> {
    request_with(req, None, write_timeout)
}

fn request_with(
    req: &Value,
    read_timeout: Option<Duration>,
    write_timeout: Duration,
) -> Result<Value> {
    let path = paths::socket_path();
    let mut stream = std::os::unix::net::UnixStream::connect(&path)
        .with_context(|| format!("connecting to {}", path.display()))?;
    stream.set_read_timeout(read_timeout)?;
    stream.set_write_timeout(Some(write_timeout))?;

    let mut line = serde_json::to_string(req)?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut resp = String::new();
    reader.read_line(&mut resp)?;
    let resp = resp.trim();
    if resp.is_empty() {
        bail!("empty response from daemon");
    }
    Ok(serde_json::from_str(resp)?)
}

// ---------------------------------------------------------------------------
// Server (daemon side)
// ---------------------------------------------------------------------------

/// Bind the control socket (removing a stale socket file, refusing to start if
/// another daemon is answering on it) and chmod it 600.
pub fn bind() -> Result<UnixListener> {
    let path = paths::socket_path();
    if fs::symlink_metadata(&path).is_ok() {
        if std::os::unix::net::UnixStream::connect(&path).is_ok() {
            bail!(
                "another ccnotify daemon is already running (socket {} is live)",
                path.display()
            );
        }
        let _ = fs::remove_file(&path);
    }
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let listener = UnixListener::bind(&path)
        .with_context(|| format!("binding control socket {}", path.display()))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod {}", path.display()))?;
    Ok(listener)
}

pub async fn serve(state: Arc<AppState>, listener: UnixListener) {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let state = state.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_conn(state, stream).await {
                        eprintln!("ccnotify: control: {e:#}");
                    }
                });
            }
            Err(e) => {
                eprintln!("ccnotify: control accept error: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    }
}

async fn handle_conn(state: Arc<AppState>, stream: tokio::net::UnixStream) -> Result<()> {
    let (rd, mut wr) = stream.into_split();
    let mut reader = tokio::io::BufReader::new(rd.take(MAX_REQUEST_BYTES));
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
        .await
        .map_err(|_| anyhow!("request read timeout"))??;

    let resp = match serde_json::from_str::<Value>(line.trim()) {
        Ok(req) if req.get("cmd").and_then(Value::as_str) == Some("ask") => {
            // Lift the size cap now that the request line is in, so the EOF
            // watch in handle_ask cannot mistake an exhausted limit for a
            // closed socket.
            reader.get_mut().set_limit(u64::MAX);
            match handle_ask(&state, &req, &mut reader).await {
                Some(resp) => resp,
                // The hook went away (answered on the PC): nobody to reply to.
                None => return Ok(()),
            }
        }
        Ok(req) => handle_request(&state, &req),
        Err(_) => json!({"ok": false, "error": "bad_json"}),
    };

    let mut out = serde_json::to_string(&resp)?;
    out.push('\n');
    wr.write_all(out.as_bytes()).await?;
    let _ = wr.shutdown().await;
    Ok(())
}

fn handle_request(state: &AppState, req: &Value) -> Value {
    match req.get("cmd").and_then(Value::as_str).unwrap_or("") {
        "emit" => {
            let ev = match req.get("event").cloned().map(serde_json::from_value::<Event>) {
                Some(Ok(ev)) => ev,
                _ => return json!({"ok": false, "error": "bad_event"}),
            };
            if !matches!(ev.kind.as_str(), "stop" | "needs_input" | "session_end") {
                return json!({"ok": false, "error": "bad_kind"});
            }
            let mut ev = ev;
            ev.message = hook::clean_message(&ev.message);
            let session = ev.session.clone();
            match state.emit(ev) {
                Some(stored) => eprintln!(
                    "ccnotify: event #{} {} [{}] {}",
                    stored.id, stored.kind, stored.project, stored.detail
                ),
                None => eprintln!(
                    "ccnotify: dropped needs_input for session {session} (request pending)"
                ),
            }
            json!({"ok": true})
        }
        "pair" => {
            let code = state.new_pair_code();
            let qr = state.pair_payload(&code);
            json!({"ok": true, "qr": qr, "code": code, "expires_in": 300})
        }
        "devices" => json!({"ok": true, "devices": state.device_list()}),
        "revoke" => {
            let id = req.get("id").and_then(Value::as_str).unwrap_or("");
            match state.revoke(id) {
                Ok(true) => json!({"ok": true}),
                Ok(false) => json!({"ok": false, "error": "not_found"}),
                Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
            }
        }
        "status" => state.status_json(),
        _ => json!({"ok": false, "error": "unknown_cmd"}),
    }
}

/// `ask`: forward a prompt to the connected phones and block until one
/// answers. Returns None when the client (the hook) hung up first — Claude
/// Code kills the hook when the prompt is answered on the PC.
async fn handle_ask<R>(state: &AppState, req: &Value, reader: &mut R) -> Option<Value>
where
    R: AsyncRead + Unpin,
{
    let mut request = match req.get("request").cloned().map(serde_json::from_value::<Request>) {
        Some(Ok(r)) => r,
        _ => return Some(json!({"ok": false, "error": "bad_request"})),
    };
    if !matches!(request.kind.as_str(), "permission" | "question" | "plan") {
        return Some(json!({"ok": false, "error": "bad_kind"}));
    }
    if state.connected.load(Ordering::SeqCst) == 0 {
        return Some(json!({"ok": false, "error": "no_devices"}));
    }
    request.summary = hook::clean_message(&request.summary);
    request.detail = ask::truncate_chars(&request.detail, ask::MAX_DETAIL_CHARS);
    let log_line = format!("{} [{}] {}", request.kind, request.project, request.summary);

    let (id, answer_rx) = state.add_request(request);
    eprintln!("ccnotify: request {id} {log_line}");

    tokio::select! {
        answer = answer_rx => {
            match answer {
                Ok(answer) => Some(json!({"ok": true, "answer": answer})),
                // Resolved without an answer (expired).
                Err(_) => Some(json!({"ok": false, "error": "timeout"})),
            }
        }
        _ = wait_for_eof(reader) => {
            if state.cancel_request(&id, "pc") {
                eprintln!("ccnotify: request {id} answered on the PC");
            }
            None
        }
    }
}

/// Resolves when the peer closes its end (or the read fails). The client
/// sends nothing after its request line; stray bytes are ignored.
async fn wait_for_eof<R>(reader: &mut R)
where
    R: AsyncRead + Unpin,
{
    let mut buf = [0u8; 256];
    loop {
        match reader.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => continue,
        }
    }
}

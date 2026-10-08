//! Local control socket: newline-delimited JSON, one request per connection.
//! Daemon side (tokio) + a small blocking client used by the CLI and the hook.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
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
use crate::requests::{AskReply, Request};
use crate::sessions::{ListenReply, ListenStart, Meta};
use crate::store::Event;

const MAX_REQUEST_BYTES: u64 = 1 << 20;
/// `mewo chat`: default and maximum number of items.
const CHAT_DEFAULT_LIMIT: usize = 20;
const CHAT_MAX_LIMIT: usize = 1000;

// ---------------------------------------------------------------------------
// Client (blocking)
// ---------------------------------------------------------------------------

/// Send one request and read one response line. `timeout` applies to both
/// the write and the read.
pub fn request(req: &Value, timeout: Duration) -> Result<Value> {
    request_with(&paths::socket_path(), req, Some(timeout), timeout)
}

/// Like `request`, at a given socket (the dashboard also reads a legacy
/// `ccnotify` daemon).
pub fn request_at(path: &Path, req: &Value, timeout: Duration) -> Result<Value> {
    request_with(path, req, Some(timeout), timeout)
}

/// Like `request`, but waits for the reply with no read timeout (`mewo ask` /
/// `mewo listen` block until a phone answers). `write_timeout` bounds the
/// send.
pub fn request_blocking(req: &Value, write_timeout: Duration) -> Result<Value> {
    request_with(&paths::socket_path(), req, None, write_timeout)
}

fn request_with(
    path: &Path,
    req: &Value,
    read_timeout: Option<Duration>,
    write_timeout: Duration,
) -> Result<Value> {
    let mut stream = std::os::unix::net::UnixStream::connect(path)
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
                "another Mewo on Fire daemon is already running (socket {} is live)",
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
                        eprintln!("mewo: control: {e:#}");
                    }
                });
            }
            Err(e) => {
                eprintln!("mewo: control accept error: {e}");
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
        Ok(req) => {
            let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("");
            match cmd {
                "ask" | "listen" => {
                    // Lift the size cap now that the request line is in, so
                    // the EOF watch cannot mistake an exhausted limit for a
                    // closed socket.
                    reader.get_mut().set_limit(u64::MAX);
                    let resp = if cmd == "ask" {
                        handle_ask(&state, &req, &mut reader).await
                    } else {
                        handle_listen(&state, &req, &mut reader).await
                    };
                    match resp {
                        Some(resp) => resp,
                        // The hook went away (answered on the PC / exited):
                        // nobody to reply to.
                        None => return Ok(()),
                    }
                }
                "sessions" => {
                    state.refresh_sessions(None).await;
                    json!({"ok": true, "sessions": state.session_list()})
                }
                "chat" => handle_chat(&state, &req).await,
                _ => handle_request(&state, &req),
            }
        }
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
            // v1.2 private fields (top level of the request).
            let mut meta = Meta::from_request(req);
            if ev.session_id.is_empty() {
                ev.session_id = meta.session_id.clone();
            } else {
                meta.session_id = ev.session_id.clone();
            }
            if meta.cwd.is_empty() {
                meta.cwd = ev.cwd.clone();
            }
            let session = ev.session.clone();
            let kind = ev.kind.clone();
            match state.emit(ev, &meta) {
                Some(stored) => eprintln!(
                    "mewo: event #{} {} [{}] {}",
                    stored.id, stored.kind, stored.project, stored.detail
                ),
                None => eprintln!(
                    "mewo: dropped needs_input for session {session} (request pending)"
                ),
            }
            if matches!(kind.as_str(), "stop" | "session_end") {
                state.cancel_session_requests(&session, &kind);
            }
            json!({"ok": true})
        }
        "session_state" => {
            let meta = Meta::from_request(req);
            let new_state = req.get("state").and_then(Value::as_str).unwrap_or("");
            if meta.session_id.is_empty()
                || !matches!(new_state, "working" | "idle" | "waiting" | "ended")
            {
                return json!({"ok": false, "error": "bad_request"});
            }
            state.set_session_state(&meta, new_state, None);
            if new_state == "working" {
                state.cancel_session_requests(&short_id(&meta.session_id), "new prompt");
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
        // The dashboard's feed: the last events and the requests waiting.
        "events" => {
            let n = req.get("limit").and_then(Value::as_u64).unwrap_or(50).min(500);
            let last = state.last_id();
            json!({"ok": true, "last_id": last, "events": state.events_since(last.saturating_sub(n))})
        }
        "requests" => json!({"ok": true, "requests": state.pending_requests()}),
        _ => json!({"ok": false, "error": "unknown_cmd"}),
    }
}

/// `ask`: forward a prompt to the connected phones and block until one
/// answers (or the request is cancelled / expires). Returns None when the
/// client (the hook) hung up first — its transcript watcher exits it when the
/// prompt is answered on the PC.
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
    // Private: the session safety net leaves subagent prompts alone.
    let agent_id = req
        .get("agent_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();

    let (id, reply_rx) = state.add_request(request, agent_id);
    eprintln!("mewo: request {id} {log_line}");

    tokio::select! {
        reply = reply_rx => {
            match reply {
                Ok(AskReply::Answer(answer)) => Some(json!({"ok": true, "answer": answer})),
                // Cancelled (session moved on) or expired.
                Ok(AskReply::Error(error)) => Some(json!({"ok": false, "error": error})),
                Err(_) => Some(json!({"ok": false, "error": "cancelled"})),
            }
        }
        _ = wait_for_eof(reader) => {
            if state.cancel_request(&id, "pc") {
                eprintln!("mewo: request {id} resolved by pc (hook exited)");
            }
            None
        }
    }
}

/// `listen` (PROTOCOL.md v1.2): hand over queued phone messages right away,
/// else wait as the session's listener until a phone message arrives, the
/// listener is superseded / cancelled, or the hook goes away (None).
async fn handle_listen<R>(state: &AppState, req: &Value, reader: &mut R) -> Option<Value>
where
    R: AsyncRead + Unpin,
{
    let meta = Meta::from_request(req);
    let (listener_id, mut reply_rx) = match state.listen(&meta) {
        None => return Some(json!({"ok": false, "error": "bad_request"})),
        Some(ListenStart::Now(text)) => {
            eprintln!(
                "mewo: session {}: delivered queued phone message(s)",
                short_id(&meta.session_id)
            );
            return Some(json!({"ok": true, "text": text}));
        }
        Some(ListenStart::Wait(id, rx)) => (id, rx),
    };

    tokio::select! {
        reply = &mut reply_rx => {
            match reply {
                Ok(ListenReply::Text(text)) => Some(json!({"ok": true, "text": text})),
                Ok(ListenReply::Error(error)) => Some(json!({"ok": false, "error": error})),
                // Listener dropped with its session (pruned).
                Err(_) => Some(json!({"ok": false, "error": "cancelled"})),
            }
        }
        _ = wait_for_eof(reader) => {
            state.unlisten(&meta.session_id, listener_id);
            // A message handed over just as the hook went away: keep it for
            // the next listen.
            if let Ok(ListenReply::Text(text)) = reply_rx.try_recv() {
                state.requeue(&meta.session_id, text);
            }
            None
        }
    }
}

/// `chat` (for `mewo chat`): the last items of the session whose id
/// starts with `session`.
async fn handle_chat(state: &AppState, req: &Value) -> Value {
    let prefix = req.get("session").and_then(Value::as_str).unwrap_or("");
    let limit = req
        .get("limit")
        .and_then(Value::as_u64)
        .map(|l| l as usize)
        .unwrap_or(CHAT_DEFAULT_LIMIT)
        .clamp(1, CHAT_MAX_LIMIT);
    let session = match state.find_session(prefix) {
        Ok(s) => s,
        Err(error) => return json!({"ok": false, "error": error}),
    };
    match state.chat(&session.id, limit).await {
        Some((session, items)) => json!({"ok": true, "session": session, "items": items}),
        None => json!({"ok": false, "error": "not_found"}),
    }
}

fn short_id(session_id: &str) -> String {
    session_id.chars().take(8).collect()
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

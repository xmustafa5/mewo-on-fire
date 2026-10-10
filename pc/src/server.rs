//! Phone-facing wss:// server: TLS (self-signed, pinned by the phone) +
//! WebSocket. First frame decides pairing vs. subscription.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast::error::RecvError;
use tokio::time::{interval_at, timeout, Instant, MissedTickBehavior};
use tokio_rustls::server::TlsStream;
use tokio_rustls::TlsAcceptor;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::config::{Device, Identity};
use crate::daemon::{AppState, Push, Subscription};
use crate::requests::Request;
use crate::sessions::Session;
use crate::store::Event;
use crate::transcript;
use crate::uploads;
use crate::artifacts;
use crate::control;
use crate::desktop;

type Ws = WebSocketStream<TlsStream<TcpStream>>;
type WsSink = SplitSink<Ws, Message>;
type WsStream = SplitStream<Ws>;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(15);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
const PING_INTERVAL: Duration = Duration::from_secs(30);
/// Drop a subscriber we have heard nothing from (no pong/ping/frame) for this long.
const IDLE_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_DEVICE_NAME_CHARS: usize = 64;

pub fn tls_acceptor(identity: &Identity) -> Result<TlsAcceptor> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cert = CertificateDer::from(identity.cert_der.clone());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_der.clone()));
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| anyhow!("TLS protocol versions: {e}"))?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| anyhow!("TLS certificate/key: {e}"))?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

pub async fn serve(state: Arc<AppState>, listener: TcpListener, acceptor: TlsAcceptor) {
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                eprintln!("mewo: accept error: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        let _ = tcp.set_nodelay(true);
        let state = state.clone();
        let acceptor = acceptor.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(state, acceptor, tcp).await {
                eprintln!("mewo: client {peer}: {e:#}");
            }
        });
    }
}

async fn handle(state: Arc<AppState>, acceptor: TlsAcceptor, tcp: TcpStream) -> Result<()> {
    let tls = timeout(HANDSHAKE_TIMEOUT, acceptor.accept(tcp))
        .await
        .map_err(|_| anyhow!("TLS handshake timeout"))?
        .map_err(|e| anyhow!("TLS handshake: {e}"))?;
    let ws: Ws = timeout(HANDSHAKE_TIMEOUT, tokio_tungstenite::accept_async(tls))
        .await
        .map_err(|_| anyhow!("WebSocket handshake timeout"))?
        .map_err(|e| anyhow!("WebSocket handshake: {e}"))?;
    let (mut sink, mut stream): (WsSink, WsStream) = ws.split();

    let first = match timeout(FIRST_FRAME_TIMEOUT, read_first(&mut stream)).await {
        Ok(Some(v)) => v,
        _ => {
            close(&mut sink).await;
            return Ok(());
        }
    };

    match first.get("type").and_then(Value::as_str) {
        Some("pair") => handle_pair(&state, &mut sink, &first).await,
        Some("auth") => handle_auth(&state, sink, stream, &first).await,
        _ => {
            let _ = send_json(&mut sink, &json!({"type": "error", "error": "bad_request"})).await;
            close(&mut sink).await;
            Ok(())
        }
    }
}

/// Read frames until the first text/binary JSON frame.
async fn read_first(stream: &mut WsStream) -> Option<Value> {
    while let Some(msg) = stream.next().await {
        match msg.ok()? {
            Message::Text(text) => return serde_json::from_str(&text).ok(),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).ok(),
            Message::Close(_) => return None,
            _ => continue,
        }
    }
    None
}

async fn send_json(sink: &mut WsSink, v: &Value) -> Result<()> {
    let text = serde_json::to_string(v)?;
    timeout(SEND_TIMEOUT, sink.send(Message::Text(text)))
        .await
        .map_err(|_| anyhow!("send timeout"))?
        .map_err(|e| anyhow!("send: {e}"))?;
    Ok(())
}

async fn send_event(sink: &mut WsSink, ev: &Event) -> Result<()> {
    send_json(sink, &json!({"type": "event", "event": ev})).await
}

async fn send_request(sink: &mut WsSink, req: &Request) -> Result<()> {
    send_json(sink, &json!({"type": "request", "request": req})).await
}

async fn send_resolved(sink: &mut WsSink, request_id: &str, by: &str) -> Result<()> {
    send_json(
        sink,
        &json!({"type": "resolved", "request_id": request_id, "by": by}),
    )
    .await
}

async fn send_session(sink: &mut WsSink, session: &Session) -> Result<()> {
    send_json(sink, &json!({"type": "session", "session": session})).await
}

async fn close(sink: &mut WsSink) {
    let _ = timeout(CLOSE_TIMEOUT, sink.close()).await;
}

async fn handle_pair(state: &AppState, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let code = msg
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if code.is_empty() || !state.take_pair_code(&code) {
        eprintln!("mewo: pairing attempt with invalid code");
        let _ = send_json(sink, &json!({"type": "error", "error": "invalid_code"})).await;
        close(sink).await;
        return Ok(());
    }

    let raw_name = msg
        .get("device_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let name: String = if raw_name.is_empty() {
        "Phone".to_string()
    } else {
        raw_name.chars().take(MAX_DEVICE_NAME_CHARS).collect()
    };

    let device = match state.add_device(&name) {
        Ok(d) => d,
        Err(e) => {
            let _ = send_json(sink, &json!({"type": "error", "error": "internal"})).await;
            close(sink).await;
            return Err(e);
        }
    };
    eprintln!("mewo: paired device {} ({})", device.id, device.name);

    let reply = json!({
        "type": "paired",
        "device_id": device.id,
        "token": device.token,
        "pc_id": state.config.pc_id,
        "name": state.config.name,
        "last_id": state.last_id(),
    });
    let result = send_json(sink, &reply).await;
    close(sink).await;
    result
}

/// Decrements the connected counter when a subscriber goes away.
struct ConnGuard<'a>(&'a AtomicUsize);

impl<'a> ConnGuard<'a> {
    fn new(counter: &'a AtomicUsize) -> Self {
        counter.fetch_add(1, Ordering::SeqCst);
        ConnGuard(counter)
    }
}

impl Drop for ConnGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn handle_auth(
    state: &AppState,
    mut sink: WsSink,
    mut stream: WsStream,
    msg: &Value,
) -> Result<()> {
    let token = msg.get("token").and_then(Value::as_str).unwrap_or("");
    let device = match state.device_by_token(token) {
        Some(d) => d,
        None => {
            let _ = send_json(&mut sink, &json!({"type": "error", "error": "unauthorized"})).await;
            close(&mut sink).await;
            return Ok(());
        }
    };
    let since = msg.get("since").and_then(Value::as_u64).unwrap_or(0);

    let sub = state.subscribe_since(since);
    send_json(
        &mut sink,
        &json!({
            "type": "hello",
            "pc_id": state.config.pc_id,
            "name": state.config.name,
            "last_id": sub.last_id,
            "hosts": state.hosts(),
        }),
    )
    .await?;

    let _guard = ConnGuard::new(&state.connected);
    eprintln!(
        "mewo: device {} ({}) connected, since={} replay={} pending={}",
        device.id,
        device.name,
        since,
        sub.backlog.len(),
        sub.pending.len()
    );

    let result = subscriber_loop(state, &device, &mut sink, &mut stream, sub, since).await;
    close(&mut sink).await;
    eprintln!("mewo: device {} ({}) disconnected", device.id, device.name);
    result
}

async fn subscriber_loop(
    state: &AppState,
    device: &Device,
    sink: &mut WsSink,
    stream: &mut WsStream,
    sub: Subscription,
    since: u64,
) -> Result<()> {
    let Subscription {
        mut rx,
        last_id,
        backlog,
        pending,
    } = sub;
    let mut last_sent = since.min(last_id);
    for ev in backlog {
        if !ev.to.is_empty() && ev.to != device.name {
            continue;
        }
        send_event(sink, &ev).await?;
        last_sent = ev.id;
    }
    for req in &pending {
        send_request(sink, req).await?;
    }

    let mut ping = interval_at(Instant::now() + PING_INTERVAL, PING_INTERVAL);
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last_seen = Instant::now();

    loop {
        tokio::select! {
            received = rx.recv() => {
                match received {
                    Ok(Push::Event(ev)) => {
                        if ev.id > last_sent {
                            last_sent = ev.id;
                            // v1.8: an event for one phone goes to that phone only.
                            if ev.to.is_empty() || ev.to == device.name {
                                send_event(sink, &ev).await?;
                            }
                        }
                    }
                    Ok(Push::Request(req)) => send_request(sink, &req).await?,
                    Ok(Push::Resolved { request_id, by }) => {
                        send_resolved(sink, &request_id, by).await?
                    }
                    Ok(Push::Session(session)) => send_session(sink, &session).await?,
                    Err(RecvError::Lagged(_)) => {
                        // Fell behind the live stream: catch up from the store
                        // and re-send the pending requests and the sessions
                        // (the phone dedupes them by id).
                        for ev in state.events_since(last_sent) {
                            send_event(sink, &ev).await?;
                            last_sent = ev.id;
                        }
                        for req in state.pending_requests() {
                            send_request(sink, &req).await?;
                        }
                        for session in state.session_list() {
                            send_session(sink, &session).await?;
                        }
                    }
                    Err(RecvError::Closed) => return Ok(()),
                }
            }
            _ = ping.tick() => {
                if !state.token_valid(&device.token) {
                    let _ = send_json(sink, &json!({"type": "error", "error": "unauthorized"})).await;
                    return Ok(());
                }
                if last_seen.elapsed() > IDLE_TIMEOUT {
                    return Err(anyhow!("idle timeout"));
                }
                timeout(SEND_TIMEOUT, sink.send(Message::Ping(Vec::new())))
                    .await
                    .map_err(|_| anyhow!("ping timeout"))?
                    .map_err(|e| anyhow!("ping: {e}"))?;
            }
            incoming = stream.next() => {
                match incoming {
                    None | Some(Ok(Message::Close(_))) => return Ok(()),
                    Some(Ok(Message::Text(text))) => {
                        last_seen = Instant::now();
                        handle_frame(state, device, sink, &text).await?;
                    }
                    Some(Ok(_)) => last_seen = Instant::now(),
                    Some(Err(e)) => return Err(anyhow!("read: {e}")),
                }
            }
        }
    }
}

/// A text frame from a subscribed phone: `answer` (v1.1), `sessions`,
/// `get_chat`, `send` (v1.2), `get_image` (v1.3), `get_prs` (v1.6). Other
/// frames are ignored.
async fn handle_frame(
    state: &AppState,
    device: &Device,
    sink: &mut WsSink,
    text: &str,
) -> Result<()> {
    let msg: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Ok(()),
    };
    match msg.get("type").and_then(Value::as_str).unwrap_or("") {
        "answer" => handle_answer(state, device, sink, &msg).await,
        "sessions" => {
            state.refresh_sessions(None).await;
            let sessions = state.session_list();
            send_json(sink, &json!({"type": "sessions", "sessions": sessions})).await
        }
        "get_chat" => handle_get_chat(state, sink, &msg).await,
        "get_image" => handle_get_image(state, sink, &msg).await,
        "send" => handle_send(state, device, sink, &msg).await,
        "get_prs" => handle_get_prs(state, sink, &msg).await,
        "get_artifact" => handle_get_artifact(state, sink, &msg).await,
        "new_session" => handle_new_session(device, sink, &msg).await,
        // v1.7: the TORCH flow.
        "get_features" => {
            let mut v = state.features_json().await;
            if let Some(o) = v.as_object_mut() {
                o.insert("type".to_string(), json!("features"));
            }
            send_json(sink, &v).await
        }
        "sign" | "plan_status" | "start_session" | "request_sign" | "get_scan" | "set_check"
        | "flow_next" | "flow_set" | "estimate" | "estimates_done" | "export_handoff" | "uat_user" | "release" | "close_branches" | "new_feature" | "set_role" | "rollback" => handle_policy(state, device, sink, &msg).await,
        _ => Ok(()),
    }
}

/// `new_session` → `new_session_result` (v1.6): a new Claude Code session in
/// Claude Desktop on this PC, with the phone's text as its first message.
async fn handle_new_session(device: &Device, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let cwd = str_field(msg, "cwd").to_string();
    let prompt = str_field(msg, "prompt").to_string();
    let client_id = str_field(msg, "client_id").to_string();
    let result = tokio::task::block_in_place(|| desktop::open_new_session(&cwd, &prompt));
    match &result {
        Ok(()) => eprintln!("mewo: device {} ({}) started a session", device.id, device.name),
        Err(e) => eprintln!("mewo: device {} ({}) could not start a session: {e}", device.id, device.name),
    }
    send_json(
        sink,
        &json!({
            "type": "new_session_result",
            "client_id": client_id,
            "ok": result.is_ok(),
            "error": result.err().unwrap_or_default(),
        }),
    )
    .await
}

/// `get_prs` → `prs` (v1.6): the open pull requests of the session's
/// repository, from `gh` on this PC.
async fn handle_get_prs(state: &AppState, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let session_id = str_field(msg, "session_id");
    let cwd = state
        .session_list()
        .into_iter()
        .find(|s| s.id == session_id)
        .map(|s| s.cwd)
        .unwrap_or_default();
    let mut v = state.prs.list(&cwd).await;
    if let Some(obj) = v.as_object_mut() {
        obj.insert("type".to_string(), json!("prs"));
        obj.insert("session_id".to_string(), json!(session_id));
    }
    send_json(sink, &v).await
}

/// The policy frames (v1.7): each answers with the same shape as the
/// control command, typed `<frame>_result` and carrying `client_id` back.
async fn handle_policy(state: &AppState, device: &Device, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let frame = str_field(msg, "type").to_string();
    let client_id = str_field(msg, "client_id").to_string();
    let mut req = msg.clone();
    if let Some(o) = req.as_object_mut() {
        let cmd = match frame.as_str() {
            "get_scan" => "scan",
            other => other,
        };
        o.insert("cmd".to_string(), json!(cmd));
        // A role set from a phone reaches that phone (v1.8).
        if frame == "set_role" && str_field(msg, "phone").is_empty() {
            o.insert("phone".to_string(), json!(device.name));
        }
    }
    let mut v = tokio::task::block_in_place(|| control::policy_request(state, &req));
    if frame == "set_check" {
        // The session push carries the checks; a small ack is enough.
        v = json!({"ok": v.get("ok").and_then(Value::as_bool).unwrap_or(false)});
    }
    if let Some(o) = v.as_object_mut() {
        o.insert("type".to_string(), json!(format!("{}_result", frame.trim_start_matches("get_"))));
        o.insert("client_id".to_string(), json!(client_id));
    }
    send_json(sink, &v).await
}

/// `get_artifact` → the files of an artifact the daemon kept a copy of:
/// one `artifact_file` per chunk, then `artifact_end` (v1.6).
async fn handle_get_artifact(state: &AppState, sink: &mut WsSink, msg: &Value) -> Result<()> {
    use base64::Engine as _;
    let client_id = str_field(msg, "client_id").to_string();
    let session_id = str_field(msg, "session_id");
    let url = str_field(msg, "url");
    let by_id = str_field(msg, "id").to_string();
    let found = if !by_id.is_empty() && by_id == artifacts::id_of(&format!("x/{by_id}")) && artifacts::dir(&by_id).is_dir() {
        // A folder the daemon exposed itself (a feature's handoff, v1.7).
        Some(transcript::Artifact { id: by_id.clone(), local: true, entry: str_field(msg, "entry").to_string(), kind: "page".to_string(), title: str_field(msg, "title").to_string(), ..transcript::Artifact::default() })
    } else {
        state
            .session_list()
            .into_iter()
            .find(|s| s.id == session_id)
            .and_then(|s| s.artifacts.into_iter().find(|a| a.url == url))
            .filter(|a| a.local && !a.id.is_empty())
    };
    let Some(a) = found else {
        let v = json!({"type": "artifact_end", "client_id": client_id, "ok": false, "error": "The files are no longer on the PC"});
        return send_json(sink, &v).await;
    };
    let id = a.id.clone();
    let files = tokio::task::spawn_blocking(move || artifacts::files(&id)).await.unwrap_or_default();
    if files.is_empty() {
        let v = json!({"type": "artifact_end", "client_id": client_id, "ok": false, "error": "The files are no longer on the PC"});
        return send_json(sink, &v).await;
    }
    for (path, bytes) in files {
        let text = if artifacts::is_text(&path) { String::from_utf8(bytes.clone()).ok() } else { None };
        let (encoding, payload) = match text {
            Some(t) => ("text", t),
            None => ("base64", base64::engine::general_purpose::STANDARD.encode(&bytes)),
        };
        let parts = chunks(&payload, ARTIFACT_CHUNK);
        let n = parts.len();
        for (i, data) in parts.into_iter().enumerate() {
            let v = json!({"type": "artifact_file", "client_id": client_id, "path": path, "part": i, "parts": n, "encoding": encoding, "data": data});
            send_json(sink, &v).await?;
        }
    }
    let v = json!({"type": "artifact_end", "client_id": client_id, "ok": true, "id": a.id, "kind": a.kind, "entry": a.entry, "title": a.title});
    send_json(sink, &v).await
}

/// Bytes per `artifact_file` frame: under the relay's message limit.
const ARTIFACT_CHUNK: usize = 600_000;

/// `s` in pieces of at most `max` bytes, on char boundaries; one empty
/// piece for an empty string.
fn chunks(s: &str, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0;
    while start < s.len() {
        let mut end = (start + max).min(s.len());
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        out.push(s[start..end].to_string());
        start = end;
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

fn str_field<'a>(msg: &'a Value, key: &str) -> &'a str {
    msg.get(key).and_then(Value::as_str).unwrap_or("")
}

/// `get_chat` → `chat` (empty for an unknown session).
async fn handle_get_chat(state: &AppState, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let session_id = str_field(msg, "session_id");
    let limit = msg
        .get("limit")
        .and_then(Value::as_u64)
        .map(|l| l as usize)
        .unwrap_or(transcript::DEFAULT_LIMIT)
        .clamp(1, transcript::MAX_LIMIT);
    let (title, items) = match state.chat(session_id, limit).await {
        Some((session, items)) => (session.title, items),
        None => (String::new(), Vec::new()),
    };
    send_json(
        sink,
        &json!({"type": "chat", "session_id": session_id, "title": title, "items": items}),
    )
    .await
}

/// `get_image` → `image` with the data, or with `error` when it is gone.
async fn handle_get_image(state: &AppState, sink: &mut WsSink, msg: &Value) -> Result<()> {
    let session_id = str_field(msg, "session_id");
    let image_id = str_field(msg, "image_id");
    let reply = match state.image(session_id, image_id).await {
        Some((mime, data)) => json!({
            "type": "image", "session_id": session_id, "image_id": image_id,
            "mime": mime, "data": data,
        }),
        None => json!({
            "type": "image", "session_id": session_id, "image_id": image_id,
            "error": "not_found",
        }),
    };
    send_json(sink, &reply).await
}

/// `send` → deliver / queue / reject (PROTOCOL.md v1.2), then `send_result`.
async fn handle_send(
    state: &AppState,
    device: &Device,
    sink: &mut WsSink,
    msg: &Value,
) -> Result<()> {
    let session_id = str_field(msg, "session_id");
    let client_id = str_field(msg, "client_id");
    let outcome = match uploads::decode(msg.get("images")) {
        Ok(images) => {
            state
                .send_message(session_id, str_field(msg, "text"), client_id, images)
                .await
        }
        Err(reason) => crate::sessions::SendOutcome::Rejected(reason),
    };
    let short: String = session_id.chars().take(8).collect();
    eprintln!(
        "mewo: phone message for session {short} from device {} ({}): {} {}",
        device.id,
        device.name,
        outcome.status(),
        outcome.reason()
    );
    send_json(
        sink,
        &json!({
            "type": "send_result",
            "client_id": client_id,
            "status": outcome.status(),
            "reason": outcome.reason(),
        }),
    )
    .await
}

/// `answer` for a pending v1.1 request.
async fn handle_answer(
    state: &AppState,
    device: &Device,
    sink: &mut WsSink,
    msg: &Value,
) -> Result<()> {
    let request_id = msg.get("request_id").and_then(Value::as_str).unwrap_or("");
    let answer = match msg.get("answer") {
        Some(a) if a.is_object() => a.clone(),
        _ => {
            eprintln!(
                "mewo: device {} sent a malformed answer for request {request_id}",
                device.id
            );
            return Ok(());
        }
    };
    if state.answer_request(request_id, answer) {
        eprintln!(
            "mewo: request {request_id} answered by device {} ({})",
            device.id, device.name
        );
        return Ok(());
    }
    // Unknown or already resolved: tell this phone only.
    send_resolved(sink, request_id, state.resolved_by(request_id)).await
}

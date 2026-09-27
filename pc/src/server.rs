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

use crate::config::Identity;
use crate::daemon::AppState;
use crate::store::Event;

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
                eprintln!("ccnotify: accept error: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        let _ = tcp.set_nodelay(true);
        let state = state.clone();
        let acceptor = acceptor.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(state, acceptor, tcp).await {
                eprintln!("ccnotify: client {peer}: {e:#}");
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
        eprintln!("ccnotify: pairing attempt with invalid code");
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
    eprintln!("ccnotify: paired device {} ({})", device.id, device.name);

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

    let (mut rx, last_id, backlog) = state.subscribe_since(since);
    send_json(
        &mut sink,
        &json!({
            "type": "hello",
            "pc_id": state.config.pc_id,
            "name": state.config.name,
            "last_id": last_id,
        }),
    )
    .await?;

    let _guard = ConnGuard::new(&state.connected);
    eprintln!(
        "ccnotify: device {} ({}) connected, since={} replay={}",
        device.id,
        device.name,
        since,
        backlog.len()
    );

    let result = subscriber_loop(state, &device.token, &mut sink, &mut stream, &mut rx, since.min(last_id), backlog).await;
    close(&mut sink).await;
    eprintln!("ccnotify: device {} ({}) disconnected", device.id, device.name);
    result
}

async fn subscriber_loop(
    state: &AppState,
    token: &str,
    sink: &mut WsSink,
    stream: &mut WsStream,
    rx: &mut tokio::sync::broadcast::Receiver<Event>,
    start_after: u64,
    backlog: Vec<Event>,
) -> Result<()> {
    let mut last_sent = start_after;
    for ev in backlog {
        send_event(sink, &ev).await?;
        last_sent = ev.id;
    }

    let mut ping = interval_at(Instant::now() + PING_INTERVAL, PING_INTERVAL);
    ping.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last_seen = Instant::now();

    loop {
        tokio::select! {
            received = rx.recv() => {
                match received {
                    Ok(ev) => {
                        if ev.id > last_sent {
                            send_event(sink, &ev).await?;
                            last_sent = ev.id;
                        }
                    }
                    Err(RecvError::Lagged(_)) => {
                        // Fell behind the live stream: catch up from the store.
                        for ev in state.events_since(last_sent) {
                            send_event(sink, &ev).await?;
                            last_sent = ev.id;
                        }
                    }
                    Err(RecvError::Closed) => return Ok(()),
                }
            }
            _ = ping.tick() => {
                if !state.token_valid(token) {
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
                    Some(Ok(_)) => last_seen = Instant::now(),
                    Some(Err(e)) => return Err(anyhow!("read: {e}")),
                }
            }
        }
    }
}

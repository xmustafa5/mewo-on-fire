//! Relay for phones outside the LAN (PROTOCOL.md v1.4).
//!
//! A PC behind a provider's NAT cannot be reached from the internet, so the
//! daemon and the phone both connect out to a relay, which passes bytes
//! between them. What it passes is the phone's ordinary connection — TLS
//! with the pinned certificate, then the token — so the relay sees nothing
//! but ciphertext and needs no trust.
//!
//! The daemon keeps one WebSocket to `<relay>/pc/<pc_id>/listen?key=<key>`:
//! - text `{"open": N}`: a phone connected; `{"close": N}`: it left (sent by
//!   either side);
//! - binary: 4 bytes connection number (big endian), then the bytes.
//! Every connection is piped to the daemon's own port on localhost.
//!
//! [`serve`] is the relay itself, for a machine of your own (plain `ws://`:
//! put it behind a TLS proxy). `relay/` has the same for a Cloudflare Worker.

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::Connector;

use crate::daemon::AppState;

const MAX_BACKOFF: Duration = Duration::from_secs(60);
const PING_EVERY: Duration = Duration::from_secs(30);
/// Nothing from the relay for this long (not even a pong): connect again.
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
/// Bytes read from the local connection per relay message.
const CHUNK: usize = 32 * 1024;

/// What phones are told to connect to: `wss://relay.example` as it is in the
/// config, without a trailing slash.
pub fn base_url(configured: &str) -> String {
    configured.trim().trim_end_matches('/').to_string()
}

fn frame(id: u32, data: &[u8]) -> Message {
    let mut out = Vec::with_capacity(4 + data.len());
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(data);
    Message::Binary(out)
}

fn control(kind: &str, id: u32) -> Message {
    Message::Text(json!({ kind: id }).to_string())
}

/// The connection number of a `{"open": N}` / `{"close": N}` message.
fn control_id(text: &str, kind: &str) -> Option<u32> {
    serde_json::from_str::<Value>(text)
        .ok()?
        .get(kind)?
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
}

// ---------------------------------------------------------------------------
// daemon side
// ---------------------------------------------------------------------------

/// TLS towards the relay: ordinary web certificates.
fn connector() -> Result<Connector> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| anyhow!("TLS protocol versions: {e}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Connector::Rustls(Arc::new(config)))
}

/// Stays connected to the configured relay for as long as the daemon runs.
pub async fn run(state: Arc<AppState>) {
    let base = base_url(&state.config.relay);
    if base.is_empty() {
        return;
    }
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        let result = session(&state, &base).await;
        state.relay_up.store(false, Ordering::SeqCst);
        match result {
            Ok(()) => eprintln!("ccnotify: relay closed the connection"),
            Err(e) => eprintln!("ccnotify: relay: {e:#}"),
        }
        if started.elapsed() > Duration::from_secs(30) {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

async fn session(state: &Arc<AppState>, base: &str) -> Result<()> {
    let url = format!(
        "{base}/pc/{}/listen?key={}",
        state.config.pc_id, state.config.relay_key
    );
    let (ws, _) = tokio::time::timeout(
        Duration::from_secs(20),
        tokio_tungstenite::connect_async_tls_with_config(url, None, false, Some(connector()?)),
    )
    .await
    .map_err(|_| anyhow!("no answer from {base}"))?
    .with_context(|| format!("connecting to {base}"))?;
    eprintln!("ccnotify: relay connected: {base}");
    state.relay_up.store(true, Ordering::SeqCst);

    let (mut sink, mut stream) = ws.split();
    // Everything the phones' connections send goes through here.
    let (out_tx, mut out_rx) = mpsc::channel::<Message>(256);
    let mut conns: HashMap<u32, mpsc::Sender<Vec<u8>>> = HashMap::new();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut heard = Instant::now();
    let port = state.config.port;

    loop {
        tokio::select! {
            msg = stream.next() => {
                let msg = match msg {
                    Some(m) => m.context("reading from the relay")?,
                    None => return Ok(()),
                };
                heard = Instant::now();
                match msg {
                    Message::Text(text) => {
                        if let Some(id) = control_id(&text, "open") {
                            let (tx, rx) = mpsc::channel::<Vec<u8>>(64);
                            conns.insert(id, tx);
                            tokio::spawn(pipe(id, port, out_tx.clone(), rx));
                        } else if let Some(id) = control_id(&text, "close") {
                            conns.remove(&id);
                        }
                    }
                    Message::Binary(data) if data.len() >= 4 => {
                        let id = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
                        let gone = match conns.get(&id) {
                            Some(tx) => tx.send(data[4..].to_vec()).await.is_err(),
                            None => false,
                        };
                        if gone {
                            conns.remove(&id);
                        }
                    }
                    Message::Close(_) => return Ok(()),
                    _ => {}
                }
            }
            Some(msg) = out_rx.recv() => {
                // A connection that ended is forgotten here too.
                if let Message::Text(text) = &msg {
                    if let Some(id) = control_id(text, "close") {
                        conns.remove(&id);
                    }
                }
                sink.send(msg).await.context("writing to the relay")?;
            }
            _ = ping.tick() => {
                if heard.elapsed() > SILENCE_LIMIT {
                    bail!("the relay went silent");
                }
                sink.send(Message::Ping(Vec::new())).await.context("writing to the relay")?;
            }
        }
    }
}

/// One phone's connection: relay <-> this daemon's port on localhost.
async fn pipe(id: u32, port: u16, out: mpsc::Sender<Message>, mut from_phone: mpsc::Receiver<Vec<u8>>) {
    if let Ok(stream) = TcpStream::connect(("127.0.0.1", port)).await {
        let (mut reader, mut writer) = stream.into_split();
        let mut buf = vec![0u8; CHUNK];
        loop {
            tokio::select! {
                read = reader.read(&mut buf) => match read {
                    Ok(n) if n > 0 => {
                        if out.send(frame(id, &buf[..n])).await.is_err() {
                            return; // the relay connection is gone
                        }
                    }
                    _ => break,
                },
                data = from_phone.recv() => match data {
                    Some(data) => {
                        if writer.write_all(&data).await.is_err() {
                            break;
                        }
                    }
                    None => break, // closed by the phone or the relay
                },
            }
        }
    }
    let _ = out.send(control("close", id)).await;
}

// ---------------------------------------------------------------------------
// the relay itself (`ccnotify relay-server`)
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Pc {
    /// Set by the first daemon that listens for this id.
    key: String,
    host: Option<mpsc::Sender<Message>>,
    /// Counts the daemon connections, so an old one cannot clear a new one.
    generation: u64,
    phones: HashMap<u32, mpsc::Sender<Message>>,
    next: u32,
}

type Pcs = Arc<Mutex<HashMap<String, Pc>>>;

fn lock(pcs: &Pcs) -> std::sync::MutexGuard<'_, HashMap<String, Pc>> {
    pcs.lock().unwrap_or_else(|e| e.into_inner())
}

/// `/pc/<id>/<listen|connect>[?key=…]` → (id, role, key).
fn parse_path(uri: &str) -> Option<(String, String, String)> {
    let (path, query) = uri.split_once('?').unwrap_or((uri, ""));
    let mut parts = path.trim_start_matches('/').split('/');
    let (pc, id, role) = (parts.next()?, parts.next()?, parts.next()?);
    if pc != "pc" || parts.next().is_some() || !matches!(role, "listen" | "connect") {
        return None;
    }
    if id.len() < 8 || id.len() > 64 || !id.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let key = query
        .split('&')
        .find_map(|p| p.strip_prefix("key="))
        .unwrap_or("")
        .to_string();
    Some((id.to_string(), role.to_string(), key))
}

/// Runs a relay on `port` until the process is stopped.
pub fn serve(port: u16) -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting tokio runtime")?;
    rt.block_on(async move {
        let listener = TcpListener::bind(("0.0.0.0", port))
            .await
            .with_context(|| format!("binding 0.0.0.0:{port}"))?;
        eprintln!("ccnotify relay: listening on port {port} (ws://, put TLS in front of it)");
        let pcs: Pcs = Arc::default();
        loop {
            let (tcp, _) = listener.accept().await?;
            let pcs = pcs.clone();
            tokio::spawn(async move {
                let _ = serve_one(tcp, pcs).await;
            });
        }
    })
}

async fn serve_one(tcp: TcpStream, pcs: Pcs) -> Result<()> {
    let mut target: Option<(String, String, String)> = None;
    let ws = tokio_tungstenite::accept_hdr_async(tcp, |req: &Request, resp: Response| {
        target = parse_path(&req.uri().to_string());
        if target.is_some() {
            Ok(resp)
        } else {
            let mut refuse = ErrorResponse::new(None);
            *refuse.status_mut() = StatusCode::NOT_FOUND;
            Err(refuse)
        }
    })
    .await?;
    let (id, role, key) = target.ok_or_else(|| anyhow!("no path"))?;
    let (mut sink, mut stream) = ws.split();
    let (tx, mut rx) = mpsc::channel::<Message>(256);

    if role == "listen" {
        // None: the id belongs to a daemon with another key.
        let generation = {
            let mut pcs = lock(&pcs);
            let pc = pcs.entry(id.clone()).or_default();
            if key.len() < 16 || (!pc.key.is_empty() && pc.key != key) {
                None
            } else {
                pc.key = key;
                pc.phones.clear(); // they were talking to the daemon before this one
                pc.host = Some(tx);
                pc.generation += 1;
                Some(pc.generation)
            }
        };
        let Some(generation) = generation else {
            let _ = sink.send(Message::Close(None)).await;
            bail!("wrong key for {id}");
        };
        loop {
            tokio::select! {
                msg = stream.next() => match msg {
                    Some(Ok(Message::Binary(data))) if data.len() >= 4 => {
                        let n = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
                        let phone = lock(&pcs).get(&id).and_then(|pc| pc.phones.get(&n).cloned());
                        if let Some(phone) = phone {
                            let _ = phone.send(Message::Binary(data[4..].to_vec())).await;
                        }
                    }
                    Some(Ok(Message::Text(text))) => {
                        if let Some(n) = control_id(&text, "close") {
                            // Dropping its sender ends the phone's task.
                            lock(&pcs).get_mut(&id).map(|pc| pc.phones.remove(&n));
                        }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
                Some(msg) = rx.recv() => {
                    if sink.send(msg).await.is_err() {
                        break;
                    }
                }
            }
        }
        let mut pcs = lock(&pcs);
        if let Some(pc) = pcs.get_mut(&id) {
            if pc.generation == generation {
                pc.host = None;
                pc.phones.clear();
            }
        }
        return Ok(());
    }

    // A phone.
    let (n, host) = {
        let mut pcs = lock(&pcs);
        let Some(pc) = pcs.get_mut(&id) else {
            bail!("no such PC");
        };
        let Some(host) = pc.host.clone() else {
            bail!("PC offline");
        };
        pc.next = pc.next.wrapping_add(1);
        pc.phones.insert(pc.next, tx);
        (pc.next, host)
    };
    let _ = host.send(control("open", n)).await;
    loop {
        tokio::select! {
            msg = stream.next() => match msg {
                Some(Ok(Message::Binary(data))) => {
                    if host.send(frame(n, &data)).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
            msg = rx.recv() => match msg {
                Some(msg) => {
                    if sink.send(msg).await.is_err() {
                        break;
                    }
                }
                None => break, // closed by the daemon
            },
        }
    }
    lock(&pcs).get_mut(&id).map(|pc| pc.phones.remove(&n));
    let _ = host.send(control("close", n)).await;
    let _ = sink.send(Message::Close(None)).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths() {
        assert_eq!(
            parse_path("/pc/0123456789abcdef/listen?key=secret"),
            Some(("0123456789abcdef".into(), "listen".into(), "secret".into()))
        );
        assert_eq!(
            parse_path("/pc/0123456789abcdef/connect"),
            Some(("0123456789abcdef".into(), "connect".into(), String::new()))
        );
        assert_eq!(parse_path("/pc/xyz/connect"), None);
        assert_eq!(parse_path("/pc/0123456789abcdef/other"), None);
        assert_eq!(parse_path("/"), None);
    }

    #[test]
    fn control_messages() {
        assert_eq!(control_id(r#"{"open":7}"#, "open"), Some(7));
        assert_eq!(control_id(r#"{"open":7}"#, "close"), None);
        assert_eq!(control_id("nonsense", "open"), None);
        assert_eq!(base_url(" wss://relay.example/ "), "wss://relay.example");
    }
}

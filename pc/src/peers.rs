//! Peers (v2.0): the other PCs' daemons this one pairs with, as a phone
//! does, and stays connected to. Their sessions, features and events
//! show up here, and commands go to them. The PC the console talks to is
//! the hub of its network; any PC can be one.

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use futures_util::{SinkExt, StreamExt};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, oneshot, Notify};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::Connector;

use crate::config::{now_ms, random_hex};
use crate::daemon::AppState;
use crate::paths;
use crate::sessions::Session;
use crate::store::Event;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const REPLY_TIMEOUT: Duration = Duration::from_secs(25);
const FEATURES_EVERY: Duration = Duration::from_secs(30);
const PING_EVERY: Duration = Duration::from_secs(25);
const IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
const MAX_EVENTS: usize = 60;

/// A paired PC, as `peers.json` keeps it (mode 600: it holds the token).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Peer {
    pub pc_id: String,
    pub name: String,
    pub hosts: Vec<String>,
    pub port: u16,
    pub fp: String,
    pub token: String,
    pub device_id: String,
    pub added: u64,
}

/// What we know of a peer right now.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Live {
    pub connected: bool,
    pub error: String,
    pub host: String,
    pub last_seen: u64,
    pub since: u64,
    pub latency_ms: u64,
    pub account: String,
    pub sessions: Vec<Session>,
    #[serde(skip)]
    pub features: Value,
    pub events: VecDeque<Event>,
    pub requests: Vec<Value>,
}

#[derive(Default)]
pub struct Peers {
    list: Mutex<Vec<Peer>>,
    live: Mutex<HashMap<String, Live>>,
    outbound: Mutex<HashMap<String, mpsc::Sender<Value>>>,
    waits: Mutex<HashMap<String, oneshot::Sender<Value>>>,
    seq: AtomicU64,
    /// Woken when the list changes, so loops start or stop.
    pub changed: Notify,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn file() -> std::path::PathBuf {
    paths::config_dir().join("peers.json")
}

fn load() -> Vec<Peer> {
    fs::read_to_string(file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save(list: &[Peer]) -> Result<()> {
    let text = serde_json::to_string_pretty(list)?;
    paths::write_atomic(&file(), format!("{text}\n").as_bytes(), 0o600).context("writing peers.json")
}

impl Peers {
    pub fn new() -> Peers {
        let list = load();
        let mut live = HashMap::new();
        for p in &list {
            live.insert(p.pc_id.clone(), Live::default());
        }
        Peers { list: Mutex::new(list), live: Mutex::new(live), ..Peers::default() }
    }

    pub fn list(&self) -> Vec<Peer> {
        lock(&self.list).clone()
    }

    pub fn get(&self, pc_id: &str) -> Option<Peer> {
        lock(&self.list).iter().find(|p| p.pc_id == pc_id).cloned()
    }

    pub fn is_peer(&self, pc_id: &str) -> bool {
        self.get(pc_id).is_some()
    }

    /// The peers with their live state, for the console and the phones.
    pub fn summary(&self) -> Vec<Value> {
        let list = self.list();
        let live = lock(&self.live);
        list.iter()
            .map(|p| {
                let l = live.get(&p.pc_id).cloned().unwrap_or_default();
                let working = l.sessions.iter().filter(|s| s.state == "working").count();
                let waiting = l.sessions.iter().filter(|s| s.state == "waiting").count();
                json!({
                    "pc_id": p.pc_id, "name": p.name, "hosts": p.hosts, "port": p.port, "added": p.added,
                    "connected": l.connected, "error": l.error, "host": l.host, "last_seen": l.last_seen,
                    "latency_ms": l.latency_ms, "account": l.account,
                    "sessions": l.sessions, "working": working, "waiting": waiting,
                    "events": l.events, "requests": l.requests,
                    "features": l.features.get("features").cloned().unwrap_or(json!([])),
                })
            })
            .collect()
    }

    /// Every peer's sessions, tagged with the PC.
    pub fn sessions(&self) -> Vec<(String, String, Session)> {
        let list = self.list();
        let live = lock(&self.live);
        let mut out = Vec::new();
        for p in list {
            if let Some(l) = live.get(&p.pc_id) {
                for s in &l.sessions {
                    out.push((p.pc_id.clone(), p.name.clone(), s.clone()));
                }
            }
        }
        out
    }

    /// A peer's last `features` reply.
    pub fn features(&self, pc_id: &str) -> Value {
        lock(&self.live).get(pc_id).map(|l| l.features.clone()).unwrap_or(Value::Null)
    }

    pub fn add(&self, peer: Peer) -> Result<()> {
        let mut list = lock(&self.list);
        list.retain(|p| p.pc_id != peer.pc_id);
        list.push(peer.clone());
        save(&list)?;
        lock(&self.live).insert(peer.pc_id.clone(), Live::default());
        self.changed.notify_waiters();
        Ok(())
    }

    pub fn remove(&self, pc_id: &str) -> Result<bool> {
        let mut list = lock(&self.list);
        let before = list.len();
        list.retain(|p| p.pc_id != pc_id);
        let removed = list.len() != before;
        if removed {
            save(&list)?;
            lock(&self.live).remove(pc_id);
            lock(&self.outbound).remove(pc_id);
            self.changed.notify_waiters();
        }
        Ok(removed)
    }

    fn update<F: FnOnce(&mut Live)>(&self, pc_id: &str, f: F) {
        let mut live = lock(&self.live);
        let entry = live.entry(pc_id.to_string()).or_default();
        f(entry);
    }

    /// Sends a frame to a peer and waits for its reply (by `client_id`).
    pub async fn forward(&self, pc_id: &str, mut frame: Value) -> Value {
        let name = self.get(pc_id).map(|p| p.name).unwrap_or_else(|| pc_id.to_string());
        let sender = match lock(&self.outbound).get(pc_id).cloned() {
            Some(s) => s,
            None => return json!({"ok": false, "error": format!("{name} is not connected")}),
        };
        let client_id = format!("hub-{}-{}", self.seq.fetch_add(1, Ordering::SeqCst), random_hex(2));
        if let Some(o) = frame.as_object_mut() {
            o.insert("client_id".to_string(), json!(client_id));
        }
        let (tx, rx) = oneshot::channel();
        lock(&self.waits).insert(client_id.clone(), tx);
        if sender.send(frame).await.is_err() {
            lock(&self.waits).remove(&client_id);
            return json!({"ok": false, "error": format!("{name} is not connected")});
        }
        match tokio::time::timeout(REPLY_TIMEOUT, rx).await {
            Ok(Ok(v)) => v,
            _ => {
                lock(&self.waits).remove(&client_id);
                json!({"ok": false, "error": format!("No answer from {name}")})
            }
        }
    }

    fn resolve(&self, client_id: &str, v: Value) -> bool {
        match lock(&self.waits).remove(client_id) {
            Some(tx) => tx.send(v).is_ok(),
            None => false,
        }
    }
}

// ---------------------------------------------------------------------------
// TLS: the peer's self-signed certificate, pinned by its fingerprint
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct Pinned {
    fp: Vec<u8>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let got = Sha256::digest(end_entity.as_ref());
        if got.as_slice() == self.fp.as_slice() {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("the PC's certificate is not the one it was paired with".to_string()))
        }
    }

    fn verify_tls12_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

fn connector(fp_hex: &str) -> Result<Connector> {
    let fp = hex::decode(fp_hex.trim()).context("the fingerprint is not hex")?;
    if fp.len() != 32 {
        return Err(anyhow!("the fingerprint is not a SHA-256"));
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(|e| anyhow!("TLS protocol versions: {e}"))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned { fp, provider }))
        .with_no_client_auth();
    Ok(Connector::Rustls(Arc::new(config)))
}

/// The WebSocket address of a host from a pairing payload: an IP or name
/// with the port, or a relay base.
fn url_for(host: &str, port: u16, pc_id: &str) -> String {
    if host.starts_with("wss://") || host.starts_with("https://") {
        let base = host.replacen("https://", "wss://", 1);
        format!("{}/pc/{pc_id}/connect", base.trim_end_matches('/'))
    } else if host.contains(':') && !host.starts_with('[') {
        format!("wss://[{host}]:{port}/")
    } else {
        format!("wss://{host}:{port}/")
    }
}

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(hosts: &[String], port: u16, pc_id: &str, fp: &str) -> Result<(Ws, String)> {
    let conn = connector(fp)?;
    let mut last = anyhow!("no host to try");
    // LAN addresses only: the relay carries a phone's own TLS tunnel, which
    // a peer does not speak.
    let ordered: Vec<&String> = hosts.iter().filter(|h| !h.starts_with("wss://") && !h.starts_with("https://")).collect();
    if ordered.is_empty() {
        return Err(anyhow!("no LAN address for this PC"));
    }
    for host in ordered {
        let url = url_for(host, port, pc_id);
        match tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async_tls_with_config(url.clone(), None, false, Some(conn.clone()))).await {
            Ok(Ok((ws, _))) => return Ok((ws, host.clone())),
            Ok(Err(e)) => last = anyhow!("{host}: {e}"),
            Err(_) => last = anyhow!("{host}: no answer"),
        }
    }
    Err(last)
}

// ---------------------------------------------------------------------------
// pairing and discovery
// ---------------------------------------------------------------------------

/// A pairing payload as `mewo pair` prints it (`{"v":1,"id","name","hosts","port","fp","code"}`).
#[derive(Debug, Clone, Deserialize)]
pub struct PairPayload {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub hosts: Vec<String>,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub fp: String,
    #[serde(default)]
    pub code: String,
}

/// Pairs with another PC as a device named after this hub.
pub async fn pair(state: &AppState, p: &PairPayload) -> Result<Peer> {
    if p.code.trim().is_empty() {
        return Err(anyhow!("The pairing code is missing"));
    }
    if p.hosts.is_empty() || p.fp.is_empty() {
        return Err(anyhow!("The pairing text needs the PC's address and certificate fingerprint; paste the whole line `mewo pair` prints"));
    }
    if p.id == state.config.pc_id {
        return Err(anyhow!("That is this PC"));
    }
    let (ws, host) = connect(&p.hosts, p.port, &p.id, &p.fp).await?;
    let (mut sink, mut stream) = ws.split();
    let device_name = format!("Hub: {}", state.config.name);
    sink.send(Message::Text(json!({"type": "pair", "code": p.code.trim(), "device_name": device_name}).to_string())).await?;
    let reply = tokio::time::timeout(CONNECT_TIMEOUT, stream.next()).await.map_err(|_| anyhow!("no answer to the pairing"))?.ok_or_else(|| anyhow!("the PC closed the connection"))??;
    let v: Value = match reply {
        Message::Text(t) => serde_json::from_str(&t).unwrap_or(Value::Null),
        _ => Value::Null,
    };
    if v.get("type").and_then(Value::as_str) != Some("paired") {
        let err = v.get("error").and_then(Value::as_str).unwrap_or("the PC refused");
        return Err(anyhow!("Pairing failed: {}", if err == "invalid_code" { "wrong or expired code (run `mewo pair` on that PC again)" } else { err }));
    }
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let peer = Peer {
        pc_id: if s("pc_id").is_empty() { p.id.clone() } else { s("pc_id") },
        name: if s("name").is_empty() { p.name.clone() } else { s("name") },
        hosts: {
            let extra: Vec<String> = p.hosts.iter().filter(|x| **x != host).cloned().collect();
            let mut h = vec![host];
            h.extend(extra);
            h
        },
        port: p.port,
        fp: p.fp.clone(),
        token: s("token"),
        device_id: s("device_id"),
        added: now_ms(),
    };
    state.peers.add(peer.clone())?;
    Ok(peer)
}

/// PCs advertising `_ccnotify._tcp` on the LAN, for a few seconds.
pub async fn scan(secs: u64) -> Vec<Value> {
    let found: Arc<Mutex<HashMap<String, Value>>> = Arc::new(Mutex::new(HashMap::new()));
    let found2 = found.clone();
    let _ = tokio::task::spawn_blocking(move || {
        let Ok(daemon) = mdns_sd::ServiceDaemon::new() else { return };
        let Ok(rx) = daemon.browse(crate::mdns::SERVICE_TYPE) else { return };
        let until = Instant::now() + Duration::from_secs(secs.clamp(1, 10));
        while Instant::now() < until {
            match rx.recv_timeout(Duration::from_millis(300)) {
                Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) => {
                    let id = info.get_property_val_str("id").unwrap_or("").to_string();
                    let fp = info.get_property_val_str("fp").unwrap_or("").to_string();
                    let name = info.get_fullname().split('.').next().unwrap_or("").replace("\\032", " ");
                    let hosts: Vec<String> = info.get_addresses().iter().filter(|a| a.is_ipv4()).map(|a| a.to_string()).collect();
                    let key = if id.is_empty() { name.clone() } else { id.clone() };
                    lock(&found2).insert(key, json!({"id": id, "name": name, "hosts": hosts, "port": info.get_port(), "fp": fp}));
                }
                Ok(_) => {}
                Err(_) => {}
            }
        }
        let _ = daemon.shutdown();
    })
    .await;
    let mut out: Vec<Value> = lock(&found).values().cloned().collect();
    out.sort_by_key(|v| v.get("name").and_then(Value::as_str).unwrap_or("").to_string());
    out
}

// ---------------------------------------------------------------------------
// staying connected
// ---------------------------------------------------------------------------

/// Keeps a connection to every paired PC for as long as the daemon runs.
pub async fn run(state: Arc<AppState>) {
    let mut running: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
    loop {
        let list = state.peers.list();
        for p in &list {
            if !running.get(&p.pc_id).map(|h| !h.is_finished()).unwrap_or(false) {
                let st = state.clone();
                let id = p.pc_id.clone();
                running.insert(p.pc_id.clone(), tokio::spawn(async move { peer_loop(st, id).await }));
            }
        }
        for (id, h) in running.iter() {
            if !list.iter().any(|p| &p.pc_id == id) {
                h.abort();
            }
        }
        running.retain(|id, _| list.iter().any(|p| &p.pc_id == id));
        let _ = tokio::time::timeout(Duration::from_secs(30), state.peers.changed.notified()).await;
    }
}

async fn peer_loop(state: Arc<AppState>, pc_id: String) {
    let mut backoff = Duration::from_secs(2);
    loop {
        let Some(peer) = state.peers.get(&pc_id) else { return };
        let started = Instant::now();
        let result = session(&state, &peer).await;
        state.peers.update(&pc_id, |l| {
            l.connected = false;
            if let Err(e) = &result {
                l.error = format!("{e:#}");
            }
        });
        lock(&state.peers.outbound).remove(&pc_id);
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(2);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

async fn session(state: &Arc<AppState>, peer: &Peer) -> Result<()> {
    let (ws, host) = connect(&peer.hosts, peer.port, &peer.pc_id, &peer.fp).await?;
    let (mut sink, mut stream) = ws.split();
    let since = lock(&state.peers.live).get(&peer.pc_id).map(|l| l.since).unwrap_or(0);
    sink.send(Message::Text(json!({"type": "auth", "token": peer.token, "since": since}).to_string())).await?;
    let (tx, mut rx) = mpsc::channel::<Value>(64);
    lock(&state.peers.outbound).insert(peer.pc_id.clone(), tx);
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut features_tick = tokio::time::interval(FEATURES_EVERY);
    let mut heard = Instant::now();
    let mut pinged_at: Option<Instant> = None;
    let mut hello = false;
    loop {
        tokio::select! {
            msg = stream.next() => {
                let msg = match msg {
                    Some(m) => m.with_context(|| format!("reading from {}", peer.name))?,
                    None => return Err(anyhow!("{} closed the connection", peer.name)),
                };
                heard = Instant::now();
                match msg {
                    Message::Text(t) => {
                        let v: Value = match serde_json::from_str(&t) { Ok(v) => v, Err(_) => continue };
                        let ty = v.get("type").and_then(Value::as_str).unwrap_or("").to_string();
                        match ty.as_str() {
                            "hello" => {
                                hello = true;
                                let account = v.get("account").and_then(Value::as_str).unwrap_or("").to_string();
                                state.peers.update(&peer.pc_id, |l| { l.connected = true; l.error.clear(); l.host = host.clone(); l.last_seen = now_ms(); l.account = account; });
                                eprintln!("mewo: peer {} connected via {host}", peer.name);
                                sink.send(Message::Text(json!({"type": "sessions"}).to_string())).await?;
                                sink.send(Message::Text(json!({"type": "get_features", "client_id": "hub-features"}).to_string())).await?;
                            }
                            "error" => {
                                let e = v.get("error").and_then(Value::as_str).unwrap_or("error").to_string();
                                return Err(anyhow!("{} said: {}", peer.name, if e == "unauthorized" { "unauthorized (pair again)".to_string() } else { e }));
                            }
                            "sessions" => {
                                let list: Vec<Session> = v.get("sessions").and_then(|s| serde_json::from_value(s.clone()).ok()).unwrap_or_default();
                                state.peers.update(&peer.pc_id, |l| { l.sessions = list; l.last_seen = now_ms(); });
                            }
                            "session" => {
                                if let Some(s) = v.get("session").and_then(|s| serde_json::from_value::<Session>(s.clone()).ok()) {
                                    state.peers.update(&peer.pc_id, |l| {
                                        l.sessions.retain(|x| x.id != s.id);
                                        l.sessions.push(s);
                                        l.sessions.sort_by(|a, b| b.last_ts.cmp(&a.last_ts));
                                        l.last_seen = now_ms();
                                    });
                                }
                            }
                            "event" => {
                                if let Some(ev) = v.get("event").and_then(|e| serde_json::from_value::<Event>(e.clone()).ok()) {
                                    state.peers.update(&peer.pc_id, |l| {
                                        l.since = l.since.max(ev.id);
                                        l.events.push_back(ev);
                                        while l.events.len() > MAX_EVENTS { l.events.pop_front(); }
                                        l.last_seen = now_ms();
                                    });
                                }
                            }
                            "request" => {
                                if let Some(r) = v.get("request").cloned() {
                                    state.peers.update(&peer.pc_id, |l| { l.requests.retain(|x| x.get("id") != r.get("id")); l.requests.push(r); });
                                }
                            }
                            "resolved" => {
                                let id = v.get("request_id").cloned().unwrap_or(Value::Null);
                                state.peers.update(&peer.pc_id, |l| l.requests.retain(|x| x.get("id") != Some(&id)));
                            }
                            "features" => {
                                if v.get("client_id").and_then(Value::as_str) == Some("hub-features") || v.get("client_id").is_none() {
                                    state.peers.update(&peer.pc_id, |l| { l.features = v.clone(); });
                                } else if let Some(cid) = v.get("client_id").and_then(Value::as_str) {
                                    state.peers.resolve(cid, v.clone());
                                }
                            }
                            _ => {
                                if let Some(cid) = v.get("client_id").and_then(Value::as_str) {
                                    state.peers.resolve(cid, v.clone());
                                }
                            }
                        }
                    }
                    Message::Pong(_) => {
                        if let Some(at) = pinged_at.take() {
                            let ms = at.elapsed().as_millis() as u64;
                            state.peers.update(&peer.pc_id, |l| l.latency_ms = ms);
                        }
                    }
                    Message::Ping(p) => { sink.send(Message::Pong(p)).await?; }
                    Message::Close(_) => return Err(anyhow!("{} closed the connection", peer.name)),
                    _ => {}
                }
            }
            out = rx.recv() => {
                let Some(frame) = out else { return Err(anyhow!("hub channel closed")) };
                sink.send(Message::Text(frame.to_string())).await?;
            }
            _ = ping.tick() => {
                if heard.elapsed() > IDLE_TIMEOUT {
                    return Err(anyhow!("{} went quiet", peer.name));
                }
                pinged_at = Some(Instant::now());
                sink.send(Message::Ping(Vec::new())).await?;
            }
            _ = features_tick.tick() => {
                if hello {
                    sink.send(Message::Text(json!({"type": "get_features", "client_id": "hub-features"}).to_string())).await?;
                    sink.send(Message::Text(json!({"type": "sessions"}).to_string())).await?;
                }
            }
        }
    }
}

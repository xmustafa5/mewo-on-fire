//! `ccnotify daemon`: shared state + startup/shutdown orchestration.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

use crate::config::{self, now_ms, random_hex, Config, Device};
use crate::store::{Event, Store};
use crate::{control, mdns, net, paths, server};

pub const PAIR_TTL: Duration = Duration::from_secs(300);
const BROADCAST_CAPACITY: usize = 256;

pub struct AppState {
    pub config: Config,
    pub fp: String,
    devices: Mutex<Vec<Device>>,
    store: Mutex<Store>,
    tx: broadcast::Sender<Event>,
    pair_codes: Mutex<HashMap<String, Instant>>,
    pub connected: AtomicUsize,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Constant-time byte comparison (for tokens).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

impl AppState {
    /// Store the event (assigning id/ts) and broadcast it to live clients.
    /// Broadcast happens under the store lock so subscribe_since() snapshots
    /// are consistent with the live stream.
    pub fn emit(&self, ev: Event) -> Event {
        let mut store = lock(&self.store);
        let stored = store.append(ev);
        let _ = self.tx.send(stored.clone());
        stored
    }

    pub fn last_id(&self) -> u64 {
        lock(&self.store).last_id()
    }

    pub fn events_since(&self, since: u64) -> Vec<Event> {
        lock(&self.store).since(since)
    }

    /// Atomically: subscribe to live events, read last_id, and snapshot the
    /// stored events after `min(since, last_id)`.
    pub fn subscribe_since(&self, since: u64) -> (broadcast::Receiver<Event>, u64, Vec<Event>) {
        let store = lock(&self.store);
        let rx = self.tx.subscribe();
        let last_id = store.last_id();
        let effective = since.min(last_id);
        let backlog = store.since(effective);
        (rx, last_id, backlog)
    }

    // --- pairing codes -----------------------------------------------------

    pub fn new_pair_code(&self) -> String {
        let code = random_hex(8);
        let now = Instant::now();
        let mut codes = lock(&self.pair_codes);
        codes.retain(|_, expiry| *expiry > now);
        codes.insert(code.clone(), now + PAIR_TTL);
        code
    }

    /// Consume a pairing code. True if it existed and had not expired.
    pub fn take_pair_code(&self, code: &str) -> bool {
        let now = Instant::now();
        let mut codes = lock(&self.pair_codes);
        codes.retain(|_, expiry| *expiry > now);
        codes.remove(code).is_some()
    }

    pub fn pair_payload(&self, code: &str) -> String {
        let payload = json!({
            "v": 1,
            "id": self.config.pc_id,
            "name": self.config.name,
            "hosts": net::hosts(),
            "port": self.config.port,
            "fp": self.fp,
            "code": code,
        });
        serde_json::to_string(&payload).unwrap_or_default()
    }

    // --- devices -----------------------------------------------------------

    pub fn add_device(&self, name: &str) -> Result<Device> {
        let mut devices = lock(&self.devices);
        let mut id = random_hex(4);
        while devices.iter().any(|d| d.id == id) {
            id = random_hex(4);
        }
        let device = Device {
            id,
            name: name.to_string(),
            token: random_hex(32),
            created: now_ms(),
        };
        devices.push(device.clone());
        if let Err(e) = config::save_devices(&devices) {
            devices.pop();
            return Err(e);
        }
        Ok(device)
    }

    pub fn device_by_token(&self, token: &str) -> Option<Device> {
        if token.is_empty() {
            return None;
        }
        lock(&self.devices)
            .iter()
            .find(|d| ct_eq(d.token.as_bytes(), token.as_bytes()))
            .cloned()
    }

    pub fn token_valid(&self, token: &str) -> bool {
        self.device_by_token(token).is_some()
    }

    /// Remove a device. Ok(false) if no such id.
    pub fn revoke(&self, id: &str) -> Result<bool> {
        let mut devices = lock(&self.devices);
        let before = devices.len();
        devices.retain(|d| d.id != id);
        if devices.len() == before {
            return Ok(false);
        }
        config::save_devices(&devices)?;
        Ok(true)
    }

    pub fn device_list(&self) -> Vec<Value> {
        lock(&self.devices)
            .iter()
            .map(|d| json!({"id": d.id, "name": d.name, "created": d.created}))
            .collect()
    }

    pub fn status_json(&self) -> Value {
        let device_count = lock(&self.devices).len();
        json!({
            "ok": true,
            "pc_id": self.config.pc_id,
            "name": self.config.name,
            "port": self.config.port,
            "fp": self.fp,
            "hosts": net::hosts(),
            "devices": device_count,
            "last_id": self.last_id(),
            "connected": self.connected.load(Ordering::SeqCst),
        })
    }
}

pub fn run() -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting tokio runtime")?;
    rt.block_on(run_async())
}

async fn run_async() -> Result<()> {
    let config = config::load_or_create()?;
    let identity = config::load_or_create_identity()?;
    let devices = config::load_devices();
    let store = Store::load(paths::events_file());
    let acceptor = server::tls_acceptor(&identity)?;

    let control_listener = control::bind()?;
    let tcp_listener = TcpListener::bind(("0.0.0.0", config.port))
        .await
        .with_context(|| format!("binding 0.0.0.0:{}", config.port))?;

    let (tx, _rx) = broadcast::channel::<Event>(BROADCAST_CAPACITY);
    let state = Arc::new(AppState {
        config: config.clone(),
        fp: identity.fp.clone(),
        devices: Mutex::new(devices),
        store: Mutex::new(store),
        tx,
        pair_codes: Mutex::new(HashMap::new()),
        connected: AtomicUsize::new(0),
    });

    eprintln!(
        "ccnotify: daemon started: name={} pc_id={} port={} devices={} last_id={}",
        config.name,
        config.pc_id,
        config.port,
        lock(&state.devices).len(),
        state.last_id()
    );
    eprintln!("ccnotify: fp={}", identity.fp);
    eprintln!("ccnotify: hosts={}", net::hosts().join(", "));
    eprintln!("ccnotify: control socket {}", paths::socket_path().display());

    let mdns_daemon = mdns::advertise(&config);

    tokio::spawn(control::serve(state.clone(), control_listener));
    tokio::spawn(server::serve(state.clone(), tcp_listener, acceptor));

    wait_for_shutdown().await;
    eprintln!("ccnotify: shutting down");
    mdns::shutdown(mdns_daemon);
    let _ = std::fs::remove_file(paths::socket_path());
    Ok(())
}

async fn wait_for_shutdown() {
    use tokio::signal::unix::{signal, SignalKind};
    match signal(SignalKind::terminate()) {
        Ok(mut term) => {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {},
                _ = term.recv() => {},
            }
        }
        Err(_) => {
            let _ = tokio::signal::ctrl_c().await;
        }
    }
}

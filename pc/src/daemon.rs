//! `ccnotify daemon`: shared state + startup/shutdown orchestration.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, oneshot};
use tokio::time::MissedTickBehavior;

use crate::config::{self, now_ms, random_hex, Config, Device};
use crate::requests::{self, AskReply, Request, Requests};
use crate::sessions::{self, ListenStart, Meta, ScanResult, SendOutcome, Session, Sessions};
use crate::store::{Event, Store};
use crate::transcript::{self, ChatItem};
use crate::{control, mdns, net, paths, server, uploads};

pub const PAIR_TTL: Duration = Duration::from_secs(300);
const BROADCAST_CAPACITY: usize = 256;
const EXPIRE_CHECK_INTERVAL: Duration = Duration::from_secs(60);
/// While phones are connected, re-check changed transcripts this often
/// (title, agents running → read_only).
const SESSION_REFRESH_INTERVAL: Duration = Duration::from_secs(15);

/// Everything pushed live to subscribed phones.
#[derive(Debug, Clone)]
pub enum Push {
    Event(Event),
    Request(Request),
    Resolved {
        request_id: String,
        by: &'static str,
    },
    Session(Session),
}

/// What a new subscriber starts from (see subscribe_since).
pub struct Subscription {
    pub rx: broadcast::Receiver<Push>,
    pub last_id: u64,
    pub backlog: Vec<Event>,
    pub pending: Vec<Request>,
}

pub struct AppState {
    pub config: Config,
    pub fp: String,
    devices: Mutex<Vec<Device>>,
    store: Mutex<Store>,
    requests: Mutex<Requests>,
    sessions: Mutex<Sessions>,
    tx: broadcast::Sender<Push>,
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
    /// Store the event (assigning id/ts) and broadcast it to live clients,
    /// then update the session (`meta`: the hook's private fields).
    /// Broadcast happens under the store lock so subscribe_since() snapshots
    /// are consistent with the live stream.
    /// Returns None when the event was dropped as a duplicate: a permission /
    /// elicitation notification for a session that has a pending request.
    pub fn emit(&self, ev: Event, meta: &Meta) -> Option<Event> {
        let duplicate = ev.kind == "needs_input"
            && matches!(ev.detail.as_str(), "permission_prompt" | "elicitation_dialog")
            && lock(&self.requests).has_session(&ev.session);
        let session_state = match ev.kind.as_str() {
            "stop" => "idle",
            "needs_input" => "waiting",
            "session_end" => "ended",
            _ => "",
        };
        let last_text = if ev.kind == "stop" {
            Some(ev.message.clone())
        } else {
            None
        };
        let stored = if duplicate {
            None
        } else {
            let mut store = lock(&self.store);
            let stored = store.append(ev);
            let _ = self.tx.send(Push::Event(stored.clone()));
            Some(stored)
        };
        self.set_session_state(meta, session_state, last_text.as_deref());
        stored
    }

    pub fn last_id(&self) -> u64 {
        lock(&self.store).last_id()
    }

    pub fn events_since(&self, since: u64) -> Vec<Event> {
        lock(&self.store).since(since)
    }

    /// Atomically: subscribe to the live stream, read last_id, snapshot the
    /// stored events after `min(since, last_id)` and the pending requests.
    /// Lock order is store → requests; nothing else holds both.
    pub fn subscribe_since(&self, since: u64) -> Subscription {
        let store = lock(&self.store);
        let requests = lock(&self.requests);
        let rx = self.tx.subscribe();
        let last_id = store.last_id();
        let effective = since.min(last_id);
        Subscription {
            rx,
            last_id,
            backlog: store.since(effective),
            pending: requests.snapshot(),
        }
    }

    // --- phone requests (PROTOCOL.md v1.1) ---------------------------------
    // Broadcasts happen under the requests lock so subscribe_since()
    // snapshots are consistent with the live stream.

    /// Register a request from `ccnotify ask` (assigning id/ts) and broadcast
    /// it to phones. `agent_id` (private) is set for a prompt from a
    /// subagent. Returns its id and the receiver for the reply.
    pub fn add_request(
        &self,
        mut request: Request,
        agent_id: String,
    ) -> (String, oneshot::Receiver<AskReply>) {
        let mut requests = lock(&self.requests);
        let mut id = random_hex(4);
        while requests.contains(&id) {
            id = random_hex(4);
        }
        request.id = id.clone();
        request.ts = now_ms();
        let _ = self.tx.send(Push::Request(request.clone()));
        let session = request.session.clone();
        let reply_rx = requests.insert(request, agent_id);
        self.push_session(lock(&self.sessions).request_pending(&session));
        (id, reply_rx)
    }

    /// Deliver a phone's answer. The first answer wins; false if the request
    /// is unknown or already resolved.
    pub fn answer_request(&self, id: &str, answer: Value) -> bool {
        let mut requests = lock(&self.requests);
        let (reply_tx, request) = match requests.resolve(id, "phone") {
            Some(x) => x,
            None => return false,
        };
        let _ = reply_tx.send(AskReply::Answer(answer));
        let _ = self.tx.send(Push::Resolved {
            request_id: id.to_string(),
            by: "phone",
        });
        self.request_finished(&requests, &request.session);
        true
    }

    /// Resolve a request without an answer (`by` = "pc" or "timeout"). The
    /// waiting `ask` (if still there) gets `{"ok":false,"error":"cancelled"}`
    /// / `"timeout"`. False if the request was already resolved.
    pub fn cancel_request(&self, id: &str, by: &'static str) -> bool {
        let mut requests = lock(&self.requests);
        let (reply_tx, request) = match requests.resolve(id, by) {
            Some(x) => x,
            None => return false,
        };
        let error = if by == "timeout" { "timeout" } else { "cancelled" };
        let _ = reply_tx.send(AskReply::Error(error));
        let _ = self.tx.send(Push::Resolved {
            request_id: id.to_string(),
            by,
        });
        self.request_finished(&requests, &request.session);
        true
    }

    /// Safety net (PROTOCOL.md v1.1): session `short` moved on (Stop,
    /// SessionEnd, a new prompt), so its prompts were answered on the PC —
    /// resolve (by "pc") every request pending for it that did not come from
    /// a subagent. `reason` is for the log.
    pub fn cancel_session_requests(&self, short: &str, reason: &str) {
        let ids = lock(&self.requests).main_chain(short);
        for id in ids {
            if self.cancel_request(&id, "pc") {
                eprintln!("ccnotify: request {id} resolved by pc ({reason})");
            }
        }
    }

    /// A request of session `short` was resolved: once none is left, the
    /// session is no longer waiting on the user. Called with the requests
    /// lock held (lock order requests → sessions).
    fn request_finished(&self, requests: &Requests, short: &str) {
        if !requests.has_session(short) {
            self.push_session(lock(&self.sessions).requests_done(short));
        }
    }

    /// Drop requests pending for longer than requests::MAX_AGE.
    pub fn expire_requests(&self) {
        let expired = lock(&self.requests).expired(requests::MAX_AGE);
        for id in expired {
            if self.cancel_request(&id, "timeout") {
                eprintln!("ccnotify: request {id} timed out");
            }
        }
    }

    /// Who resolved a finished request (for a late answer); "pc" if unknown.
    pub fn resolved_by(&self, id: &str) -> &'static str {
        lock(&self.requests).resolved_by(id).unwrap_or("pc")
    }

    pub fn pending_requests(&self) -> Vec<Request> {
        lock(&self.requests).snapshot()
    }

    pub fn pending_count(&self) -> usize {
        lock(&self.requests).count()
    }

    // --- sessions (PROTOCOL.md v1.2) ---------------------------------------
    // Session pushes happen under the sessions lock, like the other pushes.
    // Lock order: store → requests → sessions.

    fn push_session(&self, update: Option<Session>) {
        if let Some(session) = update {
            let _ = self.tx.send(Push::Session(session));
        }
    }

    /// A hook reported a session state (`working` / `idle` / `waiting` /
    /// `ended`); `last_text` is Claude's last reply (Stop).
    pub fn set_session_state(&self, meta: &Meta, state: &str, last_text: Option<&str>) {
        if state.is_empty() {
            return;
        }
        let mut sessions = lock(&self.sessions);
        self.push_session(sessions.hook_state(meta, state, last_text));
    }

    /// Register a `listen` hook. None if the request has no session id.
    pub fn listen(&self, meta: &Meta) -> Option<ListenStart> {
        let mut sessions = lock(&self.sessions);
        let (start, update) = sessions.listen(meta)?;
        self.push_session(update);
        Some(start)
    }

    pub fn unlisten(&self, session_id: &str, listener_id: u64) {
        let mut sessions = lock(&self.sessions);
        self.push_session(sessions.unlisten(session_id, listener_id));
    }

    pub fn requeue(&self, session_id: &str, text: String) {
        let mut sessions = lock(&self.sessions);
        self.push_session(sessions.requeue(session_id, text));
    }

    /// All sessions, most recently active first.
    pub fn session_list(&self) -> Vec<Session> {
        lock(&self.sessions).snapshot()
    }

    pub fn find_session(&self, prefix: &str) -> Result<Session, &'static str> {
        lock(&self.sessions).find(prefix)
    }

    pub fn prune_sessions(&self) {
        lock(&self.sessions).prune_and_persist();
    }

    /// Re-read the transcripts that changed since their last scan (`only`
    /// that session, else every session not ended) and push the sessions
    /// whose title / read_only changed.
    pub async fn refresh_sessions(&self, only: Option<&str>) {
        let targets = lock(&self.sessions).scan_targets(only);
        if targets.is_empty() {
            return;
        }
        let results = tokio::task::spawn_blocking(move || sessions::scan(targets))
            .await
            .unwrap_or_default();
        let mut sessions = lock(&self.sessions);
        for result in results {
            let update = sessions.apply_scan(result);
            self.push_session(update);
        }
    }

    /// The session and its last `limit` chat items: the transcript merged by
    /// `ts` with the messages sent from phones. None for an unknown session.
    pub async fn chat(&self, session_id: &str, limit: usize) -> Option<(Session, Vec<ChatItem>)> {
        let source = lock(&self.sessions).chat_source(session_id);
        let (path, phone) = source?;
        let mut items: Vec<ChatItem> = Vec::new();
        if !path.is_empty() {
            let scanned = tokio::task::spawn_blocking(move || {
                let key = transcript::file_key(&path);
                (key, transcript::read(&path, limit))
            })
            .await
            .ok();
            if let Some((key, tr)) = scanned {
                if let Some(key) = key {
                    let result = ScanResult {
                        id: session_id.to_string(),
                        key,
                        title: tr.title,
                        agents_running: tr.agents_running,
                    };
                    self.push_session(lock(&self.sessions).apply_scan(result));
                }
                items = tr.items;
            }
        }
        items.extend(phone);
        // Stable: transcript order is kept for equal timestamps.
        items.sort_by_key(|item| item.ts);
        let excess = items.len().saturating_sub(limit);
        if excess > 0 {
            items.drain(..excess);
        }
        let session = lock(&self.sessions).get(session_id)?;
        Some((session, items))
    }

    /// A message from a phone for a session (PROTOCOL.md v1.2 "send rules"),
    /// with its images (v1.3): they are saved first and removed again when
    /// the message is rejected.
    pub async fn send_message(
        &self,
        session_id: &str,
        text: &str,
        client_id: &str,
        images: Vec<uploads::Upload>,
    ) -> SendOutcome {
        // Current agents-running state for read_only.
        self.refresh_sessions(Some(session_id)).await;
        let saved = if images.is_empty() {
            Vec::new()
        } else {
            let short: String = session_id.chars().take(8).collect();
            // Names the files; a message without a client id gets a random one.
            let stem = if client_id.trim().is_empty() {
                random_hex(8)
            } else {
                client_id.to_string()
            };
            let saved =
                tokio::task::spawn_blocking(move || uploads::save(&short, &stem, &images)).await;
            match saved {
                Ok(Ok(saved)) => saved,
                Ok(Err(e)) => {
                    eprintln!("ccnotify: saving images from a phone failed: {e}");
                    return SendOutcome::Rejected("The PC could not save the images");
                }
                Err(_) => return SendOutcome::Rejected("The PC could not save the images"),
            }
        };
        let outcome = {
            let mut sessions = lock(&self.sessions);
            let (outcome, update) = sessions.send(session_id, text, client_id, &saved);
            self.push_session(update);
            outcome
        };
        if matches!(outcome, SendOutcome::Rejected(_)) {
            uploads::remove(&saved);
        }
        outcome
    }

    /// An image of a session's chat (PROTOCOL.md v1.3): (media type, base64).
    pub async fn image(&self, session_id: &str, image_id: &str) -> Option<(String, String)> {
        let mut parts = image_id.splitn(3, '/');
        match (parts.next(), parts.next(), parts.next()) {
            (Some("up"), Some(short), Some(_)) => {
                // Only uploads of this session.
                if short != session_id.chars().take(8).collect::<String>() {
                    return None;
                }
                let id = image_id.to_string();
                let (mime, data) = tokio::task::spawn_blocking(move || uploads::read(&id))
                    .await
                    .ok()??;
                Some((mime.to_string(), data))
            }
            (Some("tr"), Some(uuid), Some(index)) => {
                let (path, _) = lock(&self.sessions).chat_source(session_id)?;
                let (uuid, index) = (uuid.to_string(), index.parse::<usize>().ok()?);
                tokio::task::spawn_blocking(move || transcript::image(&path, &uuid, index))
                    .await
                    .ok()?
            }
            _ => None,
        }
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
        let (session_count, listening) = {
            let sessions = lock(&self.sessions);
            (sessions.count(), sessions.listening_count())
        };
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
            "pending": self.pending_count(),
            "sessions": session_count,
            "listening": listening,
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
    let sessions = Sessions::load(paths::sessions_file());
    let acceptor = server::tls_acceptor(&identity)?;

    let control_listener = control::bind()?;
    let tcp_listener = TcpListener::bind(("0.0.0.0", config.port))
        .await
        .with_context(|| format!("binding 0.0.0.0:{}", config.port))?;

    let (tx, _rx) = broadcast::channel::<Push>(BROADCAST_CAPACITY);
    let state = Arc::new(AppState {
        config: config.clone(),
        fp: identity.fp.clone(),
        devices: Mutex::new(devices),
        store: Mutex::new(store),
        requests: Mutex::new(Requests::default()),
        sessions: Mutex::new(sessions),
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
    tokio::spawn(expire_loop(state.clone()));
    tokio::spawn(sessions_loop(state.clone()));

    wait_for_shutdown().await;
    eprintln!("ccnotify: shutting down");
    mdns::shutdown(mdns_daemon);
    let _ = std::fs::remove_file(paths::socket_path());
    Ok(())
}

/// Periodically drop phone requests nobody answered (PROTOCOL.md: 24 h),
/// and once an hour the images phones sent more than a week ago.
async fn expire_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(EXPIRE_CHECK_INTERVAL);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut minutes = 0u64;
    loop {
        tick.tick().await;
        state.expire_requests();
        if minutes % 60 == 0 {
            let _ = tokio::task::spawn_blocking(uploads::prune).await;
        }
        minutes += 1;
    }
}

/// Drop old sessions, and keep titles / read_only fresh while phones are
/// connected.
async fn sessions_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(SESSION_REFRESH_INTERVAL);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        state.prune_sessions();
        if state.connected.load(Ordering::SeqCst) > 0 {
            state.refresh_sessions(None).await;
        }
    }
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

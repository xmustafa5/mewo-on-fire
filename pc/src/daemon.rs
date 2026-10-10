//! `mewo daemon`: shared state + startup/shutdown orchestration.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::path::Path;
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
use crate::policy;
use crate::desktop;
use crate::flow;
use crate::{control, mdns, net, paths, prs, relay, server, uploads};

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
    /// Connected to the relay right now (see relay.rs).
    pub relay_up: AtomicBool,
    /// Pull requests by repository (prs.rs, v1.6).
    pub prs: prs::PrCache,
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

    /// v1.7: one line of a session's self-check.
    pub fn set_check(&self, session_id: &str, index: usize, checked: bool) -> Option<Session> {
        let update = lock(&self.sessions).set_check(session_id, index, checked);
        if let Some(s) = &update {
            let _ = self.tx.send(Push::Session(s.clone()));
        }
        update
    }

    /// v1.8: one feature with its live state, from what is cached (no
    /// GitHub call), for the flow's synchronous commands.
    pub fn feature(&self, ws: &Path, key: &str) -> Option<policy::Feature> {
        let mut f = policy::features(ws).into_iter().find(|f| f.key == key)?;
        let sessions = self.session_list();
        let mut prs: Vec<Value> = Vec::new();
        for repo in &f.fetched_repos {
            let dir = ws.join(repo).to_string_lossy().into_owned();
            prs.extend(self.prs.cached_base(&dir, &f.branch));
        }
        policy::enrich(&mut f, &sessions, &prs);
        Some(f)
    }

    /// The feature as the phones and the console see it: the records plus
    /// the flow (autopilot, next action, estimates, log) and the PRD gate.
    fn feature_json(&self, ws: &Path, f: &policy::Feature, sessions: &[Session]) -> Value {
        let st = flow::get(ws, &f.key);
        let action = flow::next_action(ws, f, &st, sessions);
        let mut v = serde_json::to_value(f).unwrap_or(Value::Null);
        if let Some(o) = v.as_object_mut() {
            // Estimates (step 2) sit between the draft and the signature.
            if action.step == 2 && !f.light && !f.released {
                o.insert("step".to_string(), json!(2));
                o.insert("step_label".to_string(), json!(policy::STEPS[1]));
            }
            // The PRD's signature as a gate of its own (v1.8).
            if !f.light {
                let prd_gate = json!({
                    "id": "prd", "checklist": "A", "title": "PRD signed (V1.0)", "step": 3,
                    "file": f.prd, "items": [], "roles": ["CEO"],
                    "signatures": if f.prd_signed { json!([{"role": "CEO", "name": "signed"}]) } else { json!([]) },
                    "date": "", "signed": f.prd_signed, "present": !f.prd.is_empty(),
                });
                if let Some(gates) = o.get_mut("gates").and_then(Value::as_array_mut) {
                    gates.insert(0, prd_gate);
                }
            }
            o.insert(
                "flow".to_string(),
                json!({
                    "autopilot": st.autopilot,
                    "estimates": st.estimates,
                    "estimates_done": st.estimates_done,
                    "log": st.log,
                    "released_at": st.released_at,
                    "closed_at": st.closed_at,
                    "history": st.history.iter().rev().take(30).collect::<Vec<_>>(),
                    "action": action,
                }),
            );
        }
        v
    }

    /// v1.8: asks a role (its phone, or every phone) to sign a gate.
    pub fn ask_signature(&self, ws: &Path, f: &policy::Feature, gate: &str, role: &str, by: &str) -> Value {
        let title = if gate == "prd" {
            "PRD signature".to_string()
        } else {
            f.gates.iter().find(|g| g.id == gate).map(|g| g.title.clone()).unwrap_or_else(|| gate.to_string())
        };
        let who = flow::role_named(ws, role);
        let to = who.as_ref().map(|r| r.phone.clone()).unwrap_or_default();
        let name = who.as_ref().map(|r| r.name.clone()).filter(|n| !n.is_empty());
        let ev = Event {
            kind: "signoff".to_string(),
            project: f.app.clone(),
            cwd: ws.to_string_lossy().into_owned(),
            message: format!(
                "{title} for {} / {}: {} to sign{}",
                f.app,
                f.slug,
                match (&name, role.is_empty()) {
                    (Some(n), _) => format!("{n} ({role})"),
                    (None, false) => role.to_string(),
                    (None, true) => "a lead".to_string(),
                },
                if by.is_empty() { String::new() } else { format!(" (asked by {by})") }
            ),
            detail: format!("{}|{gate}|{role}", f.key),
            to,
            ..Event::default()
        };
        flow::update(ws, &f.key, |st| {
            st.asked.insert(format!("{gate}|{role}"), now_ms());
            st.note(format!("Asked {} to sign {title}", if role.is_empty() { "the leads" } else { role }));
        });
        match self.emit(ev, &Meta::default()) {
            Some(_) => json!({"ok": true, "to": who.map(|r| r.phone).unwrap_or_default()}),
            None => json!({"ok": false, "error": "not sent"}),
        }
    }

    /// v1.8: performs the flow's next action for a feature (or `action`
    /// when given): starts the session, asks for the signatures, exports
    /// the design, releases.
    pub fn flow_execute(&self, ws: &Path, f: &policy::Feature, action: Option<flow::Action>, by: &str) -> Value {
        let sessions = self.session_list();
        let st = flow::get(ws, &f.key);
        let a = action.unwrap_or_else(|| flow::next_action(ws, f, &st, &sessions));
        match a.kind.as_str() {
            "run" | "start" => {
                // Sessions of the flow run on the feature branch of torch-main.
                let ws_s = ws.to_string_lossy().into_owned();
                if a.kind == "run" && policy::branch_of(&ws_s) != f.branch {
                    let clean = policy::git(ws, &["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"]).map(|s| s.is_empty()).unwrap_or(false);
                    if !clean {
                        return json!({"ok": false, "error": format!("torch-main is on '{}' with uncommitted changes. Commit or stash them, then try again: the session has to run on {}.", policy::branch_of(&ws_s), f.branch)});
                    }
                    let exists = policy::git(ws, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{}", f.branch)]).is_some();
                    let switched = if exists {
                        policy::git(ws, &["switch", &f.branch]).is_some()
                    } else {
                        // The feature's folder exists but its branch was never made: make it, as new-feature.sh would.
                        policy::git(ws, &["switch", "-c", &f.branch]).is_some()
                    };
                    if !switched {
                        return json!({"ok": false, "error": format!("torch-main is on '{}' and could not be switched to {}.", policy::branch_of(&ws_s), f.branch)});
                    }
                    if !exists {
                        let _ = policy::git(ws, &["add", "--", &f.dir]);
                        let _ = policy::git(ws, &["commit", "-q", "-m", &format!("Start {} feature: {}", f.app, f.slug), "--", &f.dir]);
                        flow::update(ws, &f.key, |st| st.note(format!("Created the branch {} in torch-main", f.branch)));
                    }
                }
                match desktop::open_new_session(&a.folder, &a.prompt) {
                    Ok(()) => {
                        if a.kind == "start" {
                            let _ = policy::set_plan_status(ws, &f.key, a.session, "In progress", "");
                        }
                        let note = if a.kind == "start" { a.session.to_string() } else { f.prd.clone() };
                        let started = now_ms();
                        flow::update(ws, &f.key, |st| {
                            st.runs.push(flow::Run { step: a.step, started, note });
                            st.note(format!("Started: {}", a.title));
                        });
                        flow::journal(ws, &f.key, &a.kind, &format!("Started: {}", a.title), Vec::new(), "", true, json!({"started": started, "session": a.session, "step": a.step}));
                        json!({"ok": true, "did": a.kind, "title": a.title})
                    }
                    Err(e) => json!({"ok": false, "error": e}),
                }
            }
            "ask" => {
                let roles = if a.roles.is_empty() { vec![String::new()] } else { a.roles.clone() };
                let mut sent = 0;
                for role in &roles {
                    if self.ask_signature(ws, f, &a.gate, role, by).get("ok").and_then(Value::as_bool).unwrap_or(false) {
                        sent += 1;
                    }
                }
                json!({"ok": sent > 0, "did": "ask", "title": a.title, "sent": sent})
            }
            "estimates" => {
                let mut sent = 0;
                for role in &a.roles {
                    let who = flow::role_named(ws, role);
                    let ev = Event {
                        kind: "signoff".to_string(),
                        project: f.app.clone(),
                        cwd: ws.to_string_lossy().into_owned(),
                        message: format!("Estimate for {} / {}: {} to give person-days and assumptions (policy step 2)", f.app, f.slug, who.as_ref().map(|r| format!("{} ({role})", r.name)).unwrap_or_else(|| role.clone())),
                        detail: format!("{}|estimate|{role}", f.key),
                        to: who.map(|r| r.phone).unwrap_or_default(),
                        ..Event::default()
                    };
                    if self.emit(ev, &Meta::default()).is_some() {
                        sent += 1;
                    }
                }
                flow::update(ws, &f.key, |st| {
                    for role in &a.roles {
                        st.asked.insert(format!("estimate|{role}"), now_ms());
                    }
                    st.note("Asked for the estimates");
                });
                json!({"ok": sent > 0, "did": "estimates", "sent": sent})
            }
            "export" => match flow::export_handoff(ws, f, &sessions) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            "release" => {
                let name = if by.is_empty() { flow::role_named(ws, "CEO").map(|r| r.name).unwrap_or_else(|| "CEO".to_string()) } else { by.to_string() };
                match flow::release(ws, f, &name) {
                    Ok(v) => v,
                    Err(e) => json!({"ok": false, "error": e}),
                }
            }
            "close" => flow::close_branches(ws, f),
            _ => json!({"ok": true, "did": "nothing", "title": a.title, "detail": a.detail}),
        }
    }

    /// v1.7: every feature of the workspaces this PC's sessions work in,
    /// with the live state of their plan sessions.
    pub async fn features_json(&self) -> Value {
        let mut workspaces = policy::workspaces();
        for s in self.session_list() {
            if let Some(ws) = policy::workspace_for(&s.cwd) {
                if !workspaces.contains(&ws) {
                    policy::remember_workspace(&ws);
                    workspaces.push(ws);
                }
            }
        }
        let sessions = self.session_list();
        let mut all: Vec<Value> = Vec::new();
        for ws in workspaces {
            let mut feats = if policy::git_blocked() {
                policy::last_known(&ws)
            } else {
                let ws2 = ws.clone();
                let work = tokio::task::spawn_blocking(move || policy::features(&ws2));
                match tokio::time::timeout(Duration::from_secs(12), work).await {
                    Ok(Ok(f)) => f,
                    Ok(Err(_)) => Vec::new(),
                    Err(_) => {
                        policy::mark_blocked();
                        policy::last_known(&ws)
                    }
                }
            };
            for f in &mut feats {
                let mut prs: Vec<Value> = Vec::new();
                for repo in &f.fetched_repos {
                    let dir = ws.join(repo).to_string_lossy().into_owned();
                    prs.extend(self.prs.list_base(&dir, &f.branch).await);
                }
                policy::enrich(f, &sessions, &prs);
                all.push(self.feature_json(&ws, f, &sessions));
            }
        }
        let roles: serde_json::Map<String, Value> = policy::workspaces().iter().map(|ws| (ws.to_string_lossy().into_owned(), serde_json::to_value(flow::roles(ws)).unwrap_or(Value::Null))).collect();
        let apps: serde_json::Map<String, Value> = policy::workspaces().iter().map(|ws| (ws.to_string_lossy().into_owned(), json!(policy::apps(ws)))).collect();
        json!({
            "ok": true,
            "features": all,
            "workspaces": policy::workspaces().iter().map(|p| p.to_string_lossy().into_owned()).collect::<Vec<_>>(),
            "self_check": policy::SELF_CHECK,
            "review_check": policy::REVIEW_CHECK,
            "warning": if policy::git_blocked() { policy::FOLDER_ACCESS_HINT } else { "" },
            "roles": roles,
            "apps": apps,
            "role_names": flow::ROLES,
        })
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

    /// Register a request from `mewo ask` (assigning id/ts) and broadcast
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
                eprintln!("mewo: request {id} resolved by pc ({reason})");
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
                eprintln!("mewo: request {id} timed out");
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
        // A transcript scan may copy published files from a folder macOS
        // holds the daemon out of: bounded, and remembered (v1.7).
        let work = tokio::task::spawn_blocking(move || sessions::scan(targets));
        let results = match tokio::time::timeout(Duration::from_secs(20), work).await {
            Ok(r) => r.unwrap_or_default(),
            Err(_) => {
                policy::mark_blocked();
                Vec::new()
            }
        };
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
                        artifacts: tr.artifacts,
                        model: tr.model,
                        first_prompt: tr.first_prompt,
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
                    eprintln!("mewo: saving images from a phone failed: {e}");
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

    /// What a phone may try: LAN addresses first, then Tailscale and the
    /// configured extras, then the relay (`wss://…`).
    pub fn hosts(&self) -> Vec<String> {
        let mut hosts = net::all_hosts(&self.config.extra_hosts);
        let relay = relay::base_url(&self.config.relay);
        if !relay.is_empty() {
            hosts.push(relay);
        }
        hosts
    }

    pub fn pair_payload(&self, code: &str) -> String {
        let payload = json!({
            "v": 1,
            "id": self.config.pc_id,
            "name": self.config.name,
            "hosts": self.hosts(),
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
            "hosts": self.hosts(),
            "devices": device_count,
            "last_id": self.last_id(),
            "connected": self.connected.load(Ordering::SeqCst),
            "relay": relay::base_url(&self.config.relay),
            "relay_up": self.relay_up.load(Ordering::SeqCst),
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
        relay_up: AtomicBool::new(false),
        prs: prs::PrCache::default(),
    });

    eprintln!(
        "mewo: daemon started: name={} pc_id={} port={} devices={} last_id={}",
        config.name,
        config.pc_id,
        config.port,
        lock(&state.devices).len(),
        state.last_id()
    );
    eprintln!("mewo: fp={}", identity.fp);
    eprintln!("mewo: hosts={}", state.hosts().join(", "));
    eprintln!("mewo: control socket {}", paths::socket_path().display());

    let mdns_daemon = mdns::advertise(&config);

    tokio::spawn(control::serve(state.clone(), control_listener));
    tokio::spawn(server::serve(state.clone(), tcp_listener, acceptor));
    tokio::spawn(expire_loop(state.clone()));
    tokio::spawn(sessions_loop(state.clone()));
    tokio::spawn(match_loop(state.clone()));
    tokio::spawn(flow_loop(state.clone()));
    tokio::spawn(relay::run(state.clone()));

    wait_for_shutdown().await;
    eprintln!("mewo: shutting down");
    mdns::shutdown(mdns_daemon);
    let _ = std::fs::remove_file(paths::socket_path());
    Ok(())
}

/// Periodically drop phone requests nobody answered (PROTOCOL.md: 24 h),
/// and once an hour the images phones sent more than a week ago.
/// v1.8: autopilot. Every half minute, each feature with it on gets its
/// next action done: a session started, signatures asked for (once a
/// day per role), the design exported, the release recorded.
async fn flow_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        if policy::git_blocked() {
            continue;
        }
        let sessions = state.session_list();
        for ws in policy::workspaces() {
            let ws2 = ws.clone();
            let feats = match tokio::time::timeout(Duration::from_secs(12), tokio::task::spawn_blocking(move || policy::features(&ws2))).await {
                Ok(Ok(f)) => f,
                _ => continue,
            };
            for mut f in feats {
                let st = flow::get(&ws, &f.key);
                if !st.autopilot {
                    continue;
                }
                let mut prs: Vec<Value> = Vec::new();
                for repo in &f.fetched_repos {
                    let dir = ws.join(repo).to_string_lossy().into_owned();
                    prs.extend(state.prs.list_base(&dir, &f.branch).await);
                }
                policy::enrich(&mut f, &sessions, &prs);
                let a = flow::next_action(&ws, &f, &st, &sessions);
                if !a.auto {
                    continue;
                }
                if a.kind == "ask" || a.kind == "estimates" {
                    let day = 24 * 60 * 60 * 1000;
                    let key = |role: &str| format!("{}|{role}", if a.kind == "ask" { a.gate.clone() } else { "estimate".to_string() });
                    let pending: Vec<String> = a.roles.iter().filter(|r| st.asked.get(&key(r)).map(|t| now_ms().saturating_sub(*t) > day).unwrap_or(true)).cloned().collect();
                    if pending.is_empty() {
                        continue;
                    }
                    let mut a2 = a.clone();
                    a2.roles = pending;
                    let state2 = state.clone();
                    let ws2 = ws.clone();
                    let f2 = f.clone();
                    let _ = tokio::task::spawn_blocking(move || state2.flow_execute(&ws2, &f2, Some(a2), "autopilot")).await;
                    continue;
                }
                let state2 = state.clone();
                let ws2 = ws.clone();
                let f2 = f.clone();
                let r = tokio::task::spawn_blocking(move || state2.flow_execute(&ws2, &f2, Some(a), "autopilot")).await.unwrap_or(Value::Null);
                if r.get("ok").and_then(Value::as_bool) == Some(false) {
                    let err = r.get("error").and_then(Value::as_str).unwrap_or("").to_string();
                    flow::update(&ws, &f.key, |st| st.note(format!("Autopilot could not continue: {err}")));
                }
            }
        }
    }
}

/// v1.7: matches sessions to the features of their workspace, off the
/// sessions lock, since that reads folders macOS may hold the daemon out
/// of until the user allows it.
async fn match_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(Duration::from_millis(1500));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        if policy::git_blocked() {
            continue;
        }
        let jobs = lock(&state.sessions).take_matches();
        for (id, cwd, branch, first_prompt) in jobs {
            let work = tokio::task::spawn_blocking(move || policy::match_session(&cwd, &branch, &first_prompt));
            match tokio::time::timeout(Duration::from_secs(15), work).await {
                Ok(Ok((feature, n))) => {
                    let update = lock(&state.sessions).set_match(&id, feature, n);
                    state.push_session(update);
                }
                Ok(Err(_)) => {}
                Err(_) => {
                    policy::mark_blocked();
                    break;
                }
            }
        }
    }
}

async fn expire_loop(state: Arc<AppState>) {
    let mut tick = tokio::time::interval(EXPIRE_CHECK_INTERVAL);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut minutes = 0u64;
    loop {
        tick.tick().await;
        state.expire_requests();
        if minutes % 60 == 0 {
            let _ = tokio::task::spawn_blocking(uploads::prune).await;
            let _ = tokio::task::spawn_blocking(crate::artifacts::prune).await;
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

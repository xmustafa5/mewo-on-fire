//! Session registry (PROTOCOL.md v1.2): one entry per Claude Code session,
//! driven by the hooks and persisted to sessions.json. Each entry holds the
//! `listen` hook waiting for a phone message, the phone messages queued for
//! the next `listen`, and the phone messages recorded for the chat.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::oneshot;

use crate::ask::truncate_chars;
use crate::config::{now_ms, random_hex};
use crate::hook;
use crate::paths;
use crate::transcript::{self, ChatItem, FileKey};

/// Sessions kept (most recently active first).
const MAX_SESSIONS: usize = 50;
/// Ended sessions older than this are dropped.
const ENDED_MAX_AGE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// Phone messages recorded per session for the chat.
const MAX_PHONE_MESSAGES: usize = 100;
/// Longest message accepted from a phone.
const MAX_SEND_CHARS: usize = 20_000;
/// A Stop arriving this soon after queued messages were handed to a fresh
/// `listen` belongs to the turn that ended right before: the session stays
/// `working` (the Stop `hook` and `listen` hooks run concurrently).
const FLUSH_GRACE: Duration = Duration::from_secs(2);

const REASON_CLOSED: &str = "Session is closed";
const REASON_READ_ONLY: &str =
    "Claude is running agents at high effort — read-only until it finishes";
const REASON_NOT_LISTENING: &str = "This session is not listening — run `ccnotify install` on the PC and send a message from the PC once";
const REASON_EMPTY: &str = "Empty message";
const REASON_TOO_LONG: &str = "Message is too long";

/// PROTOCOL.md v1.2 "Session". Field order matches the protocol.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Session {
    pub id: String,
    pub short: String,
    pub project: String,
    pub cwd: String,
    pub title: String,
    pub state: String,
    pub listening: bool,
    pub read_only: bool,
    pub effort: String,
    pub last_ts: u64,
    pub last_text: String,
    pub queued: usize,
}

/// Private session facts from the hooks (`emit`, `session_state`, `listen`).
/// Empty fields leave the stored value alone.
#[derive(Debug, Clone, Default)]
pub struct Meta {
    pub session_id: String,
    pub cwd: String,
    pub transcript_path: String,
    pub effort: String,
}

impl Meta {
    /// Top-level `session_id` / `cwd` / `transcript_path` / `effort` of a
    /// control request.
    pub fn from_request(req: &Value) -> Meta {
        let s = |key: &str| {
            req.get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string()
        };
        Meta {
            session_id: s("session_id"),
            cwd: s("cwd"),
            transcript_path: s("transcript_path"),
            effort: s("effort"),
        }
    }
}

/// What a waiting `listen` gets: a phone message, or an error reply
/// (`superseded` / `cancelled`).
#[derive(Debug)]
pub enum ListenReply {
    Text(String),
    Error(&'static str),
}

/// Result of registering a `listen`.
pub enum ListenStart {
    /// Messages were queued: reply right away.
    Now(String),
    /// Registered as the session's listener (id, reply channel).
    Wait(u64, oneshot::Receiver<ListenReply>),
}

/// Result of a phone `send` (PROTOCOL.md v1.2 "send rules").
#[derive(Debug, Clone, Copy)]
pub enum SendOutcome {
    Delivered,
    Queued,
    Rejected(&'static str),
}

impl SendOutcome {
    pub fn status(&self) -> &'static str {
        match *self {
            SendOutcome::Delivered => "delivered",
            SendOutcome::Queued => "queued",
            SendOutcome::Rejected(_) => "rejected",
        }
    }

    pub fn reason(&self) -> &'static str {
        match *self {
            SendOutcome::Rejected(reason) => reason,
            _ => "",
        }
    }
}

/// A session whose transcript should be checked for changes.
pub struct ScanTarget {
    id: String,
    path: String,
    key: Option<FileKey>,
}

/// Title + agents running from a transcript read at `key`.
pub struct ScanResult {
    pub id: String,
    pub key: FileKey,
    pub title: Option<String>,
    pub agents_running: bool,
}

/// Blocking (spawn_blocking): stat each target's transcript and re-read the
/// ones that changed since their last scan.
pub fn scan(targets: Vec<ScanTarget>) -> Vec<ScanResult> {
    targets
        .into_iter()
        .filter_map(|t| {
            let key = transcript::file_key(&t.path)?;
            if t.key == Some(key) {
                return None;
            }
            let tr = transcript::read(&t.path, 0);
            Some(ScanResult {
                id: t.id,
                key,
                title: tr.title,
                agents_running: tr.agents_running,
            })
        })
        .collect()
}

struct Listener {
    id: u64,
    tx: oneshot::Sender<ListenReply>,
}

struct Entry {
    /// Public snapshot; `listening` / `read_only` / `queued` kept in sync.
    session: Session,
    transcript_path: String,
    /// Phone messages waiting for the next `listen` (full text).
    queue: Vec<ChatItem>,
    /// Phone messages shown in the chat, oldest first.
    phone: VecDeque<ChatItem>,
    listener: Option<Listener>,
    /// File key of the last transcript scan.
    scan_key: Option<FileKey>,
    agents_running: bool,
    /// When queued messages were last handed to a `listen`.
    flushed_at: Option<Instant>,
}

impl Entry {
    fn new(id: &str) -> Entry {
        Entry {
            session: Session {
                id: id.to_string(),
                short: id.chars().take(8).collect(),
                state: "idle".to_string(),
                last_ts: now_ms(),
                ..Session::default()
            },
            transcript_path: String::new(),
            queue: Vec::new(),
            phone: VecDeque::new(),
            listener: None,
            scan_key: None,
            agents_running: false,
            flushed_at: None,
        }
    }

    fn apply_meta(&mut self, meta: &Meta) {
        if !meta.cwd.is_empty() && meta.cwd != self.session.cwd {
            let project = hook::project_name(&meta.cwd);
            // The title falls back to the project name until the transcript has one.
            if self.session.title.is_empty() || self.session.title == self.session.project {
                self.session.title = project.clone();
            }
            self.session.project = project;
            self.session.cwd = meta.cwd.clone();
        }
        if !meta.transcript_path.is_empty() && meta.transcript_path != self.transcript_path {
            self.transcript_path = meta.transcript_path.clone();
            self.scan_key = None;
        }
        if !meta.effort.is_empty() {
            self.session.effort = meta.effort.clone();
        }
    }

    /// Recompute the derived fields of the snapshot.
    fn sync(&mut self) {
        self.session.listening = self.listener.is_some();
        self.session.queued = self.queue.len();
        let effort = self.session.effort.to_ascii_lowercase();
        self.session.read_only = self.session.state == "working"
            && matches!(effort.as_str(), "xhigh" | "max")
            && self.agents_running;
        if self.session.title.is_empty() {
            self.session.title = self.session.project.clone();
        }
    }

    /// Answer the waiting `listen` (if any) with an error reply.
    fn release_listener(&mut self, error: &'static str) {
        if let Some(listener) = self.listener.take() {
            let _ = listener.tx.send(ListenReply::Error(error));
        }
    }

    fn record_phone(&mut self, item: &ChatItem) {
        let mut recorded = item.clone();
        recorded.text = truncate_chars(&recorded.text, transcript::MAX_ITEM_CHARS);
        self.phone.push_back(recorded);
        while self.phone.len() > MAX_PHONE_MESSAGES {
            self.phone.pop_front();
        }
    }
}

/// sessions.json
#[derive(Default, Deserialize)]
#[serde(default)]
struct Persisted {
    sessions: Vec<Record>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Record {
    session: Session,
    transcript_path: String,
    queue: Vec<ChatItem>,
    phone: Vec<ChatItem>,
}

#[derive(Serialize)]
struct PersistRef<'a> {
    sessions: Vec<RecordRef<'a>>,
}

#[derive(Serialize)]
struct RecordRef<'a> {
    session: &'a Session,
    transcript_path: &'a str,
    queue: &'a [ChatItem],
    phone: &'a VecDeque<ChatItem>,
}

pub struct Sessions {
    path: PathBuf,
    entries: HashMap<String, Entry>,
    next_listener: u64,
}

impl Sessions {
    pub fn load(path: PathBuf) -> Sessions {
        let mut entries: HashMap<String, Entry> = HashMap::new();
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<Persisted>(&bytes) {
                Ok(p) => {
                    for r in p.sessions {
                        if r.session.id.is_empty() {
                            continue;
                        }
                        let mut entry = Entry::new(&r.session.id);
                        entry.session = r.session;
                        entry.transcript_path = r.transcript_path;
                        entry.queue = r.queue;
                        entry.phone = r.phone.into_iter().collect();
                        while entry.phone.len() > MAX_PHONE_MESSAGES {
                            entry.phone.pop_front();
                        }
                        // No listener survives a restart.
                        entry.sync();
                        entries.insert(entry.session.id.clone(), entry);
                    }
                }
                Err(e) => eprintln!(
                    "ccnotify: warning: ignoring unreadable {}: {e}",
                    path.display()
                ),
            }
        }
        let mut sessions = Sessions {
            path,
            entries,
            next_listener: 1,
        };
        sessions.prune();
        sessions
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }

    pub fn listening_count(&self) -> usize {
        self.entries
            .values()
            .filter(|e| e.listener.is_some())
            .count()
    }

    /// All sessions, most recently active first.
    pub fn snapshot(&self) -> Vec<Session> {
        let mut list: Vec<Session> = self.entries.values().map(|e| e.session.clone()).collect();
        list.sort_by(|a, b| b.last_ts.cmp(&a.last_ts));
        list
    }

    pub fn get(&self, id: &str) -> Option<Session> {
        self.entries.get(id).map(|e| e.session.clone())
    }

    /// The session whose id starts with `prefix` (an exact id wins).
    /// Err("not_found" | "ambiguous").
    pub fn find(&self, prefix: &str) -> Result<Session, &'static str> {
        let prefix = prefix.trim();
        if prefix.is_empty() {
            return Err("not_found");
        }
        if let Some(entry) = self.entries.get(prefix) {
            return Ok(entry.session.clone());
        }
        let mut matches = self.entries.values().filter(|e| e.session.id.starts_with(prefix));
        match (matches.next(), matches.next()) {
            (Some(entry), None) => Ok(entry.session.clone()),
            (None, _) => Err("not_found"),
            _ => Err("ambiguous"),
        }
    }

    /// Transcript path + recorded phone messages of a session (for the chat).
    pub fn chat_source(&self, id: &str) -> Option<(String, Vec<ChatItem>)> {
        let entry = self.entries.get(id)?;
        Some((
            entry.transcript_path.clone(),
            entry.phone.iter().cloned().collect(),
        ))
    }

    /// Run `f` on the entry for `meta.session_id` (created if missing).
    /// Returns the new snapshot when it changed; any change is persisted.
    fn update<F>(&mut self, meta: &Meta, f: F) -> Option<Session>
    where
        F: FnOnce(&mut Entry),
    {
        if meta.session_id.is_empty() {
            return None;
        }
        let entry = self
            .entries
            .entry(meta.session_id.clone())
            .or_insert_with(|| Entry::new(&meta.session_id));
        let before = entry.session.clone();
        let before_path = entry.transcript_path.clone();
        entry.apply_meta(meta);
        f(&mut *entry);
        entry.sync();
        let changed = entry.session != before;
        let dirty = changed || entry.transcript_path != before_path;
        let snapshot = entry.session.clone();
        if dirty {
            self.prune();
            self.persist();
        }
        if changed {
            Some(snapshot)
        } else {
            None
        }
    }

    /// A hook reported a state: `working` (UserPromptSubmit), `idle` (Stop,
    /// with Claude's last reply), `waiting` (needs_input), `ended`
    /// (SessionEnd).
    pub fn hook_state(&mut self, meta: &Meta, state: &str, last_text: Option<&str>) -> Option<Session> {
        let state = state.to_string();
        let last_text = last_text.map(str::to_string);
        self.update(meta, move |e| {
            e.session.last_ts = now_ms();
            if let Some(text) = last_text {
                e.session.last_text = text;
            }
            match state.as_str() {
                "idle" => {
                    let just_flushed = e
                        .flushed_at
                        .map(|t| t.elapsed() < FLUSH_GRACE)
                        .unwrap_or(false);
                    if !(e.session.state == "working" && just_flushed) {
                        e.session.state = "idle".to_string();
                    }
                }
                "working" => {
                    e.release_listener("cancelled");
                    e.session.state = "working".to_string();
                }
                "ended" => {
                    e.release_listener("cancelled");
                    e.queue.clear();
                    e.session.state = "ended".to_string();
                }
                other => e.session.state = other.to_string(),
            }
        })
    }

    /// Register a `listen` hook. Queued messages are handed over right away
    /// (joined by a blank line); otherwise it becomes the session's listener,
    /// superseding the previous one. None if `session_id` is empty.
    pub fn listen(&mut self, meta: &Meta) -> Option<(ListenStart, Option<Session>)> {
        let id = self.next_listener;
        self.next_listener += 1;
        let mut start: Option<ListenStart> = None;
        let update = self.update(meta, |e| {
            if !e.queue.is_empty() {
                let text = e
                    .queue
                    .drain(..)
                    .map(|m| m.text)
                    .collect::<Vec<String>>()
                    .join("\n\n");
                e.session.state = "working".to_string();
                e.session.last_ts = now_ms();
                e.flushed_at = Some(Instant::now());
                start = Some(ListenStart::Now(text));
                return;
            }
            e.release_listener("superseded");
            let (tx, rx) = oneshot::channel();
            e.listener = Some(Listener { id, tx });
            start = Some(ListenStart::Wait(id, rx));
        });
        start.map(|s| (s, update))
    }

    /// The `listen` hook went away: drop it if it is still the listener.
    pub fn unlisten(&mut self, session_id: &str, listener_id: u64) -> Option<Session> {
        let entry = self.entries.get_mut(session_id)?;
        if entry.listener.as_ref().map(|l| l.id) != Some(listener_id) {
            return None;
        }
        entry.listener = None;
        entry.sync();
        Some(entry.session.clone())
    }

    /// Put back a message that reached a `listen` just as its hook went away.
    pub fn requeue(&mut self, session_id: &str, text: String) -> Option<Session> {
        let entry = self.entries.get_mut(session_id)?;
        if entry.session.state == "ended" {
            return None;
        }
        entry.queue.insert(
            0,
            ChatItem {
                id: format!("phone-{}", random_hex(4)),
                ts: now_ms(),
                role: "phone".to_string(),
                text,
                tool: None,
            },
        );
        entry.sync();
        let snapshot = entry.session.clone();
        self.persist();
        Some(snapshot)
    }

    /// A message from a phone (PROTOCOL.md v1.2 "send rules"). A retried
    /// `client_id` gets the first outcome again instead of a second delivery.
    pub fn send(&mut self, session_id: &str, text: &str, client_id: &str) -> (SendOutcome, Option<Session>) {
        let text = text.trim();
        let entry = match self.entries.get_mut(session_id) {
            Some(e) if e.session.state != "ended" => e,
            _ => return (SendOutcome::Rejected(REASON_CLOSED), None),
        };
        if text.is_empty() {
            return (SendOutcome::Rejected(REASON_EMPTY), None);
        }
        if text.chars().count() > MAX_SEND_CHARS {
            return (SendOutcome::Rejected(REASON_TOO_LONG), None);
        }
        let client_id = client_id.trim();
        let item_id = if client_id.is_empty() {
            format!("phone-{}", random_hex(8))
        } else {
            format!("phone-{client_id}")
        };
        if !client_id.is_empty() {
            if entry.queue.iter().any(|m| m.id == item_id) {
                return (SendOutcome::Queued, None);
            }
            if entry.phone.iter().any(|m| m.id == item_id) {
                return (SendOutcome::Delivered, None);
            }
        }
        if entry.session.read_only {
            return (SendOutcome::Rejected(REASON_READ_ONLY), None);
        }

        let before = entry.session.clone();
        let item = ChatItem {
            id: item_id,
            ts: now_ms(),
            role: "phone".to_string(),
            text: text.to_string(),
            tool: None,
        };
        let mut delivered = false;
        if let Some(listener) = entry.listener.take() {
            // Fails only if the listen hook just went away: fall through.
            delivered = listener.tx.send(ListenReply::Text(item.text.clone())).is_ok();
        }
        let outcome = if delivered {
            entry.session.state = "working".to_string();
            SendOutcome::Delivered
        } else if matches!(entry.session.state.as_str(), "working" | "waiting") {
            entry.queue.push(item.clone());
            SendOutcome::Queued
        } else {
            SendOutcome::Rejected(REASON_NOT_LISTENING)
        };
        if !matches!(outcome, SendOutcome::Rejected(_)) {
            entry.record_phone(&item);
            entry.session.last_ts = item.ts;
        }
        entry.sync();
        let update = if entry.session != before {
            Some(entry.session.clone())
        } else {
            None
        };
        if !matches!(outcome, SendOutcome::Rejected(_)) {
            self.persist();
        }
        (outcome, update)
    }

    /// Id of the most recently active session with this short id.
    fn id_for_short(&self, short: &str) -> Option<String> {
        if short.is_empty() {
            return None;
        }
        self.entries
            .values()
            .filter(|e| e.session.short == short)
            .max_by_key(|e| e.session.last_ts)
            .map(|e| e.session.id.clone())
    }

    /// A v1.1 request is pending for the session with this short id.
    pub fn request_pending(&mut self, short: &str) -> Option<Session> {
        let meta = Meta {
            session_id: self.id_for_short(short)?,
            ..Meta::default()
        };
        self.update(&meta, |e| {
            if e.session.state != "ended" {
                e.session.state = "waiting".to_string();
                e.session.last_ts = now_ms();
            }
        })
    }

    /// The session's last pending v1.1 request was resolved: Claude carries on.
    pub fn requests_done(&mut self, short: &str) -> Option<Session> {
        let meta = Meta {
            session_id: self.id_for_short(short)?,
            ..Meta::default()
        };
        self.update(&meta, |e| {
            if e.session.state == "waiting" {
                e.session.state = "working".to_string();
            }
        })
    }

    /// Sessions to check for transcript changes: `only` that one, else
    /// every session that has not ended.
    pub fn scan_targets(&self, only: Option<&str>) -> Vec<ScanTarget> {
        self.entries
            .values()
            .filter(|e| !e.transcript_path.is_empty())
            .filter(|e| match only {
                Some(id) => e.session.id == id,
                None => e.session.state != "ended",
            })
            .map(|e| ScanTarget {
                id: e.session.id.clone(),
                path: e.transcript_path.clone(),
                key: e.scan_key,
            })
            .collect()
    }

    /// Store a scan's title / agents running. Returns the snapshot when it
    /// changed.
    pub fn apply_scan(&mut self, r: ScanResult) -> Option<Session> {
        let entry = self.entries.get_mut(&r.id)?;
        let before = entry.session.clone();
        entry.scan_key = Some(r.key);
        entry.agents_running = r.agents_running;
        if let Some(title) = r.title {
            entry.session.title = title;
        }
        entry.sync();
        if entry.session == before {
            return None;
        }
        let snapshot = entry.session.clone();
        self.persist();
        Some(snapshot)
    }

    /// Drop ended sessions older than 7 days and keep the MAX_SESSIONS most
    /// recently active. True if anything was dropped (a dropped listener's
    /// hook sees its reply channel close).
    pub fn prune(&mut self) -> bool {
        let now = now_ms();
        let before = self.entries.len();
        self.entries.retain(|_, e| {
            !(e.session.state == "ended" && now.saturating_sub(e.session.last_ts) > ENDED_MAX_AGE_MS)
        });
        if self.entries.len() > MAX_SESSIONS {
            let mut by_age: Vec<(u64, String)> = self
                .entries
                .values()
                .map(|e| (e.session.last_ts, e.session.id.clone()))
                .collect();
            by_age.sort();
            let excess = self.entries.len() - MAX_SESSIONS;
            for (_, id) in by_age.into_iter().take(excess) {
                self.entries.remove(&id);
            }
        }
        self.entries.len() != before
    }

    pub fn prune_and_persist(&mut self) {
        if self.prune() {
            self.persist();
        }
    }

    fn persist(&self) {
        let mut list: Vec<&Entry> = self.entries.values().collect();
        list.sort_by(|a, b| b.session.last_ts.cmp(&a.session.last_ts));
        let data = PersistRef {
            sessions: list
                .iter()
                .map(|e| RecordRef {
                    session: &e.session,
                    transcript_path: &e.transcript_path,
                    queue: &e.queue,
                    phone: &e.phone,
                })
                .collect(),
        };
        let result = serde_json::to_vec(&data)
            .map_err(std::io::Error::other)
            .and_then(|bytes| paths::write_atomic(&self.path, &bytes, 0o600));
        if let Err(e) = result {
            eprintln!(
                "ccnotify: warning: could not write {}: {e}",
                self.path.display()
            );
        }
    }
}

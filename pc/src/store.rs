//! Event ring buffer (last 500), persisted to events.json on every append.

use std::collections::VecDeque;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config::now_ms;
use crate::paths;

pub const MAX_EVENTS: usize = 500;

/// PROTOCOL.md "Event". Field order matches the protocol.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Event {
    pub id: u64,
    pub ts: u64,
    pub kind: String,
    pub project: String,
    pub cwd: String,
    pub session: String,
    pub message: String,
    pub detail: String,
}

#[derive(Deserialize)]
struct Persisted {
    #[serde(default)]
    next_id: u64,
    #[serde(default)]
    events: Vec<Event>,
}

#[derive(Serialize)]
struct PersistRef<'a> {
    next_id: u64,
    events: &'a VecDeque<Event>,
}

pub struct Store {
    path: PathBuf,
    next_id: u64,
    events: VecDeque<Event>,
}

impl Store {
    pub fn load(path: PathBuf) -> Store {
        let mut next_id: u64 = 1;
        let mut events: VecDeque<Event> = VecDeque::new();
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<Persisted>(&bytes) {
                Ok(p) => {
                    let max_id = p.events.iter().map(|e| e.id).max().unwrap_or(0);
                    next_id = p.next_id.max(max_id + 1).max(1);
                    let mut evs = p.events;
                    evs.sort_by_key(|e| e.id);
                    events = evs.into_iter().collect();
                    while events.len() > MAX_EVENTS {
                        events.pop_front();
                    }
                }
                Err(e) => eprintln!(
                    "ccnotify: warning: ignoring unreadable {}: {e}",
                    path.display()
                ),
            }
        }
        Store {
            path,
            next_id,
            events,
        }
    }

    /// Assign id + ts, append, trim to MAX_EVENTS, persist. Returns the stored event.
    pub fn append(&mut self, mut ev: Event) -> Event {
        ev.id = self.next_id;
        ev.ts = now_ms();
        self.next_id += 1;
        self.events.push_back(ev.clone());
        while self.events.len() > MAX_EVENTS {
            self.events.pop_front();
        }
        if let Err(e) = self.persist() {
            eprintln!(
                "ccnotify: warning: could not write {}: {e}",
                self.path.display()
            );
        }
        ev
    }

    /// Id of the most recently assigned event (0 if none yet).
    pub fn last_id(&self) -> u64 {
        self.next_id.saturating_sub(1)
    }

    /// Stored events with `id > since`, oldest first.
    pub fn since(&self, since: u64) -> Vec<Event> {
        self.events
            .iter()
            .filter(|e| e.id > since)
            .cloned()
            .collect()
    }

    fn persist(&self) -> std::io::Result<()> {
        let data = PersistRef {
            next_id: self.next_id,
            events: &self.events,
        };
        let bytes = serde_json::to_vec(&data).map_err(std::io::Error::other)?;
        paths::write_atomic(&self.path, &bytes, 0o600)
    }
}

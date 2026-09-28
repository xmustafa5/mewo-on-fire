//! Pending phone requests (PROTOCOL.md v1.1): prompts forwarded by
//! `ccnotify ask`, each waiting for the first answer from a phone.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::oneshot;

/// Pending requests older than this are dropped (resolved by "timeout").
pub const MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
/// How many resolved request ids to remember, so a late answer can be told
/// who resolved the request.
const RECENT_RESOLVED: usize = 64;

/// PROTOCOL.md "Request". Field order matches the protocol.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub id: String,
    pub ts: u64,
    pub kind: String,
    pub project: String,
    pub session: String,
    pub tool: String,
    pub title: String,
    pub summary: String,
    pub detail: String,
    pub can_allow_always: bool,
    pub questions: Vec<Value>,
}

/// What a waiting `ask` gets: the phone's answer, or an error reply
/// (`cancelled` / `timeout`) when the request is resolved without one.
#[derive(Debug)]
pub enum AskReply {
    Answer(Value),
    Error(&'static str),
}

struct Pending {
    request: Request,
    /// Private (never sent to phones): set for a prompt from a subagent.
    agent_id: String,
    reply_tx: oneshot::Sender<AskReply>,
    created: Instant,
}

#[derive(Default)]
pub struct Requests {
    pending: HashMap<String, Pending>,
    recent: VecDeque<(String, &'static str)>,
}

impl Requests {
    pub fn count(&self) -> usize {
        self.pending.len()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.pending.contains_key(id)
    }

    /// Register a request (id/ts already assigned). Returns the receiver its
    /// reply will arrive on.
    pub fn insert(&mut self, request: Request, agent_id: String) -> oneshot::Receiver<AskReply> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.pending.insert(
            request.id.clone(),
            Pending {
                request,
                agent_id,
                reply_tx,
                created: Instant::now(),
            },
        );
        reply_rx
    }

    /// Remove a pending request and remember who resolved it. Returns the
    /// reply sender and the request, or None if the request is unknown /
    /// already resolved.
    pub fn resolve(
        &mut self,
        id: &str,
        by: &'static str,
    ) -> Option<(oneshot::Sender<AskReply>, Request)> {
        let pending = self.pending.remove(id)?;
        self.recent.push_back((id.to_string(), by));
        while self.recent.len() > RECENT_RESOLVED {
            self.recent.pop_front();
        }
        Some((pending.reply_tx, pending.request))
    }

    /// Who resolved a recently finished request.
    pub fn resolved_by(&self, id: &str) -> Option<&'static str> {
        self.recent
            .iter()
            .rev()
            .find(|(rid, _)| rid == id)
            .map(|(_, by)| *by)
    }

    /// Ids of requests pending for longer than `max_age`.
    pub fn expired(&self, max_age: Duration) -> Vec<String> {
        self.pending
            .iter()
            .filter(|(_, p)| p.created.elapsed() > max_age)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Ids of the requests pending for this session that did not come from
    /// a subagent.
    pub fn main_chain(&self, session: &str) -> Vec<String> {
        if session.is_empty() {
            return Vec::new();
        }
        self.pending
            .iter()
            .filter(|(_, p)| p.request.session == session && p.agent_id.is_empty())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// True if a request is pending for this session.
    pub fn has_session(&self, session: &str) -> bool {
        !session.is_empty() && self.pending.values().any(|p| p.request.session == session)
    }

    /// All pending requests, oldest first.
    pub fn snapshot(&self) -> Vec<Request> {
        let mut list: Vec<Request> = self.pending.values().map(|p| p.request.clone()).collect();
        list.sort_by_key(|r| r.ts);
        list
    }
}

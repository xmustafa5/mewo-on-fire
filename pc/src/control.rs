//! Local control socket: newline-delimited JSON, one request per connection.
//! Daemon side (tokio) + a small blocking client used by the CLI and the hook.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

use crate::ask;
use crate::daemon::AppState;
use crate::hook;
use crate::paths;
use crate::peers;
use crate::plane;
use crate::policy;
use crate::requests::{AskReply, Request};
use crate::sessions::{ListenReply, ListenStart, Meta};
use crate::store::Event;
use crate::desktop;
use crate::flow;

const MAX_REQUEST_BYTES: u64 = 1 << 20;
/// `mewo chat`: default and maximum number of items.
const CHAT_DEFAULT_LIMIT: usize = 20;
const CHAT_MAX_LIMIT: usize = 1000;

// ---------------------------------------------------------------------------
// Client (blocking)
// ---------------------------------------------------------------------------

/// Send one request and read one response line. `timeout` applies to both
/// the write and the read.
pub fn request(req: &Value, timeout: Duration) -> Result<Value> {
    request_with(&paths::socket_path(), req, Some(timeout), timeout)
}

/// Like `request`, at a given socket (the dashboard also reads a legacy
/// `ccnotify` daemon).
pub fn request_at(path: &Path, req: &Value, timeout: Duration) -> Result<Value> {
    request_with(path, req, Some(timeout), timeout)
}

/// Like `request`, but waits for the reply with no read timeout (`mewo ask` /
/// `mewo listen` block until a phone answers). `write_timeout` bounds the
/// send.
pub fn request_blocking(req: &Value, write_timeout: Duration) -> Result<Value> {
    request_with(&paths::socket_path(), req, None, write_timeout)
}

fn request_with(
    path: &Path,
    req: &Value,
    read_timeout: Option<Duration>,
    write_timeout: Duration,
) -> Result<Value> {
    let mut stream = std::os::unix::net::UnixStream::connect(path)
        .with_context(|| format!("connecting to {}", path.display()))?;
    stream.set_read_timeout(read_timeout)?;
    stream.set_write_timeout(Some(write_timeout))?;

    let mut line = serde_json::to_string(req)?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut resp = String::new();
    reader.read_line(&mut resp)?;
    let resp = resp.trim();
    if resp.is_empty() {
        bail!("empty response from daemon");
    }
    Ok(serde_json::from_str(resp)?)
}

// ---------------------------------------------------------------------------
// Server (daemon side)
// ---------------------------------------------------------------------------

/// Bind the control socket (removing a stale socket file, refusing to start if
/// another daemon is answering on it) and chmod it 600.
pub fn bind() -> Result<UnixListener> {
    let path = paths::socket_path();
    if fs::symlink_metadata(&path).is_ok() {
        if std::os::unix::net::UnixStream::connect(&path).is_ok() {
            bail!(
                "another Mewo on Fire daemon is already running (socket {} is live)",
                path.display()
            );
        }
        let _ = fs::remove_file(&path);
    }
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let listener = UnixListener::bind(&path)
        .with_context(|| format!("binding control socket {}", path.display()))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod {}", path.display()))?;
    Ok(listener)
}

pub async fn serve(state: Arc<AppState>, listener: UnixListener) {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let state = state.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_conn(state, stream).await {
                        eprintln!("mewo: control: {e:#}");
                    }
                });
            }
            Err(e) => {
                eprintln!("mewo: control accept error: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    }
}

async fn handle_conn(state: Arc<AppState>, stream: tokio::net::UnixStream) -> Result<()> {
    let (rd, mut wr) = stream.into_split();
    let mut reader = tokio::io::BufReader::new(rd.take(MAX_REQUEST_BYTES));
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
        .await
        .map_err(|_| anyhow!("request read timeout"))??;

    let resp = match serde_json::from_str::<Value>(line.trim()) {
        Ok(req) => {
            let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("");
            match cmd {
                "ask" | "listen" => {
                    // Lift the size cap now that the request line is in, so
                    // the EOF watch cannot mistake an exhausted limit for a
                    // closed socket.
                    reader.get_mut().set_limit(u64::MAX);
                    let resp = if cmd == "ask" {
                        handle_ask(&state, &req, &mut reader).await
                    } else {
                        handle_listen(&state, &req, &mut reader).await
                    };
                    match resp {
                        Some(resp) => resp,
                        // The hook went away (answered on the PC / exited):
                        // nobody to reply to.
                        None => return Ok(()),
                    }
                }
                "sessions" => {
                    state.refresh_sessions(None).await;
                    json!({"ok": true, "sessions": state.session_list()})
                }
                // v2.4: a session gone for good, with its feed events. The
                // transcript itself is the caller's to delete.
                "session_forget" => {
                    let id = req.get("session_id").and_then(Value::as_str).unwrap_or("").trim().to_string();
                    match state.find_session(&id) {
                        Ok(s) => {
                            let removed = state.forget_session(&s.id);
                            json!({"ok": true, "session_id": s.id, "removed": removed.0, "events": removed.1})
                        }
                        Err(e) => json!({"ok": false, "error": e}),
                    }
                }
                "chat" => handle_chat(&state, &req).await,
                // v2.0: a command for another PC of the network goes through this hub.
                cmd if is_for_peer(&state, &req) => {
                    let pc_id = req.get("pc_id").and_then(Value::as_str).unwrap_or("").to_string();
                    let mut frame = req.clone();
                    if let Some(o) = frame.as_object_mut() {
                        let ty = match cmd {
                            "features" => "get_features".to_string(),
                            "scan" => "get_scan".to_string(),
                            other => other.to_string(),
                        };
                        o.remove("cmd");
                        o.insert("type".to_string(), json!(ty));
                    }
                    state.peers.forward(&pc_id, frame).await
                }
                "peers" => json!({"ok": true, "pc_id": state.config.pc_id, "name": state.config.name, "account": crate::daemon::account_name(), "peers": state.peers.summary()}),
                "peer_scan" => {
                    let secs = req.get("seconds").and_then(Value::as_u64).unwrap_or(3);
                    json!({"ok": true, "found": peers::scan(secs).await})
                }
                "peer_pair" => {
                    let payload: Option<peers::PairPayload> = match req.get("payload") {
                        Some(Value::String(s)) => serde_json::from_str(s).ok(),
                        Some(v @ Value::Object(_)) => serde_json::from_value(v.clone()).ok(),
                        _ => serde_json::from_value(req.clone()).ok(),
                    };
                    match payload {
                        Some(p) => match peers::pair(&state, &p).await {
                            Ok(peer) => json!({"ok": true, "pc_id": peer.pc_id, "name": peer.name}),
                            Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
                        },
                        None => json!({"ok": false, "error": "The pairing text is not what `mewo pair` prints"}),
                    }
                }
                "peer_remove" => {
                    let pc_id = req.get("pc_id").and_then(Value::as_str).unwrap_or("");
                    match state.peers.remove(pc_id) {
                        Ok(true) => json!({"ok": true}),
                        Ok(false) => json!({"ok": false, "error": "no such peer"}),
                        Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
                    }
                }
                // v1.7: the TORCH flow.
                "features" => state.features_json().await,
                _ => handle_request(&state, &req),
            }
        }
        Err(_) => json!({"ok": false, "error": "bad_json"}),
    };

    let mut out = serde_json::to_string(&resp)?;
    out.push('\n');
    wr.write_all(out.as_bytes()).await?;
    let _ = wr.shutdown().await;
    Ok(())
}

fn handle_request(state: &AppState, req: &Value) -> Value {
    match req.get("cmd").and_then(Value::as_str).unwrap_or("") {
        "emit" => {
            let ev = match req.get("event").cloned().map(serde_json::from_value::<Event>) {
                Some(Ok(ev)) => ev,
                _ => return json!({"ok": false, "error": "bad_event"}),
            };
            if !matches!(ev.kind.as_str(), "stop" | "needs_input" | "session_end" | "warning" | "signoff") {
                return json!({"ok": false, "error": "bad_kind"});
            }
            let mut ev = ev;
            ev.message = hook::clean_message(&ev.message);
            // v1.2 private fields (top level of the request).
            let mut meta = Meta::from_request(req);
            if ev.session_id.is_empty() {
                ev.session_id = meta.session_id.clone();
            } else {
                meta.session_id = ev.session_id.clone();
            }
            if meta.cwd.is_empty() {
                meta.cwd = ev.cwd.clone();
            }
            let session = ev.session.clone();
            let kind = ev.kind.clone();
            match state.emit(ev, &meta) {
                Some(stored) => eprintln!(
                    "mewo: event #{} {} [{}] {}",
                    stored.id, stored.kind, stored.project, stored.detail
                ),
                None => eprintln!(
                    "mewo: dropped needs_input for session {session} (request pending)"
                ),
            }
            if matches!(kind.as_str(), "stop" | "session_end") {
                state.cancel_session_requests(&session, &kind);
            }
            json!({"ok": true})
        }
        "session_state" => {
            let meta = Meta::from_request(req);
            let new_state = req.get("state").and_then(Value::as_str).unwrap_or("");
            if meta.session_id.is_empty()
                || !matches!(new_state, "working" | "idle" | "waiting" | "ended")
            {
                return json!({"ok": false, "error": "bad_request"});
            }
            state.set_session_state(&meta, new_state, None);
            if new_state == "working" {
                state.cancel_session_requests(&short_id(&meta.session_id), "new prompt");
            }
            json!({"ok": true})
        }
        "pair" => {
            let code = state.new_pair_code();
            let qr = state.pair_payload(&code);
            json!({"ok": true, "qr": qr, "code": code, "expires_in": 300})
        }
        "devices" => json!({"ok": true, "devices": state.device_list()}),
        "revoke" => {
            let id = req.get("id").and_then(Value::as_str).unwrap_or("");
            match state.revoke(id) {
                Ok(true) => json!({"ok": true}),
                Ok(false) => json!({"ok": false, "error": "not_found"}),
                Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
            }
        }
        "status" => state.status_json(),
        // The dashboard's feed: the last events and the requests waiting.
        "events" => {
            let n = req.get("limit").and_then(Value::as_u64).unwrap_or(50).min(500);
            let last = state.last_id();
            json!({"ok": true, "last_id": last, "events": state.events_since(last.saturating_sub(n))})
        }
        "requests" => json!({"ok": true, "requests": state.pending_requests()}),
        // v1.7 (TORCH policy): signatures, plan status, the self-check scan,
        // starting a planned session, asking for a signature.
        "plane_config" | "plane_test" | "plane_status" | "plane_members" | "plane_projects" | "plane_signin" | "plane_mine" | "plane_tasks" | "plane_task_add" | "plane_task_done" | "plane_sync" | "plane_disconnect" => {
            tokio::task::block_in_place(|| plane_request(state, req))
        }
        "sign" | "plan_status" | "scan" | "set_check" | "start_session" | "request_sign"
        | "flow_next" | "flow_set" | "estimate" | "estimates_done" | "export_handoff" | "uat_user" | "release" | "close_branches" | "new_feature" | "set_role" | "rollback" | "unsign" | "prds" | "set_prd" | "set_design" | "flow_redo" => {
            // git and gh run here: off the async threads.
            tokio::task::block_in_place(|| policy_request(state, req))
        }
        // v1.6: a new session in Claude Desktop (the console's "New session").
        "new_session" => {
            let cwd = req.get("cwd").and_then(Value::as_str).unwrap_or("");
            let prompt = req.get("prompt").and_then(Value::as_str).unwrap_or("");
            match desktop::open_new_session(cwd, prompt) {
                Ok(()) => json!({"ok": true}),
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        _ => json!({"ok": false, "error": "unknown_cmd"}),
    }
}

/// The Plane commands (v2.1).
pub(crate) fn plane_request(state: &AppState, req: &Value) -> Value {
    let s = |k: &str| req.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
    match s("cmd").as_str() {
        "plane_status" => {
            let mut v = plane::status();
            if let Some(o) = v.as_object_mut() {
                o.insert("members".to_string(), json!(cached_members(false)));
            }
            v
        }
        "plane_members" => json!({"ok": true, "members": cached_members(true)}),
        "plane_test" | "plane_projects" => {
            let mut c = plane::load();
            if !s("base_url").is_empty() {
                c.base_url = s("base_url");
            }
            if !s("workspace").is_empty() {
                c.workspace = s("workspace");
            }
            if !s("token").is_empty() {
                c.token = s("token");
            }
            if c.base_url.is_empty() || c.token.is_empty() {
                return json!({"ok": false, "error": "The address and a token are needed"});
            }
            let me = match plane::me(&c.base_url, &c.token) {
                Ok(m) => m,
                Err(e) => return json!({"ok": false, "error": e}),
            };
            let projects = if c.workspace.is_empty() { Vec::new() } else { plane::projects(&c).unwrap_or_default() };
            let members = if c.workspace.is_empty() { Vec::new() } else { plane::members(&c).unwrap_or_default() };
            json!({"ok": true, "me": me, "projects": projects, "members": members.len(), "members_list": members})
        }
        "plane_config" => {
            let mut c = plane::load();
            c.base_url = s("base_url").trim_end_matches('/').to_string();
            c.app_url = s("app_url").trim_end_matches('/').to_string();
            c.workspace = s("workspace");
            if c.project_id != s("project_id") {
                c.states.clear();
                c.items_path.clear();
            }
            c.project_id = s("project_id");
            c.project_name = s("project_name");
            if !s("token").is_empty() {
                c.token = s("token");
            }
            match plane::save(&c) {
                Ok(()) => {
                    let _ = cached_members(true);
                    json!({"ok": true, "config": c.public()})
                }
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        "plane_disconnect" => match plane::save(&plane::PlaneConfig::default()) {
            Ok(()) => json!({"ok": true}),
            Err(e) => json!({"ok": false, "error": e}),
        },
        "plane_signin" => match plane::signin(&s("token"), &s("phone")) {
            Ok(who) => json!({"ok": true, "me": who}),
            Err(e) => json!({"ok": false, "error": e}),
        },
        "plane_mine" => {
            let plane_id = if !s("plane_id").is_empty() { s("plane_id") } else { plane::person_for_phone(&s("phone")).map(|p| p.plane_id).unwrap_or_default() };
            if plane_id.is_empty() {
                return json!({"ok": false, "error": "Sign in with Plane first (Settings)", "items": []});
            }
            json!({"ok": true, "items": plane::mine(&plane_id), "me": plane::person_for_phone(&s("phone"))})
        }
        "plane_sync" => {
            let feats = state.local_features();
            match plane::sync_once(feats) {
                Ok(n) => json!({"ok": true, "touched": n}),
                Err(e) => {
                    plane::record_error(&e);
                    json!({"ok": false, "error": e})
                }
            }
        }
        "plane_tasks" | "plane_task_add" | "plane_task_done" => {
            if s("cmd") == "plane_task_done" {
                return match plane::set_task_done(&s("id"), req.get("done").and_then(Value::as_bool).unwrap_or(true)) {
                    Ok(()) => json!({"ok": true}),
                    Err(e) => json!({"ok": false, "error": e}),
                };
            }
            let key = s("feature");
            let Some(ws) = workspace_of(&s("workspace"), &key) else {
                return json!({"ok": false, "error": format!("No workspace with the feature {key}")});
            };
            let n = req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32;
            if s("cmd") == "plane_tasks" {
                match plane::tasks(&ws, &key, n) {
                    Ok(t) => json!({"ok": true, "tasks": t}),
                    Err(e) => json!({"ok": false, "error": e, "tasks": []}),
                }
            } else {
                let assignee = plane::person_for_phone(&s("phone")).map(|p| p.plane_id).unwrap_or_default();
                match plane::add_task(&ws, &key, n, &s("name"), &assignee) {
                    Ok(v) => v,
                    Err(e) => json!({"ok": false, "error": e}),
                }
            }
        }
        _ => json!({"ok": false, "error": "unknown_cmd"}),
    }
}

/// The workspace's members, kept five minutes (Plane allows 60 calls a minute).
fn cached_members(refresh: bool) -> Vec<Value> {
    static CACHE: std::sync::Mutex<Option<(std::time::Instant, Vec<Value>)>> = std::sync::Mutex::new(None);
    if !refresh {
        let g = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((at, list)) = g.as_ref() {
            if at.elapsed() < std::time::Duration::from_secs(300) {
                return list.clone();
            }
        }
    }
    let c = plane::load();
    if c.base_url.is_empty() || c.workspace.is_empty() || c.token.is_empty() {
        return Vec::new();
    }
    // The network call runs with no lock held.
    let list = plane::members(&c).unwrap_or_default();
    *CACHE.lock().unwrap_or_else(|p| p.into_inner()) = Some((std::time::Instant::now(), list.clone()));
    list
}

/// A request carrying another PC's `pc_id` (v2.0).
fn is_for_peer(state: &AppState, req: &Value) -> bool {
    // The peer list itself is managed here, never forwarded.
    if matches!(req.get("cmd").and_then(Value::as_str).unwrap_or(""), "peers" | "peer_scan" | "peer_pair" | "peer_remove") {
        return false;
    }
    match req.get("pc_id").and_then(Value::as_str) {
        Some(id) if !id.is_empty() && id != state.config.pc_id => state.peers.is_peer(id),
        _ => false,
    }
}

/// The policy commands (v1.7). `workspace` names the workspace; when
/// absent, the one feature `feature` is in.
pub(crate) fn policy_request(state: &AppState, req: &Value) -> Value {
    let s = |k: &str| req.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
    let cmd = s("cmd");
    if cmd == "scan" {
        let session_id = s("session_id");
        let (dir, feature) = if !session_id.is_empty() {
            state
                .session_list()
                .into_iter()
                .find(|x| x.id == session_id)
                .map(|x| (x.cwd, x.feature))
                .unwrap_or_default()
        } else {
            (s("dir"), String::new())
        };
        let base = s("base");
        let feature_branch = if !base.is_empty() {
            base
        } else {
            feature_branch_of(&dir, &feature)
        };
        let ok_words = design_words(&dir, &feature);
        return serde_json::to_value(policy::scan(&dir, &feature_branch, &ok_words)).unwrap_or(Value::Null);
    }
    if cmd == "set_check" {
        let index = req.get("index").and_then(Value::as_u64).unwrap_or(99) as usize;
        let checked = req.get("checked").and_then(Value::as_bool).unwrap_or(false);
        return match state.set_check(&s("session_id"), index, checked) {
            Some(session) => json!({"ok": true, "checks": session.checks}),
            None => json!({"ok": false, "error": "unknown session or line"}),
        };
    }
    // Workspace-level commands (v1.8).
    if cmd == "set_role" || cmd == "new_feature" {
        let Some(ws) = (if s("workspace").is_empty() { policy::workspaces().into_iter().next() } else { policy::workspace_for(&s("workspace")) }) else {
            return json!({"ok": false, "error": "No workspace known yet"});
        };
        return match cmd.as_str() {
            "set_role" => match flow::set_role(&ws, &s("role"), &s("name"), &s("phone"), &s("pc"), &s("plane")) {
                Ok(list) => json!({"ok": true, "roles": list}),
                Err(e) => json!({"ok": false, "error": e}),
            },
            _ => {
                let light = req.get("light").and_then(Value::as_bool).unwrap_or(false);
                flow::new_feature(&ws, &s("app"), &s("slug"), light)
            }
        };
    }
    let key = s("feature");
    let Some(ws) = workspace_of(&s("workspace"), &key) else {
        return json!({"ok": false, "error": format!("No workspace with the feature {key}")});
    };
    match cmd.as_str() {
        "sign" if s("gate") == "prd" => match state.feature(&ws, &key) {
            Some(f) => match flow::sign_prd(&ws, &f, &s("name")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "sign" => {
            let checks: Vec<bool> = req.get("checks").and_then(Value::as_array).map(|a| a.iter().map(|v| v.as_bool().unwrap_or(false)).collect()).unwrap_or_default();
            match policy::sign(&ws, &key, &s("gate"), &s("role"), &s("name"), &checks) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        // v1.8: the flow runner.
        "flow_next" => match state.feature(&ws, &key) {
            Some(f) => state.flow_execute(&ws, &f, None, &s("name")),
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        // v2.4: a step's session again. `dry` only shows the action.
        "flow_redo" => match state.feature(&ws, &key) {
            Some(f) => {
                let step = req.get("step").and_then(Value::as_u64).unwrap_or(0) as u8;
                let st = flow::get(&ws, &f.key);
                match flow::redo_action(&ws, &f, &st, step) {
                    Some(a) => {
                        if req.get("dry").and_then(Value::as_bool).unwrap_or(false) {
                            return json!({"ok": true, "action": a});
                        }
                        let prev = st.design_since;
                        if step == 4 {
                            flow::update(&ws, &f.key, |st| {
                                st.design_since = crate::config::now_ms();
                                st.note("Design restarted: the earlier boards no longer count");
                            });
                        }
                        let r = state.flow_execute(&ws, &f, Some(a), &s("name"));
                        let ok = r.get("ok").and_then(Value::as_bool).unwrap_or(false);
                        if step == 4 {
                            if ok {
                                flow::journal(&ws, &f.key, "redo", "Design restarted", Vec::new(), "", true, json!({"prev": prev, "step": step}));
                            } else {
                                flow::update(&ws, &f.key, |st| st.design_since = prev);
                            }
                        }
                        r
                    }
                    None => json!({"ok": false, "error": format!("Step {step} has no session to run again")}),
                }
            }
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "flow_set" => {
            let on = req.get("autopilot").and_then(Value::as_bool).unwrap_or(false);
            let st = flow::update(&ws, &key, |st| {
                st.autopilot = on;
                st.note(if on { "Autopilot on" } else { "Autopilot off" });
            });
            json!({"ok": true, "autopilot": st.autopilot})
        }
        "estimate" => {
            let days = req.get("days").and_then(Value::as_f64).unwrap_or(0.0);
            let role = s("role");
            if !flow::ESTIMATE_ROLES.iter().any(|r| r.eq_ignore_ascii_case(&role)) {
                return json!({"ok": false, "error": format!("Estimates come from {}", flow::ESTIMATE_ROLES.join(", "))});
            }
            let st = flow::update(&ws, &key, |st| {
                st.estimates.retain(|e| !e.role.eq_ignore_ascii_case(&role));
                st.estimates.push(flow::Estimate { role: role.clone(), name: s("name"), days, assumptions: s("assumptions"), ts: crate::config::now_ms() });
                st.note(format!("Estimate from {}: {} days", role, days));
            });
            flow::journal(&ws, &key, "estimate", &format!("Estimate from {role}: {days} days"), Vec::new(), "", true, json!({"role": role}));
            json!({"ok": true, "estimates": st.estimates})
        }
        "estimates_done" => {
            flow::update(&ws, &key, |st| {
                st.estimates_done = true;
                st.note("Estimates recorded in the PRD");
            });
            flow::journal(&ws, &key, "estimates_done", "Estimates marked as in the PRD", Vec::new(), "", true, Value::Null);
            json!({"ok": true})
        }
        // v2.2: which PRD a feature follows.
        "prds" => match state.feature(&ws, &key) {
            Some(f) => json!({"ok": true, "prd": f.prd, "source": f.prd_source, "prds": policy::prd_choices(&ws, &f.app, &flow::picked_prd(&ws, &f.key))}),
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "set_prd" => match state.feature(&ws, &key) {
            Some(f) => match flow::set_prd(&ws, &f, &s("prd")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        // v2.3: the design system the feature follows.
        "set_design" => match state.feature(&ws, &key) {
            Some(f) => match flow::set_design(&ws, &f, &s("name"), &s("repo"), &s("dir"), &s("reference")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "unsign" => match state.feature(&ws, &key) {
            Some(f) => match flow::unsign(&ws, &f, &s("gate"), &s("role")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "rollback" => match state.feature(&ws, &key) {
            Some(f) => match flow::rollback(&ws, &f, req.get("id").and_then(Value::as_u64).unwrap_or(0)) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "export_handoff" => match state.feature(&ws, &key) {
            Some(f) => match flow::export_handoff(&ws, &f, &state.session_list()) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "uat_user" => match state.feature(&ws, &key) {
            Some(f) => match flow::uat_user(&ws, &f, &s("user"), &s("role"), req.get("unaided").and_then(Value::as_bool).unwrap_or(false), &s("notes")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "release" => match state.feature(&ws, &key) {
            Some(f) => match flow::release(&ws, &f, &s("name")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            },
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "close_branches" => match state.feature(&ws, &key) {
            Some(f) => flow::close_branches(&ws, &f),
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "plan_status" => {
            let n = req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32;
            match policy::set_plan_status(&ws, &key, n, &s("status"), &s("pr")) {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        "start_session" => {
            let n = req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32;
            let Some(f) = policy::features(&ws).into_iter().find(|f| f.key == key) else {
                return json!({"ok": false, "error": "unknown feature"});
            };
            let Some(ps) = f.plan.as_ref().and_then(|p| p.sessions.iter().find(|x| x.n == n).cloned()) else {
                return json!({"ok": false, "error": format!("The plan has no session {n}")});
            };
            if ps.prompt.is_empty() {
                return json!({"ok": false, "error": format!("Session {n} has no prompt in the plan yet")});
            }
            match desktop::open_new_session(&ps.folder, &ps.prompt) {
                Ok(()) => {
                    let _ = policy::set_plan_status(&ws, &key, n, "In progress", "");
                    json!({"ok": true, "folder": ps.folder})
                }
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        "request_sign" => match state.feature(&ws, &key) {
            Some(f) => state.ask_signature(&ws, &f, &s("gate"), &s("role"), &s("name")),
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        _ => json!({"ok": false, "error": "unknown_cmd"}),
    }
}

/// The feature branch a session's changes go into, from its feature.
fn feature_branch_of(dir: &str, feature: &str) -> String {
    if feature.is_empty() {
        return String::new();
    }
    let Some(ws) = policy::workspace_for(dir) else { return String::new() };
    policy::features(&ws).into_iter().find(|f| f.key == feature).map(|f| f.branch).unwrap_or_default()
}

/// v2.3: the feature's design system words (its name, its checkout
/// folder) the self-check accepts in a line with a colour, like "glare".
fn design_words(dir: &str, feature: &str) -> Vec<String> {
    if feature.is_empty() {
        return Vec::new();
    }
    let Some(ws) = policy::workspace_for(dir) else { return Vec::new() };
    let Some(f) = policy::features(&ws).into_iter().find(|f| f.key == feature) else { return Vec::new() };
    let mut out = Vec::new();
    for k in ["name", "dir"] {
        let v = f.design[k].as_str().unwrap_or("");
        let base = v.rsplit('/').next().unwrap_or(v).trim();
        if base.len() >= 3 && !base.eq_ignore_ascii_case("glare") {
            out.push(base.to_string());
        }
    }
    out
}

fn workspace_of(workspace: &str, key: &str) -> Option<std::path::PathBuf> {
    if !workspace.is_empty() {
        return policy::workspace_for(workspace);
    }
    policy::workspaces().into_iter().find(|ws| policy::features(ws).iter().any(|f| f.key == key))
}

/// `ask`: forward a prompt to the connected phones and block until one
/// answers (or the request is cancelled / expires). Returns None when the
/// client (the hook) hung up first — its transcript watcher exits it when the
/// prompt is answered on the PC.
async fn handle_ask<R>(state: &AppState, req: &Value, reader: &mut R) -> Option<Value>
where
    R: AsyncRead + Unpin,
{
    let mut request = match req.get("request").cloned().map(serde_json::from_value::<Request>) {
        Some(Ok(r)) => r,
        _ => return Some(json!({"ok": false, "error": "bad_request"})),
    };
    if !matches!(request.kind.as_str(), "permission" | "question" | "plan") {
        return Some(json!({"ok": false, "error": "bad_kind"}));
    }
    if state.connected.load(Ordering::SeqCst) == 0 {
        return Some(json!({"ok": false, "error": "no_devices"}));
    }
    request.summary = hook::clean_message(&request.summary);
    request.detail = ask::truncate_chars(&request.detail, ask::MAX_DETAIL_CHARS);
    let log_line = format!("{} [{}] {}", request.kind, request.project, request.summary);
    // Private: the session safety net leaves subagent prompts alone.
    let agent_id = req
        .get("agent_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();

    let (id, reply_rx) = state.add_request(request, agent_id);
    eprintln!("mewo: request {id} {log_line}");

    tokio::select! {
        reply = reply_rx => {
            match reply {
                Ok(AskReply::Answer(answer)) => Some(json!({"ok": true, "answer": answer})),
                // Cancelled (session moved on) or expired.
                Ok(AskReply::Error(error)) => Some(json!({"ok": false, "error": error})),
                Err(_) => Some(json!({"ok": false, "error": "cancelled"})),
            }
        }
        _ = wait_for_eof(reader) => {
            if state.cancel_request(&id, "pc") {
                eprintln!("mewo: request {id} resolved by pc (hook exited)");
            }
            None
        }
    }
}

/// `listen` (PROTOCOL.md v1.2): hand over queued phone messages right away,
/// else wait as the session's listener until a phone message arrives, the
/// listener is superseded / cancelled, or the hook goes away (None).
async fn handle_listen<R>(state: &AppState, req: &Value, reader: &mut R) -> Option<Value>
where
    R: AsyncRead + Unpin,
{
    let meta = Meta::from_request(req);
    let (listener_id, mut reply_rx) = match state.listen(&meta) {
        None => return Some(json!({"ok": false, "error": "bad_request"})),
        Some(ListenStart::Now(text)) => {
            eprintln!(
                "mewo: session {}: delivered queued phone message(s)",
                short_id(&meta.session_id)
            );
            return Some(json!({"ok": true, "text": text}));
        }
        Some(ListenStart::Wait(id, rx)) => (id, rx),
    };

    tokio::select! {
        reply = &mut reply_rx => {
            match reply {
                Ok(ListenReply::Text(text)) => Some(json!({"ok": true, "text": text})),
                Ok(ListenReply::Error(error)) => Some(json!({"ok": false, "error": error})),
                // Listener dropped with its session (pruned).
                Err(_) => Some(json!({"ok": false, "error": "cancelled"})),
            }
        }
        _ = wait_for_eof(reader) => {
            state.unlisten(&meta.session_id, listener_id);
            // A message handed over just as the hook went away: keep it for
            // the next listen.
            if let Ok(ListenReply::Text(text)) = reply_rx.try_recv() {
                state.requeue(&meta.session_id, text);
            }
            None
        }
    }
}

/// `chat` (for `mewo chat`): the last items of the session whose id
/// starts with `session`.
async fn handle_chat(state: &AppState, req: &Value) -> Value {
    let prefix = req.get("session").and_then(Value::as_str).unwrap_or("");
    let limit = req
        .get("limit")
        .and_then(Value::as_u64)
        .map(|l| l as usize)
        .unwrap_or(CHAT_DEFAULT_LIMIT)
        .clamp(1, CHAT_MAX_LIMIT);
    let session = match state.find_session(prefix) {
        Ok(s) => s,
        Err(error) => return json!({"ok": false, "error": error}),
    };
    match state.chat(&session.id, limit).await {
        Some((session, items)) => json!({"ok": true, "session": session, "items": items}),
        None => json!({"ok": false, "error": "not_found"}),
    }
}

fn short_id(session_id: &str) -> String {
    session_id.chars().take(8).collect()
}

/// Resolves when the peer closes its end (or the read fails). The client
/// sends nothing after its request line; stray bytes are ignored.
async fn wait_for_eof<R>(reader: &mut R)
where
    R: AsyncRead + Unpin,
{
    let mut buf = [0u8; 256];
    loop {
        match reader.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => continue,
        }
    }
}

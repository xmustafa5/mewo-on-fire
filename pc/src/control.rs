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
use crate::notes;
use crate::config::now_ms;
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
                // v2.5: the open notes of a design go to the session that made
                // it, as one review message; to a new session when that one
                // is gone. `dry` only shows the message.
                "notes_send" => {
                    let artifact = req.get("artifact").and_then(Value::as_str).unwrap_or("").trim().to_string();
                    let all = notes::list(&artifact);
                    let wanted: Vec<u64> = req.get("ids").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default();
                    let send: Vec<&notes::Note> = all.iter().filter(|n| n.status == "open" && (wanted.is_empty() || wanted.contains(&n.id))).collect();
                    if send.is_empty() {
                        json!({"ok": false, "error": "No open notes to send"})
                    } else {
                        let sessions = state.session_list();
                        let owner = sessions.iter().find(|x| x.artifacts.iter().any(|a| a.id == artifact)).cloned();
                        let art = owner.as_ref().and_then(|x| x.artifacts.iter().find(|a| a.id == artifact).cloned());
                        let title = art.as_ref().map(|a| a.title.clone()).filter(|t| !t.is_empty()).unwrap_or_else(|| req.get("title").and_then(Value::as_str).unwrap_or("").to_string());
                        let url = art.as_ref().map(|a| a.url.clone()).filter(|u| !u.is_empty()).unwrap_or_else(|| req.get("url").and_then(Value::as_str).unwrap_or("").to_string());
                        let text = notes::message(&title, &url, &all, &send);
                        if req.get("dry").and_then(Value::as_bool).unwrap_or(false) {
                            json!({"ok": true, "dry": true, "message": text, "session": owner.as_ref().map(|x| x.id.clone()), "count": send.len()})
                        } else {
                            let ids: Vec<u64> = send.iter().map(|n| n.id).collect();
                            let client_id = format!("notes-{}", crate::config::now_ms());
                            let mut how = String::new();
                            let mut err = String::new();
                            if let Some(sess) = &owner {
                                match state.send_message(&sess.id, &text, &client_id, Vec::new()).await {
                                    crate::sessions::SendOutcome::Delivered => how = "delivered".to_string(),
                                    crate::sessions::SendOutcome::Queued => how = "queued".to_string(),
                                    crate::sessions::SendOutcome::Rejected(r) => err = r.to_string(),
                                }
                            }
                            if how.is_empty() {
                                // A new session, in the design session's folder when known.
                                let cwd = owner.as_ref().map(|x| x.cwd.clone()).unwrap_or_default();
                                let prompt = format!("{text}

The design is the Design artifact{}: open it and apply the notes to its boards.", if url.is_empty() { String::new() } else { format!(" at {url}") });
                                match desktop::open_new_session(&cwd, &prompt) {
                                    Ok(()) => how = "new_session".to_string(),
                                    Err(e) => err = if err.is_empty() { e } else { format!("{err}; {e}") },
                                }
                            }
                            if how.is_empty() {
                                json!({"ok": false, "error": err})
                            } else {
                                notes::mark_sent(&artifact, &ids);
                                json!({"ok": true, "how": how, "count": ids.len(), "session": owner.as_ref().map(|x| x.id.clone())})
                            }
                        }
                    }
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
                // v3.3: the operations console's own settings (what it hides, its filters).
                "console_get" => json!({"ok": true, "prefs": crate::console_prefs::load()}),
                "console_set" => match req.get("prefs") {
                    Some(p) => match crate::console_prefs::save(p) {
                        Ok(()) => json!({"ok": true}),
                        Err(e) => json!({"ok": false, "error": e}),
                    },
                    None => json!({"ok": false, "error": "prefs missing"}),
                },
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
    let s = |k: &str| req.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
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
        // v2.11: a session as it happens, for the console's live view.
        "session_live" => {
            let limit = req.get("limit").and_then(Value::as_u64).unwrap_or(300).clamp(1, 1000) as usize;
            match tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(state.live_steps(&s("session"), limit))) {
                Some((session, steps)) => json!({"ok": true, "session": session, "steps": steps}),
                None => json!({"ok": false, "error": "No such session"}),
            }
        }
        "sign" | "plan_status" | "scan" | "set_check" | "start_session" | "request_sign"
        | "flow_next" | "flow_set" | "estimate" | "estimates_done" | "export_handoff" | "uat_user" | "release" | "close_branches" | "new_feature" | "set_role" | "rollback" | "unsign" | "prds" | "set_prd" | "set_design" | "flow_redo" | "build_set" | "session_detail" | "session_stop" | "open_questions" | "answer_question" => {
            // git and gh run here: off the async threads.
            tokio::task::block_in_place(|| policy_request(state, req))
        }
        // v1.6: a new session in Claude Desktop (the console's "New session").
        // v2.6: the GitHub account the daemon acts as.
        "github_user" => {
            let user = s("user");
            match crate::config::set_github_user(&user) {
                Ok(()) => {
                    crate::github::set_user(&user);
                    let mut v = crate::github::status();
                    v["ok"] = json!(true);
                    v
                }
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            }
        }
        // v2.7: the work hours of the build autopilot.
        "work_hours" => {
            let hours = s("hours");
            if !hours.is_empty() && crate::clock::parse_hours(&hours).is_none() {
                return json!({"ok": false, "error": "Hours look like 09:00-18:00"});
            }
            let days: Vec<u8> = req.get("days").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).map(|d| d as u8).collect()).unwrap_or_default();
            match crate::config::set_work_hours(&hours, &days) {
                Ok(()) => {
                    let mut v = crate::clock::describe(&hours, &days);
                    v["ok"] = json!(true);
                    v
                }
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            }
        }
        "github_status" => {
            let mut v = crate::github::status();
            v["ok"] = json!(true);
            v
        }
        // v2.5: review notes pinned on a design's boards.
        "notes" => json!({"ok": true, "notes": notes::list(&s("artifact")).iter().map(notes::to_json).collect::<Vec<_>>()}),
        "note_add" => match notes::add(
            &s("artifact"),
            &s("board"),
            &s("board_title"),
            req.get("x").and_then(Value::as_f64).unwrap_or(0.5),
            req.get("y").and_then(Value::as_f64).unwrap_or(0.5),
            &s("text"),
            &s("by"),
        ) {
            Ok(n) => json!({"ok": true, "note": notes::to_json(&n)}),
            Err(e) => json!({"ok": false, "error": e}),
        },
        "note_set" => match notes::set(&s("artifact"), req.get("id").and_then(Value::as_u64).unwrap_or(0), req.get("text").and_then(Value::as_str), req.get("status").and_then(Value::as_str)) {
            Ok(n) => json!({"ok": true, "note": notes::to_json(&n)}),
            Err(e) => json!({"ok": false, "error": e}),
        },
        "note_remove" => json!({"ok": true, "removed": notes::remove(&s("artifact"), req.get("id").and_then(Value::as_u64).unwrap_or(0))}),
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
        // v2.6: everything about one plan session: its run, its review, its live
        // Claude sessions with their last steps, timing and a rough estimate.
        "session_detail" => match state.feature(&ws, &key) {
            Some(f) => session_detail(state, &ws, &f, req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32),
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        "session_stop" => match state.feature(&ws, &key) {
            Some(f) => {
                let n = req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32;
                let st = flow::get(&ws, &f.key);
                let pid = st.runs.iter().rev().find(|r| r.step == 9 && r.note == n.to_string()).map(|r| r.pid).unwrap_or(0);
                let review_pid = st.history.iter().rev().find(|j| j.kind == "review" && j.data.get("session").and_then(Value::as_u64) == Some(n as u64)).and_then(|j| j.data.get("pid").and_then(Value::as_u64)).unwrap_or(0) as u32;
                let mut stopped = Vec::new();
                for p in [pid, review_pid] {
                    if p != 0 && crate::runner::alive(p) {
                        let _ = std::process::Command::new("kill").arg(p.to_string()).status();
                        stopped.push(p);
                    }
                }
                if stopped.is_empty() {
                    json!({"ok": false, "error": "No headless run of this session is alive"})
                } else {
                    flow::update(&ws, &f.key, |x| x.note(format!("Session {n} stopped by hand")));
                    flow::journal(&ws, &f.key, "stop", &format!("Session {n} stopped by hand"), Vec::new(), "", false, json!({"session": n, "pids": stopped}));
                    json!({"ok": true, "stopped": stopped})
                }
            }
            None => json!({"ok": false, "error": "unknown feature"}),
        },
        // v2.6: the build autopilot.
        "build_set" => match state.feature(&ws, &key) {
            Some(f) => {
                let on = req.get("on").and_then(Value::as_bool).unwrap_or(true);
                if on {
                    if let Err(e) = crate::runner::ready() {
                        return json!({"ok": false, "error": e});
                    }
                }
                // Pause: off, with a time to come back (the next work hours, or
                // a given time), and "stop now" ends what runs.
                let (hours, days) = crate::config::work_hours();
                let resume_at = if on {
                    0
                } else if req.get("resume_next_work").and_then(Value::as_bool).unwrap_or(false) {
                    let t = crate::clock::next_start(&hours, &days);
                    if t <= now_ms() + 60_000 { now_ms() + 12 * 60 * 60 * 1000 } else { t }
                } else {
                    req.get("resume_at").and_then(Value::as_u64).unwrap_or(0)
                };
                let mut v = flow::set_build(&ws, &f, on, req.get("parallel").and_then(Value::as_u64).map(|p| p as u8), req.get("review").and_then(Value::as_bool), resume_at, req.get("merge_on_pass").and_then(Value::as_bool), req.get("attended").and_then(Value::as_bool));
                if !on && req.get("stop_running").and_then(Value::as_bool).unwrap_or(false) {
                    let st = flow::get(&ws, &f.key);
                    let pids = flow::alive_pids(&st);
                    for p in &pids {
                        let _ = std::process::Command::new("kill").arg(p.to_string()).status();
                    }
                    if !pids.is_empty() {
                        flow::update(&ws, &f.key, |x| x.note(format!("Stopped {} running session{}", pids.len(), if pids.len() == 1 { "" } else { "s" })));
                        flow::journal(&ws, &f.key, "stop", &format!("Stopped {} running session{} by hand", pids.len(), if pids.len() == 1 { "" } else { "s" }), Vec::new(), "", false, json!({"pids": pids}));
                    }
                    v["stopped"] = json!(pids.len());
                }
                // v3.3: the run's own instructions, when given.
                let nums = |k: &str| req.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).map(|n| n as u32).collect::<Vec<u32>>());
                let note = req.get("note").and_then(Value::as_str).map(str::to_string);
                if note.is_some() || ["hold", "order", "fresh"].iter().any(|k| req.get(*k).is_some()) {
                    v["run"] = flow::set_build_run(&ws, &f, note, nums("hold"), nums("order"), nums("fresh"));
                }
                v
            }
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
        // v2.10: the open questions, asked one by one in the console.
        "open_questions" => policy::open_questions(&ws, &key).unwrap_or_else(|e| json!({"ok": false, "error": e})),
        "answer_question" => {
            let n = req.get("n").and_then(Value::as_u64).unwrap_or(0) as u32;
            match policy::answer_question(&ws, &key, n, &s("answer"), &s("name")) {
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

/// The last `max` characters of the newest run log matching `prefix`
/// (and `-review-` only when `review`).
pub(crate) fn run_log_tail(prefix: &str, review: bool, max: usize) -> (String, String) {
    let dir = crate::paths::state_dir().join("runs");
    let Ok(rd) = std::fs::read_dir(&dir) else { return (String::new(), String::new()) };
    let mut names: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.starts_with(prefix) && n.ends_with(".log") && n.contains("-review-") == review).collect();
    names.sort();
    let Some(name) = names.pop() else { return (String::new(), String::new()) };
    let tail = |p: std::path::PathBuf| -> String {
        let t = std::fs::read_to_string(p).unwrap_or_default();
        let start = t.char_indices().rev().nth(max).map(|(i, _)| i).unwrap_or(0);
        t[start..].to_string()
    };
    (tail(dir.join(&name)), tail(dir.join(name.replace(".log", ".err"))))
}

/// v2.6: one plan session in full, for the console and the phone.
fn session_detail(state: &AppState, ws: &std::path::Path, f: &policy::Feature, n: u32) -> Value {
    let Some(plan) = &f.plan else { return json!({"ok": false, "error": "no plan"}) };
    let Some(ps) = plan.sessions.iter().find(|s| s.n == n) else { return json!({"ok": false, "error": format!("no session {n}")}) };
    let st = flow::get(ws, &f.key);
    let now = now_ms();
    let runs: Vec<&flow::Run> = st.runs.iter().filter(|r| r.step == 9 && r.note == n.to_string()).collect();
    let run = runs.last().map(|r| {
        let alive = r.pid != 0 && crate::runner::alive(r.pid);
        let (log, err) = run_log_tail(&format!("{}-S{}-", f.slug, n), false, 1600);
        json!({"started": r.started, "pid": r.pid, "headless": r.pid != 0, "alive": alive, "exit": crate::runner::exit_code(r.pid), "elapsed_s": now.saturating_sub(r.started) / 1000, "attempt": runs.len(), "log": log, "err": err, "folder": r.folder})
    });
    let review_pid = st.history.iter().rev().find(|j| j.kind == "review" && j.data.get("session").and_then(Value::as_u64) == Some(n as u64)).and_then(|j| j.data.get("pid").and_then(Value::as_u64)).unwrap_or(0) as u32;
    let review = st.reviews.get(&n).map(|t| {
        let (log, _) = run_log_tail(&format!("{}-S{}-", f.slug, n), true, 1600);
        json!({"started": t, "pid": review_pid, "alive": review_pid != 0 && crate::runner::alive(review_pid), "elapsed_s": now.saturating_sub(*t) / 1000, "log": log})
    });
    // The live Claude sessions, with their last steps: its runs, then the
    // reviewers in its review worktree (v2.11, for the console's live view).
    let mut ids: Vec<(String, &str)> = ps.live.iter().filter_map(|l| l.get("id").and_then(Value::as_str)).filter(|id| !id.is_empty()).map(|id| (id.to_string(), "run")).collect();
    let review_dir = format!("-S{n}-review");
    let mut reviewers = state.reviewers_of(&ps.pr_url);
    for x in state.session_list() {
        if x.cwd.starts_with(&*ws.to_string_lossy()) && x.cwd.ends_with(&review_dir) {
            reviewers.push(x.id);
        }
    }
    for id in reviewers {
        if !ids.iter().any(|(x, _)| *x == id) {
            ids.push((id, "review"));
        }
    }
    let mut live = Vec::new();
    for (id, kind) in ids {
        let chat = tokio::runtime::Handle::current().block_on(state.chat(&id, 14));
        let (sess, items) = match chat {
            Some(x) => x,
            None => continue,
        };
        live.push(json!({
            "id": sess.id, "short": sess.short, "kind": kind, "state": sess.state, "title": sess.title, "last_ts": sess.last_ts, "last_text": sess.last_text.chars().take(600).collect::<String>(), "desktop": sess.desktop,
            "chat": items.iter().map(|c| json!({"ts": c.ts, "role": c.role, "tool": c.tool, "text": c.text.chars().take(280).collect::<String>()})).collect::<Vec<_>>(),
        }));
    }
    // Timing: this session's marks, and what sessions of the same tier took.
    let mark = |m: u32, status: &str| st.history.iter().filter(|j| j.kind == "plan_status" && j.data.get("n").and_then(Value::as_u64) == Some(m as u64) && j.data.get("status").and_then(Value::as_str).map(|s| s.eq_ignore_ascii_case(status)).unwrap_or(false)).map(|j| j.ts).min();
    // The run that counts: the last one started before the pull request
    // opened (earlier attempts stopped), else the latest.
    let start_of = |m: u32| -> Option<u64> {
        let review = mark(m, "In review");
        st.runs.iter().filter(|r| r.step == 9 && r.note == m.to_string() && review.map(|t| r.started < t).unwrap_or(true)).map(|r| r.started).max()
    };
    let started_at = start_of(n);
    let in_review_at = mark(n, "In review");
    let merged_at = mark(n, "Merged");
    let mut by_tier: std::collections::HashMap<u8, Vec<u64>> = std::collections::HashMap::new();
    for s in &plan.sessions {
        if let (Some(a), Some(b)) = (start_of(s.n), mark(s.n, "In review")) {
            if b > a {
                by_tier.entry(s.tier).or_default().push((b - a) / 1000);
            }
        }
    }
    let default_s = |tier: u8| -> u64 { match tier { 1 => 25 * 60, 2 => 15 * 60, _ => 8 * 60 } };
    let typical = |tier: u8| -> (u64, usize) { by_tier.get(&tier).filter(|v| !v.is_empty()).map(|v| (v.iter().sum::<u64>() / v.len() as u64, v.len())).unwrap_or((default_s(tier), 0)) };
    let (typical_s, samples) = typical(ps.tier);
    let elapsed_s = started_at.map(|a| (in_review_at.unwrap_or(now).saturating_sub(a)) / 1000).unwrap_or(0);
    let eta_s = if ps.effective == "progress" { Some(typical_s.saturating_sub(elapsed_s)) } else { None };
    let parallel = if st.build_parallel == 0 { 2 } else { st.build_parallel } as u64;
    let remaining: u64 = plan.sessions.iter().filter(|s| s.effective != "merged").map(|s| typical(s.tier).0 + 6 * 60).sum::<u64>() / parallel.max(1);
    let merged = plan.sessions.iter().filter(|s| s.effective == "merged").count();
    json!({
        "ok": true,
        "session": {"n": ps.n, "goal": ps.goal, "level": ps.level, "tier": ps.tier, "repo": ps.repo, "folder": ps.folder, "owner": ps.owner, "status": ps.status, "effective": ps.effective, "depends_on": ps.depends_on, "pr_url": ps.pr_url, "pr_state": ps.pr_state, "attempts": ps.attempts, "done_when": ps.done_when, "load_first": ps.load_first, "warnings": ps.warnings, "note": ps.note, "running": ps.running},
        "run": run,
        "review": review,
        "live": live,
        "timing": {"started_at": started_at, "in_review_at": in_review_at, "merged_at": merged_at, "elapsed_s": elapsed_s, "typical_s": typical_s, "typical_from": samples, "eta_s": eta_s, "build_merged": merged, "build_total": plan.sessions.len(), "build_remaining_s": remaining, "parallel": parallel},
    })
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

//! Plane (v2.1): the team's board. The daemon mirrors every feature, its
//! sign-offs and its plan sessions as work items in a Plane project,
//! assigned to the people who hold the roles; what changes in Plane
//! (assignees, states) comes back; people sign in from their phones with
//! a Plane token so their name, phone and Plane user are one person. The
//! markdown records stay the truth (policy section 3): Done in Plane does
//! not sign, signing closes the item.
//!
//! `plane.json` in the config folder (mode 600) keeps the connection and
//! the people; `plane-map.json` in the state folder keeps which item is
//! which.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::config::now_ms;
use crate::flow;
use crate::paths;
use crate::policy::{self, Feature};

const TIMEOUT: Duration = Duration::from_secs(20);
const SYNC_EVERY: Duration = Duration::from_secs(60);

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------

/// Someone who signed in with Plane from a phone.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Person {
    pub plane_id: String,
    pub display: String,
    pub email: String,
    /// The paired phone's device name.
    pub phone: String,
    pub since: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaneConfig {
    /// `https://api.plane.so` or the self-hosted address.
    pub base_url: String,
    /// The web app, for links; derived from `base_url` when empty.
    pub app_url: String,
    pub workspace: String,
    pub project_id: String,
    pub project_name: String,
    /// The token Mewo acts with (a Plane user of its own, or a lead's).
    pub token: String,
    /// `work-items` (Plane since 2025) or `issues` (older self-hosted).
    pub items_path: String,
    /// State ids by group: backlog, unstarted, started, completed.
    pub states: HashMap<String, String>,
    /// Every state of the project: `{id, name, group}`.
    pub all_states: Vec<Value>,
    pub people: Vec<Person>,
}

impl PlaneConfig {
    pub fn configured(&self) -> bool {
        !self.base_url.is_empty() && !self.workspace.is_empty() && !self.project_id.is_empty() && !self.token.is_empty()
    }

    pub fn app_base(&self) -> String {
        if !self.app_url.is_empty() {
            return self.app_url.trim_end_matches('/').to_string();
        }
        let b = self.base_url.trim_end_matches('/');
        if b.contains("api.plane.so") {
            b.replacen("api.plane.so", "app.plane.so", 1)
        } else {
            b.to_string()
        }
    }

    pub fn item_url(&self, item_id: &str) -> String {
        format!("{}/{}/projects/{}/issues/{}", self.app_base(), self.workspace, self.project_id, item_id)
    }

    /// Without the token, for the console and the phones.
    pub fn public(&self) -> Value {
        json!({
            "base_url": self.base_url, "app_url": self.app_base(), "workspace": self.workspace,
            "project_id": self.project_id, "project_name": self.project_name, "configured": self.configured(),
            "has_token": !self.token.is_empty(), "people": self.people,
        })
    }
}

fn config_file() -> PathBuf {
    paths::config_dir().join("plane.json")
}

pub fn load() -> PlaneConfig {
    fs::read_to_string(config_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn save(c: &PlaneConfig) -> Result<(), String> {
    let text = serde_json::to_string_pretty(c).map_err(|e| e.to_string())?;
    paths::write_atomic(&config_file(), format!("{text}\n").as_bytes(), 0o600).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// a small HTTP client (rustls, HTTP/1.1, JSON)
// ---------------------------------------------------------------------------

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: Mutex<Option<Arc<rustls::ClientConfig>>> = Mutex::new(None);
    let mut guard = CONFIG.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(c) = guard.as_ref() {
        return c.clone();
    }
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let c = Arc::new(
        rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("tls versions")
            .with_root_certificates(roots)
            .with_no_client_auth(),
    );
    *guard = Some(c.clone());
    c
}

struct Url {
    https: bool,
    host: String,
    port: u16,
    path: String,
}

fn parse_url(url: &str) -> Result<Url, String> {
    let (https, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        return Err("the address must start with https:// or http://".to_string());
    };
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !h.contains(']') => (h.to_string(), p.parse().unwrap_or(if https { 443 } else { 80 })),
        _ => (hostport.to_string(), if https { 443 } else { 80 }),
    };
    if host.is_empty() {
        return Err("the address has no host".to_string());
    }
    Ok(Url { https, host, port, path: path.to_string() })
}

/// `(status, json)` of a request with `X-API-Key: token`.
pub fn request(method: &str, url: &str, token: &str, body: Option<&Value>) -> Result<(u16, Value), String> {
    let u = parse_url(url)?;
    let addr = (u.host.as_str(), u.port).to_socket_addrs().map_err(|e| format!("{}: {e}", u.host))?.next().ok_or_else(|| format!("{}: no address", u.host))?;
    let mut tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| format!("{}: {e}", u.host))?;
    let _ = tcp.set_read_timeout(Some(TIMEOUT));
    let _ = tcp.set_write_timeout(Some(TIMEOUT));
    let payload = body.map(|b| b.to_string()).unwrap_or_default();
    let mut req = format!("{method} {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: mewo-on-fire\r\nAccept: application/json\r\nConnection: close\r\n", u.path, u.host);
    if !token.is_empty() {
        if token.starts_with("Bearer ") {
            req.push_str(&format!("Authorization: {token}\r\n"));
        } else {
            req.push_str(&format!("X-API-Key: {token}\r\n"));
        }
    }
    if body.is_some() {
        req.push_str(&format!("Content-Type: application/json\r\nContent-Length: {}\r\n", payload.len()));
    }
    req.push_str("\r\n");
    req.push_str(&payload);
    let mut raw = Vec::new();
    if u.https {
        let name = rustls::pki_types::ServerName::try_from(u.host.clone()).map_err(|_| "bad host name".to_string())?;
        let mut conn = rustls::ClientConnection::new(tls_config(), name).map_err(|e| e.to_string())?;
        let mut tls = rustls::Stream::new(&mut conn, &mut tcp);
        tls.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
        let _ = tls.read_to_end(&mut raw);
    } else {
        tcp.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
        let _ = tcp.read_to_end(&mut raw);
    }
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or_else(|| "no HTTP response".to_string())?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let mut body_bytes = raw[split + 4..].to_vec();
    let status: u16 = head.lines().next().and_then(|l| l.split_whitespace().nth(1)).and_then(|s| s.parse().ok()).unwrap_or(0);
    let chunked = head.lines().any(|l| l.to_ascii_lowercase().starts_with("transfer-encoding:") && l.to_ascii_lowercase().contains("chunked"));
    if chunked {
        body_bytes = dechunk(&body_bytes);
    }
    let text = String::from_utf8_lossy(&body_bytes).to_string();
    let v = if text.trim().is_empty() { Value::Null } else { serde_json::from_str(&text).unwrap_or_else(|_| json!({"raw": text.chars().take(300).collect::<String>()})) };
    Ok((status, v))
}

fn dechunk(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let Some(nl) = b[i..].windows(2).position(|w| w == b"\r\n") else { break };
        let size_line = String::from_utf8_lossy(&b[i..i + nl]).to_string();
        let size = usize::from_str_radix(size_line.split(';').next().unwrap_or("0").trim(), 16).unwrap_or(0);
        i += nl + 2;
        if size == 0 {
            break;
        }
        out.extend_from_slice(&b[i..(i + size).min(b.len())]);
        i += size + 2;
    }
    out
}

fn err_of(status: u16, v: &Value) -> String {
    let detail = v.get("detail").or_else(|| v.get("error")).or_else(|| v.get("raw")).and_then(Value::as_str).unwrap_or("");
    match status {
        401 | 403 => format!("Plane refused the token ({status}){}", if detail.is_empty() { String::new() } else { format!(": {detail}") }),
        404 => format!("Plane has no such workspace, project or item (404){}", if detail.is_empty() { String::new() } else { format!(": {detail}") }),
        429 => "Plane's rate limit (60 requests a minute); try again shortly".to_string(),
        _ => format!("Plane answered {status}{}", if detail.is_empty() { String::new() } else { format!(": {detail}") }),
    }
}

// ---------------------------------------------------------------------------
// the API
// ---------------------------------------------------------------------------

fn api(c: &PlaneConfig, path: &str) -> String {
    format!("{}/api/v1{}", c.base_url.trim_end_matches('/'), path)
}

/// `/users/me/` with a token: `{id, display_name, email}`.
pub fn me(base_url: &str, token: &str) -> Result<Value, String> {
    let c = PlaneConfig { base_url: base_url.to_string(), ..PlaneConfig::default() };
    let (st, v) = request("GET", &api(&c, "/users/me/"), token, None)?;
    if st != 200 {
        return Err(err_of(st, &v));
    }
    Ok(json!({
        "id": v.get("id").and_then(Value::as_str).unwrap_or(""),
        "display": display_of(&v),
        "email": v.get("email").and_then(Value::as_str).unwrap_or(""),
    }))
}

fn display_of(m: &Value) -> String {
    let s = |k: &str| m.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
    let full = format!("{} {}", s("first_name"), s("last_name")).trim().to_string();
    if !s("display_name").is_empty() {
        s("display_name")
    } else if !full.is_empty() {
        full
    } else {
        s("email")
    }
}

/// Every page of a list endpoint (`results` + `next_cursor`), or a bare array.
fn list_all(c: &PlaneConfig, path: &str) -> Result<Vec<Value>, String> {
    let mut out = Vec::new();
    let mut cursor = String::new();
    for _ in 0..20 {
        let sep = if path.contains('?') { '&' } else { '?' };
        let url = api(c, &format!("{path}{sep}per_page=100{}", if cursor.is_empty() { String::new() } else { format!("&cursor={cursor}") }));
        let (st, v) = request("GET", &url, &c.token, None)?;
        if st != 200 {
            return Err(err_of(st, &v));
        }
        match &v {
            Value::Array(a) => {
                out.extend(a.iter().cloned());
                break;
            }
            Value::Object(_) => {
                if let Some(a) = v.get("results").and_then(Value::as_array) {
                    out.extend(a.iter().cloned());
                }
                let more = v.get("next_page_results").and_then(Value::as_bool).unwrap_or(false);
                let next = v.get("next_cursor").and_then(Value::as_str).unwrap_or("").to_string();
                if !more || next.is_empty() {
                    break;
                }
                cursor = next;
            }
            _ => break,
        }
    }
    Ok(out)
}

/// The workspace's members: `[{id, display, email}]`.
pub fn members(c: &PlaneConfig) -> Result<Vec<Value>, String> {
    let list = list_all(c, &format!("/workspaces/{}/members/", c.workspace))?;
    Ok(list
        .iter()
        .map(|e| {
            let m = e.get("member").filter(|m| m.is_object()).unwrap_or(e);
            json!({"id": m.get("id").and_then(Value::as_str).unwrap_or(""), "display": display_of(m), "email": m.get("email").and_then(Value::as_str).unwrap_or("")})
        })
        .filter(|m| !m.get("id").and_then(Value::as_str).unwrap_or("").is_empty())
        .collect())
}

pub fn projects(c: &PlaneConfig) -> Result<Vec<Value>, String> {
    let list = list_all(c, &format!("/workspaces/{}/projects/", c.workspace))?;
    Ok(list.iter().map(|p| json!({"id": p.get("id").and_then(Value::as_str).unwrap_or(""), "name": p.get("name").and_then(Value::as_str).unwrap_or(""), "identifier": p.get("identifier").and_then(Value::as_str).unwrap_or("")})).collect())
}

/// The project's states, into the config. A project without any (one
/// made by API, say) gets the five standard ones first.
pub fn load_states(c: &mut PlaneConfig) -> Result<(), String> {
    let path = format!("/workspaces/{}/projects/{}/states/", c.workspace, c.project_id);
    let mut list = list_all(c, &path)?;
    if list.is_empty() {
        for (name, group, color) in [("Backlog", "backlog", "#60646C"), ("Todo", "unstarted", "#3B82F6"), ("In Progress", "started", "#F59E0B"), ("Done", "completed", "#46A758"), ("Cancelled", "cancelled", "#9AA4BC")] {
            let (st, v) = request("POST", &api(c, &path), &c.token, Some(&json!({"name": name, "group": group, "color": color})))?;
            if st != 200 && st != 201 {
                return Err(format!("The project has no states and one could not be made: {}", err_of(st, &v)));
            }
            list.push(v);
        }
    }
    let mut states: HashMap<String, String> = HashMap::new();
    let mut all = Vec::new();
    for s in &list {
        let group = s.get("group").and_then(Value::as_str).unwrap_or("").to_string();
        let id = s.get("id").and_then(Value::as_str).unwrap_or("").to_string();
        let name = s.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        if group.is_empty() || id.is_empty() {
            continue;
        }
        all.push(json!({"id": id, "name": name, "group": group}));
        // The group's plain state (Todo, In Progress, Done) stands for it;
        // the first one seen otherwise.
        let plain = matches!(name.to_ascii_lowercase().as_str(), "backlog" | "todo" | "to do" | "in progress" | "doing" | "done" | "completed" | "cancelled" | "canceled");
        if plain || !states.contains_key(&group) {
            states.insert(group, id);
        }
    }
    if states.is_empty() {
        return Err("The project has no states".to_string());
    }
    c.states = states;
    c.all_states = all;
    Ok(())
}

/// The feature's own item follows its step: PRD, Build, Staging, UAT by
/// name when the board has them, Done when released.
fn parent_state(c: &PlaneConfig, f: &Feature) -> String {
    if f.released {
        return c.states.get("completed").cloned().unwrap_or_default();
    }
    let hint = match f.step {
        1..=3 => "prd",
        4..=9 => "build",
        10 => "staging",
        11 => "uat",
        _ => "",
    };
    if !hint.is_empty() {
        if let Some(s) = c.all_states.iter().find(|s| s.get("name").and_then(Value::as_str).map(|n| n.eq_ignore_ascii_case(hint)).unwrap_or(false)) {
            if let Some(id) = s.get("id").and_then(Value::as_str) {
                return id.to_string();
            }
        }
    }
    c.states.get("started").or_else(|| c.states.get("unstarted")).cloned().unwrap_or_default()
}

/// The state for an item: one named after its step when the board has
/// it (PRD, Build, Staging, UAT…), else the group's plain state.
fn state_for(c: &PlaneConfig, item_key: &str, group: &str) -> String {
    let hint: Option<&str> = match (item_key, group) {
        (_, "completed") | (_, "backlog") | (_, "unstarted") => None,
        ("prd", _) | ("estimates", _) => Some("prd"),
        (k, _) if k.starts_with("session:") => Some("build"),
        ("gate:staging", _) => Some("staging"),
        ("gate:uat", _) => Some("uat"),
        _ => None,
    };
    if let Some(h) = hint {
        if let Some(s) = c.all_states.iter().find(|s| s.get("name").and_then(Value::as_str).map(|n| n.eq_ignore_ascii_case(h)).unwrap_or(false)) {
            if let Some(id) = s.get("id").and_then(Value::as_str) {
                return id.to_string();
            }
        }
    }
    c.states.get(group).cloned().unwrap_or_default()
}

fn items_path(c: &PlaneConfig) -> String {
    if c.items_path.is_empty() { "work-items".to_string() } else { c.items_path.clone() }
}

fn with_items_fallback<T>(c: &mut PlaneConfig, mut f: impl FnMut(&PlaneConfig) -> Result<(u16, T), String>) -> Result<T, String> {
    if c.items_path.is_empty() {
        c.items_path = "work-items".to_string();
        match f(c) {
            Ok((404, _)) => {
                c.items_path = "issues".to_string();
                let (st, v) = f(c)?;
                if st == 404 {
                    return Err("Plane has no work-items nor issues endpoint for this project".to_string());
                }
                Ok(v)
            }
            Ok((_, v)) => Ok(v),
            Err(e) => Err(e),
        }
    } else {
        f(c).map(|(_, v)| v)
    }
}

/// Every work item of the project: `{id, name, state, assignees, parent, sequence_id}`.
pub fn items(c: &mut PlaneConfig) -> Result<Vec<Value>, String> {
    let list = with_items_fallback(c, |c| {
        let path = format!("/workspaces/{}/projects/{}/{}/", c.workspace, c.project_id, items_path(c));
        match list_all(c, &path) {
            Ok(l) => Ok((200, l)),
            Err(e) if e.contains("404") => Ok((404, Vec::new())),
            Err(e) => Err(e),
        }
    })?;
    Ok(list
        .iter()
        .map(|i| {
            json!({
                "id": i.get("id").and_then(Value::as_str).unwrap_or(""),
                "name": i.get("name").and_then(Value::as_str).unwrap_or(""),
                "state": i.get("state").and_then(Value::as_str).unwrap_or(""),
                "assignees": i.get("assignees").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect::<Vec<_>>()).unwrap_or_default(),
                "parent": i.get("parent").and_then(Value::as_str).unwrap_or(""),
                "sequence_id": i.get("sequence_id").and_then(Value::as_u64).unwrap_or(0),
            })
        })
        .collect())
}

pub fn create_item(c: &mut PlaneConfig, body: Value) -> Result<Value, String> {
    with_items_fallback(c, |c| {
        let url = api(c, &format!("/workspaces/{}/projects/{}/{}/", c.workspace, c.project_id, items_path(c)));
        let (st, v) = request("POST", &url, &c.token, Some(&body))?;
        if st == 404 {
            return Ok((404, Value::Null));
        }
        if st != 200 && st != 201 {
            return Err(err_of(st, &v));
        }
        Ok((st, v))
    })
}

pub fn update_item(c: &PlaneConfig, id: &str, body: Value) -> Result<Value, String> {
    let url = api(c, &format!("/workspaces/{}/projects/{}/{}/{id}/", c.workspace, c.project_id, items_path(c)));
    let (st, v) = request("PATCH", &url, &c.token, Some(&body))?;
    if st != 200 {
        return Err(err_of(st, &v));
    }
    Ok(v)
}

pub fn comment(c: &PlaneConfig, id: &str, text: &str) -> Result<(), String> {
    let url = api(c, &format!("/workspaces/{}/projects/{}/{}/{id}/comments/", c.workspace, c.project_id, items_path(c)));
    let html = format!("<p>{}</p>", html_escape(text));
    let (st, v) = request("POST", &url, &c.token, Some(&json!({"comment_html": html})))?;
    if st != 200 && st != 201 {
        return Err(err_of(st, &v));
    }
    Ok(())
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

// ---------------------------------------------------------------------------
// the map: which item is which
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct MappedItem {
    pub id: String,
    pub name: String,
    /// The state group we last saw or set.
    pub group: String,
    pub assignees: Vec<String>,
    pub sequence_id: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct FeatureMap {
    pub parent: String,
    pub items: HashMap<String, MappedItem>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Map {
    pub features: HashMap<String, FeatureMap>,
    pub last_sync: u64,
    pub last_error: String,
    pub synced_items: usize,
}

fn map_file() -> PathBuf {
    paths::state_dir().join("plane-map.json")
}

pub fn load_map() -> Map {
    fs::read_to_string(map_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn save_map(m: &Map) {
    let _ = fs::create_dir_all(paths::state_dir());
    let _ = fs::write(map_file(), serde_json::to_string_pretty(m).unwrap_or_default());
}

fn map_key(ws: &Path, key: &str) -> String {
    format!("{}|{key}", ws.display())
}

/// The Plane side of a feature, for the console and the phones:
/// `{item_key: {id, url, group, assignees, sequence_id}}`.
pub fn feature_items(c: &PlaneConfig, ws: &Path, key: &str) -> Value {
    let m = load_map();
    let Some(fm) = m.features.get(&map_key(ws, key)) else { return Value::Null };
    let mut out = serde_json::Map::new();
    for (k, it) in &fm.items {
        out.insert(k.clone(), json!({"id": it.id, "url": c.item_url(&it.id), "group": it.group, "assignees": it.assignees, "sequence_id": it.sequence_id}));
    }
    json!({"parent": fm.parent, "parent_url": if fm.parent.is_empty() { String::new() } else { c.item_url(&fm.parent) }, "items": out})
}

// Comments to post, flushed by the sync loop so no action waits on Plane.
static PENDING: Mutex<Vec<(String, String, String)>> = Mutex::new(Vec::new());

/// Queues a comment on a feature's item (`item_key`: `gate:staging`,
/// `session:2`, `prd`, `estimates`, or `` for the feature itself).
pub fn note(ws: &Path, key: &str, item_key: &str, text: &str) {
    PENDING.lock().unwrap_or_else(|p| p.into_inner()).push((map_key(ws, key), item_key.to_string(), text.to_string()));
}

// ---------------------------------------------------------------------------
// the sync
// ---------------------------------------------------------------------------

/// What a feature should look like on the board: `(item_key, name,
/// description, group, role or owner)`.
fn desired(ws: &Path, f: &Feature, st: &flow::FlowState) -> Vec<(String, String, String, String, String)> {
    let mut out = Vec::new();
    let asked = |gate: &str| st.asked.keys().any(|k| k.starts_with(&format!("{gate}|")));
    for g in &f.gates {
        let group = if g.signed {
            "completed"
        } else if g.step == f.step && asked(&g.id) {
            "started"
        } else if g.step == f.step {
            "unstarted"
        } else {
            "backlog"
        };
        let role = g.roles.first().cloned().unwrap_or_default();
        let name = format!("Sign-off: {}{}", g.title, if g.checklist.is_empty() { String::new() } else { format!(" (Checklist {})", g.checklist) });
        out.push((format!("gate:{}", g.id), name, format!("{} / {} · {} · signed from the phone, recorded in {}", f.app, f.slug, g.title, g.file), group.to_string(), role));
    }
    if !f.light {
        let prd_group = if f.prd_signed { "completed" } else if f.step == 3 && asked("prd") { "started" } else if f.step == 3 { "unstarted" } else { "backlog" };
        out.push(("prd".to_string(), "Sign-off: PRD V1.0 (Checklist A)".to_string(), format!("{} / {} · the CEO signs the PRD from the phone", f.app, f.slug), prd_group.to_string(), "CEO".to_string()));
        let est_group = if st.estimates_done { "completed" } else if f.step == 2 { "started" } else { "backlog" };
        out.push(("estimates".to_string(), "Estimates (policy step 2)".to_string(), format!("{} / {} · design, FE and BE leads give person-days from the phone", f.app, f.slug), est_group.to_string(), "Product lead".to_string()));
    }
    if let Some(plan) = &f.plan {
        for s in &plan.sessions {
            let group = match s.effective.as_str() {
                "merged" => "completed",
                "progress" | "review" => "started",
                "ready" => "unstarted",
                _ => "backlog",
            };
            let mut desc = format!("{} / {} · {} · Tier {} · {}", f.app, f.slug, s.level, s.tier, s.repo);
            if !s.pr_url.is_empty() {
                desc.push_str(&format!(" · PR {}", s.pr_url));
            }
            out.push((format!("session:{}", s.n), format!("S{}: {}", s.n, s.goal), desc, group.to_string(), s.owner.clone()));
        }
    }
    let _ = ws;
    out
}

fn rank(group: &str) -> u8 {
    match group {
        "backlog" => 0,
        "unstarted" => 1,
        "started" => 2,
        "completed" => 3,
        _ => 0,
    }
}

/// The Plane user for a role or a person's name, through `context/roles.md`
/// (its Plane column) and the people who signed in.
fn plane_user_for(c: &PlaneConfig, ws: &Path, who: &str) -> Option<String> {
    if who.trim().is_empty() {
        return None;
    }
    let roles = flow::roles(ws);
    let by_role = roles.iter().find(|r| r.role.eq_ignore_ascii_case(who));
    let by_name = roles.iter().find(|r| !r.name.is_empty() && (r.name.eq_ignore_ascii_case(who) || who.to_ascii_lowercase().starts_with(&r.name.to_ascii_lowercase())));
    let r = by_role.or(by_name)?;
    if !r.plane.is_empty() {
        return Some(r.plane.clone());
    }
    c.people.iter().find(|p| p.display.eq_ignore_ascii_case(&r.name) || p.email.eq_ignore_ascii_case(&r.name)).map(|p| p.plane_id.clone())
}

/// One pass: items created, states and assignees pushed or taken, comments posted.
pub fn sync_once(features: Vec<(PathBuf, Feature)>) -> Result<usize, String> {
    let mut c = load();
    if !c.configured() {
        return Ok(0);
    }
    if c.states.is_empty() {
        load_states(&mut c)?;
        let _ = save(&c);
    }
    let existing = items(&mut c)?;
    let _ = save(&c);
    let by_id: HashMap<String, &Value> = existing.iter().map(|i| (i.get("id").and_then(Value::as_str).unwrap_or("").to_string(), i)).collect();
    let states = c.states.clone();
    let group_of = move |state_id: &str| -> String { states.iter().find(|(_, id)| id.as_str() == state_id).map(|(g, _)| g.clone()).unwrap_or_default() };
    let mut map = load_map();
    let mut touched = 0usize;
    let started = Instant::now();
    for (ws, f) in &features {
        if started.elapsed() > Duration::from_secs(40) {
            break;
        }
        let st = flow::get(ws, &f.key);
        let mk = map_key(ws, &f.key);
        let fm = map.features.entry(mk.clone()).or_default();
        // The feature itself, in the column of its step.
        let parent_state_id = parent_state(&c, f);
        if fm.parent.is_empty() || !by_id.contains_key(&fm.parent) {
            let name = format!("{} / {}", policy::app_display(ws, &f.app), f.slug);
            let desc = format!("<p>{} · branch {} · records in {}</p>", html_escape(&name), html_escape(&f.branch), html_escape(&f.dir));
            let body = json!({"name": name, "description_html": desc, "state": parent_state_id});
            let v = create_item(&mut c, body)?;
            fm.parent = v.get("id").and_then(Value::as_str).unwrap_or("").to_string();
            touched += 1;
        } else if let Some(live) = by_id.get(&fm.parent) {
            let live_state = live.get("state").and_then(Value::as_str).unwrap_or("");
            if live_state != parent_state_id && group_of(live_state) != "cancelled" && !parent_state_id.is_empty() {
                update_item(&c, &fm.parent, json!({"state": parent_state_id}))?;
                touched += 1;
            }
        }
        for (item_key, name, desc, group, who) in desired(ws, f, &st) {
            let state_id = state_for(&c, &item_key, &group);
            let assignee = plane_user_for(&c, ws, &who);
            match fm.items.get_mut(&item_key) {
                Some(it) if by_id.contains_key(&it.id) => {
                    let live = by_id[&it.id];
                    let live_group = group_of(live.get("state").and_then(Value::as_str).unwrap_or(""));
                    let live_assignees: Vec<String> = live.get("assignees").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
                    it.sequence_id = live.get("sequence_id").and_then(Value::as_u64).unwrap_or(it.sequence_id);
                    let mut patch = serde_json::Map::new();
                    // States only move forward from here; Plane's own moves stay.
                    if rank(&group) > rank(&live_group) && !state_id.is_empty() {
                        patch.insert("state".to_string(), json!(state_id));
                        it.group = group.clone();
                    } else {
                        it.group = live_group.clone();
                    }
                    // Assignees: Plane's choice wins once someone changed it there.
                    if live_assignees != it.assignees && !live_assignees.is_empty() {
                        it.assignees = live_assignees.clone();
                    } else if let Some(a) = &assignee {
                        if live_assignees.is_empty() {
                            patch.insert("assignees".to_string(), json!([a]));
                            it.assignees = vec![a.clone()];
                        }
                    }
                    if !patch.is_empty() {
                        update_item(&c, &it.id, Value::Object(patch))?;
                        touched += 1;
                    }
                }
                _ => {
                    let mut body = json!({"name": name, "description_html": format!("<p>{}</p>", html_escape(&desc)), "state": state_id, "parent": fm.parent});
                    if let Some(a) = &assignee {
                        body["assignees"] = json!([a]);
                    }
                    let v = create_item(&mut c, body)?;
                    let id = v.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                    if !id.is_empty() {
                        fm.items.insert(item_key.clone(), MappedItem { id, name: name.clone(), group: group.clone(), assignees: assignee.into_iter().collect(), sequence_id: v.get("sequence_id").and_then(Value::as_u64).unwrap_or(0) });
                        touched += 1;
                    }
                }
            }
        }
    }
    // Comments.
    let pending: Vec<(String, String, String)> = std::mem::take(&mut *PENDING.lock().unwrap_or_else(|p| p.into_inner()));
    for (mk, item_key, text) in pending {
        let Some(fm) = map.features.get(&mk) else { continue };
        let id = if item_key.is_empty() { fm.parent.clone() } else { fm.items.get(&item_key).map(|i| i.id.clone()).unwrap_or_default() };
        if !id.is_empty() {
            let _ = comment(&c, &id, &text);
        }
    }
    map.last_sync = now_ms();
    map.last_error.clear();
    map.synced_items = map.features.values().map(|f| f.items.len()).sum();
    save_map(&map);
    Ok(touched)
}

pub fn record_error(e: &str) {
    let mut m = load_map();
    m.last_error = e.to_string();
    save_map(&m);
}

/// Status for the console: the connection (no token), the map, the people.
pub fn status() -> Value {
    let c = load();
    let m = load_map();
    json!({
        "ok": true,
        "config": c.public(),
        "last_sync": m.last_sync,
        "last_error": m.last_error,
        "items": m.synced_items,
        "features": m.features.len(),
    })
}

/// The items assigned to a Plane user that are not done, across features.
pub fn mine(plane_id: &str) -> Vec<Value> {
    let c = load();
    let m = load_map();
    let mut out = Vec::new();
    for (mk, fm) in &m.features {
        let key = mk.split('|').nth(1).unwrap_or("").to_string();
        for (item_key, it) in &fm.items {
            if it.group != "completed" && it.assignees.iter().any(|a| a == plane_id) {
                out.push(json!({"feature": key, "item": item_key, "name": it.name, "group": it.group, "url": c.item_url(&it.id), "id": it.id}));
            }
        }
    }
    out.sort_by(|a, b| a.get("feature").and_then(Value::as_str).cmp(&b.get("feature").and_then(Value::as_str)));
    out
}

/// A task under a plan session's item, created from a phone.
pub fn add_task(ws: &Path, key: &str, n: u32, name: &str, assignee: &str) -> Result<Value, String> {
    let mut c = load();
    if !c.configured() {
        return Err("Plane is not connected (console → PLANE)".to_string());
    }
    let map = load_map();
    let parent = map.features.get(&map_key(ws, key)).and_then(|fm| fm.items.get(&format!("session:{n}"))).map(|i| i.id.clone()).unwrap_or_default();
    if parent.is_empty() {
        return Err("This session has no Plane item yet; the next sync makes it".to_string());
    }
    let mut body = json!({"name": name.trim(), "parent": parent, "state": c.states.get("unstarted").cloned().unwrap_or_default()});
    if !assignee.is_empty() {
        body["assignees"] = json!([assignee]);
    }
    let v = create_item(&mut c, body)?;
    let id = v.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    Ok(json!({"ok": true, "id": id, "url": c.item_url(&id), "name": name.trim()}))
}

/// The tasks under a plan session's item: `{id, name, done, assignees, url}`.
pub fn tasks(ws: &Path, key: &str, n: u32) -> Result<Vec<Value>, String> {
    let mut c = load();
    if !c.configured() {
        return Ok(Vec::new());
    }
    let map = load_map();
    let parent = map.features.get(&map_key(ws, key)).and_then(|fm| fm.items.get(&format!("session:{n}"))).map(|i| i.id.clone()).unwrap_or_default();
    if parent.is_empty() {
        return Ok(Vec::new());
    }
    let all = items(&mut c)?;
    let states = c.states.clone();
    let group_of = move |state_id: &str| -> String { states.iter().find(|(_, id)| id.as_str() == state_id).map(|(g, _)| g.clone()).unwrap_or_default() };
    Ok(all
        .iter()
        .filter(|i| i.get("parent").and_then(Value::as_str) == Some(parent.as_str()))
        .map(|i| {
            let id = i.get("id").and_then(Value::as_str).unwrap_or("");
            json!({"id": id, "name": i.get("name").and_then(Value::as_str).unwrap_or(""), "done": group_of(i.get("state").and_then(Value::as_str).unwrap_or("")) == "completed", "assignees": i.get("assignees").cloned().unwrap_or(json!([])), "url": c.item_url(id), "sequence_id": i.get("sequence_id").and_then(Value::as_u64).unwrap_or(0)})
        })
        .collect())
}

pub fn set_task_done(id: &str, done: bool) -> Result<(), String> {
    let c = load();
    let state = c.states.get(if done { "completed" } else { "unstarted" }).cloned().unwrap_or_default();
    if state.is_empty() {
        return Err("The project's states are not known yet".to_string());
    }
    update_item(&c, id, json!({"state": state})).map(|_| ())
}

/// Someone signed in from a phone: their Plane user, remembered with the phone.
pub fn signin(token: &str, phone: &str) -> Result<Value, String> {
    let mut c = load();
    if c.base_url.is_empty() {
        return Err("Plane is not connected yet (console → PLANE)".to_string());
    }
    let who = me(&c.base_url, token.trim())?;
    let plane_id = who.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    if plane_id.is_empty() {
        return Err("Plane did not say who the token belongs to".to_string());
    }
    c.people.retain(|p| p.plane_id != plane_id && p.phone != phone);
    c.people.push(Person { plane_id: plane_id.clone(), display: who.get("display").and_then(Value::as_str).unwrap_or("").to_string(), email: who.get("email").and_then(Value::as_str).unwrap_or("").to_string(), phone: phone.to_string(), since: now_ms() });
    save(&c)?;
    Ok(who)
}

pub fn person_for_phone(phone: &str) -> Option<Person> {
    load().people.into_iter().find(|p| p.phone == phone)
}

/// The phone of the Plane user, if they signed in.
pub fn phone_for_plane(plane_id: &str) -> Option<String> {
    load().people.into_iter().find(|p| p.plane_id == plane_id).map(|p| p.phone)
}

pub const SYNC_INTERVAL: Duration = SYNC_EVERY;

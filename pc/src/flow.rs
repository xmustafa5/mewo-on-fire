//! The flow runner (v1.8): drives a feature through the policy's twelve
//! steps. Claude's work runs as Claude Desktop sessions that Mewo starts
//! with the right prompt and skill; people's decisions come back as
//! signatures from their phones. Per feature, `<state>/flow.json` keeps
//! the autopilot switch, what was started or asked and when, the
//! estimates, and a short log.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::artifacts;
use crate::config::now_ms;
use crate::paths;
use crate::policy::{self, Feature};
use crate::sessions::Session;

/// The roles the policy names, in the order the phone lists them.
pub const ROLES: [&str; 6] = ["CEO", "Product lead", "Design lead", "Tech lead", "FE lead", "BE lead"];
/// Who gives an estimate (policy Checklist B).
pub const ESTIMATE_ROLES: [&str; 3] = ["Design lead", "FE lead", "BE lead"];

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Run {
    pub step: u8,
    pub started: u64,
    /// What the step produced when it started, to see it change.
    pub note: String,
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Estimate {
    pub role: String,
    pub name: String,
    pub days: f64,
    pub assumptions: String,
    pub ts: u64,
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct FlowState {
    pub autopilot: bool,
    pub runs: Vec<Run>,
    /// `gate|role` → when it was asked for.
    pub asked: HashMap<String, u64>,
    pub estimates: Vec<Estimate>,
    pub estimates_done: bool,
    pub log: Vec<Value>,
    pub released_at: u64,
    pub closed_at: u64,
}

impl FlowState {
    pub fn last_run(&self, step: u8) -> Option<&Run> {
        self.runs.iter().rev().find(|r| r.step == step)
    }

    pub fn note(&mut self, text: impl Into<String>) {
        self.log.push(json!({"ts": now_ms(), "text": text.into()}));
        while self.log.len() > 40 {
            self.log.remove(0);
        }
    }
}

fn file() -> PathBuf {
    paths::state_dir().join("flow.json")
}

fn load_all() -> HashMap<String, FlowState> {
    fs::read_to_string(file())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_all(map: &HashMap<String, FlowState>) {
    let _ = fs::create_dir_all(paths::state_dir());
    let _ = fs::write(file(), serde_json::to_string_pretty(map).unwrap_or_default());
}

fn flow_key(ws: &Path, key: &str) -> String {
    format!("{}|{key}", ws.display())
}

pub fn get(ws: &Path, key: &str) -> FlowState {
    load_all().remove(&flow_key(ws, key)).unwrap_or_default()
}

pub fn update(ws: &Path, key: &str, f: impl FnOnce(&mut FlowState)) -> FlowState {
    let mut all = load_all();
    let entry = all.entry(flow_key(ws, key)).or_default();
    f(entry);
    let out = entry.clone();
    save_all(&all);
    out
}

// ---------------------------------------------------------------------------
// roles: context/roles.md
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone, Default, Debug)]
pub struct Role {
    pub role: String,
    pub name: String,
    pub phone: String,
}

fn roles_file(ws: &Path) -> PathBuf {
    ws.join("context").join("roles.md")
}

/// `| Role | Name | Phone |` rows of `context/roles.md`.
pub fn roles(ws: &Path) -> Vec<Role> {
    let Ok(text) = fs::read_to_string(roles_file(ws)) else { return Vec::new() };
    let mut out = Vec::new();
    for l in text.lines() {
        let t = l.trim();
        if !t.starts_with('|') || t.contains("---") {
            continue;
        }
        let c: Vec<String> = t.trim_matches('|').split('|').map(|x| x.trim().to_string()).collect();
        if c.len() < 2 || c[0].eq_ignore_ascii_case("role") {
            continue;
        }
        out.push(Role { role: c[0].clone(), name: c[1].clone(), phone: c.get(2).cloned().unwrap_or_default() });
    }
    out
}

pub fn role_named(ws: &Path, role: &str) -> Option<Role> {
    roles(ws).into_iter().find(|r| r.role.eq_ignore_ascii_case(role))
}

/// Writes or replaces a role's row. An empty name removes the row.
pub fn set_role(ws: &Path, role: &str, name: &str, phone: &str) -> Result<Vec<Role>, String> {
    let role = ROLES.iter().find(|r| r.eq_ignore_ascii_case(role)).ok_or_else(|| format!("Unknown role {role}. The policy's roles: {}", ROLES.join(", ")))?;
    let mut list = roles(ws);
    list.retain(|r| !r.role.eq_ignore_ascii_case(role));
    if !name.trim().is_empty() {
        list.push(Role { role: role.to_string(), name: name.trim().to_string(), phone: phone.trim().to_string() });
    }
    list.sort_by_key(|r| ROLES.iter().position(|x| x.eq_ignore_ascii_case(&r.role)).unwrap_or(99));
    let mut out = String::from("# Roles\n\nWho holds each role of the TORCH Agentic Development Policy, and the phone (Mewo on Fire) that reaches them. Written from the phones; edit by hand if you like.\n\n| Role | Name | Phone |\n|---|---|---|\n");
    for r in &list {
        out.push_str(&format!("| {} | {} | {} |\n", r.role, r.name, r.phone));
    }
    let path = roles_file(ws);
    let _ = fs::create_dir_all(path.parent().unwrap_or(ws));
    fs::write(&path, out).map_err(|e| e.to_string())?;
    Ok(list)
}

// ---------------------------------------------------------------------------
// the next action
// ---------------------------------------------------------------------------

/// What the flow does next for a feature. `kind`: `run` (a Claude session),
/// `ask` (signatures), `estimates`, `export` (designs to the handoff
/// folder), `start` (a planned session), `release`, `close`, `wait`, `done`.
#[derive(Serialize, Clone, Default, Debug)]
pub struct Action {
    pub kind: String,
    pub step: u8,
    pub title: String,
    pub detail: String,
    pub gate: String,
    pub roles: Vec<String>,
    pub session: u32,
    pub prompt: String,
    pub folder: String,
    /// Autopilot may do it by itself.
    pub auto: bool,
}

fn action(kind: &str, step: u8, title: impl Into<String>, detail: impl Into<String>) -> Action {
    Action { kind: kind.to_string(), step, title: title.into(), detail: detail.into(), auto: matches!(kind, "run" | "ask" | "export" | "start" | "release"), ..Action::default() }
}

/// The app's display name: the notebook's first heading.
pub fn app_name(ws: &Path, app: &str) -> String {
    policy::app_display(ws, app)
}

fn feature_words(slug: &str) -> String {
    slug.split('-')
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A session is working on this feature right now.
fn busy(f: &Feature, sessions: &[Session]) -> Option<String> {
    sessions
        .iter()
        .find(|s| s.feature == f.key && matches!(s.state.as_str(), "working" | "waiting"))
        .map(|s| s.short.clone())
}

/// A session of this feature that started after `since` has finished.
fn finished_since(f: &Feature, sessions: &[Session], since: u64) -> bool {
    sessions.iter().any(|s| s.feature == f.key && s.last_ts > since && matches!(s.state.as_str(), "idle" | "ended"))
}

/// The run of `step` is still fresh: started under 15 minutes ago, so its
/// session may not have reported yet.
fn fresh_run(flow: &FlowState, step: u8) -> bool {
    flow.last_run(step).map(|r| now_ms().saturating_sub(r.started) < 15 * 60 * 1000).unwrap_or(false)
}


fn design_artifacts(f: &Feature, sessions: &[Session]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for s in sessions.iter().filter(|s| s.feature == f.key) {
        for a in &s.artifacts {
            if a.kind == "design" && a.local && !a.id.is_empty() {
                out.push((a.id.clone(), a.title.clone()));
            }
        }
    }
    out
}

pub fn prompt_for(step: u8, ws: &Path, f: &Feature, flow: &FlowState) -> String {
    let app = app_name(ws, &f.app);
    let feature = feature_words(&f.slug);
    let dir = &f.dir;
    let prd_folder = format!("torch-product/Business OS/Business OS - apps/{app}/PRD/");
    match step {
        1 => format!(
            "We are starting the feature \"{feature}\" of the {app} app (notebook app-notebooks/{}/, branch {}). Use the prd-writer skill to draft its PRD. Read the root CLAUDE.md, the app's CLAUDE.md, the Apps Catalog and the app's existing PRDs in \"{prd_folder}\" first. Run grill-me: ask me your questions in rounds and do not fill gaps yourself. Save the result as {}_{}_PRD_V0.1.md in \"{prd_folder}\", status Draft, with the changelog, and report the readiness checklist (policy Checklist A) line by line.",
            f.app, f.branch, app.replace(' ', "_"), feature.replace(' ', "_")
        ),
        2 => {
            let rows: Vec<String> = flow.estimates.iter().map(|e| format!("| {} | {} | {} days | {} |", e.role, e.name, e.days, if e.assumptions.is_empty() { "-" } else { &e.assumptions })).collect();
            format!(
                "Use the prd-writer skill to make the next draft version of the PRD {} in \"{prd_folder}\" for the {app} app, feature \"{feature}\". The teams returned their estimates (policy step 2):\n\n| Team | By | Effort | Assumptions |\n|---|---|---|---|\n{}\n\nAdd them to Release Plan and Milestones as a table, add a changelog row saying so, keep everything else as it is, and save it as a new file with the next draft version number. Never overwrite the earlier file.",
                f.prd, rows.join("\n")
            )
        }
        4 => format!(
            "The PRD {} of the {app} app, feature \"{feature}\", is signed (\"{prd_folder}\"). Design every screen of its In-Scope items with Claude Design: start a Design artifact (one for the whole feature) and add one board per screen and per state the policy asks for: empty, loading, error, filled and permission-denied, following the Glare design system (the rules in context/rules/) and the app's design principles. Name each board after its flow and screen. Ask me when a decision is the product team's. When every In-Scope item has its boards, say that the design is ready for handoff.",
            f.prd
        ),
        7 => format!(
            "Use the handoff-intake skill on the handoff in {dir}/handoff/ for the {app} app, feature \"{feature}\", against the signed PRD {} in \"{prd_folder}\". Validate first and report the gaps, then clean, write the handoff README from context/templates/HANDOFF_README.md, add open questions to {dir}/OPEN_QUESTIONS.md, and fill in the intake section of {dir}/HANDOFF_CHECKLIST.md for the FE and BE leads to confirm.",
            f.prd
        ),
        8 => format!(
            "Use the session-plan skill for the {app} app, feature \"{feature}\": the signed PRD {} in \"{prd_folder}\", the handoff in {dir}/handoff/ with its README, {dir}/HANDOFF_CHECKLIST.md and {dir}/OPEN_QUESTIONS.md. Run grill-me first and ask me in rounds. Write {dir}/SESSION_PLAN.md from context/templates/SESSION_PLAN.md with the header, the order table and one section per session with its paste-ready prompt, done-when checks and dependencies. Branch: {}. Code repositories: {}.",
            f.prd, f.branch, if f.repos.is_empty() { "see context/scripts/app-repos.conf".to_string() } else { f.repos.join(", ") }
        ),
        _ => String::new(),
    }
}

/// Where the flow stands and what it does next.
pub fn next_action(ws: &Path, f: &Feature, flow: &FlowState, sessions: &[Session]) -> Action {
    let signed_roles = |gate: &str| -> Vec<String> {
        f.gates.iter().find(|g| g.id == gate).map(|g| g.signatures.iter().filter_map(|s| s.get("name").and_then(Value::as_str).map(str::to_string)).collect()).unwrap_or_default()
    };
    let open_roles = |gate: &str| -> Vec<String> {
        f.gates
            .iter()
            .find(|g| g.id == gate)
            .map(|g| g.roles.iter().filter(|r| !g.signatures.iter().any(|s| s.get("role").and_then(Value::as_str) == Some(r.as_str()))).cloned().collect())
            .unwrap_or_default()
    };
    let _ = signed_roles;
    if let Some(short) = busy(f, sessions) {
        let mut a = action("wait", f.step, "Claude is at work", format!("Session {short} is running for this feature. The flow waits for it."));
        a.auto = false;
        return a;
    }
    if f.light {
        let gate = f.gates.first();
        if f.released {
            return action("done", 12, "Released", "The light-path record is complete.");
        }
        let roles = gate.map(|g| g.roles.clone()).unwrap_or_default();
        let mut a = action("ask", f.step, "Light-path record", "The product lead and the tech lead sign Checklist L from the phone.");
        a.gate = "light".to_string();
        a.roles = roles;
        return a;
    }
    if f.released {
        if flow.released_at == 0 {
            return action("release", 12, "Record the release", "Mark the PRD Released and write the Register row.");
        }
        if flow.closed_at == 0 {
            let mut a = action("close", 12, "Merge and close the branches", format!("Merge {} into main in torch-main and every code repository it touches, then delete it.", f.branch));
            a.auto = false;
            return a;
        }
        return action("done", 12, "Released", "Everything is signed, recorded and merged.");
    }
    match f.step {
        1 | 2 | 3 => {
            if f.prd.is_empty() {
                if fresh_run(flow, 1) {
                    let mut a = action("wait", 1, "Drafting the PRD", "A session was started for the PRD draft. The file appears in the PRD folder when it is done.");
                    a.auto = false;
                    return a;
                }
                let mut a = action("run", 1, "Draft the PRD", "A Claude session runs the prd-writer skill with grill-me. Answer its questions from your phone.");
                a.prompt = prompt_for(1, ws, f, flow);
                a.folder = ws.to_string_lossy().into_owned();
                return a;
            }
            // Estimates (step 2) before the CEO's signature.
            if !flow.estimates_done {
                let missing: Vec<String> = ESTIMATE_ROLES.iter().filter(|r| !flow.estimates.iter().any(|e| e.role.eq_ignore_ascii_case(r))).map(|s| s.to_string()).collect();
                if !missing.is_empty() {
                    let mut a = action("estimates", 2, "Estimates", format!("Waiting for {} (person-days and assumptions, from the phone).", missing.join(", ")));
                    a.roles = missing;
                    a.auto = false;
                    return a;
                }
                if let Some(r) = flow.last_run(2) {
                    if r.note != f.prd {
                        // A new draft came out of the estimates run: step 2 is done.
                        let mut a = action("wait", 2, "Estimates recorded", "The PRD has a new draft with the estimates. Mark estimates done to move on.");
                        a.auto = false;
                        return a;
                    }
                    if fresh_run(flow, 2) {
                        let mut a = action("wait", 2, "Adding the estimates", "A session is adding the estimates to the PRD.");
                        a.auto = false;
                        return a;
                    }
                }
                let mut a = action("run", 2, "Put the estimates in the PRD", "A Claude session runs prd-writer to add the three estimates as a new draft version.");
                a.prompt = prompt_for(2, ws, f, flow);
                a.folder = ws.to_string_lossy().into_owned();
                return a;
            }
            let mut a = action("ask", 3, "PRD signature", format!("The CEO signs {} as V1.0 from the phone.", f.prd));
            a.gate = "prd".to_string();
            a.roles = vec!["CEO".to_string()];
            a
        }
        4 => {
            let designs = design_artifacts(f, sessions);
            if !designs.is_empty() {
                return action("export", 4, "Export the design to the handoff folder", format!("{} design artifact(s) from this feature's sessions become the handoff HTML, one file per board.", designs.len()));
            }
            if fresh_run(flow, 4) {
                let mut a = action("wait", 4, "Designing", "A design session was started. Its boards appear here as artifacts.");
                a.auto = false;
                return a;
            }
            let mut a = action("run", 4, "Design the screens", "A Claude session designs every In-Scope screen and state with Claude Design.");
            a.prompt = prompt_for(4, ws, f, flow);
            a.folder = ws.to_string_lossy().into_owned();
            a
        }
        5 => {
            let mut a = action("ask", 5, "Design proven", "The product lead confirms Checklist D part 1: scope covered, internal users completed the flows on the prototype, buildable within the estimate.");
            a.gate = "handoff1".to_string();
            a.roles = vec!["Product lead".to_string()];
            a
        }
        6 => {
            let mut a = action("ask", 6, "Handoff session", "The design, FE and BE leads sign Checklist D part 2 after the handoff session.");
            a.gate = "handoff2".to_string();
            a.roles = open_roles("handoff2");
            a
        }
        7 => {
            let ran = flow.last_run(7).map(|r| finished_since(f, sessions, r.started) || now_ms().saturating_sub(r.started) > 3 * 60 * 60 * 1000).unwrap_or(false);
            if ran {
                let mut a = action("ask", 7, "Intake confirmed", "The FE and BE leads tick Checklist E once the cleaned handoff is in place.");
                a.gate = "intake".to_string();
                a.roles = vec!["FE lead".to_string(), "BE lead".to_string()];
                return a;
            }
            if fresh_run(flow, 7) {
                let mut a = action("wait", 7, "Intake running", "A session runs the handoff-intake skill.");
                a.auto = false;
                return a;
            }
            let mut a = action("run", 7, "Validate and clean the handoff", "A Claude session runs the handoff-intake skill: coverage, states, tokens, then the cleaned files and README.");
            a.prompt = prompt_for(7, ws, f, flow);
            a.folder = ws.to_string_lossy().into_owned();
            a
        }
        8 => {
            let has_plan = f.plan.as_ref().map(|p| !p.sessions.is_empty()).unwrap_or(false);
            if has_plan {
                let mut a = action("ask", 8, "Plan review", "The tech lead reviews SESSION_PLAN.md and signs from the phone.");
                a.gate = "plan".to_string();
                a.roles = vec!["Tech lead".to_string()];
                return a;
            }
            if fresh_run(flow, 8) {
                let mut a = action("wait", 8, "Planning", "A session runs the session-plan skill with grill-me. Answer its questions from your phone.");
                a.auto = false;
                return a;
            }
            let mut a = action("run", 8, "Write the session plan", "A Claude session runs the session-plan skill with grill-me and writes SESSION_PLAN.md.");
            a.prompt = prompt_for(8, ws, f, flow);
            a.folder = ws.to_string_lossy().into_owned();
            a
        }
        9 => {
            let Some(plan) = &f.plan else { return action("wait", 9, "No plan", "") };
            if let Some(s) = plan.sessions.iter().find(|s| s.effective == "progress") {
                let mut a = action("wait", 9, format!("Session {} in progress", s.n), s.goal.clone());
                a.session = s.n;
                a.auto = false;
                return a;
            }
            if let Some(s) = plan.sessions.iter().find(|s| s.effective == "review") {
                let mut a = action("wait", 9, format!("Session {} in review", s.n), format!("Another developer reviews {}; the next session starts once it merges.", if s.pr_url.is_empty() { "the pull request".to_string() } else { s.pr_url.clone() }));
                a.session = s.n;
                a.auto = false;
                return a;
            }
            if let Some(s) = plan.sessions.iter().find(|s| s.effective == "ready") {
                if fresh_run(flow, 9) && flow.last_run(9).map(|r| r.note == s.n.to_string()).unwrap_or(false) {
                    let mut a = action("wait", 9, format!("Session {} starting", s.n), "Claude Desktop is starting it.");
                    a.auto = false;
                    return a;
                }
                let mut a = action("start", 9, format!("Start session {}", s.n), s.goal.clone());
                a.session = s.n;
                a.prompt = s.prompt.clone();
                a.folder = s.folder.clone();
                if s.prompt.is_empty() {
                    a.kind = "wait".to_string();
                    a.auto = false;
                    a.detail = "The plan has no prompt for it yet.".to_string();
                }
                return a;
            }
            if let Some(s) = plan.sessions.iter().find(|s| s.effective == "blocked" || s.effective == "waiting") {
                let mut a = action("wait", 9, format!("Session {} {}", s.n, if s.effective == "blocked" { "is blocked" } else { "waits" }), if s.note.is_empty() { "See OPEN_QUESTIONS.md".to_string() } else { s.note.clone() });
                a.auto = false;
                return a;
            }
            action("wait", 9, "Sessions", "")
        }
        10 => {
            let mut a = action("ask", 10, "Staging sign-off", "Deploy the feature branch to staging, then the product and design leads sign Checklist I from the phone.");
            a.gate = "staging".to_string();
            a.roles = open_roles("staging");
            a
        }
        11 => {
            let mut a = action("ask", 11, "UAT sign-off", "Record the 5 to 8 UAT users and their results from the phone; at 80 percent unaided the product and design leads sign Checklist J.");
            a.gate = "uat".to_string();
            a.roles = open_roles("uat");
            a
        }
        _ => {
            let mut a = action("ask", 12, "Production release", "The tech lead prepares Checklist K; the CEO signs from the phone.");
            a.gate = "production".to_string();
            a.roles = vec!["CEO".to_string()];
            a
        }
    }
}

// ---------------------------------------------------------------------------
// the records the flow writes itself
// ---------------------------------------------------------------------------

fn today() -> String {
    policy::today()
}

/// The feature's PRD file and its version (the plan's, the feature's own,
/// or the app's).
fn find_prd(ws: &Path, f: &Feature) -> Option<(PathBuf, u32, u32)> {
    let named = f.plan.as_ref().map(|p| p.prd.clone()).unwrap_or_default();
    policy::prd_file(ws, &f.app, &f.slug, &named).map(|(p, a, b, _)| (p, a, b))
}

fn set_header(lines: &mut [String], key: &str, value: &str) -> bool {
    for l in lines.iter_mut() {
        let t = l.trim();
        if t.starts_with('|') {
            let c: Vec<&str> = t.trim_matches('|').split('|').map(str::trim).collect();
            if c.len() == 2 && c[0].eq_ignore_ascii_case(key) {
                *l = format!("| {key} | {value} |");
                return true;
            }
        }
    }
    false
}

/// Inserts a changelog row after the last existing one.
fn add_changelog_row(lines: &mut Vec<String>, row: &str) {
    let mut last: Option<usize> = None;
    let mut in_log = false;
    for (i, l) in lines.iter().enumerate() {
        if l.starts_with("## ") {
            in_log = l[3..].trim().eq_ignore_ascii_case("changelog");
            continue;
        }
        if in_log && l.trim().starts_with("| V") {
            last = Some(i);
        }
    }
    match last {
        Some(i) => lines.insert(i + 1, row.to_string()),
        None => lines.push(row.to_string()),
    }
}

fn commit(ws: &Path, branch: &str, files: &[String], message: &str) -> bool {
    commit_why(ws, branch, files, message).is_empty()
}

/// Commits the files on the feature branch; the reason when it did not.
fn commit_why(ws: &Path, branch: &str, files: &[String], message: &str) -> String {
    let on = policy::branch_of(&ws.to_string_lossy());
    if on != branch {
        return format!("torch-main is on '{}', not {branch}", if on.is_empty() { "?" } else { &on });
    }
    let mut args: Vec<&str> = vec!["add", "--"];
    args.extend(files.iter().map(String::as_str));
    if policy::git(ws, &args).is_none() {
        return if policy::git_blocked() { policy::FOLDER_ACCESS_HINT.to_string() } else { "git add failed".to_string() };
    }
    let mut args: Vec<&str> = vec!["commit", "-q", "-m", message, "--"];
    args.extend(files.iter().map(String::as_str));
    if policy::git(ws, &args).is_none() {
        return if policy::git_blocked() { policy::FOLDER_ACCESS_HINT.to_string() } else { "git commit failed (nothing to commit, or no git identity)".to_string() };
    }
    String::new()
}

fn register_path(ws: &Path) -> PathBuf {
    ws.join("torch-product").join("Business OS").join("Portfolio").join("Portfolio_Decision_Register.md")
}

/// Adds or updates the feature's row in the Register's §2 table.
fn register_row(ws: &Path, app: &str, prd_rel: &str, signed_on: &str, released_on: &str) -> Result<(), String> {
    let path = register_path(ws);
    let text = fs::read_to_string(&path).map_err(|_| "No Portfolio_Decision_Register.md in torch-product/Business OS/Portfolio/".to_string())?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let mut in_sec = false;
    let mut last_row: Option<usize> = None;
    let mut existing: Option<usize> = None;
    for (i, l) in lines.iter().enumerate() {
        if l.starts_with("## ") {
            in_sec = l.contains("§2") || l.to_ascii_lowercase().contains("approved prd");
            continue;
        }
        if in_sec && l.trim().starts_with('|') && !l.contains("---") {
            let c: Vec<&str> = l.trim().trim_matches('|').split('|').map(str::trim).collect();
            if c.first().map(|x| x.eq_ignore_ascii_case("app")).unwrap_or(false) {
                continue;
            }
            last_row = Some(i);
            if c.get(1).map(|x| x.contains(prd_rel.rsplit('/').next().unwrap_or(prd_rel)) || x.contains(&prd_rel.replace("_V1.0.md", ""))).unwrap_or(false) {
                existing = Some(i);
            }
        }
    }
    let row = format!("| {app} | `{prd_rel}` | {signed_on} | Not set | {} | {} |", if released_on.is_empty() { "Approved" } else { "Released" }, if released_on.is_empty() { "—" } else { released_on });
    match (existing, last_row) {
        (Some(i), _) => {
            let c: Vec<String> = lines[i].trim().trim_matches('|').split('|').map(|x| x.trim().to_string()).collect();
            let mut c = c;
            while c.len() < 6 {
                c.push(String::new());
            }
            if !released_on.is_empty() {
                c[4] = "Released".to_string();
                c[5] = released_on.to_string();
            } else {
                c[1] = format!("`{prd_rel}`");
                c[2] = signed_on.to_string();
                c[4] = "Approved".to_string();
            }
            lines[i] = format!("| {} |", c.join(" | "));
        }
        (None, Some(i)) => lines.insert(i + 1, row),
        (None, None) => return Err("The Register has no §2 table".to_string()),
    }
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&path, out).map_err(|e| e.to_string())
}

/// The CEO's signature: the newest draft becomes V1.0 as a new file, with
/// the changelog row and the Register's line (policy 5.2 and 5.5).
pub fn sign_prd(ws: &Path, f: &Feature, name: &str) -> Result<Value, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("A name is needed for the signature".to_string());
    }
    let (path, major, minor) = find_prd(ws, f).ok_or_else(|| "No PRD file found for this feature".to_string())?;
    if major >= 1 {
        return Ok(json!({"ok": true, "already": true, "file": path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()}));
    }
    let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let date = today();
    set_header(&mut lines, "Version", "V1.0");
    set_header(&mut lines, "Status", "Signed");
    set_header(&mut lines, "Date", &date);
    add_changelog_row(&mut lines, &format!("| V1.0 | {date} | {name} | Signed version of V{major}.{minor}; no content change. | {name} (CEO), {date} |"));
    let old_name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let new_name = match old_name.rfind("_PRD_V") {
        Some(i) => format!("{}_PRD_V1.0.md", &old_name[..i]),
        None => return Err("The PRD file name does not follow {App}_{Feature}_PRD_V{version}.md".to_string()),
    };
    let new_path = path.with_file_name(&new_name);
    if new_path.exists() {
        return Err(format!("{new_name} already exists"));
    }
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&new_path, out).map_err(|e| e.to_string())?;
    let rel_ws = new_path.strip_prefix(ws).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let rel_product = new_path.strip_prefix(ws.join("torch-product")).map(|p| p.to_string_lossy().into_owned()).unwrap_or(rel_ws.clone());
    let register = register_row(ws, &app_name(ws, &f.app), &rel_product, &date, "");
    let mut files = vec![rel_ws.clone()];
    if register.is_ok() {
        files.push(register_path(ws).strip_prefix(ws).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
    }
    let committed = commit(ws, &f.branch, &files, &format!("{}: PRD V1.0 signed by {name}", f.key));
    policy::invalidate();
    Ok(json!({"ok": true, "file": new_name, "committed": committed, "register": register.is_ok(), "register_error": register.err().unwrap_or_default()}))
}

/// After Checklist K: the PRD's status becomes Released and the Register
/// says when (policy 10.4).
pub fn release(ws: &Path, f: &Feature, name: &str) -> Result<Value, String> {
    let (path, _, _) = find_prd(ws, f).ok_or_else(|| "No PRD file found for this feature".to_string())?;
    let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let date = today();
    let version = lines
        .iter()
        .find_map(|l| l.trim().strip_prefix("| Version |"))
        .map(|v| v.trim().trim_end_matches('|').trim().to_string())
        .unwrap_or_else(|| "V1.0".to_string());
    set_header(&mut lines, "Status", "Released");
    add_changelog_row(&mut lines, &format!("| {version} | {date} | {} | Released to production (policy Checklist K). | {} (CEO), {date} |", name.trim(), name.trim()));
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&path, out).map_err(|e| e.to_string())?;
    let rel_ws = path.strip_prefix(ws).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let rel_product = path.strip_prefix(ws.join("torch-product")).map(|p| p.to_string_lossy().into_owned()).unwrap_or(rel_ws.clone());
    let register = register_row(ws, &app_name(ws, &f.app), &rel_product, "", &date);
    let mut files = vec![rel_ws];
    if register.is_ok() {
        files.push(register_path(ws).strip_prefix(ws).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
    }
    let committed = commit(ws, &f.branch, &files, &format!("{}: released", f.key));
    update(ws, &f.key, |s| {
        s.released_at = now_ms();
        s.note(format!("Released; PRD status Released, Register updated{}", if committed { ", committed" } else { "" }));
    });
    policy::invalidate();
    Ok(json!({"ok": true, "committed": committed, "register": register.is_ok(), "register_error": register.err().unwrap_or_default()}))
}

fn slugify(s: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash && !out.is_empty() {
            out.push('-');
            dash = true;
        }
    }
    out.trim_end_matches('-').to_string()
}

/// Copies the feature's design boards (the daemon's rendered copies) into
/// `handoff/`, one HTML file per board, and lists them in the README.
pub fn export_handoff(ws: &Path, f: &Feature, sessions: &[Session]) -> Result<Value, String> {
    let designs = design_artifacts(f, sessions);
    if designs.is_empty() {
        return Err("No design artifact from this feature's sessions yet".to_string());
    }
    let handoff = ws.join(&f.dir).join("handoff");
    fs::create_dir_all(&handoff).map_err(|e| e.to_string())?;
    let mut rows: Vec<(String, String)> = Vec::new();
    for (id, _title) in &designs {
        let dir = artifacts::dir(id);
        // Boards and their titles from canvas.json when there is one.
        let mut boards: Vec<(PathBuf, String)> = Vec::new();
        let mut canvases: Vec<PathBuf> = Vec::new();
        collect_files(&dir, &dir, &mut canvases, "canvas.json");
        for canvas in &canvases {
            let base = canvas.parent().unwrap_or(&dir).to_path_buf();
            if let Ok(v) = serde_json::from_str::<Value>(&fs::read_to_string(canvas).unwrap_or_default()) {
                let specs = v.get("boards").cloned().unwrap_or(Value::Null);
                let order: Vec<String> = v
                    .get("order")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
                    .unwrap_or_else(|| specs.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default());
                for file in order {
                    let title = specs.get(&file).and_then(|s| s.get("title")).and_then(Value::as_str).unwrap_or(file.trim_end_matches(".dc.html")).to_string();
                    boards.push((base.join(&file), title));
                }
            }
        }
        if boards.is_empty() {
            let mut found = Vec::new();
            collect_files(&dir, &dir, &mut found, ".dc.html");
            for p in found {
                let t = p.file_name().map(|n| n.to_string_lossy().trim_end_matches(".dc.html").to_string()).unwrap_or_default();
                boards.push((p, t));
            }
        }
        for (src, title) in boards {
            let Ok(html) = fs::read_to_string(&src) else { continue };
            let name = format!("{}.html", slugify(&title));
            fs::write(handoff.join(&name), html).map_err(|e| e.to_string())?;
            rows.push((name, title));
        }
    }
    if rows.is_empty() {
        return Err("The design artifacts have no boards to export".to_string());
    }
    let app = app_name(ws, &f.app);
    let mut readme = format!("# Handoff files: {app} / {}\n\nMaps every handoff file to the PRD section it serves. Exported by Mewo on Fire from the Claude Design artifact on {}; the FE and BE leads complete the states and PRD sections during intake.\n\n| File | Flow / screen | States covered | PRD section |\n|---|---|---|---|\n", feature_words(&f.slug), today());
    for (file, title) in &rows {
        readme.push_str(&format!("| `{file}` | {title} | | |\n"));
    }
    fs::write(handoff.join("README.md"), readme).map_err(|e| e.to_string())?;
    let rel = format!("{}/handoff", f.dir);
    let committed = commit(ws, &f.branch, &[rel.clone()], &format!("{}: handoff exported from the design ({} boards)", f.key, rows.len()));
    update(ws, &f.key, |s| s.note(format!("Exported {} boards to handoff/", rows.len())));
    policy::invalidate();
    Ok(json!({"ok": true, "files": rows.iter().map(|(f, _)| f.clone()).collect::<Vec<_>>(), "committed": committed}))
}

fn collect_files(base: &Path, dir: &Path, out: &mut Vec<PathBuf>, suffix: &str) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_files(base, &p, out, suffix);
        } else if p.file_name().map(|n| n.to_string_lossy().ends_with(suffix)).unwrap_or(false) {
            out.push(p);
        }
    }
    out.sort();
}

/// A UAT user's result in RELEASE.md's table, and the pass-bar line.
pub fn uat_user(ws: &Path, f: &Feature, user: &str, role: &str, unaided: bool, notes: &str) -> Result<Value, String> {
    if user.trim().is_empty() {
        return Err("A user name is needed".to_string());
    }
    let path = ws.join(&f.dir).join("RELEASE.md");
    let text = fs::read_to_string(&path).map_err(|_| "No RELEASE.md for this feature".to_string())?;
    let lines: Vec<String> = text.lines().map(str::to_string).collect();
    // The UAT section.
    let mut a = None;
    let mut b = lines.len();
    for (i, l) in lines.iter().enumerate() {
        if l.starts_with("## ") {
            if a.is_some() {
                b = i;
                break;
            }
            if l[3..].trim().to_ascii_lowercase().starts_with("uat") {
                a = Some(i + 1);
            }
        }
    }
    let Some(a) = a else { return Err("RELEASE.md has no UAT section".to_string()) };
    let Some(h) = (a..b).find(|i| lines[*i].trim().starts_with("| #")) else { return Err("RELEASE.md has no UAT table".to_string()) };
    let mut rows_end = h + 2;
    while rows_end < b && lines[rows_end].trim().starts_with('|') {
        rows_end += 1;
    }
    // Existing users (the template's empty row dropped), then the new one.
    let mut users: Vec<(String, String, bool, String)> = Vec::new();
    for l in &lines[h + 2..rows_end] {
        let c: Vec<String> = l.trim().trim_matches('|').split('|').map(|x| x.trim().to_string()).collect();
        if c.len() >= 4 && !c[1].is_empty() {
            users.push((c[1].clone(), c[2].clone(), c[3].to_ascii_lowercase().starts_with('y'), c.get(4).cloned().unwrap_or_default()));
        }
    }
    users.retain(|u| !u.0.eq_ignore_ascii_case(user.trim()));
    users.push((user.trim().to_string(), role.trim().to_string(), unaided, notes.trim().to_string()));
    let total = users.len();
    let unaided_n = users.iter().filter(|u| u.2).count();
    let pct = unaided_n * 100 / total.max(1);
    let bar_line = format!("Completed unaided: {unaided_n} / {total} = {pct}%. Pass bar: 80%, with 5 to 8 users.");
    let mut out: Vec<String> = lines[..h + 2].to_vec();
    for (i, u) in users.iter().enumerate() {
        out.push(format!("| {} | {} | {} | {} | {} |", i + 1, u.0, u.1, if u.2 { "Yes" } else { "No" }, u.3));
    }
    let mut replaced = false;
    for l in &lines[rows_end..] {
        if !replaced && l.trim().starts_with("Completed unaided:") {
            out.push(bar_line.clone());
            replaced = true;
        } else {
            out.push(l.clone());
        }
    }
    if !replaced {
        out.insert(h + 2 + users.len(), format!("\n{bar_line}"));
    }
    let mut text = out.join("\n");
    text.push('\n');
    fs::write(&path, text).map_err(|e| e.to_string())?;
    let why = commit_why(ws, &f.branch, &[format!("{}/RELEASE.md", f.dir)], &format!("{}: UAT result for {}", f.key, user.trim()));
    policy::invalidate();
    Ok(json!({"ok": true, "total": total, "unaided": unaided_n, "percent": pct, "pass": total >= 5 && pct >= 80, "committed": why.is_empty(), "note": why}))
}

/// Merges the feature branch into main in torch-main and every fetched
/// code repository on it, pushes, and deletes the branch (policy 10.4).
pub fn close_branches(ws: &Path, f: &Feature) -> Value {
    let mut results = Vec::new();
    let mut repos: Vec<PathBuf> = vec![ws.to_path_buf()];
    repos.extend(f.fetched_repos.iter().map(|r| ws.join(r)));
    for repo in repos {
        let label = repo.strip_prefix(ws).ok().map(|p| p.to_string_lossy().into_owned()).filter(|s| !s.is_empty()).unwrap_or_else(|| "torch-main".to_string());
        let dir = repo.to_string_lossy().into_owned();
        if policy::git(&repo, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{}", f.branch)]).is_none() {
            results.push(json!({"repo": label, "ok": true, "note": "no such branch"}));
            continue;
        }
        if policy::git(&repo, &["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"]).map(|s| !s.is_empty()).unwrap_or(true) {
            results.push(json!({"repo": label, "ok": false, "error": "uncommitted changes; commit or stash them first"}));
            continue;
        }
        let main = ["main", "master"].into_iter().find(|b| policy::git(&repo, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{b}")]).is_some());
        let Some(main) = main else {
            results.push(json!({"repo": label, "ok": false, "error": "no main branch"}));
            continue;
        };
        let before = policy::branch_of(&dir);
        if policy::git(&repo, &["switch", main]).is_none() {
            results.push(json!({"repo": label, "ok": false, "error": format!("could not switch to {main}")}));
            continue;
        }
        let merged = policy::git(&repo, &["merge", "--no-ff", "--no-edit", "-m", &format!("Merge {} (released)", f.branch), &f.branch]).is_some();
        if !merged {
            let _ = policy::git(&repo, &["merge", "--abort"]);
            if !before.is_empty() {
                let _ = policy::git(&repo, &["switch", &before]);
            }
            results.push(json!({"repo": label, "ok": false, "error": "merge conflict; merge it by hand"}));
            continue;
        }
        let pushed = policy::git(&repo, &["push", "origin", main]).is_some();
        let deleted = policy::git(&repo, &["branch", "-d", &f.branch]).is_some();
        if deleted {
            let _ = policy::git(&repo, &["push", "origin", "--delete", &f.branch]);
        }
        results.push(json!({"repo": label, "ok": true, "pushed": pushed, "deleted": deleted}));
    }
    let all_ok = results.iter().all(|r| r.get("ok").and_then(Value::as_bool).unwrap_or(false));
    if all_ok {
        update(ws, &f.key, |s| {
            s.closed_at = now_ms();
            s.note("Branches merged and closed");
        });
    }
    policy::invalidate();
    json!({"ok": all_ok, "repos": results})
}

/// `context/scripts/new-feature.sh {app} {slug} [--light]`.
pub fn new_feature(ws: &Path, app: &str, slug: &str, light: bool) -> Value {
    let script = ws.join("context").join("scripts").join("new-feature.sh");
    if !script.is_file() {
        return json!({"ok": false, "error": "This workspace has no context/scripts/new-feature.sh"});
    }
    let bash = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"].into_iter().find(|b| Path::new(b).is_file()).unwrap_or("/bin/bash");
    let mut cmd = Command::new(bash);
    cmd.arg(&script).arg(app).arg(slug);
    if light {
        cmd.arg("--light");
    }
    let out = cmd.current_dir(ws).stdin(Stdio::null()).env("GIT_TERMINAL_PROMPT", "0").output();
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).trim().to_string();
            policy::invalidate();
            if o.status.success() {
                let key = format!("{app}/{slug}");
                let dir = format!("app-notebooks/{app}/features/{slug}");
                let committed = commit(ws, &format!("{}/{app}-{slug}", if light { "fix" } else { "feature" }), &[dir.clone()], &format!("Start {app} {}: {slug}", if light { "fix" } else { "feature" }));
                json!({"ok": true, "key": key, "output": stdout, "note": stderr, "committed": committed})
            } else if stderr.contains("mapfile") || stderr.contains("syntax error") {
                // macOS ships bash 3.2; do what the script does.
                new_feature_native(ws, app, slug, light)
            } else {
                json!({"ok": false, "error": if stderr.is_empty() { stdout } else { stderr }})
            }
        }
        Err(e) => json!({"ok": false, "error": e.to_string()}),
    }
}

/// What `new-feature.sh` does, in Rust, for a Mac whose bash is too old
/// for the script: the branch in torch-main and in the fetched code
/// repositories, the record folder from the templates.
fn new_feature_native(ws: &Path, app: &str, slug: &str, light: bool) -> Value {
    let ok_slug = !slug.is_empty() && slug.split('-').all(|w| !w.is_empty() && w.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
    if !ok_slug {
        return json!({"ok": false, "error": "The slug must be lowercase words joined by hyphens, for example bank-reconciliation"});
    }
    if !ws.join("app-notebooks").join(app).is_dir() {
        return json!({"ok": false, "error": format!("No notebook at app-notebooks/{app}")});
    }
    let prefix = if light { "fix" } else { "feature" };
    let branch = format!("{prefix}/{app}-{slug}");
    let dest = ws.join("app-notebooks").join(app).join("features").join(slug);
    if dest.exists() {
        return json!({"ok": false, "error": format!("app-notebooks/{app}/features/{slug} already exists")});
    }
    if policy::git(ws, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")]).is_some() {
        return json!({"ok": false, "error": format!("Branch {branch} already exists in torch-main")});
    }
    if policy::git(ws, &["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"]).map(|s| !s.is_empty()).unwrap_or(true) {
        return json!({"ok": false, "error": "torch-main has uncommitted changes. Commit or stash them first."});
    }
    let repos: Vec<String> = policy::app_repos(ws).get(app).cloned().unwrap_or_default();
    let fetched: Vec<String> = repos.iter().filter(|r| ws.join(r).join(".git").exists()).cloned().collect();
    for r in &fetched {
        let dir = ws.join(r);
        if policy::branch_of(&dir.to_string_lossy()).is_empty() {
            return json!({"ok": false, "error": format!("{r} has no branch checked out (detached HEAD). Run `git switch main` there first.")});
        }
        if policy::git(&dir, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")]).is_some() {
            return json!({"ok": false, "error": format!("Branch {branch} already exists in {r}")});
        }
    }
    if policy::git(ws, &["switch", "-c", &branch]).is_none() {
        return json!({"ok": false, "error": "Could not create the branch in torch-main"});
    }
    let templates = ws.join("context").join("templates");
    let _ = fs::create_dir_all(&dest);
    let app_display = app_name(ws, app);
    let fill = |name: &str| -> String {
        fs::read_to_string(templates.join(name))
            .unwrap_or_default()
            .replace("{App} / {Feature}", &format!("{app_display} / {slug}"))
            .replace("{App} / {short title}", &format!("{app_display} / {slug}"))
    };
    if light {
        let _ = fs::write(dest.join("LIGHT_PATH.md"), fill("LIGHT_PATH.md"));
    } else {
        let _ = fs::create_dir_all(dest.join("handoff"));
        for f in ["SESSION_PLAN.md", "HANDOFF_CHECKLIST.md", "OPEN_QUESTIONS.md", "RELEASE.md"] {
            let _ = fs::write(dest.join(f), fill(f));
        }
        let _ = fs::write(dest.join("handoff").join("README.md"), fill("HANDOFF_README.md"));
    }
    let mut branched = Vec::new();
    for r in &fetched {
        if policy::git(&ws.join(r), &["switch", "-c", &branch]).is_some() {
            branched.push(r.clone());
        }
    }
    let dir = format!("app-notebooks/{app}/features/{slug}");
    let committed = commit(ws, &branch, &[dir.clone()], &format!("Start {app} {prefix}: {slug}"));
    policy::invalidate();
    json!({
        "ok": true,
        "key": format!("{app}/{slug}"),
        "branch": branch,
        "repos": branched,
        "committed": committed,
        "output": format!("Branch {branch} created in torch-main{}. Record folder: {dir}", if branched.is_empty() { String::new() } else { format!(" and in {}", branched.join(", ")) }),
    })
}

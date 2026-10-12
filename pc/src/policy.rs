//! TORCH Agentic Development Policy support (v1.7): the workspace a
//! session works in, its features and their records (`SESSION_PLAN.md`,
//! `HANDOFF_CHECKLIST.md`, `RELEASE.md`, `LIGHT_PATH.md`), read from the
//! files the policy keeps them in and written back for a signature or a
//! session's status. A workspace is any folder with `app-notebooks/` and
//! the record templates under `context/templates/`; nothing here knows
//! Business OS itself.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{json, Value};

use crate::artifacts;
use crate::paths;
use crate::sessions::Session;

/// The twelve steps of the full flow (policy section 4), by index 1..=12.
pub const STEPS: [&str; 12] = [
    "PRD draft",
    "Estimates",
    "Alignment and sign-off",
    "Design process",
    "Prototype and test",
    "Handoff session",
    "Handoff intake",
    "Session planning",
    "Build sessions",
    "Staging",
    "UAT",
    "Production",
];

/// Checklist F (session self-check), as the pull request template lists it.
pub const SELF_CHECK: [&str; 8] = [
    "I read the whole diff, and I can explain every line.",
    "The session's \"done when\" checks pass.",
    "Tests exist for the new behaviour and they test behaviour, not just that the code runs.",
    "The change stays inside the session's goal.",
    "The feature's design system's components and variables are used (Glare, or the one in DESIGN_SYSTEM.md). No hardcoded design values.",
    "The rule files listed in the session plan were followed.",
    "No secrets, keys or personal data in the code or the commit.",
    "Lint, type check and the full test suite pass locally.",
];

/// Checklists G and H (reviewer), as the pull request template lists them.
pub const REVIEW_CHECK: [&str; 11] = [
    "Does what the session goal says; the PRD items it touches are met.",
    "Follows the architecture and patterns already in the repository.",
    "Reuses the design system, platform services and existing modules instead of copying them.",
    "Errors are handled properly and not hidden.",
    "Permissions and data access are checked on the server where they need to be.",
    "The tests would fail if the feature broke. No tests edited only so they pass.",
    "Matches the handoff HTML on screen.",
    "No duplicated code, unexplained dependencies, leftover TODOs, debug logs or placeholder text.",
    "No comments that just restate the code; nothing much larger than the task needed.",
    "Names match the domain language in the PRD and the existing code.",
    "I would have accepted this code if a person had written it.",
];

// ---------------------------------------------------------------------------
// workspace
// ---------------------------------------------------------------------------

fn is_workspace(dir: &Path) -> bool {
    dir.join("app-notebooks").is_dir() && dir.join("context").join("templates").join("SESSION_PLAN.md").is_file()
}

/// The workspace `cwd` is inside (itself, a notebook, a code repository…).
pub fn workspace_for(cwd: &str) -> Option<PathBuf> {
    if cwd.is_empty() {
        return None;
    }
    let mut dir = Path::new(cwd);
    loop {
        if is_workspace(dir) {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
}

/// `code/<repo>` when `cwd` is inside one of the workspace's code repositories.
pub fn repo_of(ws: &Path, cwd: &str) -> Option<String> {
    let rel = Path::new(cwd).strip_prefix(ws.join("code")).ok()?;
    let first = rel.components().next()?;
    Some(format!("code/{}", first.as_os_str().to_string_lossy()))
}

fn workspaces_file() -> PathBuf {
    paths::state_dir().join("workspaces.json")
}

/// Workspaces seen so far (sessions ran inside them), existing ones only.
pub fn workspaces() -> Vec<PathBuf> {
    let list: Vec<String> = fs::read_to_string(workspaces_file())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    list.into_iter().map(PathBuf::from).filter(|p| is_workspace(p)).collect()
}

/// Keeps a workspace for later `features` queries. True when it was new.
pub fn remember_workspace(ws: &Path) -> bool {
    let mut list = workspaces();
    if list.iter().any(|p| p == ws) {
        return false;
    }
    list.push(ws.to_path_buf());
    let strings: Vec<String> = list.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    let _ = fs::create_dir_all(paths::state_dir());
    let _ = fs::write(workspaces_file(), serde_json::to_string_pretty(&strings).unwrap_or_default());
    true
}

// ---------------------------------------------------------------------------
// git
// ---------------------------------------------------------------------------

/// A git binary reached directly: `/usr/bin/git` on macOS is the xcrun
/// shim, which can take long on a cold cache from a background daemon.
pub fn git_bin() -> PathBuf {
    static FOUND: Mutex<Option<PathBuf>> = Mutex::new(None);
    if let Some(p) = FOUND.lock().unwrap_or_else(|p| p.into_inner()).clone() {
        return p;
    }
    let mut candidates: Vec<PathBuf> = vec![
        PathBuf::from("/Library/Developer/CommandLineTools/usr/bin/git"),
        PathBuf::from("/opt/homebrew/bin/git"),
        PathBuf::from("/usr/local/bin/git"),
    ];
    if let Ok(dev) = fs::read_to_string("/var/db/xcode_select_link").map(|s| s.trim().to_string()) {
        candidates.push(Path::new(&dev).join("usr").join("bin").join("git"));
    }
    if let Ok(link) = fs::read_link("/var/db/xcode_select_link") {
        candidates.push(link.join("usr").join("bin").join("git"));
    }
    candidates.push(PathBuf::from("/Applications/Xcode.app/Contents/Developer/usr/bin/git"));
    candidates.push(PathBuf::from("/usr/bin/git"));
    let found = candidates.into_iter().find(|p| p.is_file()).unwrap_or_else(|| PathBuf::from("git"));
    *FOUND.lock().unwrap_or_else(|p| p.into_inner()) = Some(found.clone());
    found
}

/// How long a git command may take before it counts as blocked (macOS
/// holds a process that enters a protected folder until the user answers
/// its privacy prompt).
const GIT_TIMEOUT: Duration = Duration::from_secs(8);
static GIT_BLOCKED_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);

/// Remembers that the daemon is being held out of a folder, for a minute:
/// callers answer with the hint instead of piling up stuck threads.
pub fn mark_blocked() {
    *GIT_BLOCKED_UNTIL.lock().unwrap_or_else(|p| p.into_inner()) = Some(Instant::now() + Duration::from_secs(60));
}

/// True while git is known to hang for the daemon (no folder access).
pub fn git_blocked() -> bool {
    GIT_BLOCKED_UNTIL
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .is_some_and(|until| until > Instant::now())
}

/// stdout of `git <args>` in `dir`, trimmed; None when it fails or hangs.
pub fn git(dir: &Path, args: &[&str]) -> Option<String> {
    if git_blocked() {
        return None;
    }
    let mut child = Command::new(git_bin())
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .envs(crate::github::envs())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < GIT_TIMEOUT => std::thread::sleep(Duration::from_millis(25)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                *GIT_BLOCKED_UNTIL.lock().unwrap_or_else(|p| p.into_inner()) = Some(Instant::now() + Duration::from_secs(60));
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// What to tell people when git hangs for the daemon.
pub const FOLDER_ACCESS_HINT: &str = "The PC's Mewo daemon cannot read the workspace folder: macOS is waiting for you to allow it (or has denied it). Allow mewo under System Settings > Privacy & Security > Files and Folders, then try again.";

static BRANCHES: Mutex<Vec<(PathBuf, Instant, String)>> = Mutex::new(Vec::new());

/// The branch checked out in `dir` (`""` when unknown or detached), cached
/// for a few seconds since the hooks ask often.
pub fn branch_of(dir: &str) -> String {
    if dir.is_empty() {
        return String::new();
    }
    let path = PathBuf::from(dir);
    {
        let cache = BRANCHES.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((_, at, b)) = cache.iter().find(|(p, _, _)| *p == path) {
            if at.elapsed() < Duration::from_secs(15) {
                return b.clone();
            }
        }
    }
    let branch = git(&path, &["branch", "--show-current"]).unwrap_or_default();
    let mut cache = BRANCHES.lock().unwrap_or_else(|p| p.into_inner());
    cache.retain(|(p, at, _)| *p != path && at.elapsed() < Duration::from_secs(60));
    cache.push((path, Instant::now(), branch.clone()));
    branch
}

fn is_repo(dir: &Path) -> bool {
    // A submodule checkout has a `.git` file, a clone a `.git` folder.
    dir.join(".git").exists()
}

// ---------------------------------------------------------------------------
// apps, branches
// ---------------------------------------------------------------------------

/// The notebooks: `app-notebooks/<app>/`.
pub fn apps(ws: &Path) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(ws.join("app-notebooks"))
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| !n.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// `context/scripts/app-repos.conf`: app → its code repositories (`code/x`).
pub fn app_repos(ws: &Path) -> HashMap<String, Vec<String>> {
    let mut map = HashMap::new();
    let Ok(text) = fs::read_to_string(ws.join("context").join("scripts").join("app-repos.conf")) else {
        return map;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let Some(app) = parts.next() else { continue };
        map.insert(app.to_string(), parts.map(|r| format!("code/{r}")).collect());
    }
    map
}

/// `(app, slug, light)` of a `feature/{app}-{slug}` or `fix/{app}-{slug}`
/// branch, the app being one of the workspace's notebooks.
pub fn parse_branch(ws: &Path, branch: &str) -> Option<(String, String, bool)> {
    let (light, rest) = if let Some(r) = branch.strip_prefix("feature/") {
        (false, r)
    } else if let Some(r) = branch.strip_prefix("fix/") {
        (true, r)
    } else {
        return None;
    };
    let mut apps = apps(ws);
    apps.sort_by_key(|a| std::cmp::Reverse(a.len()));
    for app in apps {
        if let Some(slug) = rest.strip_prefix(&format!("{app}-")) {
            if !slug.is_empty() {
                return Some((app, slug.to_string(), light));
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// records
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize)]
pub struct GateItem {
    pub text: String,
    pub checked: bool,
}

/// A sign-off point: a checklist and the signature table under it.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Gate {
    /// `handoff1`, `handoff2`, `intake`, `plan`, `staging`, `uat`,
    /// `production`, `light`.
    pub id: String,
    /// The policy's letter: D, E, I, J, K, L (or "" for the plan review).
    pub checklist: String,
    pub title: String,
    /// Which step of the flow it closes (1..=12).
    pub step: u8,
    /// File, relative to the workspace.
    pub file: String,
    pub items: Vec<GateItem>,
    /// Roles the table asks for (`Product lead`, `Design lead`, …).
    pub roles: Vec<String>,
    /// `{role, name}` for the roles filled in.
    pub signatures: Vec<Value>,
    pub date: String,
    /// Every role signed (or, with no table, every item ticked).
    pub signed: bool,
    /// The record file exists.
    pub present: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct PlanSession {
    pub n: u32,
    pub goal: String,
    pub level: String,
    pub tier: u8,
    pub depends_on: Vec<u32>,
    pub owner: String,
    /// The order table's status.
    pub status: String,
    pub load_first: Vec<String>,
    pub prompt: String,
    pub done_when: Vec<String>,
    pub pr: String,
    pub stopped_early: String,
    /// `code/x`, from the prompt or the plan's first repository.
    pub repo: String,
    /// Where to start the session: the repository when it is fetched, else
    /// the workspace.
    pub folder: String,
    // Live (filled by `enrich`):
    pub effective: String,
    pub note: String,
    pub running: bool,
    pub attempts: u32,
    pub live: Vec<Value>,
    pub pr_state: String,
    pub pr_url: String,
    pub pr_number: u64,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Plan {
    pub file: String,
    pub prd: String,
    pub branch: String,
    pub repos: Vec<String>,
    pub planned_by: String,
    pub reviewed_by: String,
    pub revised: Vec<String>,
    pub sessions: Vec<PlanSession>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Feature {
    /// `app/slug`.
    pub key: String,
    pub app: String,
    pub slug: String,
    pub branch: String,
    pub light: bool,
    pub workspace: String,
    /// `app-notebooks/app/features/slug`.
    pub dir: String,
    pub step: u8,
    pub step_label: String,
    pub released: bool,
    pub gates: Vec<Gate>,
    pub plan: Option<Plan>,
    pub handoff_files: Vec<String>,
    /// Artifact id the console and phones read the handoff through.
    pub handoff_id: String,
    pub open_questions: u32,
    pub repos: Vec<String>,
    pub fetched_repos: Vec<String>,
    pub prd: String,
    pub prd_signed: bool,
    /// Where the PRD came from: `plan` (named in SESSION_PLAN.md),
    /// `feature` (named after the feature), `app` (the app's own PRD),
    /// `picked` (chosen for the feature, v2.2).
    pub prd_source: String,
    /// v2.3: the design system the feature follows, from DESIGN_SYSTEM.md
    /// in its folder: `{name, repo, dir, reference, present, checked_out,
    /// glare}`. Glare, the policy's default, when there is no record.
    pub design: Value,
    pub warnings: Vec<String>,
    pub diff_files: u64,
    pub diff_additions: u64,
    pub too_big: bool,
    pub sessions_merged: u32,
    pub sessions_total: u32,
    pub updated: u64,
    /// v2.0: `{remote, ahead, behind, local}` of the feature branch in torch-main.
    pub sync: Value,
    /// v2.0: which fetched code repositories have the feature branch.
    pub branches: Vec<String>,
}

fn placeholder(s: &str) -> bool {
    let t = s.trim();
    t.is_empty() || (t.starts_with('{') && t.ends_with('}')) || t == "—"
}

fn clean(s: &str) -> String {
    let t = s.trim().trim_matches('`').trim();
    if placeholder(t) {
        String::new()
    } else {
        t.to_string()
    }
}

fn cells(line: &str) -> Vec<String> {
    let t = line.trim();
    if !t.starts_with('|') {
        return Vec::new();
    }
    t.trim_matches('|').split('|').map(|c| c.trim().to_string()).collect()
}

fn is_separator(line: &str) -> bool {
    let t = line.trim();
    t.starts_with('|') && t.chars().all(|c| matches!(c, '|' | '-' | ':' | ' '))
}

/// Level-2 sections: `(heading, first line index, end line index)`.
fn sections(lines: &[&str]) -> Vec<(String, usize, usize)> {
    let mut out: Vec<(String, usize, usize)> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if let Some(h) = l.strip_prefix("## ") {
            if let Some(last) = out.last_mut() {
                last.2 = i;
            }
            out.push((h.trim().to_string(), i + 1, lines.len()));
        }
    }
    out
}

fn checkboxes(lines: &[&str]) -> Vec<(usize, String, bool)> {
    let mut out = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let t = l.trim_start();
        if let Some(rest) = t.strip_prefix("- [ ] ") {
            out.push((i, rest.trim().to_string(), false));
        } else if let Some(rest) = t.strip_prefix("- [x] ").or_else(|| t.strip_prefix("- [X] ")) {
            out.push((i, rest.trim().to_string(), true));
        }
    }
    out
}

/// The signature table in `lines`: header cells, the first data row's
/// cells, and their line indexes. A table whose header names a `Date`.
fn signature_table(lines: &[&str]) -> Option<(Vec<String>, Vec<String>, usize, usize)> {
    for (i, l) in lines.iter().enumerate() {
        let head = cells(l);
        if head.is_empty() || !head.iter().any(|c| c.eq_ignore_ascii_case("date")) {
            continue;
        }
        if i + 2 >= lines.len() + 1 || !is_separator(lines.get(i + 1).copied().unwrap_or("")) {
            continue;
        }
        let row_i = i + 2;
        let mut row = cells(lines.get(row_i).copied().unwrap_or(""));
        // A row of another shape is not this table's.
        if row.is_empty() || row.len() > head.len() {
            row = vec![String::new(); head.len()];
        }
        while row.len() < head.len() {
            row.push(String::new());
        }
        return Some((head, row, i, row_i));
    }
    None
}

fn gate_from(lines: &[&str], id: &str, checklist: &str, title: &str, step: u8, file: &str, present: bool) -> Gate {
    let items: Vec<GateItem> = checkboxes(lines)
        .into_iter()
        .map(|(_, text, checked)| GateItem { text, checked })
        .collect();
    let mut gate = Gate {
        id: id.to_string(),
        checklist: checklist.to_string(),
        title: title.to_string(),
        step,
        file: file.to_string(),
        items,
        present,
        ..Gate::default()
    };
    if let Some((head, row, _, _)) = signature_table(lines) {
        for (h, v) in head.iter().zip(row.iter()) {
            if h.eq_ignore_ascii_case("date") {
                gate.date = clean(v);
            } else {
                gate.roles.push(h.clone());
                let name = clean(v);
                if !name.is_empty() {
                    gate.signatures.push(json!({"role": h, "name": name}));
                }
            }
        }
        gate.signed = !gate.roles.is_empty() && gate.signatures.len() == gate.roles.len();
    } else {
        gate.signed = present && !gate.items.is_empty() && gate.items.iter().all(|i| i.checked);
    }
    gate
}

fn read_lines(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok()
}

/// `RELEASE.md`: staging (I), UAT (J), production (K).
fn release_gates(dir: &Path, rel: &str) -> Vec<Gate> {
    let path = dir.join("RELEASE.md");
    let text = read_lines(&path).unwrap_or_default();
    let present = !text.is_empty();
    let lines: Vec<&str> = text.lines().collect();
    let secs = sections(&lines);
    let find = |needle: &str| -> Vec<&str> {
        secs.iter()
            .find(|(h, _, _)| h.to_ascii_lowercase().starts_with(needle))
            .map(|(_, a, b)| lines[*a..*b].to_vec())
            .unwrap_or_default()
    };
    let file = format!("{rel}/RELEASE.md");
    vec![
        gate_from(&find("staging"), "staging", "I", "Staging sign-off", 10, &file, present),
        gate_from(&find("uat"), "uat", "J", "UAT sign-off", 11, &file, present),
        gate_from(&find("production"), "production", "K", "Production release", 12, &file, present),
    ]
}

/// `HANDOFF_CHECKLIST.md`: part 1, part 2 (D) and intake (E).
fn handoff_gates(dir: &Path, rel: &str) -> Vec<Gate> {
    let path = dir.join("HANDOFF_CHECKLIST.md");
    let text = read_lines(&path).unwrap_or_default();
    let present = !text.is_empty();
    let lines: Vec<&str> = text.lines().collect();
    let secs = sections(&lines);
    let find = |needle: &str| -> Vec<&str> {
        secs.iter()
            .find(|(h, _, _)| h.to_ascii_lowercase().starts_with(needle))
            .map(|(_, a, b)| lines[*a..*b].to_vec())
            .unwrap_or_default()
    };
    let file = format!("{rel}/HANDOFF_CHECKLIST.md");
    let mut part1 = gate_from(&find("part 1"), "handoff1", "D", "Design proven", 5, &file, present);
    // Part 1 has no table of its own in the template: the part 2 table
    // covers both, so part 1 counts as signed once its items are ticked.
    if part1.roles.is_empty() {
        part1.signed = present && !part1.items.is_empty() && part1.items.iter().all(|i| i.checked);
    }
    vec![
        part1,
        gate_from(&find("part 2"), "handoff2", "D", "Handoff session", 6, &file, present),
        gate_from(&find("intake"), "intake", "E", "Handoff intake", 7, &file, present),
    ]
}

/// `LIGHT_PATH.md`: Checklist L.
fn light_gate(dir: &Path, rel: &str) -> Gate {
    let path = dir.join("LIGHT_PATH.md");
    let text = read_lines(&path).unwrap_or_default();
    let present = !text.is_empty();
    let lines: Vec<&str> = text.lines().collect();
    gate_from(&lines, "light", "L", "Light-path record", 12, &format!("{rel}/LIGHT_PATH.md"), present)
}

fn field_value(lines: &[&str], i: usize, key: &str) -> Option<String> {
    let l = lines[i].trim();
    let rest = l.strip_prefix(&format!("**{key}:**"))?;
    Some(rest.trim().to_string())
}

/// Bulleted lines right after line `i` (`- …`), until a blank line or the
/// next field.
fn list_after(lines: &[&str], i: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut j = i + 1;
    while j < lines.len() {
        let t = lines[j].trim();
        if t.starts_with("- ") {
            let v = clean(&t[2..]);
            if !v.is_empty() {
                out.push(v);
            }
        } else if t.is_empty() && out.is_empty() {
            // allow one blank line before the list
        } else if t.is_empty() || t.starts_with("**") || t.starts_with("## ") {
            break;
        }
        j += 1;
    }
    out
}

/// The fenced block after line `i`.
fn fence_after(lines: &[&str], i: usize) -> String {
    let mut j = i + 1;
    while j < lines.len() && !lines[j].trim_start().starts_with("```") {
        if lines[j].trim().starts_with("**") || lines[j].starts_with("## ") {
            return String::new();
        }
        j += 1;
    }
    let mut out = Vec::new();
    j += 1;
    while j < lines.len() && !lines[j].trim_start().starts_with("```") {
        out.push(lines[j]);
        j += 1;
    }
    let text = out.join("\n").trim().to_string();
    if placeholder(&text) {
        String::new()
    } else {
        text
    }
}

/// Session numbers in a "Depends on" cell: `1, 2`, `11 to 17` (a range,
/// also `11-17` and `11–17`), `none`. A note after `;` and references to
/// open questions (`OQ 28`) are not sessions.
fn parse_depends(s: &str) -> Vec<u32> {
    let s = s.split(';').next().unwrap_or("");
    let lower = s.to_ascii_lowercase();
    let mut out: Vec<u32> = Vec::new();
    let mut i = 0;
    let b = lower.as_bytes();
    while i < b.len() {
        if b[i].is_ascii_digit() {
            let start = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            // `OQ 28`, `question 28`, `#28` in prose: an open question, not a session.
            let before = lower[..start].trim_end();
            if before.ends_with("oq") || before.ends_with("question") || before.ends_with("questions") {
                continue;
            }
            let Ok(n) = lower[start..i].parse::<u32>() else { continue };
            // A range: `11 to 17`, `11-17`, `11–17`.
            let rest = lower[i..].trim_start();
            let range = ["to ", "-", "–", "—"].iter().find_map(|sep| rest.strip_prefix(sep)).map(|r| r.trim_start());
            if let Some(r) = range {
                let digits: String = r.chars().take_while(|c| c.is_ascii_digit()).collect();
                if let Ok(m) = digits.parse::<u32>() {
                    if m >= n && m - n <= 40 {
                        out.extend(n..=m);
                        // Skip past the range's end.
                        let consumed = lower[i..].len() - rest.len() + (rest.len() - r.len()) + digits.len();
                        i += consumed;
                        continue;
                    }
                }
            }
            out.push(n);
        } else {
            i += 1;
        }
    }
    out.dedup();
    out
}

fn repo_in(text: &str) -> Option<String> {
    let mut rest = text;
    while let Some(i) = rest.find("code/") {
        let tail = &rest[i + 5..];
        let name: String = tail
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            .collect();
        if !name.is_empty() && name != "README.md" {
            return Some(format!("code/{name}"));
        }
        rest = &rest[i + 5..];
    }
    None
}

/// `SESSION_PLAN.md`.
pub fn parse_plan(ws: &Path, dir: &Path, rel: &str) -> Option<Plan> {
    let path = dir.join("SESSION_PLAN.md");
    let text = read_lines(&path)?;
    let lines: Vec<&str> = text.lines().collect();
    let mut plan = Plan { file: format!("{rel}/SESSION_PLAN.md"), ..Plan::default() };
    let secs = sections(&lines);
    let head_end = secs.first().map(|(_, a, _)| a.saturating_sub(1)).unwrap_or(lines.len());
    for l in &lines[..head_end] {
        let t = l.trim();
        if let Some(r) = t.strip_prefix("Revised ") {
            plan.revised.push(r.trim().to_string());
        }
        let c = cells(l);
        if c.len() >= 2 {
            let key = c[0].to_ascii_lowercase();
            let val = clean(&c[1]);
            match key.as_str() {
                "prd" => plan.prd = val.split_whitespace().next().unwrap_or("").trim_matches('`').to_string(),
                "branch" => plan.branch = val.split_whitespace().next().unwrap_or("").trim_matches('`').to_string(),
                "code repositories" => {
                    let mut seen = HashSet::new();
                    let mut rest = c[1].as_str();
                    while let Some(r) = repo_in(rest) {
                        let i = rest.find(&r).unwrap_or(0) + r.len();
                        if seen.insert(r.clone()) {
                            plan.repos.push(r);
                        }
                        rest = &rest[i..];
                    }
                }
                "planned by" => plan.planned_by = val,
                "reviewed by tech lead" => plan.reviewed_by = val,
                _ => {}
            }
        }
    }
    // The order table, by its header. The template's columns are
    // `# | Session | Level | Tier | Depends on | Owner | Status`; a plan may
    // add one (Repository) or reorder them, so the header decides.
    let mut order: HashMap<u32, (String, String, u8, Vec<u32>, String, String, String)> = HashMap::new();
    if let Some((_, a, b)) = secs.iter().find(|(h, _, _)| h.eq_ignore_ascii_case("order")) {
        let mut col: HashMap<&str, usize> = HashMap::new();
        for l in &lines[*a..*b] {
            let c = cells(l);
            if c.len() < 4 || is_separator(l) {
                continue;
            }
            if c[0].parse::<u32>().is_err() {
                if c.iter().any(|h| h.trim() == "#") {
                    col.clear();
                    for (i, h) in c.iter().enumerate() {
                        let h = h.trim().to_ascii_lowercase();
                        let key = if h == "session" || h == "goal" {
                            "goal"
                        } else if h == "level" {
                            "level"
                        } else if h.starts_with("repo") {
                            "repo"
                        } else if h == "tier" {
                            "tier"
                        } else if h.starts_with("depend") || h == "after" || h == "needs" {
                            "depends"
                        } else if h == "owner" || h == "dev" || h == "developer" {
                            "owner"
                        } else if h == "status" {
                            "status"
                        } else {
                            continue;
                        };
                        col.entry(key).or_insert(i);
                    }
                }
                continue;
            }
            let Ok(n) = c[0].parse::<u32>() else { continue };
            let pick = |key: &str, default: usize| -> String {
                let i = if col.is_empty() { Some(default) } else { col.get(key).copied() };
                i.and_then(|i| c.get(i)).map(|s| s.to_string()).unwrap_or_default()
            };
            let tier = pick("tier", 3).trim().chars().find(|ch| ch.is_ascii_digit()).and_then(|ch| ch.to_digit(10)).unwrap_or(0) as u8;
            let deps: Vec<u32> = parse_depends(&pick("depends", 4)).into_iter().filter(|d| *d != n).collect();
            order.insert(n, (clean(&pick("goal", 1)), clean(&pick("level", 2)), tier, deps, clean(&pick("owner", 5)), clean(&pick("status", 6)), clean(&pick("repo", usize::MAX))));
        }
    }
    let mut sessions = Vec::new();
    for (h, a, b) in &secs {
        let Some(rest) = h.strip_prefix("Session ") else { continue };
        let (num, goal) = rest.split_once(':').unwrap_or((rest, ""));
        let Ok(n) = num.trim().parse::<u32>() else { continue };
        let body = &lines[*a..*b];
        let mut s = PlanSession { n, goal: clean(goal), ..PlanSession::default() };
        if let Some((g, level, tier, dep, owner, status, _)) = order.get(&n) {
            if s.goal.is_empty() {
                s.goal = g.clone();
            }
            s.level = level.clone();
            s.tier = *tier;
            s.depends_on = dep.clone();
            s.owner = owner.clone();
            s.status = status.clone();
        }
        for (i, _) in body.iter().enumerate() {
            if let Some(v) = field_value(body, i, "Level and tier") {
                let v = clean(&v);
                if !v.is_empty() {
                    let (level, tier) = v.split_once(',').unwrap_or((&v, ""));
                    if s.level.is_empty() {
                        s.level = level.trim().to_string();
                    }
                    if s.tier == 0 {
                        s.tier = tier.chars().find(|c| c.is_ascii_digit()).and_then(|c| c.to_digit(10)).unwrap_or(0) as u8;
                    }
                }
            } else if field_value(body, i, "Load first").is_some() {
                s.load_first = list_after(body, i);
            } else if field_value(body, i, "Prompt").is_some() {
                s.prompt = fence_after(body, i);
            } else if field_value(body, i, "Done when").is_some() {
                s.done_when = list_after(body, i);
            } else if let Some(v) = field_value(body, i, "Depends on") {
                if s.depends_on.is_empty() && !placeholder(&v) {
                    s.depends_on = parse_depends(&v).into_iter().filter(|d| *d != n).collect();
                }
            } else if let Some(v) = field_value(body, i, "Pull request") {
                s.pr = clean(&v);
            } else if let Some(v) = field_value(body, i, "Stopped early") {
                let v = clean(&v);
                if !v.starts_with("(Remove") {
                    s.stopped_early = v;
                }
            }
        }
        // The order table's Repository column wins, then the repositories the
        // prompt names, then the plan's first.
        let listed = order.get(&n).map(|t| t.6.clone()).filter(|r| !r.is_empty()).map(|r| if r.starts_with("code/") { r } else { format!("code/{r}") });
        let mentioned = s.load_first.iter().chain(std::iter::once(&s.prompt)).find_map(|t| repo_in(t));
        s.repo = listed.or(mentioned).or_else(|| plan.repos.first().cloned()).unwrap_or_default();
        let repo_dir = ws.join(&s.repo);
        s.folder = if !s.repo.is_empty() && is_repo(&repo_dir) {
            repo_dir.to_string_lossy().into_owned()
        } else {
            ws.to_string_lossy().into_owned()
        };
        if s.status.is_empty() {
            s.status = "Not started".to_string();
        }
        sessions.push(s);
    }
    sessions.sort_by_key(|s| s.n);
    plan.sessions = sessions;
    Some(plan)
}

fn mtime(path: &Path) -> u64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The app's display name: its notebook's first heading (`# Contact
/// Center`), else the slug.
pub fn app_display(ws: &Path, app: &str) -> String {
    let text = fs::read_to_string(ws.join("app-notebooks").join(app).join("CLAUDE.md")).unwrap_or_default();
    text.lines()
        .find_map(|l| l.strip_prefix("# "))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| app.to_string())
}

/// The feature's PRD: `(path, major, minor, source)`. The one the plan
/// names, else the newest named after the feature
/// (`{App}_{Feature}_PRD_V…`), else the app's own (`{App}_App_PRD_V…`),
/// since a full-app PRD covers its features (policy 5.2).
pub fn prd_file(ws: &Path, app: &str, slug: &str, named: &str, pick: &str) -> Option<(PathBuf, u32, u32, &'static str)> {
    let all = all_prds(ws);
    // v2.2: the family the feature was pointed at, its newest version.
    let pick_l = pick.trim().to_ascii_lowercase();
    if !pick_l.is_empty() {
        let needle = format!("{pick_l}_prd_v");
        if let Some((p, _, a, b, _)) = all.iter().find(|(_, n, _, _, _)| n.starts_with(&needle)) {
            return Some((p.clone(), *a, *b, "picked"));
        }
    }
    let named_l = named.trim().trim_matches('`').to_ascii_lowercase();
    if !named_l.is_empty() {
        if let Some((p, _, a, b, _)) = all.iter().find(|(_, n, _, _, _)| *n == named_l) {
            return Some((p.clone(), *a, *b, "plan"));
        }
    }
    let feature_needle = format!("_{}_prd_v", slug.to_ascii_lowercase().replace('-', "_"));
    if let Some((p, _, a, b, _)) = all.iter().find(|(_, n, _, _, _)| n.contains(&feature_needle)) {
        return Some((p.clone(), *a, *b, "feature"));
    }
    let app_needle = format!("{}_app_prd_v", app_display(ws, app).to_ascii_lowercase().replace(' ', "_").replace('&', "and"));
    if let Some((p, _, a, b, _)) = all.iter().find(|(_, n, _, _, _)| n.contains(&app_needle)) {
        return Some((p.clone(), *a, *b, "app"));
    }
    None
}

/// Every `…_PRD_V….md` under torch-product: `(path, lowercased name,
/// major, minor, patch rank)`, newest first.
fn all_prds(ws: &Path) -> Vec<(PathBuf, String, u32, u32, u32)> {
    let mut all: Vec<(PathBuf, String, u32, u32, u32)> = Vec::new();
    walk_prds(&ws.join("torch-product"), 0, &mut |path| {
        let name = path.file_name().map(|n| n.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        if !name.contains("_prd_v") {
            return;
        }
        let ver = name.rsplit("_prd_v").next().unwrap_or("").trim_end_matches(".md");
        let mut it = ver.split('.');
        let major: u32 = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        let minor: u32 = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        // A third number when there is one; a suffix like `_delta` ranks below the plain file.
        let patch: u32 = it.next().and_then(|s| s.split('_').next()).and_then(|s| s.parse().ok()).map(|p: u32| if ver.contains('_') { p * 2 } else { p * 2 + 1 }).unwrap_or(1);
        all.push((path.to_path_buf(), name, major, minor, patch));
    });
    all.sort_by_key(|(_, _, a, b, c)| std::cmp::Reverse((*a, *b, *c)));
    all
}

/// v2.2: the PRD families of the workspace (the part of the file name
/// before `_PRD_V`), the newest version of each, the app's own first.
pub fn prd_choices(ws: &Path, app: &str, pick: &str) -> Vec<Value> {
    let app_l = app_display(ws, app).to_ascii_lowercase().replace(' ', "_").replace('&', "and");
    let pick_l = pick.trim().to_ascii_lowercase();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut out: Vec<Value> = Vec::new();
    for (p, n, a, _, _) in all_prds(ws) {
        let Some(i) = n.find("_prd_v") else { continue };
        if !seen.insert(n[..i].to_string()) {
            continue;
        }
        let file = p.file_name().map(|x| x.to_string_lossy().into_owned()).unwrap_or_default();
        let stem = file.get(..i).unwrap_or(&file).to_string();
        let version = n[i + "_prd_v".len()..].trim_end_matches(".md").to_ascii_uppercase();
        let folder = p.parent().and_then(|d| d.strip_prefix(ws).ok()).map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
        out.push(json!({
            "stem": stem,
            "display": stem.replace('_', " "),
            "file": file,
            "folder": folder,
            "version": format!("V{version}"),
            "signed": a >= 1,
            "app": n[..i].starts_with(&app_l),
            "current": !pick_l.is_empty() && n[..i] == pick_l,
        }));
    }
    out.sort_by_key(|v| !v["app"].as_bool().unwrap_or(false));
    out
}

/// v2.6: a code repository ready for a session of the feature: on the
/// feature branch, made from main and pushed when it did not exist
/// (policy 7.2, as new-feature.sh does). Refuses a dirty working tree
/// that is not on the branch. Returns what it did.
pub fn prepare_repo(repo: &Path, branch: &str) -> Result<String, String> {
    if !is_repo(repo) {
        return Err(format!("{} is not a git repository", repo.display()));
    }
    // These run on their own clock: the daemon's "git is blocked" marker
    // (set when some other call hung) must not read as a dirty tree.
    let g = |args: &[&str], secs: u64| git_now(repo, args, secs);
    let on = g(&["branch", "--show-current"], 20).ok_or_else(|| format!("git did not answer in {}", repo.display()))?;
    if on == branch {
        return Ok("already on the branch".to_string());
    }
    let status = g(&["status", "--porcelain", "--untracked-files=no"], 40).ok_or_else(|| format!("git status did not answer in {}", repo.display()))?;
    if !status.trim().is_empty() {
        return Err(format!("{} has uncommitted changes on '{}'; commit or stash them so the session can switch to {branch}", repo.display(), if on.is_empty() { "a detached HEAD" } else { &on }));
    }
    let _ = g(&["fetch", "--quiet", "origin"], 60);
    let local = g(&["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")], 20).is_some();
    let remote = g(&["rev-parse", "--verify", "--quiet", &format!("refs/remotes/origin/{branch}")], 20).is_some();
    if local {
        g(&["switch", "--quiet", branch], 40).ok_or_else(|| format!("could not switch {} to {branch}", repo.display()))?;
        if remote {
            let _ = g(&["pull", "--quiet", "--ff-only"], 60);
        }
        return Ok("switched to the branch".to_string());
    }
    if remote {
        g(&["switch", "--quiet", "--track", "-c", branch, &format!("origin/{branch}")], 40).ok_or_else(|| format!("could not check out origin/{branch} in {}", repo.display()))?;
        return Ok("checked out the branch from origin".to_string());
    }
    let base = ["origin/main", "main", "origin/master", "master"].into_iter().find(|b| g(&["rev-parse", "--verify", "--quiet", b], 20).is_some()).ok_or_else(|| format!("{} has no main branch to branch from", repo.display()))?;
    g(&["switch", "--quiet", "-c", branch, base], 40).ok_or_else(|| format!("could not create {branch} in {}", repo.display()))?;
    if g(&["remote", "get-url", "origin"], 20).is_some() {
        if g(&["push", "--quiet", "-u", "origin", branch], 90).is_none() {
            return Ok(format!("created the branch from {base}; the push failed, so the pull request will need it pushed"));
        }
        return Ok(format!("created the branch from {base} and pushed it"));
    }
    Ok(format!("created the branch from {base}"))
}

/// v2.8: a worktree of the repository `repo_rel` (under the workspace)
/// for one session or review: `code/.worktrees/<repo>-<tag>` on `branch`,
/// made from `base` (origin's copy when it has one) unless the branch
/// already exists. Sessions in one repository then run side by side.
pub fn worktree_for(ws: &Path, repo_rel: &str, tag: &str, branch: &str, base: &str) -> Result<PathBuf, String> {
    let repo = ws.join(repo_rel);
    if !is_repo(&repo) {
        return Err(format!("{repo_rel} is not a git repository"));
    }
    let name = format!("{}-{tag}", repo_rel.rsplit('/').next().unwrap_or(repo_rel));
    let wt = ws.join("code").join(".worktrees").join(&name);
    // Kept out of torch-main's status (a local exclude, never committed).
    let exclude = ws.join(".git").join("info").join("exclude");
    if let Ok(text) = fs::read_to_string(&exclude) {
        if !text.lines().any(|l| l.trim() == "code/.worktrees/") {
            let _ = fs::write(&exclude, format!("{}\ncode/.worktrees/\n", text.trim_end()));
        }
    } else {
        let _ = fs::create_dir_all(exclude.parent().unwrap_or(ws));
        let _ = fs::write(&exclude, "code/.worktrees/\n");
    }
    if wt.join(".git").exists() {
        // Already there: the branch it is on stays; a fast-forward from origin when possible.
        let _ = git_now(&wt, &["pull", "--quiet", "--ff-only"], 60);
        return Ok(wt);
    }
    let _ = git_now(&repo, &["worktree", "prune"], 20);
    let _ = git_now(&repo, &["fetch", "--quiet", "origin"], 60);
    let _ = fs::create_dir_all(wt.parent().unwrap_or(ws));
    let wt_s = wt.to_string_lossy().into_owned();
    let have_branch = git_now(&repo, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")], 20).is_some();
    let have_remote = git_now(&repo, &["rev-parse", "--verify", "--quiet", &format!("refs/remotes/origin/{branch}")], 20).is_some();
    let start = if git_now(&repo, &["rev-parse", "--verify", "--quiet", &format!("refs/remotes/origin/{base}")], 20).is_some() { format!("origin/{base}") } else { base.to_string() };
    let ok = if have_branch {
        git_now(&repo, &["worktree", "add", "--quiet", &wt_s, branch], 60).is_some()
    } else if have_remote {
        git_now(&repo, &["worktree", "add", "--quiet", "--track", "-b", branch, &wt_s, &format!("origin/{branch}")], 60).is_some()
    } else {
        git_now(&repo, &["worktree", "add", "--quiet", "-b", branch, &wt_s, &start], 60).is_some()
    };
    if !ok {
        return Err(format!("could not make a worktree of {repo_rel} for {branch}"));
    }
    Ok(wt)
}

/// v2.8: a worktree that is no longer needed (its session merged).
pub fn remove_worktree(ws: &Path, repo_rel: &str, tag: &str) {
    let repo = ws.join(repo_rel);
    let name = format!("{}-{tag}", repo_rel.rsplit('/').next().unwrap_or(repo_rel));
    let wt = ws.join("code").join(".worktrees").join(&name);
    if wt.exists() {
        let _ = git_now(&repo, &["worktree", "remove", "--force", &wt.to_string_lossy()], 60);
        let _ = fs::remove_dir_all(&wt);
        let _ = git_now(&repo, &["worktree", "prune"], 20);
    }
}

/// `git <args>` in `dir` with its own timeout, ignoring the blocked
/// marker and never setting it: for work that must not be mistaken
/// for a hang elsewhere.
fn git_now(dir: &Path, args: &[&str], secs: u64) -> Option<String> {
    let mut child = Command::new(git_bin())
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .envs(crate::github::envs())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut out = String::new();
                if let Some(mut so) = child.stdout.take() {
                    use std::io::Read;
                    let _ = so.read_to_string(&mut out);
                }
                return if status.success() { Some(out.trim().to_string()) } else { None };
            }
            Ok(None) if started.elapsed() < Duration::from_secs(secs) => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

/// v2.3: the design system a feature follows, read from
/// `DESIGN_SYSTEM.md` in its folder (a `| Field | Value |` table with
/// System, Repository, Checkout and Reference). Glare, the policy's
/// default, when there is no record.
pub fn design_system(ws: &Path, feature_dir: &Path) -> Value {
    let mut name = String::new();
    let mut repo = String::new();
    let mut dir = String::new();
    let mut reference = String::new();
    let present = match read_lines(&feature_dir.join("DESIGN_SYSTEM.md")) {
        Some(text) => {
            for l in text.lines() {
                let c = cells(l);
                if c.len() < 2 {
                    continue;
                }
                let v = c[1].trim().trim_matches('`').to_string();
                match c[0].trim().to_ascii_lowercase().as_str() {
                    "system" => name = v,
                    "repository" => repo = v,
                    "checkout" => dir = v.trim_matches('/').to_string(),
                    "reference" => reference = v,
                    _ => {}
                }
            }
            true
        }
        None => false,
    };
    let glare = !present || name.is_empty() || name.eq_ignore_ascii_case("glare");
    if glare {
        name = "Glare".to_string();
        if reference.is_empty() {
            reference = "context/rules/".to_string();
        }
    }
    let checked_out = dir.is_empty() || ws.join(&dir).is_dir();
    json!({"name": name, "repo": repo, "dir": dir, "reference": reference, "present": present, "checked_out": checked_out, "glare": glare})
}

fn walk_prds(dir: &Path, depth: u8, f: &mut dyn FnMut(&Path)) {
    if depth > 6 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            if !name.starts_with('.') && name != "Archived" && name != "node_modules" {
                walk_prds(&p, depth + 1, f);
            }
        } else if name.ends_with(".md") {
            f(&p);
        }
    }
}

static DIFFS: Mutex<Vec<(String, Instant, (u64, u64, u64))>> = Mutex::new(Vec::new());

/// `(files, additions, deletions)` of the branch against main, when the
/// repository has it checked out; cached a minute.
fn branch_diff(repo: &Path, branch: &str) -> Option<(u64, u64, u64)> {
    let key = format!("{}#{branch}", repo.display());
    {
        let cache = DIFFS.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((_, at, v)) = cache.iter().find(|(k, _, _)| *k == key) {
            if at.elapsed() < Duration::from_secs(60) {
                return Some(*v);
            }
        }
    }
    if branch_of(&repo.to_string_lossy()) != branch {
        return None;
    }
    let base = ["origin/main", "main", "origin/master", "master"]
        .into_iter()
        .find(|b| git(repo, &["rev-parse", "--verify", "--quiet", b]).is_some())?;
    let mb = git(repo, &["merge-base", base, "HEAD"])?;
    let stat = git(repo, &["diff", "--shortstat", &mb])?;
    let mut files = 0;
    let mut add = 0;
    let mut del = 0;
    for part in stat.split(',') {
        let n: u64 = part.trim().split_whitespace().next().and_then(|s| s.parse().ok()).unwrap_or(0);
        if part.contains("file") {
            files = n;
        } else if part.contains("insertion") {
            add = n;
        } else if part.contains("deletion") {
            del = n;
        }
    }
    let v = (files, add, del);
    let mut cache = DIFFS.lock().unwrap_or_else(|p| p.into_inner());
    cache.retain(|(k, _, _)| *k != key);
    cache.push((key, Instant::now(), v));
    Some(v)
}

/// Six hex digits of FNV-1a, to tell workspaces apart in an id.
fn short_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{:06x}", h & 0xff_ffff)
}

/// The handoff folder as an artifact the console and phones can read.
fn link_handoff(id: &str, handoff: &Path) {
    let link = artifacts::dir(id);
    if !handoff.is_dir() {
        return;
    }
    if fs::read_link(&link).ok().as_deref() == Some(handoff) {
        return;
    }
    let _ = fs::remove_file(&link);
    let _ = fs::create_dir_all(artifacts::root());
    #[cfg(unix)]
    let _ = std::os::unix::fs::symlink(handoff, &link);
}

static FEATURES: Mutex<Vec<(PathBuf, Instant, Vec<Feature>)>> = Mutex::new(Vec::new());
/// The last successful read per workspace, for when the folder is out of
/// reach.
static LAST_KNOWN: Mutex<Vec<(PathBuf, Vec<Feature>)>> = Mutex::new(Vec::new());

pub fn last_known(ws: &Path) -> Vec<Feature> {
    LAST_KNOWN
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
        .find(|(p, _)| p == ws)
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

/// Forgets cached records (after a write).
pub fn invalidate() {
    FEATURES.lock().unwrap_or_else(|p| p.into_inner()).clear();
}

/// Every feature of the workspace with its records, cached a few seconds.
pub fn features(ws: &Path) -> Vec<Feature> {
    {
        let cache = FEATURES.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((_, at, v)) = cache.iter().find(|(p, _, _)| p == ws) {
            if at.elapsed() < Duration::from_secs(3) {
                return v.clone();
            }
        }
    }
    let out = read_features(ws);
    {
        let mut last = LAST_KNOWN.lock().unwrap_or_else(|p| p.into_inner());
        last.retain(|(p, _)| p != ws);
        last.push((ws.to_path_buf(), out.clone()));
    }
    let mut cache = FEATURES.lock().unwrap_or_else(|p| p.into_inner());
    cache.retain(|(p, _, _)| p != ws);
    cache.push((ws.to_path_buf(), Instant::now(), out.clone()));
    out
}

fn read_features(ws: &Path) -> Vec<Feature> {
    let repos_by_app = app_repos(ws);
    let mut out = Vec::new();
    for app in apps(ws) {
        let features_dir = ws.join("app-notebooks").join(&app).join("features");
        let Ok(rd) = fs::read_dir(&features_dir) else { continue };
        let mut slugs: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect();
        slugs.sort();
        for slug in slugs {
            let dir = features_dir.join(&slug);
            let rel = format!("app-notebooks/{app}/features/{slug}");
            let light = dir.join("LIGHT_PATH.md").is_file() && !dir.join("SESSION_PLAN.md").is_file();
            let plan = parse_plan(ws, &dir, &rel);
            let branch = plan
                .as_ref()
                .map(|p| p.branch.clone())
                .filter(|b| !b.is_empty())
                .unwrap_or_else(|| format!("{}/{app}-{slug}", if light { "fix" } else { "feature" }));
            let mut repos: Vec<String> = plan.as_ref().map(|p| p.repos.clone()).unwrap_or_default();
            if repos.is_empty() {
                repos = repos_by_app.get(&app).cloned().unwrap_or_default();
            }
            let fetched: Vec<String> = repos.iter().filter(|r| is_repo(&ws.join(r))).cloned().collect();
            let handoff_dir = dir.join("handoff");
            let mut handoff_files: Vec<String> = fs::read_dir(&handoff_dir)
                .map(|rd| {
                    rd.flatten()
                        .filter(|e| e.path().is_file())
                        .map(|e| e.file_name().to_string_lossy().into_owned())
                        .filter(|n| !n.starts_with('.'))
                        .collect()
                })
                .unwrap_or_default();
            handoff_files.sort();
            let handoff_id = format!("handoff-{app}-{slug}-{}", short_hash(&ws.to_string_lossy()))
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
                .collect::<String>();
            if !handoff_files.is_empty() {
                link_handoff(&handoff_id, &handoff_dir);
            }
            let open_questions = read_lines(&dir.join("OPEN_QUESTIONS.md"))
                .map(|t| {
                    t.lines()
                        .filter(|l| {
                            let c = cells(l);
                            c.len() >= 6 && c[0].parse::<u32>().is_ok() && !clean(&c[1]).is_empty() && clean(&c[5]).is_empty()
                        })
                        .count() as u32
                })
                .unwrap_or(0);
            let named = plan.as_ref().map(|p| p.prd.clone()).unwrap_or_default();
            let pick = crate::flow::picked_prd(ws, &format!("{app}/{slug}"));
            let (prd, prd_signed, prd_source) = match prd_file(ws, &app, &slug, &named, &pick) {
                Some((path, major, _, source)) => (path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), major >= 1, source.to_string()),
                None => (String::new(), false, String::new()),
            };
            let mut gates = Vec::new();
            if light {
                gates.push(light_gate(&dir, &rel));
            } else {
                gates.extend(handoff_gates(&dir, &rel));
                let reviewed = plan.as_ref().map(|p| !p.reviewed_by.is_empty()).unwrap_or(false);
                gates.push(Gate {
                    id: "plan".to_string(),
                    checklist: String::new(),
                    title: "Session plan reviewed".to_string(),
                    step: 8,
                    file: format!("{rel}/SESSION_PLAN.md"),
                    roles: vec!["Tech lead".to_string()],
                    signatures: if reviewed {
                        vec![json!({"role": "Tech lead", "name": plan.as_ref().map(|p| p.reviewed_by.clone()).unwrap_or_default()})]
                    } else {
                        Vec::new()
                    },
                    signed: reviewed,
                    present: plan.is_some(),
                    ..Gate::default()
                });
                gates.extend(release_gates(&dir, &rel));
            }
            let mut diff = (0, 0, 0);
            for r in &fetched {
                if let Some(d) = branch_diff(&ws.join(r), &branch) {
                    diff.0 += d.0;
                    diff.1 += d.1;
                    diff.2 += d.2;
                }
            }
            let too_big = light && (diff.0 > 15 || diff.1 > 400);
            let mut warnings = Vec::new();
            let design = design_system(ws, &dir);
            if design["present"].as_bool() == Some(true) && design["checked_out"].as_bool() == Some(false) {
                warnings.push(format!(
                    "The design system checkout {} is missing. Clone {} there.",
                    design["dir"].as_str().unwrap_or(""),
                    design["repo"].as_str().filter(|r| !r.is_empty()).unwrap_or("its repository")
                ));
            }
            if too_big {
                warnings.push(format!(
                    "Bigger than a light path: {} files, {} lines added. Policy 11: stop and move to the full flow.",
                    diff.0, diff.1
                ));
            }
            if !light && plan.is_some() && !prd_signed {
                warnings.push("A session plan exists but no signed PRD (V1.0 or later) was found.".to_string());
            }
            let updated = [
                "SESSION_PLAN.md",
                "RELEASE.md",
                "HANDOFF_CHECKLIST.md",
                "LIGHT_PATH.md",
                "OPEN_QUESTIONS.md",
                "DESIGN_SYSTEM.md",
            ]
            .iter()
            .map(|f| mtime(&dir.join(f)))
            .max()
            .unwrap_or(0);
            let sync = sync_state(ws, &branch);
            let branches: Vec<String> = fetched.iter().filter(|r| git(&ws.join(r), &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")]).is_some()).cloned().collect();
            let mut f = Feature {
                sync,
                branches,
                key: format!("{app}/{slug}"),
                app: app.clone(),
                slug: slug.clone(),
                branch,
                light,
                workspace: ws.to_string_lossy().into_owned(),
                dir: rel,
                gates,
                plan,
                handoff_files,
                handoff_id,
                open_questions,
                repos,
                fetched_repos: fetched,
                prd,
                prd_signed,
                prd_source,
                design,
                warnings,
                diff_files: diff.0,
                diff_additions: diff.1,
                too_big,
                updated,
                ..Feature::default()
            };
            compute_step(&mut f);
            out.push(f);
        }
    }
    out
}

/// Where the feature stands: the first gate not passed (policy section 4).
fn compute_step(f: &mut Feature) {
    let gate = |id: &str| f.gates.iter().find(|g| g.id == id).map(|g| g.signed).unwrap_or(false);
    if f.light {
        let items: Vec<bool> = f.gates.first().map(|g| g.items.iter().map(|i| i.checked).collect()).unwrap_or_default();
        let labels = ["Describe the change", "Agree it is small", "Self-check and review", "Staging", "Release"];
        let first_open = items.iter().position(|c| !c).unwrap_or(items.len());
        let signed = gate("light");
        f.released = signed && first_open >= items.len();
        f.step = (first_open.min(labels.len() - 1) + 1) as u8;
        f.step_label = if f.released { "Released".to_string() } else { labels[first_open.min(labels.len() - 1)].to_string() };
        if let Some(p) = &f.plan {
            f.sessions_total = p.sessions.len() as u32;
        }
        return;
    }
    let (total, merged) = f
        .plan
        .as_ref()
        .map(|p| (p.sessions.len() as u32, p.sessions.iter().filter(|s| s.status.eq_ignore_ascii_case("merged")).count() as u32))
        .unwrap_or((0, 0));
    f.sessions_total = total;
    f.sessions_merged = merged;
    let checks: [(u8, bool); 11] = [
        (1, !f.prd.is_empty()),
        (3, f.prd_signed),
        (4, !f.handoff_files.is_empty()),
        (5, gate("handoff1")),
        (6, gate("handoff2")),
        (7, gate("intake")),
        (8, gate("plan")),
        (9, total > 0 && merged == total),
        (10, gate("staging")),
        (11, gate("uat")),
        (12, gate("production")),
    ];
    let mut step = 1u8;
    let mut all = true;
    for (s, ok) in checks {
        if ok {
            step = s + 1;
        } else {
            all = false;
            step = s;
            break;
        }
    }
    f.released = all;
    f.step = step.min(12);
    f.step_label = if f.released { "Released".to_string() } else { STEPS[(f.step - 1) as usize].to_string() };
}

// ---------------------------------------------------------------------------
// live data: sessions and pull requests
// ---------------------------------------------------------------------------

/// Policy tier of a model name: 1 for the strongest, 3 for the lightest,
/// 0 when unknown.
pub fn tier_of(model: &str) -> u8 {
    let m = model.to_ascii_lowercase();
    if m.contains("haiku") {
        3
    } else if m.contains("sonnet") {
        2
    } else if m.contains("opus") || m.contains("fable") || m.contains("mythos") {
        1
    } else {
        0
    }
}

fn norm(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_ascii_lowercase()
}

/// Which plan session a live session runs, from its first prompt.
fn match_prompt(plan: &Plan, first_prompt: &str) -> Option<u32> {
    let fp = norm(first_prompt);
    if fp.len() < 20 {
        return None;
    }
    for s in &plan.sessions {
        let p = norm(&s.prompt);
        if p.len() < 20 {
            continue;
        }
        let head: String = p.chars().take(80).collect();
        if fp.starts_with(&head) || fp.contains(&head) {
            return Some(s.n);
        }
    }
    None
}

/// `(feature key, plan session)` for a live session, from its folder,
/// branch and first prompt.
pub fn match_session(cwd: &str, branch: &str, first_prompt: &str) -> (String, u32) {
    let Some(ws) = workspace_for(cwd) else { return (String::new(), 0) };
    remember_workspace(&ws);
    let Some((app, slug, _)) = parse_branch(&ws, branch) else { return (String::new(), 0) };
    let dir = ws.join("app-notebooks").join(&app).join("features").join(&slug);
    if !dir.is_dir() {
        return (String::new(), 0);
    }
    let key = format!("{app}/{slug}");
    let n = parse_plan(&ws, &dir, "").and_then(|p| match_prompt(&p, first_prompt)).unwrap_or(0);
    (key, n)
}

/// Fills the live part of a feature's plan from the sessions the daemon
/// knows and the pull requests into the feature branch.
pub fn enrich(f: &mut Feature, sessions: &[Session], prs: &[Value]) {
    let Some(plan) = f.plan.as_mut() else { return };
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let mut merged = 0u32;
    for ps in &mut plan.sessions {
        // The pull request: named in the plan, or titled "Session N".
        let needle_a = format!("session {}:", ps.n);
        let needle_b = format!("session {} ", ps.n);
        let needle_c = format!("session {}\n", ps.n);
        let pr = prs.iter().find(|p| !ps.pr.is_empty() && s(p, "url") == ps.pr.trim_matches(|c| c == '<' || c == '>')).or_else(|| {
            prs.iter().find(|p| {
                let t = format!("{}\n{}", s(p, "title").to_ascii_lowercase(), s(p, "body").to_ascii_lowercase());
                t.starts_with(&needle_a) || t.starts_with(&needle_b) || t.contains(&needle_c) || t.contains(&format!("\n{needle_b}")) || t.contains(&format!("\n{needle_a}"))
            })
        });
        if let Some(pr) = pr {
            ps.pr_state = s(pr, "state").to_ascii_lowercase();
            ps.pr_url = s(pr, "url");
            ps.pr_number = pr.get("number").and_then(Value::as_u64).unwrap_or(0);
            if ps.pr.is_empty() {
                ps.pr = ps.pr_url.clone();
            }
        }
        let live: Vec<&Session> = sessions.iter().filter(|x| x.feature == f.key && x.plan_session == ps.n).collect();
        ps.attempts = live.len() as u32;
        ps.running = live.iter().any(|x| matches!(x.state.as_str(), "working" | "waiting"));
        ps.live = live
            .iter()
            .map(|x| json!({"id": x.id, "short": x.short, "state": x.state, "model": x.model, "tier": x.tier, "title": x.title, "desktop": x.desktop}))
            .collect();
        for x in &live {
            if x.tier != 0 && ps.tier != 0 && x.tier > ps.tier {
                ps.warnings.push(format!("Running at Tier {} while the plan says Tier {} (a session may only move up).", x.tier, ps.tier));
                break;
            }
        }
        if ps.attempts >= 3 && ps.pr_state != "merged" {
            ps.warnings.push("Third attempt. Policy 9.1: after two failures at a tier, repeat one tier up; never the same prompt a third time.".to_string());
        } else if ps.attempts == 2 && ps.pr_state != "merged" && !ps.running {
            ps.warnings.push("Failed twice? The next attempt goes one tier up (policy 9.1).".to_string());
        }
        let status = ps.status.to_ascii_lowercase();
        ps.effective = if ps.pr_state == "merged" || status == "merged" {
            "merged".to_string()
        } else if ps.pr_state == "open" || status == "in review" {
            "review".to_string()
        } else if status == "blocked" {
            "blocked".to_string()
        } else if ps.running || status == "in progress" {
            "progress".to_string()
        } else {
            "ready".to_string()
        };
        if ps.effective == "merged" {
            merged += 1;
        }
    }
    // Dependencies not merged yet hold a session back.
    let merged_set: HashSet<u32> = plan.sessions.iter().filter(|p| p.effective == "merged").map(|p| p.n).collect();
    for ps in &mut plan.sessions {
        if ps.effective == "ready" {
            let waiting: Vec<String> = ps.depends_on.iter().filter(|d| !merged_set.contains(d)).map(|d| d.to_string()).collect();
            if !waiting.is_empty() {
                ps.effective = "waiting".to_string();
                ps.note = format!("Waits for session {}", waiting.join(", "));
            }
        }
    }
    f.sessions_merged = merged;
    f.sessions_total = plan.sessions.len() as u32;
    if f.sessions_total > 0 && merged == f.sessions_total && f.step == 9 {
        // All merged by their pull requests even if the plan's table lags.
        let mut copy = f.clone();
        if let Some(p) = copy.plan.as_mut() {
            for s in &mut p.sessions {
                s.status = "Merged".to_string();
            }
        }
        compute_step(&mut copy);
        f.step = copy.step;
        f.step_label = copy.step_label;
        f.released = copy.released;
    }
}

// ---------------------------------------------------------------------------
// writing records
// ---------------------------------------------------------------------------

pub fn today() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let days = secs.div_euclid(86_400);
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

fn find_feature(ws: &Path, key: &str) -> Option<Feature> {
    features(ws).into_iter().find(|f| f.key == key)
}

/// The section's line range for a gate inside its file.
fn gate_range(lines: &[&str], gate_id: &str) -> (usize, usize) {
    let secs = sections(lines);
    let needle = match gate_id {
        "staging" => "staging",
        "uat" => "uat",
        "production" => "production",
        "handoff1" => "part 1",
        "handoff2" => "part 2",
        "intake" => "intake",
        _ => "",
    };
    if needle.is_empty() {
        return (0, lines.len());
    }
    secs.iter()
        .find(|(h, _, _)| h.to_ascii_lowercase().starts_with(needle))
        .map(|(_, a, b)| (*a, *b))
        .unwrap_or((0, lines.len()))
}

/// Commits one file of the workspace when it is on the feature's branch.
/// `git <args>` that may take a while (fetch, pull, push): 40 s.
pub fn git_long(dir: &Path, args: &[&str]) -> Option<String> {
    if git_blocked() {
        return None;
    }
    let mut child = Command::new(git_bin())
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .envs(crate::github::envs())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < Duration::from_secs(40) => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// `git fetch origin`, quietly (v2.0).
pub fn fetch(ws: &Path) {
    if git(ws, &["remote", "get-url", "origin"]).is_some() {
        let _ = git_long(ws, &["fetch", "-q", "origin"]);
    }
}

/// Before a record is written on a shared branch: the remote's commits
/// come in first (rebase, local changes stashed around it). Quiet when
/// there is no remote or nothing to do; the reason when it failed.
pub fn sync_pull(ws: &Path, branch: &str) -> Result<(), String> {
    if branch_of(&ws.to_string_lossy()) != branch {
        return Ok(());
    }
    if git(ws, &["rev-parse", "--verify", "--quiet", &format!("refs/remotes/origin/{branch}")]).is_none() {
        return Ok(());
    }
    match git_long(ws, &["pull", "-q", "--rebase", "--autostash", "origin", branch]) {
        Some(_) => Ok(()),
        None => {
            let _ = git(ws, &["rebase", "--abort"]);
            Err(format!("Could not pull origin/{branch} (a conflict, or no network). The record was written locally."))
        }
    }
}

/// Ahead / behind the remote for a branch, after the last fetch.
pub fn sync_state(ws: &Path, branch: &str) -> Value {
    if git(ws, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")]).is_none() {
        return json!({"remote": false, "ahead": 0, "behind": 0, "local": false});
    }
    let remote = git(ws, &["rev-parse", "--verify", "--quiet", &format!("refs/remotes/origin/{branch}")]).is_some();
    if !remote {
        return json!({"remote": false, "ahead": 0, "behind": 0, "local": true});
    }
    let counts = git(ws, &["rev-list", "--left-right", "--count", &format!("origin/{branch}...{branch}")]).unwrap_or_default();
    let mut it = counts.split_whitespace();
    let behind: u64 = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let ahead: u64 = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    json!({"remote": true, "ahead": ahead, "behind": behind, "local": true})
}

/// Commits the files on the feature branch and pushes them: the commit's
/// hash, or why not. The push is best effort (the ahead count shows it).
pub fn commit_files(ws: &Path, branch: &str, files: &[String], message: &str) -> Result<String, String> {
    let on = branch_of(&ws.to_string_lossy());
    if on != branch {
        return Err(format!("torch-main is on '{}', not {branch}", if on.is_empty() { "?" } else { &on }));
    }
    let _ = sync_pull(ws, branch);
    let mut args: Vec<&str> = vec!["add", "--"];
    args.extend(files.iter().map(String::as_str));
    if git(ws, &args).is_none() {
        return Err(if git_blocked() { FOLDER_ACCESS_HINT.to_string() } else { "git add failed".to_string() });
    }
    let mut args: Vec<&str> = vec!["commit", "-q", "-m", message, "--"];
    args.extend(files.iter().map(String::as_str));
    if git(ws, &args).is_none() {
        return Err(if git_blocked() { FOLDER_ACCESS_HINT.to_string() } else { "git commit failed (nothing to commit, or no git identity)".to_string() });
    }
    let hash = git(ws, &["rev-parse", "HEAD"]).unwrap_or_default();
    if git(ws, &["remote", "get-url", "origin"]).is_some() {
        let _ = git_long(ws, &["push", "-q", "-u", "origin", branch]);
    }
    Ok(hash)
}

/// Signs a gate: ticks the items the signer confirmed (`checks`, by index)
/// and writes the name and today's date into the signature table. The
/// file is committed when the workspace is on the feature branch.
pub fn sign(ws: &Path, key: &str, gate_id: &str, role: &str, name: &str, checks: &[bool]) -> Result<Value, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("A name is needed for the signature".to_string());
    }
    let f = find_feature(ws, key).ok_or_else(|| format!("No feature {key} in this workspace"))?;
    let gate = f.gates.iter().find(|g| g.id == gate_id).ok_or_else(|| format!("No gate {gate_id}"))?;
    let path = ws.join(&gate.file);
    let text = fs::read_to_string(&path).map_err(|_| format!("{} is missing. Create it from context/templates first.", gate.file))?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
    let (a, b) = gate_range(&refs, gate_id);
    let date = today();
    let mut ticked: Vec<usize> = Vec::new();
    if gate_id == "plan" {
        let mut done = false;
        for l in lines.iter_mut() {
            let c = cells(l);
            if c.len() >= 2 && c[0].eq_ignore_ascii_case("reviewed by tech lead") {
                *l = format!("| Reviewed by tech lead | {name}, {date} |");
                done = true;
                break;
            }
        }
        if !done {
            return Err("The plan has no 'Reviewed by tech lead' row".to_string());
        }
    } else {
        // Tick the confirmed items (never untick), remembering which.
        let boxes = checkboxes(&refs[a..b]);
        for (i, (line, _, checked)) in boxes.iter().enumerate() {
            if checks.get(i).copied().unwrap_or(false) && !checked {
                let l = &mut lines[a + line];
                if let Some(pos) = l.find("- [ ]") {
                    l.replace_range(pos..pos + 5, "- [x]");
                    ticked.push(i);
                }
            }
        }
        let refs2: Vec<&str> = lines.iter().map(String::as_str).collect();
        if let Some((head, mut row, _, row_i)) = signature_table(&refs2[a..b]) {
            let col = head
                .iter()
                .position(|h| h.eq_ignore_ascii_case(role))
                .ok_or_else(|| format!("This record has no '{role}' column (it asks for: {})", head.iter().filter(|h| !h.eq_ignore_ascii_case("date")).cloned().collect::<Vec<_>>().join(", ")))?;
            row[col] = name.to_string();
            if let Some(dc) = head.iter().position(|h| h.eq_ignore_ascii_case("date")) {
                if clean(&row[dc]).is_empty() {
                    row[dc] = date.clone();
                }
            }
            let new_line = format!("| {} |", row.join(" | "));
            let target = a + row_i;
            if target < lines.len() && cells(&lines[target]).len() == head.len() {
                lines[target] = new_line;
            } else {
                lines.insert(target, new_line);
            }
        } else if gate_id != "intake" && gate_id != "handoff1" {
            return Err("No signature table under this checklist".to_string());
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&path, out).map_err(|e| format!("Could not write {}: {e}", gate.file))?;
    invalidate();
    let commit = commit_files(ws, &f.branch, &[gate.file.clone()], &format!("{}: signed by {name} ({role})", gate.title));
    let committed = commit.is_ok();
    crate::flow::journal(ws, key, "sign", &format!("{} signed by {name} ({role})", gate.title), vec![gate.file.clone()], commit.as_deref().unwrap_or(""), true, json!({"gate": gate_id, "role": role, "ticked": ticked}));
    let blocked = git_blocked();
    let fresh = find_feature(ws, key).and_then(|f| f.gates.into_iter().find(|g| g.id == gate_id));
    Ok(json!({
        "ok": true,
        "file": gate.file,
        "committed": committed,
        "signed": fresh.as_ref().map(|g| g.signed).unwrap_or(false),
        "note": if committed { String::new() } else if blocked { format!("Written to {}, not committed: {}", gate.file, FOLDER_ACCESS_HINT) } else { format!("Written to {}. torch-main is not on {}, so it is not committed.", gate.file, f.branch) },
    }))
}

/// Removes a signature: the role's name out of the table (and the date
/// when nobody is left), the items in `untick` back to open. With no
/// table and no `untick`, every item of the gate goes back to open.
pub fn unsign(ws: &Path, key: &str, gate_id: &str, role: &str, untick: &[usize]) -> Result<Value, String> {
    let f = find_feature(ws, key).ok_or_else(|| format!("No feature {key} in this workspace"))?;
    let gate = f.gates.iter().find(|g| g.id == gate_id).ok_or_else(|| format!("No gate {gate_id}"))?;
    let path = ws.join(&gate.file);
    let text = fs::read_to_string(&path).map_err(|_| format!("{} is missing", gate.file))?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
    let (a, b) = gate_range(&refs, gate_id);
    let mut changed = false;
    if gate_id == "plan" {
        for l in lines.iter_mut() {
            let c = cells(l);
            if c.len() >= 2 && c[0].eq_ignore_ascii_case("reviewed by tech lead") && !clean(&c[1]).is_empty() {
                *l = "| Reviewed by tech lead | {name}, {date} |".to_string();
                changed = true;
            }
        }
    } else {
        let boxes = checkboxes(&refs[a..b]);
        let table = signature_table(&refs[a..b]);
        let all_items = untick.is_empty() && table.is_none();
        for (i, (line, _, checked)) in boxes.iter().enumerate() {
            if *checked && (all_items || untick.contains(&i)) {
                let l = &mut lines[a + line];
                if let Some(pos) = l.find("- [x]").or_else(|| l.find("- [X]")) {
                    l.replace_range(pos..pos + 5, "- [ ]");
                    changed = true;
                }
            }
        }
        if let Some((head, mut row, _, row_i)) = table {
            if let Some(col) = head.iter().position(|h| h.eq_ignore_ascii_case(role)) {
                if !clean(&row[col]).is_empty() {
                    row[col] = String::new();
                    changed = true;
                }
                let anyone = head.iter().zip(row.iter()).any(|(h, v)| !h.eq_ignore_ascii_case("date") && !clean(v).is_empty());
                if !anyone {
                    if let Some(dc) = head.iter().position(|h| h.eq_ignore_ascii_case("date")) {
                        row[dc] = String::new();
                    }
                }
                let target = a + row_i;
                if target < lines.len() {
                    lines[target] = format!("| {} |", row.join(" | "));
                }
            } else if !role.is_empty() {
                return Err(format!("This record has no '{role}' column"));
            }
        }
    }
    if !changed {
        return Err("Nothing to remove: that signature is not in the record".to_string());
    }
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&path, out).map_err(|e| format!("Could not write {}: {e}", gate.file))?;
    invalidate();
    let commit = commit_files(ws, &f.branch, &[gate.file.clone()], &format!("{}: signature of {} removed", gate.title, if role.is_empty() { "the items" } else { role }));
    Ok(json!({"ok": true, "file": gate.file, "committed": commit.is_ok(), "note": commit.err().unwrap_or_default()}))
}

/// Sets a session's status (and optional pull request link) in the plan's
/// order table and section, as the owner records it (policy 8.4).
pub fn set_plan_status(ws: &Path, key: &str, n: u32, status: &str, pr: &str) -> Result<Value, String> {
    let f = find_feature(ws, key).ok_or_else(|| format!("No feature {key}"))?;
    let plan = f.plan.as_ref().ok_or_else(|| "This feature has no session plan".to_string())?;
    let path = ws.join(&plan.file);
    let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let mut in_order = false;
    let mut in_session = false;
    let mut changed = false;
    let mut prev = String::new();
    let mut status_col = 6usize;
    for l in lines.iter_mut() {
        if l.starts_with("## ") {
            in_order = l[3..].trim().eq_ignore_ascii_case("order");
            in_session = l[3..].trim().to_ascii_lowercase().starts_with(&format!("session {n}:")) || l[3..].trim().eq_ignore_ascii_case(&format!("session {n}"));
            continue;
        }
        if in_order {
            let mut c = cells(l);
            // The Status column by the table's header (a plan may add a Repository column).
            if c.len() >= 4 && c[0].parse::<u32>().is_err() && c.iter().any(|h| h.trim() == "#") {
                status_col = c.iter().position(|h| h.trim().eq_ignore_ascii_case("status")).unwrap_or(6);
                continue;
            }
            if c.len() > status_col && c[0].parse::<u32>().ok() == Some(n) {
                prev = c[status_col].clone();
                c[status_col] = status.to_string();
                *l = format!("| {} |", c.join(" | "));
                changed = true;
            }
        }
        if in_session && !pr.is_empty() && l.trim().starts_with("**Pull request:**") {
            *l = format!("**Pull request:** {pr}");
            changed = true;
        }
    }
    if !changed {
        return Err(format!("Session {n} is not in the order table"));
    }
    let mut out = lines.join("\n");
    out.push('\n');
    fs::write(&path, out).map_err(|e| e.to_string())?;
    crate::flow::journal(ws, key, "plan_status", &format!("Session {n}: {status}"), vec![plan.file.clone()], "", true, json!({"n": n, "status": status, "prev": prev}));
    invalidate();
    Ok(json!({"ok": true, "file": plan.file}))
}

// ---------------------------------------------------------------------------
// the self-check scan (Checklists F and H, policy 8.5)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub rule: String,
    pub file: String,
    pub line: u32,
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Scan {
    pub ok: bool,
    pub error: String,
    pub base: String,
    pub files: u64,
    pub additions: u64,
    pub deletions: u64,
    pub findings: Vec<Finding>,
    pub counts: Vec<Value>,
}

const MAX_FINDINGS: usize = 120;

fn is_test_file(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    p.contains("/test/") || p.contains("/tests/") || p.contains("__tests__") || p.contains(".test.") || p.contains(".spec.") || p.ends_with("_test.dart") || p.ends_with("_test.rs") || p.ends_with("_test.go") || p.contains("/testdata/")
}

fn is_manifest(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    matches!(name, "package.json" | "Cargo.toml" | "pubspec.yaml" | "requirements.txt" | "go.mod" | "pyproject.toml" | "Gemfile" | "Package.swift")
}

fn looks_like_code(s: &str) -> bool {
    let t = s.trim();
    if t.len() < 6 {
        return false;
    }
    let ends = t.ends_with(';') || t.ends_with('{') || t.ends_with("});") || t.ends_with(") {");
    let starts = ["const ", "let ", "var ", "return ", "if (", "for (", "while (", "import ", "export ", "function ", "await ", "this.", "fn ", "pub ", "def ", "class "];
    (ends && t.contains('(')) || starts.iter().any(|p| t.starts_with(p)) || (t.contains('(') && t.contains(')') && t.contains('='))
}

fn check_added(path: &str, n: u32, line: &str, findings: &mut Vec<Finding>) {
    let t = line.trim();
    let push = |findings: &mut Vec<Finding>, rule: &str| {
        if findings.len() < MAX_FINDINGS {
            findings.push(Finding { rule: rule.to_string(), file: path.to_string(), line: n, text: t.chars().take(160).collect() });
        }
    };
    let upper = t.to_ascii_uppercase();
    if ["TODO", "FIXME", "XXX", "HACK"].iter().any(|w| upper.split(|c: char| !c.is_ascii_alphanumeric()).any(|tok| tok == *w)) {
        push(findings, "todo");
    }
    let lower = t.to_ascii_lowercase();
    if !is_test_file(path) {
        let ext = path.rsplit('.').next().unwrap_or("");
        let debug = match ext {
            "ts" | "tsx" | "js" | "jsx" | "mjs" => lower.contains("console.log(") || lower.contains("console.debug(") || lower.starts_with("debugger"),
            "rs" => t.contains("dbg!(") || (t.contains("println!(") && !path.contains("main.rs") && !path.contains("cli")),
            "dart" => t.starts_with("print(") || t.contains(" print("),
            "py" => t.starts_with("print(") || t.contains("breakpoint()") || t.contains("pdb.set_trace"),
            _ => false,
        };
        if debug {
            push(findings, "debug");
        }
        let comment = t.strip_prefix("//").or_else(|| if matches!(ext, "py" | "rb" | "sh" | "yaml" | "yml") { t.strip_prefix('#') } else { None });
        if let Some(c) = comment {
            if !c.starts_with('/') && !c.starts_with('!') && looks_like_code(c) {
                push(findings, "commented_code");
            }
        }
        if matches!(ext, "ts" | "tsx" | "js" | "jsx" | "css" | "scss" | "html" | "dart" | "swift")
            && !lower.contains("token")
            && !lower.contains("glare")
            && !SCAN_OK_WORDS.lock().unwrap_or_else(|p| p.into_inner()).iter().any(|w| lower.contains(w.as_str()))
            && !lower.contains("--")
            && (has_hex_colour(t) || lower.contains("rgb(") || lower.contains("rgba(") || lower.contains("hsl("))
        {
            push(findings, "hardcoded_colour");
        }
        if (lower.contains("catch") && (t.ends_with("{}") || t.ends_with("{ }"))) || lower.contains("catch (_) {}") || lower.contains("except: pass") || lower.contains("except exception: pass") {
            push(findings, "swallowed_error");
        }
    }
    if lower.contains("lorem ipsum") || lower.contains("placeholder text") || upper.split(|c: char| !c.is_ascii_alphanumeric()).any(|tok| tok == "TBD") {
        push(findings, "placeholder");
    }
    if is_manifest(path) && t.len() > 3 && !t.starts_with('#') && !t.starts_with("//") && (t.contains(": \"") || t.contains(" = \"") || t.contains(": ^") || t.contains(" = {") || t.contains("==") || t.starts_with("gem ") || t.starts_with("require ")) {
        let name_ok = !lower.starts_with("\"name\"") && !lower.starts_with("\"version\"") && !lower.starts_with("name =") && !lower.starts_with("version =") && !lower.starts_with("version:") && !lower.starts_with("description");
        if name_ok {
            push(findings, "dependency");
        }
    }
}

fn has_hex_colour(t: &str) -> bool {
    let b = t.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'#' {
            let run = b[i + 1..].iter().take_while(|c| c.is_ascii_hexdigit()).count();
            if (run == 6 || run == 8 || run == 3) && b.get(i + 1 + run).map(|c| !c.is_ascii_alphanumeric()).unwrap_or(true) {
                return true;
            }
        }
        i += 1;
    }
    false
}

/// Scans the session's changes against the branch they will be reviewed
/// into: the feature branch when the session has its own branch, else
/// main. Working tree included, so the owner sees it before committing.
/// v2.3: words of the feature's design system (its name, its checkout
/// folder) that make a line with a colour acceptable, like "glare" does.
static SCAN_OK_WORDS: Mutex<Vec<String>> = Mutex::new(Vec::new());

pub fn scan(dir: &str, feature_branch: &str, ok_words: &[String]) -> Scan {
    *SCAN_OK_WORDS.lock().unwrap_or_else(|p| p.into_inner()) = ok_words.iter().map(|w| w.trim().to_ascii_lowercase()).filter(|w| w.len() >= 3).collect();
    let repo = Path::new(dir);
    if dir.is_empty() || !repo.is_dir() {
        return Scan { error: "The session's folder is not on this PC".to_string(), ..Scan::default() };
    }
    let Some(top) = git(repo, &["rev-parse", "--show-toplevel"]) else {
        return Scan { error: if git_blocked() { FOLDER_ACCESS_HINT.to_string() } else { "Not a git repository".to_string() }, ..Scan::default() };
    };
    let repo = Path::new(&top);
    let current = branch_of(&top);
    let mut candidates: Vec<String> = Vec::new();
    if !feature_branch.is_empty() && feature_branch != current {
        candidates.push(feature_branch.to_string());
        candidates.push(format!("origin/{feature_branch}"));
    }
    for b in ["origin/main", "main", "origin/master", "master"] {
        if b != current {
            candidates.push(b.to_string());
        }
    }
    let Some(base) = candidates.into_iter().find(|b| git(repo, &["rev-parse", "--verify", "--quiet", &format!("{b}^{{commit}}")]).is_some()) else {
        return Scan { error: "No base branch to compare with (main or the feature branch)".to_string(), ..Scan::default() };
    };
    let Some(mb) = git(repo, &["merge-base", &base, "HEAD"]) else {
        return Scan { error: format!("No common history with {base}"), ..Scan::default() };
    };
    let mut scan = Scan { ok: true, base: base.clone(), ..Scan::default() };
    if let Some(stat) = git(repo, &["diff", "--shortstat", &mb]) {
        for part in stat.split(',') {
            let n: u64 = part.trim().split_whitespace().next().and_then(|s| s.parse().ok()).unwrap_or(0);
            if part.contains("file") {
                scan.files = n;
            } else if part.contains("insertion") {
                scan.additions = n;
            } else if part.contains("deletion") {
                scan.deletions = n;
            }
        }
    }
    let diff = git(repo, &["diff", "--unified=0", "--no-color", "--no-ext-diff", &mb]).unwrap_or_default();
    let mut findings = Vec::new();
    let mut file = String::new();
    let mut line_no = 0u32;
    let mut added_in_file: HashMap<String, u32> = HashMap::new();
    let mut removed_asserts: HashMap<String, u32> = HashMap::new();
    let mut added_asserts: HashMap<String, u32> = HashMap::new();
    for l in diff.lines().take(60_000) {
        if let Some(rest) = l.strip_prefix("+++ ") {
            file = rest.strip_prefix("b/").unwrap_or(rest).to_string();
            continue;
        }
        if l.starts_with("--- ") || l.starts_with("diff --git") || l.starts_with("index ") {
            continue;
        }
        if let Some(rest) = l.strip_prefix("@@ ") {
            // @@ -a,b +c,d @@
            if let Some(plus) = rest.split_whitespace().nth(1) {
                line_no = plus.trim_start_matches('+').split(',').next().and_then(|s| s.parse().ok()).unwrap_or(0);
            }
            continue;
        }
        if file == "/dev/null" || file.is_empty() {
            continue;
        }
        if let Some(added) = l.strip_prefix('+') {
            *added_in_file.entry(file.clone()).or_default() += 1;
            if is_test_file(&file) && (added.contains("expect(") || added.contains("assert") || added.contains(".should")) {
                *added_asserts.entry(file.clone()).or_default() += 1;
            }
            check_added(&file, line_no, added, &mut findings);
            line_no += 1;
        } else if let Some(removed) = l.strip_prefix('-') {
            if is_test_file(&file) && (removed.contains("expect(") || removed.contains("assert") || removed.contains(".should")) {
                *removed_asserts.entry(file.clone()).or_default() += 1;
            }
        }
    }
    // Untracked files count as added in full.
    if let Some(list) = git(repo, &["ls-files", "--others", "--exclude-standard"]) {
        for f in list.lines().take(200) {
            let path = repo.join(f);
            if fs::metadata(&path).map(|m| m.len() > 512 * 1024).unwrap_or(true) {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else { continue };
            let mut n = 0u32;
            for l in text.lines().take(4000) {
                n += 1;
                check_added(f, n, l, &mut findings);
            }
            added_in_file.insert(f.to_string(), n);
        }
    }
    for (f, n) in &added_in_file {
        if *n > 400 && findings.len() < MAX_FINDINGS {
            findings.push(Finding { rule: "large_file".to_string(), file: f.clone(), line: 0, text: format!("{n} lines added in one file") });
        }
    }
    for (f, removed) in &removed_asserts {
        let added = added_asserts.get(f).copied().unwrap_or(0);
        if *removed > added && findings.len() < MAX_FINDINGS {
            findings.push(Finding { rule: "test_weakened".to_string(), file: f.clone(), line: 0, text: format!("{removed} assertions removed, {added} added") });
        }
    }
    findings.sort_by(|a, b| a.file.cmp(&b.file).then(a.line.cmp(&b.line)));
    let mut counts: HashMap<String, u32> = HashMap::new();
    for f in &findings {
        *counts.entry(f.rule.clone()).or_default() += 1;
    }
    let mut counts: Vec<(String, u32)> = counts.into_iter().collect();
    counts.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    scan.counts = counts.into_iter().map(|(rule, n)| json!({"rule": rule, "n": n, "label": rule_label(&rule)})).collect();
    scan.findings = findings;
    scan
}

pub fn rule_label(rule: &str) -> &'static str {
    match rule {
        "todo" => "Leftover TODO",
        "debug" => "Debug output",
        "commented_code" => "Commented-out code",
        "placeholder" => "Placeholder text",
        "dependency" => "New dependency",
        "hardcoded_colour" => "Hardcoded colour",
        "swallowed_error" => "Error swallowed",
        "large_file" => "Large change in one file",
        "test_weakened" => "Tests weakened",
        _ => "Finding",
    }
}

// ---------------------------------------------------------------------------
// guard rails (hooks)
// ---------------------------------------------------------------------------

/// Why a Bash command in `cwd` must not run (policy 8.4: nothing is
/// committed to main of a code repository from a session), or None.
pub fn guard_command(cwd: &str, command: &str) -> Option<String> {
    let ws = workspace_for(cwd)?;
    let repo = repo_of(&ws, cwd)?;
    let c = command.to_ascii_lowercase();
    if !c.contains("git ") {
        return None;
    }
    let commits = c.contains("git commit") || c.contains("git merge") || c.contains("git push") || c.contains("git cherry-pick") || c.contains("git revert");
    if !commits || c.contains("--dry-run") {
        return None;
    }
    let branch = branch_of(cwd);
    let on_main = matches!(branch.as_str(), "main" | "master");
    let switches_to_main = ["checkout main", "switch main", "checkout master", "switch master"].iter().any(|s| c.contains(s));
    let pushes_main = ["push origin main", "push -u origin main", "push --set-upstream origin main", ":main", "push origin master", ":master"].iter().any(|s| c.contains(s))
        || (c.contains("git push") && on_main && !c.contains("push origin feature/") && !c.contains("push origin fix/") && !c.contains("push -u origin feature/") && !c.contains("push -u origin fix/"));
    if (on_main && (c.contains("git commit") || c.contains("git merge") || c.contains("git cherry-pick") || c.contains("git revert"))) || switches_to_main || pushes_main {
        return Some(format!(
            "TORCH policy 8.4: nothing is committed to main of a code repository from a session ({repo} is on '{}'). Work on the feature branch (feature/{{app}}-{{feature}}) and open a pull request into it.",
            if branch.is_empty() { "?" } else { branch.as_str() }
        ));
    }
    None
}

/// What is wrong with starting a session in `cwd`, for a warning on the
/// phone; None when the session is on a proper branch.
pub fn session_warning(cwd: &str) -> Option<String> {
    let ws = workspace_for(cwd)?;
    remember_workspace(&ws);
    let repo = repo_of(&ws, cwd)?;
    let branch = branch_of(cwd);
    if branch.is_empty() {
        return Some(format!("{repo} has no branch checked out (detached HEAD). Run `git switch main` there, then `context/scripts/new-feature.sh`."));
    }
    if matches!(branch.as_str(), "main" | "master") {
        return Some(format!("This session runs on '{branch}' of {repo}. Policy 8.3: sessions run on the feature branch. Start one with context/scripts/new-feature.sh."));
    }
    if parse_branch(&ws, &branch).is_none() {
        return Some(format!("Branch '{branch}' in {repo} does not follow feature/{{app}}-{{feature}} or fix/{{app}}-{{slug}} (policy 7.2)."));
    }
    None
}

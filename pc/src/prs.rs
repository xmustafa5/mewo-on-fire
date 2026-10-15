//! Pull requests of a session's repository (PROTOCOL.md v1.6), read on the
//! PC with the GitHub CLI (`gh`, logged in by the user) and kept for a
//! short while so phones asking again do not hit GitHub every time.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

const TTL: Duration = Duration::from_secs(45);
const GH_TIMEOUT: Duration = Duration::from_secs(25);
const LIMIT: &str = "20";
const FIELDS: &str =
    "number,title,headRefName,additions,deletions,url,isDraft,reviewDecision,statusCheckRollup,updatedAt,author";

pub struct PrCache {
    entries: Mutex<HashMap<String, (Instant, Value)>>,
    /// The base-branch lists, shared with their background refreshes.
    shared: std::sync::Arc<Mutex<HashMap<String, (Instant, Value)>>>,
}

impl Default for PrCache {
    fn default() -> Self {
        PrCache { entries: Mutex::new(HashMap::new()), shared: std::sync::Arc::new(Mutex::new(HashMap::new())) }
    }
}

impl PrCache {
    /// `{"repo", "branch", "prs": [...], "error"}` for the repository at [cwd].
    pub async fn list(&self, cwd: &str) -> Value {
        if let Some((at, v)) = self.entries.lock().unwrap_or_else(|p| p.into_inner()).get(cwd) {
            if at.elapsed() < TTL {
                return v.clone();
            }
        }
        let dir = cwd.to_string();
        let fetched = tokio::time::timeout(GH_TIMEOUT, tokio::task::spawn_blocking(move || fetch(&dir)))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_else(|| empty("GitHub took too long to answer"));
        self.entries
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(cwd.to_string(), (Instant::now(), fetched.clone()));
        fetched
    }
}

impl PrCache {
    /// Pull requests (open, merged, closed) into `base` in the repository at
    /// `dir`: what is cached, refreshed in the background when stale. The
    /// first call answers with nothing and starts the fetch.
    pub async fn list_base(&self, dir: &str, base: &str) -> Vec<Value> {
        let key = format!("{dir}#{base}");
        let cached = self.shared.lock().unwrap_or_else(|p| p.into_inner()).get(&key).map(|(at, v)| (at.elapsed(), v.clone()));
        let (stale, value) = match cached {
            Some((age, v)) => (age >= TTL, v),
            None => (true, json!({"prs": [], "loading": true})),
        };
        if stale {
            // Mark it fresh now so one fetch runs at a time.
            self.shared
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(key.clone(), (Instant::now(), value.clone()));
            let dir = dir.to_string();
            let base = base.to_string();
            let entries = self.entries_arc();
            tokio::spawn(async move {
                let fetched = tokio::time::timeout(GH_TIMEOUT, tokio::task::spawn_blocking(move || fetch_base(&dir, &base)))
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or_else(|| json!({"prs": [], "error": "GitHub took too long to answer"}));
                entries.lock().unwrap_or_else(|p| p.into_inner()).insert(key, (Instant::now(), fetched));
            });
        }
        value.get("prs").and_then(Value::as_array).cloned().unwrap_or_default()
    }

    /// What is cached for `base` in `dir`, without a refresh.
    pub fn cached_base(&self, dir: &str, base: &str) -> Vec<Value> {
        let key = format!("{dir}#{base}");
        self.shared
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(&key)
            .and_then(|(_, v)| v.get("prs").and_then(Value::as_array).cloned())
            .unwrap_or_default()
    }

    fn entries_arc(&self) -> std::sync::Arc<Mutex<HashMap<String, (Instant, Value)>>> {
        self.shared.clone()
    }
}

const BASE_FIELDS: &str = "number,title,state,url,mergedAt,headRefName,isDraft,reviewDecision,author,body,updatedAt";

/// `gh pr list --base <base> --state all`, trimmed to what the plan needs.
fn fetch_base(dir: &str, base: &str) -> Value {
    if dir.is_empty() || !Path::new(dir).is_dir() {
        return json!({"prs": [], "error": "not on this PC"});
    }
    let Some(gh) = gh_path() else {
        return json!({"prs": [], "error": "GitHub CLI (gh) is not installed on the PC"});
    };
    let raw = match run(dir, &gh, &["pr", "list", "--base", base, "--state", "all", "--limit", "60", "--json", BASE_FIELDS]) {
        Ok(r) => r,
        Err(e) => return json!({"prs": [], "error": friendly(&e)}),
    };
    let list: Vec<Value> = serde_json::from_str(&raw).unwrap_or_default();
    let prs: Vec<Value> = list
        .iter()
        .map(|pr| {
            let body: String = s(pr, "body").chars().take(400).collect();
            json!({
                "number": pr.get("number").and_then(Value::as_u64).unwrap_or(0),
                "title": s(pr, "title"),
                "state": s(pr, "state"),
                "url": s(pr, "url"),
                "merged_at": s(pr, "mergedAt"),
                "branch": s(pr, "headRefName"),
                "draft": pr.get("isDraft").and_then(Value::as_bool).unwrap_or(false),
                "review": s(pr, "reviewDecision"),
                "author": pr.get("author").map(|a| s(a, "login")).unwrap_or_default(),
                "body": body,
            })
        })
        .collect();
    json!({"prs": prs, "error": ""})
}

fn empty(error: &str) -> Value {
    json!({"repo": "", "branch": "", "prs": [], "error": error})
}

/// launchd and systemd give the daemon a short PATH; `gh` usually lives
/// where Homebrew or the user put it.
pub fn gh_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        "/opt/homebrew/bin/gh".to_string(),
        "/usr/local/bin/gh".to_string(),
        format!("{home}/.local/bin/gh"),
        "/usr/bin/gh".to_string(),
        "/snap/bin/gh".to_string(),
    ];
    for c in candidates {
        if Path::new(&c).is_file() {
            return Some(PathBuf::from(c));
        }
    }
    // Last try: whatever PATH has.
    let out = Command::new("sh")
        .args(["-c", "command -v gh"])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() && !p.is_empty() {
        Some(PathBuf::from(p))
    } else {
        None
    }
}

/// v2.9: marks a pull request ready and merges it (squash) into its base.
pub fn merge_pr(cwd: &str, url: &str) -> Result<String, String> {
    let gh = gh_path().ok_or_else(|| "gh is not installed".to_string())?;
    let _ = run(cwd, &gh, &["pr", "ready", url]);
    run(cwd, &gh, &["pr", "merge", url, "--squash"])
}

/// v2.8: the head branch of a pull request, by its url.
pub fn pr_head(cwd: &str, url: &str) -> Option<String> {
    let gh = gh_path()?;
    run(cwd, &gh, &["pr", "view", url, "--json", "headRefName", "-q", ".headRefName"]).ok().filter(|s| !s.is_empty())
}

/// Runs a command in [cwd]: stdout trimmed, or the first line of stderr.
fn run(cwd: &str, program: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("NO_COLOR", "1")
        .envs(crate::github::envs())
        .output()
        .map_err(|e| format!("{}: {e}", program.display()))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(err.lines().find(|l| !l.trim().is_empty()).unwrap_or("failed").trim().to_string())
    }
}

fn fetch(cwd: &str) -> Value {
    if cwd.is_empty() || !Path::new(cwd).is_dir() {
        return empty("The session's folder is not on this PC");
    }
    let git = crate::policy::git_bin();
    let branch = match run(cwd, &git, &["rev-parse", "--abbrev-ref", "HEAD"]) {
        Ok(b) => b,
        Err(_) => return empty("Not a git repository"),
    };
    let Some(gh) = gh_path() else {
        return empty("GitHub CLI (gh) is not installed on the PC");
    };
    let repo = match run(cwd, &gh, &["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]) {
        Ok(r) => r,
        Err(e) => return empty(&friendly(&e)),
    };
    let raw = match run(cwd, &gh, &["pr", "list", "--state", "open", "--limit", LIMIT, "--json", FIELDS]) {
        Ok(r) => r,
        Err(e) => return empty(&friendly(&e)),
    };
    let list: Vec<Value> = serde_json::from_str(&raw).unwrap_or_default();
    let mut prs: Vec<Value> = list.iter().map(|pr| summarize(pr, &branch)).collect();
    // The session's own branch first; gh already has the newest first.
    prs.sort_by_key(|p| !p.get("current").and_then(Value::as_bool).unwrap_or(false));
    json!({"repo": repo, "branch": branch, "prs": prs, "error": ""})
}

fn friendly(err: &str) -> String {
    let e = err.to_lowercase();
    if e.contains("auth") && (e.contains("login") || e.contains("token") || e.contains("not logged")) {
        return "gh is not logged in on the PC (run `gh auth login` there)".to_string();
    }
    if e.contains("could not resolve to a repository") || e.contains("not found") {
        return "GitHub does not show this repository to the PC's gh account".to_string();
    }
    if e.contains("no git remotes") || e.contains("none of the git remotes") {
        return "This repository has no GitHub remote".to_string();
    }
    if e.contains("dial tcp") || e.contains("no such host") || e.contains("network") {
        return "The PC could not reach GitHub".to_string();
    }
    err.to_string()
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

/// One check of `statusCheckRollup` → `{"name", "state": pass|fail|pending}`.
fn check(v: &Value) -> Value {
    let name = if s(v, "name").is_empty() { s(v, "context") } else { s(v, "name") };
    let state = match s(v, "__typename") {
        "StatusContext" => match s(v, "state") {
            "SUCCESS" => "pass",
            "PENDING" | "EXPECTED" => "pending",
            _ => "fail",
        },
        _ => {
            if s(v, "status") != "COMPLETED" {
                "pending"
            } else {
                match s(v, "conclusion") {
                    "SUCCESS" | "NEUTRAL" | "SKIPPED" => "pass",
                    _ => "fail",
                }
            }
        }
    };
    json!({"name": name, "state": state})
}

fn summarize(pr: &Value, branch: &str) -> Value {
    let checks: Vec<Value> = pr
        .get("statusCheckRollup")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(check).collect())
        .unwrap_or_default();
    let ci = if checks.is_empty() {
        "none"
    } else if checks.iter().any(|c| s(c, "state") == "fail") {
        "fail"
    } else if checks.iter().any(|c| s(c, "state") == "pending") {
        "pending"
    } else {
        "pass"
    };
    let review = match s(pr, "reviewDecision") {
        "APPROVED" => "approved",
        "CHANGES_REQUESTED" => "changes",
        "REVIEW_REQUIRED" => "required",
        _ => "",
    };
    let head = s(pr, "headRefName");
    json!({
        "number": pr.get("number").and_then(Value::as_u64).unwrap_or(0),
        "title": s(pr, "title"),
        "branch": head,
        "url": s(pr, "url"),
        "additions": pr.get("additions").and_then(Value::as_u64).unwrap_or(0),
        "deletions": pr.get("deletions").and_then(Value::as_u64).unwrap_or(0),
        "draft": pr.get("isDraft").and_then(Value::as_bool).unwrap_or(false),
        "review": review,
        "ci": ci,
        "checks": checks,
        "author": pr.get("author").map(|a| s(a, "login")).unwrap_or(""),
        "updated": s(pr, "updatedAt"),
        "current": !head.is_empty() && head == branch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ci_rolls_up() {
        let pr = json!({
            "number": 7, "title": "t", "headRefName": "feat", "url": "u",
            "additions": 3, "deletions": 1, "isDraft": false, "reviewDecision": "APPROVED",
            "statusCheckRollup": [
                {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"__typename": "CheckRun", "name": "test", "status": "IN_PROGRESS", "conclusion": null},
                {"__typename": "StatusContext", "context": "lint", "state": "FAILURE"}
            ],
            "updatedAt": "2026-10-07T10:00:00Z", "author": {"login": "me"}
        });
        let v = summarize(&pr, "feat");
        assert_eq!(v["ci"], "fail");
        assert_eq!(v["current"], true);
        assert_eq!(v["review"], "approved");
        assert_eq!(v["checks"].as_array().unwrap().len(), 3);
        assert_eq!(v["checks"][1]["state"], "pending");
        let v = summarize(&json!({"number": 1, "statusCheckRollup": []}), "x");
        assert_eq!(v["ci"], "none");
        assert_eq!(v["current"], false);
    }
}

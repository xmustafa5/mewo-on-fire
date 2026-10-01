//! Claude Code transcript (JSONL) → chat items (PROTOCOL.md v1.2
//! "Transcript → chat items"). Blocking file IO: call from spawn_blocking.

use std::collections::{HashSet, VecDeque};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ask::truncate_chars;

/// Only the tail of the transcript is read.
const MAX_READ_BYTES: u64 = 4 * 1024 * 1024;
pub const MAX_ITEM_CHARS: usize = 6000;
pub const DEFAULT_LIMIT: usize = 100;
/// Upper bound for a requested `limit`.
pub const MAX_LIMIT: usize = 1000;

/// PROTOCOL.md v1.2 "ChatItem". Field order matches the protocol; `tool`
/// only for role `tool`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ChatItem {
    pub id: String,
    pub ts: u64,
    pub role: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
}

#[derive(Debug, Default)]
pub struct Transcript {
    /// The last `limit` items, oldest first.
    pub items: Vec<ChatItem>,
    /// Last `custom-title` entry's `customTitle` (a session renamed by the
    /// user; the Claude desktop app writes its titles this way too), else the
    /// last `ai-title` entry's `aiTitle`.
    pub title: Option<String>,
    /// After the last role-`user` item, some Agent/Task/Workflow tool_use has
    /// no matching tool_result.
    pub agents_running: bool,
}

/// (size, mtime): a cheap "did the file change" key.
pub type FileKey = (u64, SystemTime);

pub fn file_key(path: &str) -> Option<FileKey> {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.len(), meta.modified().unwrap_or(UNIX_EPOCH)))
}

/// Read the tail of the transcript at `path`, keeping the last `limit` items
/// (title and agents are computed over the whole tail). A missing or
/// unreadable file gives an empty transcript.
pub fn read(path: &str, limit: usize) -> Transcript {
    match read_tail(Path::new(path)) {
        Ok(bytes) => parse(&bytes, limit),
        Err(_) => Transcript::default(),
    }
}

/// The last MAX_READ_BYTES of the file, without the first (partial) line
/// when the file is longer than that.
fn read_tail(path: &Path) -> std::io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(MAX_READ_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::with_capacity((len - start) as usize);
    file.take(MAX_READ_BYTES).read_to_end(&mut buf)?;
    if start > 0 {
        match buf.iter().position(|&b| b == b'\n') {
            Some(nl) => {
                buf.drain(..=nl);
            }
            None => buf.clear(),
        }
    }
    Ok(buf)
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// Parse JSONL (bad lines are skipped) into chat items; see the module doc.
fn parse(bytes: &[u8], limit: usize) -> Transcript {
    let mut items: VecDeque<ChatItem> = VecDeque::new();
    let mut ai_title: Option<String> = None;
    let mut custom_title: Option<String> = None;
    // Agent/Task/Workflow tool_use ids without a tool_result since the last
    // role-user item.
    let mut open_agents: HashSet<String> = HashSet::new();
    let mut last_ts: u64 = 0;

    for (n, line) in bytes.split(|&b| b == b'\n').enumerate() {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let v: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = str_of(&v, "type");
        if kind == "ai-title" {
            let t = str_of(&v, "aiTitle").trim();
            if !t.is_empty() {
                ai_title = Some(t.to_string());
            }
            continue;
        }
        if kind == "custom-title" {
            let t = str_of(&v, "customTitle").trim();
            if !t.is_empty() {
                custom_title = Some(t.to_string());
            }
            continue;
        }
        if !matches!(kind, "user" | "assistant") || flag(&v, "isSidechain") || flag(&v, "isMeta") {
            continue;
        }
        if let Some(ts) = v.get("timestamp").and_then(Value::as_str).and_then(parse_ts) {
            last_ts = ts;
        }
        let base_id = match v.get("uuid").and_then(Value::as_str) {
            Some(u) if !u.is_empty() => u.to_string(),
            _ => format!("line-{n}"),
        };
        let content = v.get("message").and_then(|m| m.get("content"));

        // (role, text, tool) for this line.
        let mut found: Vec<(&'static str, String, Option<String>)> = Vec::new();
        if kind == "user" {
            if let Some(text) = user_text(content, &mut open_agents) {
                open_agents.clear();
                found.push(("user", text, None));
            }
        } else {
            assistant_items(content, &mut found, &mut open_agents);
        }

        if limit == 0 {
            continue;
        }
        for (i, (role, text, tool)) in found.into_iter().enumerate() {
            let id = if i == 0 {
                base_id.clone()
            } else {
                format!("{base_id}:{i}")
            };
            items.push_back(ChatItem {
                id,
                ts: last_ts,
                role: role.to_string(),
                text: truncate_chars(&text, MAX_ITEM_CHARS),
                tool,
            });
            while items.len() > limit {
                items.pop_front();
            }
        }
    }

    Transcript {
        items: items.into_iter().collect(),
        title: custom_title.or(ai_title),
        agents_running: !open_agents.is_empty(),
    }
}

/// The visible text of a user line (None if nothing is left), dropping the
/// tool_results' ids from `open_agents` along the way.
fn user_text(content: Option<&Value>, open_agents: &mut HashSet<String>) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    match content {
        Some(Value::String(s)) => parts.push(strip_wrappers(s)),
        Some(Value::Array(blocks)) => {
            for b in blocks {
                match str_of(b, "type") {
                    "text" => parts.push(strip_wrappers(str_of(b, "text"))),
                    "image" => parts.push("[image]".to_string()),
                    "tool_result" => {
                        open_agents.remove(str_of(b, "tool_use_id"));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    let text = parts
        .iter()
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .collect::<Vec<&str>>()
        .join("\n\n");
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// Items of an assistant line: `text` blocks and one-liners for `tool_use`
/// blocks (`thinking` is skipped).
fn assistant_items(
    content: Option<&Value>,
    out: &mut Vec<(&'static str, String, Option<String>)>,
    open_agents: &mut HashSet<String>,
) {
    let null = Value::Null;
    match content {
        Some(Value::String(s)) => {
            let t = s.trim();
            if !t.is_empty() {
                out.push(("assistant", t.to_string(), None));
            }
        }
        Some(Value::Array(blocks)) => {
            for b in blocks {
                match str_of(b, "type") {
                    "text" => {
                        let t = str_of(b, "text").trim();
                        if !t.is_empty() {
                            out.push(("assistant", t.to_string(), None));
                        }
                    }
                    "tool_use" => {
                        let name = str_of(b, "name");
                        let input = b.get("input").unwrap_or(&null);
                        if matches!(name, "Agent" | "Task" | "Workflow") {
                            let id = str_of(b, "id");
                            if !id.is_empty() {
                                open_agents.insert(id.to_string());
                            }
                        }
                        out.push(("tool", tool_line(name, input), Some(name.to_string())));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

/// One-liner for a tool call (PROTOCOL.md v1.2); the tool name when there is
/// nothing better.
fn tool_line(name: &str, input: &Value) -> String {
    let line = match name {
        "Bash" => first_line(str_of(input, "command")),
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" | "Read" => {
            first_nonempty(str_of(input, "file_path"), str_of(input, "notebook_path"))
        }
        "Grep" | "Glob" => str_of(input, "pattern"),
        "WebFetch" => str_of(input, "url"),
        "WebSearch" => str_of(input, "query"),
        "Agent" | "Task" => str_of(input, "description"),
        "Workflow" => first_nonempty(str_of(input, "description"), str_of(input, "name")),
        "AskUserQuestion" => input
            .get("questions")
            .and_then(Value::as_array)
            .and_then(|qs| qs.first())
            .map(|q| str_of(q, "question"))
            .unwrap_or(""),
        "TodoWrite" => "update todos",
        _ => "",
    };
    let line = line.trim();
    if !line.is_empty() {
        line.to_string()
    } else if name.is_empty() {
        "tool".to_string()
    } else {
        name.to_string()
    }
}

fn first_nonempty<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.trim().is_empty() {
        b
    } else {
        a
    }
}

fn first_line(s: &str) -> &str {
    s.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("")
}

/// Tags removed together with their content from user text.
fn is_stripped_tag(name: &str) -> bool {
    matches!(name, "system-reminder" | "ide_selection" | "ide_opened_file")
        || name.starts_with("command-")
        || name.starts_with("local-command-")
}

/// Remove `<tag>…</tag>` spans (see is_stripped_tag) by plain string
/// scanning. An opening tag without its closing tag is left as is.
pub fn strip_wrappers(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(pos) = rest.find('<') {
        let after = &rest[pos + 1..];
        let name_len = after
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-'))
            .unwrap_or(after.len());
        let name = &after[..name_len];
        let tail = &after[name_len..];
        // Offset of the opening tag's '>' within `tail` (attributes allowed).
        let open_end = if tail.starts_with('>') {
            Some(0)
        } else if tail.starts_with(char::is_whitespace) {
            tail.find('>')
        } else {
            None
        };
        if let Some(open_end) = open_end {
            if !name.is_empty() && is_stripped_tag(name) {
                let body_start = pos + 1 + name_len + open_end + 1;
                let close = format!("</{name}>");
                if let Some(end) = rest[body_start..].find(&close) {
                    out.push_str(&rest[..pos]);
                    rest = &rest[body_start + end + close.len()..];
                    continue;
                }
            }
        }
        out.push_str(&rest[..pos + 1]);
        rest = &rest[pos + 1..];
    }
    out.push_str(rest);
    out
}

/// RFC 3339 timestamp ("2026-09-27T10:51:43.353Z") → unix ms.
fn parse_ts(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19
        || b[4] != b'-'
        || b[7] != b'-'
        || (b[10] != b'T' && b[10] != b't' && b[10] != b' ')
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> {
        let part = s.get(from..to)?;
        if !part.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        part.parse::<i64>().ok()
    };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);

    let mut rest = &s[19..];
    let mut ms: i64 = 0;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits = frac.bytes().take_while(u8::is_ascii_digit).count();
        for (i, c) in frac.bytes().take(digits.min(3)).enumerate() {
            ms += i64::from(c - b'0') * [100, 10, 1][i];
        }
        rest = &frac[digits..];
    }
    let offset: i64 = match rest.as_bytes().first() {
        Some(&sign) if sign == b'+' || sign == b'-' => {
            let digits: String = rest[1..].chars().filter(char::is_ascii_digit).collect();
            let hh: i64 = digits.get(0..2).and_then(|x| x.parse().ok()).unwrap_or(0);
            let mm: i64 = digits.get(2..4).and_then(|x| x.parse().ok()).unwrap_or(0);
            let o = hh * 3600 + mm * 60;
            if sign == b'-' {
                -o
            } else {
                o
            }
        }
        _ => 0,
    };

    let days = days_from_civil(y, mo, d);
    let secs = days * 86_400 + h * 3600 + mi * 60 + sec - offset;
    if secs < 0 {
        return None;
    }
    Some(secs as u64 * 1000 + ms as u64)
}

/// Howard Hinnant's days-from-civil (days since 1970-01-01).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

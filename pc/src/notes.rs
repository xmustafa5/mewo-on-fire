//! Design review notes (v2.5): pins on a design board, each with a text,
//! kept per artifact under `<state>/notes/<artifact>.json`, and sent to
//! the session that made the design as one review message, the way a
//! product team hands notes to a designer.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{fs, path::PathBuf, sync::Mutex};

use crate::{config::now_ms, paths};

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Note {
    pub id: u64,
    /// The board file inside the artifact (`project/x.dc.html`).
    pub board: String,
    pub board_title: String,
    /// Where on the board, as fractions of its width and height.
    pub x: f64,
    pub y: f64,
    pub text: String,
    /// `open`, `sent`, `done`.
    pub status: String,
    pub by: String,
    pub ts: u64,
    pub sent_ts: u64,
}

static LOCK: Mutex<()> = Mutex::new(());

fn safe(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect()
}

fn file(artifact: &str) -> PathBuf {
    paths::state_dir().join("notes").join(format!("{}.json", safe(artifact)))
}

pub fn list(artifact: &str) -> Vec<Note> {
    fs::read_to_string(file(artifact)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn save(artifact: &str, notes: &[Note]) {
    let p = file(artifact);
    if let Some(d) = p.parent() {
        let _ = fs::create_dir_all(d);
    }
    let _ = fs::write(p, serde_json::to_string_pretty(notes).unwrap_or_default());
}

pub fn add(artifact: &str, board: &str, board_title: &str, x: f64, y: f64, text: &str, by: &str) -> Result<Note, String> {
    let text = text.trim();
    if artifact.trim().is_empty() {
        return Err("Which design?".to_string());
    }
    if text.is_empty() {
        return Err("The note is empty".to_string());
    }
    let _g = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut notes = list(artifact);
    let note = Note {
        id: now_ms(),
        board: board.to_string(),
        board_title: board_title.trim().to_string(),
        x: x.clamp(0.0, 1.0),
        y: y.clamp(0.0, 1.0),
        text: text.to_string(),
        status: "open".to_string(),
        by: by.trim().to_string(),
        ts: now_ms(),
        sent_ts: 0,
    };
    notes.push(note.clone());
    save(artifact, &notes);
    Ok(note)
}

pub fn set(artifact: &str, id: u64, text: Option<&str>, status: Option<&str>) -> Result<Note, String> {
    let _g = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut notes = list(artifact);
    let n = notes.iter_mut().find(|n| n.id == id).ok_or_else(|| "No such note".to_string())?;
    if let Some(t) = text {
        if !t.trim().is_empty() {
            n.text = t.trim().to_string();
        }
    }
    if let Some(s) = status {
        if matches!(s, "open" | "sent" | "done") {
            n.status = s.to_string();
        }
    }
    let out = n.clone();
    save(artifact, &notes);
    Ok(out)
}

pub fn remove(artifact: &str, id: u64) -> bool {
    let _g = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut notes = list(artifact);
    let before = notes.len();
    notes.retain(|n| n.id != id);
    if notes.len() != before {
        save(artifact, &notes);
        true
    } else {
        false
    }
}

pub fn mark_sent(artifact: &str, ids: &[u64]) {
    let _g = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut notes = list(artifact);
    for n in notes.iter_mut().filter(|n| ids.contains(&n.id)) {
        n.status = "sent".to_string();
        n.sent_ts = now_ms();
    }
    save(artifact, &notes);
}

/// Where a pin sits, in words: thirds of the board.
pub fn place(x: f64, y: f64) -> String {
    let row = if y < 1.0 / 3.0 { "top" } else if y > 2.0 / 3.0 { "bottom" } else { "" };
    let col = if x < 1.0 / 3.0 { "left" } else if x > 2.0 / 3.0 { "right" } else { "" };
    match (row, col) {
        ("", "") => "centre".to_string(),
        (r, "") => r.to_string(),
        ("", c) => c.to_string(),
        (r, c) => format!("{r} {c}"),
    }
}

/// The review message for `notes`: per board, each note numbered as the
/// console shows it, with where it sits.
pub fn message(title: &str, url: &str, all: &[Note], send: &[&Note]) -> String {
    let mut out = format!(
        "Design review of \"{}\"{}: {} note{} from the product team, pinned on the boards (the position is where on the board the note sits, x from the left and y from the top as fractions).\n",
        if title.trim().is_empty() { "the design" } else { title.trim() },
        if url.trim().is_empty() { String::new() } else { format!(" ({})", url.trim()) },
        send.len(),
        if send.len() == 1 { "" } else { "s" }
    );
    let mut boards: Vec<String> = Vec::new();
    for n in send {
        if !boards.contains(&n.board) {
            boards.push(n.board.clone());
        }
    }
    for b in boards {
        let title = send.iter().find(|n| n.board == b).map(|n| if n.board_title.is_empty() { n.board.clone() } else { n.board_title.clone() }).unwrap_or_default();
        out.push_str(&format!("\nBoard \"{title}\":\n"));
        for n in send.iter().filter(|n| n.board == b) {
            let number = all.iter().position(|a| a.id == n.id).map(|i| i + 1).unwrap_or(0);
            out.push_str(&format!("  {number}. {} (x {:.2}, y {:.2}){}: {}\n", place(n.x, n.y), n.x, n.y, if n.by.is_empty() { String::new() } else { format!(", from {}", n.by) }, n.text));
        }
    }
    out.push_str("\nTreat this as one review round: for each note, change the board accordingly or say why it should stay, ask when a note is ambiguous, keep the other boards as they are, and reply with what changed note by note, so the notes can be closed.");
    out
}

pub fn to_json(n: &Note) -> Value {
    json!(n)
}

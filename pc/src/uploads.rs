//! Images sent from a phone with a message (PROTOCOL.md v1.3). They are
//! saved under `~/.local/state/ccnotify/uploads/<session short>/`; the message
//! handed to Claude Code names the files so it can look at them.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::Value;

use crate::paths;

pub const MAX_IMAGES: usize = 4;
/// Per image, decoded. Four of them still fit one WebSocket frame as base64.
pub const MAX_IMAGE_BYTES: usize = 2_500_000;
/// Uploads older than this are deleted.
const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub const REASON_TOO_MANY: &str = "Too many images (4 at most)";
pub const REASON_TOO_LARGE: &str = "An image is too large";
pub const REASON_NOT_AN_IMAGE: &str = "Only JPEG, PNG, GIF and WebP images can be sent";

/// A decoded image of a `send` frame.
pub struct Upload {
    ext: &'static str,
    data: Vec<u8>,
}

/// A saved upload: `id` is what phones ask for (`get_image`), `path` what
/// Claude Code reads.
pub struct Saved {
    pub id: String,
    pub path: PathBuf,
}

fn dir() -> PathBuf {
    paths::state_dir().join("uploads")
}

/// File extension by content (the phone's `mime` is not trusted).
fn extension(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpg")
    } else if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        Some("gif")
    } else if data.len() > 12 && data.starts_with(b"RIFF") && &data[8..12] == b"WEBP" {
        Some("webp")
    } else {
        None
    }
}

fn mime(file_name: &str) -> &'static str {
    match file_name.rsplit('.').next() {
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/jpeg",
    }
}

/// One path component made of `[A-Za-z0-9._-]`, not hidden.
fn is_safe_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The `images` field of a `send` frame: `[{"mime": "...", "data": "<base64>"}]`.
/// Err(reason) for the phone when it cannot be accepted.
pub fn decode(images: Option<&Value>) -> Result<Vec<Upload>, &'static str> {
    let list = match images.and_then(Value::as_array) {
        Some(list) => list,
        None => return Ok(Vec::new()),
    };
    if list.len() > MAX_IMAGES {
        return Err(REASON_TOO_MANY);
    }
    let mut uploads = Vec::with_capacity(list.len());
    for image in list {
        let encoded = image.get("data").and_then(Value::as_str).unwrap_or("");
        // 4 base64 characters per 3 bytes.
        if encoded.len() / 4 * 3 > MAX_IMAGE_BYTES + 3 {
            return Err(REASON_TOO_LARGE);
        }
        let data = STANDARD.decode(encoded).map_err(|_| REASON_NOT_AN_IMAGE)?;
        if data.len() > MAX_IMAGE_BYTES {
            return Err(REASON_TOO_LARGE);
        }
        let ext = extension(&data).ok_or(REASON_NOT_AN_IMAGE)?;
        uploads.push(Upload { ext, data });
    }
    Ok(uploads)
}

/// Save the images of one message. Files are named after the message's
/// `client_id`, so a retried message overwrites its own files.
pub fn save(short: &str, client_id: &str, uploads: &[Upload]) -> std::io::Result<Vec<Saved>> {
    let invalid = |what: &str| std::io::Error::new(std::io::ErrorKind::InvalidInput, what.to_string());
    if !is_safe_name(short) {
        return Err(invalid("bad session id"));
    }
    let stem: String = client_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(32)
        .collect();
    if stem.is_empty() {
        return Err(invalid("bad client id"));
    }
    let dir = dir().join(short);
    fs::create_dir_all(&dir)?;
    // Only the user may list what was sent.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    let mut saved = Vec::with_capacity(uploads.len());
    for (n, upload) in uploads.iter().enumerate() {
        let name = format!("{stem}-{}.{}", n + 1, upload.ext);
        let path = dir.join(&name);
        paths::write_atomic(&path, &upload.data, 0o600)?;
        saved.push(Saved {
            id: format!("up/{short}/{name}"),
            path,
        });
    }
    Ok(saved)
}

/// The message was not accepted after all.
pub fn remove(saved: &[Saved]) {
    for s in saved {
        let _ = fs::remove_file(&s.path);
    }
}

/// (mime, base64) of the upload with this id (`up/<short>/<file>`).
pub fn read(id: &str) -> Option<(&'static str, String)> {
    let mut parts = id.split('/');
    let (prefix, short, name) = (parts.next()?, parts.next()?, parts.next()?);
    if prefix != "up" || parts.next().is_some() || !is_safe_name(short) || !is_safe_name(name) {
        return None;
    }
    let data = fs::read(dir().join(short).join(name)).ok()?;
    Some((mime(name), STANDARD.encode(data)))
}

/// Delete uploads older than a week, and the session directories left empty.
pub fn prune() {
    let Ok(sessions) = fs::read_dir(dir()) else {
        return;
    };
    let now = SystemTime::now();
    for session in sessions.flatten() {
        let Ok(files) = fs::read_dir(session.path()) else {
            continue;
        };
        for file in files.flatten() {
            let old = file
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|modified| now.duration_since(modified).ok())
                .is_some_and(|age| age > MAX_AGE);
            if old {
                let _ = fs::remove_file(file.path());
            }
        }
        // Fails while files are left in it.
        let _ = fs::remove_dir(session.path());
    }
}

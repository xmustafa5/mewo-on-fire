//! The console's own settings (v3.3): what the operations console hides and
//! how it filters, kept in `<state>/console.json`. Only the console reads
//! and writes them; sessions, events and Claude Code are never touched.

use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::paths;

/// The most a saved document may take, serialized.
const MAX_BYTES: usize = 256 * 1024;

/// What the console starts from: nothing hidden, no filters.
pub fn defaults() -> Value {
    json!({"v": 1, "hidden": {}, "feed_cleared_at": 0, "filters": {"status": [], "projects": [], "pcs": [], "range": "all"}})
}

/// The settings in `path`; the defaults when it is missing, unreadable or
/// not a JSON object.
pub fn load_from(path: &Path) -> Value {
    fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(Value::is_object)
        .unwrap_or_else(defaults)
}

/// Replaces the settings in `path` with `prefs` as given: any object up to
/// 256 KB; anything else is refused and nothing is written.
pub fn save_to(path: &Path, prefs: &Value) -> Result<(), String> {
    if !prefs.is_object() {
        return Err("The console settings must be a JSON object".to_string());
    }
    let bytes = serde_json::to_vec(prefs).map_err(|e| e.to_string())?;
    if bytes.len() > MAX_BYTES {
        return Err(format!("The console settings are too large ({} KB, at most {} KB)", bytes.len().div_ceil(1024), MAX_BYTES / 1024));
    }
    paths::write_atomic(path, &bytes, 0o600).map_err(|e| e.to_string())
}

pub fn load() -> Value {
    load_from(&paths::console_file())
}

pub fn save(prefs: &Value) -> Result<(), String> {
    save_to(&paths::console_file(), prefs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A fresh folder for one test, under the system temp dir.
    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mewo-console-prefs-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn missing_file_gives_defaults() {
        let d = dir("missing");
        assert_eq!(load_from(&d.join("console.json")), defaults());
    }

    #[test]
    fn corrupt_file_gives_defaults() {
        let d = dir("corrupt");
        fs::create_dir_all(&d).unwrap();
        let p = d.join("console.json");
        fs::write(&p, "{not json").unwrap();
        assert_eq!(load_from(&p), defaults());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn array_file_gives_defaults() {
        let d = dir("array");
        fs::create_dir_all(&d).unwrap();
        let p = d.join("console.json");
        fs::write(&p, "[1, 2]").unwrap();
        assert_eq!(load_from(&p), defaults());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn round_trip() {
        let d = dir("round-trip");
        let p = d.join("console.json");
        let prefs = json!({
            "v": 1,
            "hidden": {"abc123": 1760450000000u64},
            "feed_cleared_at": 1760450000001u64,
            "filters": {"status": ["working"], "projects": ["mewo"], "pcs": [], "range": "24h"}
        });
        save_to(&p, &prefs).unwrap();
        assert_eq!(load_from(&p), prefs);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn rejects_non_object() {
        let d = dir("non-object");
        let p = d.join("console.json");
        assert!(save_to(&p, &json!([1, 2])).is_err());
        assert!(!p.exists());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn rejects_over_256_kb() {
        let d = dir("too-large");
        let p = d.join("console.json");
        let prefs = json!({"v": 1, "hidden": {}, "big": "x".repeat(300 * 1024)});
        assert!(save_to(&p, &prefs).is_err());
        assert!(!p.exists());
        let _ = fs::remove_dir_all(&d);
    }
}

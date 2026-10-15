//! Local copies of what a session published with the Artifact tool, so a
//! phone and the console can show a design, a page or a document in place
//! (v1.6). Claude writes the published files wherever it works, often a
//! temporary folder, so the daemon copies them under its state folder the
//! first time a transcript scan sees them, before they go away.
//!
//! `~/.local/state/mewo-on-fire/artifacts/<id>/<published path>`, the id
//! being the last segment of the claude.ai url. A design's boards
//! (`*.dc.html`) get their `{{prop}}` placeholders filled with the props'
//! defaults, so they render without the design runtime; a document
//! (`*.md`) gets a `<name>.md.html` page beside it for the console.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::paths;
use crate::transcript::Artifact;

/// A published file: where the page expects it, and where it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct Source {
    pub published: String,
    pub from: PathBuf,
    /// The page, document or canvas itself rather than a supporting file.
    pub main: bool,
}

const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_FILES: usize = 64;
/// What a phone gets at most, all files together.
const MAX_SEND_BYTES: usize = 24 * 1024 * 1024;
const MAX_AGE: Duration = Duration::from_secs(90 * 24 * 60 * 60);

pub fn root() -> PathBuf {
    paths::state_dir().join("artifacts")
}

pub fn dir(id: &str) -> PathBuf {
    root().join(id)
}

/// The artifact's id: the last path segment of its url, letters, digits,
/// `-` and `_` only (empty for anything else).
pub fn id_of(url: &str) -> String {
    let tail = url.split(['?', '#']).next().unwrap_or("");
    let tail = tail.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    tail.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(64)
        .collect()
}

/// A published path that stays inside the artifact's folder.
fn safe(rel: &str) -> Option<String> {
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() || rel.len() > 512 {
        return None;
    }
    for part in rel.split('/') {
        if part.is_empty() || part == "." || part == ".." || part.contains('\\') {
            return None;
        }
    }
    Some(rel.to_string())
}

/// Copies the sources that are new or changed into the artifact's folder,
/// then records on `a` what to open and whether it is there.
pub fn snapshot(a: &mut Artifact, sources: &[Source]) {
    a.id = id_of(&a.url);
    a.local = false;
    if a.id.is_empty() || sources.is_empty() {
        return;
    }
    let dir = dir(&a.id);
    for s in sources.iter().take(MAX_FILES) {
        let Some(rel) = safe(&s.published) else { continue };
        let Ok(meta) = fs::metadata(&s.from) else { continue };
        if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
            continue;
        }
        let dst = dir.join(&rel);
        let fresh = match (meta.modified().ok(), fs::metadata(&dst).and_then(|m| m.modified()).ok()) {
            (_, None) => true,
            (Some(src), Some(old)) => src > old,
            (None, Some(_)) => false,
        };
        if !fresh {
            continue;
        }
        if let Some(parent) = dst.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = if rel.ends_with(".dc.html") {
            fs::read_to_string(&s.from).and_then(|html| fs::write(&dst, render_design(&html)))
        } else if rel.ends_with(".md") {
            fs::read_to_string(&s.from).and_then(|md| {
                fs::write(dir.join(format!("{rel}.html")), document_page(&md))?;
                fs::write(&dst, md)
            })
        } else {
            fs::copy(&s.from, &dst).map(|_| ())
        };
    }
    // What to open: a design's canvas, else the page or document itself.
    let published = || sources.iter().filter_map(|s| safe(&s.published));
    let is_main = |p: &String| p.ends_with(".dc.html") || p.ends_with(".html") || p.ends_with(".htm") || p.ends_with(".md");
    let entry = published()
        .find(|p| p.ends_with("canvas.json"))
        .or_else(|| sources.iter().filter(|s| s.main).filter_map(|s| safe(&s.published)).find(is_main))
        .or_else(|| published().find(is_main));
    if let Some(entry) = entry {
        if dir.join(&entry).is_file() {
            a.entry = entry;
            a.local = true;
        }
    }
}

/// `snapshot` for every artifact of a transcript.
pub fn snapshot_all(artifacts: &mut [Artifact], sources: &std::collections::HashMap<String, Vec<Source>>) {
    for a in artifacts {
        match sources.get(&a.url) {
            Some(s) => snapshot(a, s),
            None => {
                a.id = id_of(&a.url);
                a.local = false;
            }
        }
    }
}

/// One file of an artifact, for the dashboard's `/artifact/<id>/<path>`.
pub fn file(id: &str, rel: &str) -> Option<(&'static str, Vec<u8>)> {
    if id.is_empty() || id != id_of(&format!("x/{id}")) {
        return None;
    }
    let rel = safe(rel)?;
    let path = dir(id).join(&rel);
    let bytes = fs::read(&path).ok()?;
    Some((mime(&rel), bytes))
}

/// Every file of an artifact for a phone, `(published path, bytes)`, the
/// console's `.md.html` pages left out.
pub fn files(id: &str) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    if id.is_empty() {
        return out;
    }
    let base = dir(id);
    let mut total = 0usize;
    walk(&base, &base, &mut out, &mut total);
    out
}

fn walk(base: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>, total: &mut usize) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut entries: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    entries.sort();
    for path in entries {
        if out.len() >= MAX_FILES {
            return;
        }
        if path.is_dir() {
            walk(base, &path, out, total);
            continue;
        }
        let Ok(rel) = path.strip_prefix(base) else { continue };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if rel.ends_with(".md.html") {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else { continue };
        if *total + bytes.len() > MAX_SEND_BYTES {
            continue;
        }
        *total += bytes.len();
        out.push((rel, bytes));
    }
}

pub fn is_text(path: &str) -> bool {
    matches!(
        path.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str(),
        "html" | "htm" | "css" | "js" | "mjs" | "json" | "md" | "txt" | "svg" | "csv" | "xml"
    )
}

pub fn mime(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "md" => "text/markdown; charset=utf-8",
        "txt" | "csv" => "text/plain; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}

/// Drops artifact folders nobody touched for MAX_AGE.
pub fn prune() {
    let Ok(entries) = fs::read_dir(root()) else { return };
    let now = SystemTime::now();
    for e in entries.flatten() {
        let path = e.path();
        let old = fs::metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .is_some_and(|age| age > MAX_AGE);
        if old && path.is_dir() {
            let _ = fs::remove_dir_all(&path);
        }
    }
}

// ---------------------------------------------------------------------------
// designs and documents
// ---------------------------------------------------------------------------

/// The `data-props` JSON of a design board.
fn design_props(html: &str) -> Option<Value> {
    let i = html.find("data-props='")? + "data-props='".len();
    let rest = &html[i..];
    let end = rest.find('\'')?;
    serde_json::from_str(&rest[..end].replace("&#39;", "'").replace("&quot;", "\"")).ok()
}

/// A board as a page of its own: `{{prop}}` placeholders replaced by the
/// props' defaults, the board's width as the viewport so a phone shows it
/// edge to edge.
fn render_design(html: &str) -> String {
    let props = design_props(html);
    let mut out = html.to_string();
    let mut width = 390u64;
    if let Some(Value::Object(obj)) = &props {
        for (name, spec) in obj {
            if name == "$preview" {
                if let Some(w) = spec.get("width").and_then(Value::as_u64) {
                    width = w.clamp(200, 4000);
                }
                continue;
            }
            let val = match spec.get("default") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Number(n)) => n.to_string(),
                Some(Value::Bool(b)) => b.to_string(),
                _ => continue,
            };
            out = out.replace(&format!("{{{{{name}}}}}"), &val).replace(&format!("{{{{ {name} }}}}"), &val);
        }
    }
    if !out.contains("name=\"viewport\"") {
        let meta = format!("<meta name=\"viewport\" content=\"width={width}, initial-scale=1\">");
        if let Some(i) = out.find("<head>") {
            out.insert_str(i + "<head>".len(), &meta);
        } else {
            out.insert_str(0, &meta);
        }
    }
    out
}

/// A document as a page: the markdown, rendered in the browser by a small
/// script, in the app's colours.
fn document_page(md: &str) -> String {
    let escaped = md.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    DOCUMENT_PAGE.replacen("{{markdown}}", &escaped, 1)
}

const DOCUMENT_PAGE: &str = r##"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Document</title>
<style>
:root{color-scheme:dark}
body{margin:0;background:#0C0A09;color:#F6F1EC;font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif}
main{max-width:760px;margin:0 auto;padding:28px 24px 60px}
h1,h2,h3,h4{line-height:1.25;letter-spacing:-.01em;margin:1.4em 0 .5em}h1{font-size:30px;margin-top:.2em}h2{font-size:23px}h3{font-size:18px}
a{color:#FFB347}a:hover{color:#FF6B35}
p,ul,ol,blockquote,table,pre{margin:0 0 1em}
code{font-family:"SF Mono",Menlo,monospace;font-size:.92em;background:#15110E;border:1px solid rgba(255,255,255,.08);border-radius:6px;padding:1px 5px;color:#FFD66B}
pre{background:#15110E;border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:14px;overflow:auto}pre code{border:0;padding:0;background:none;color:#F6F1EC}
blockquote{border-left:3px solid #FF6B35;margin-left:0;padding:2px 14px;color:#BCB2A8}
hr{border:0;border-top:1px solid rgba(255,255,255,.12);margin:1.6em 0}
table{border-collapse:collapse;width:100%}th,td{border:1px solid rgba(255,255,255,.12);padding:6px 10px;text-align:left;font-size:14px}th{color:#BCB2A8;font-weight:600}
li{margin:.25em 0}li::marker{color:#FFB347}
img{max-width:100%;border-radius:10px}
</style></head><body><main id="out"></main><pre id="src" hidden>{{markdown}}</pre>
<script>
(function(){
function md(src){
  var esc=function(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');};
  var inline=function(s){return esc(s)
    .replace(/`([^`]+)`/g,'<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
    .replace(/(^|[^*\w])\*([^*]+)\*/g,'$1<em>$2</em>')
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g,'<img alt="$1" src="$2">')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');};
  var lines=src.replace(/\r/g,'').split('\n'),out=[],i=0,m;
  var block=/^(#{1,6}\s|```|\s*[-*+]\s|\s*\d+[.)]\s|>|\|)/;
  while(i<lines.length){
    var l=lines[i];
    if(/^```/.test(l)){var buf=[];i++;while(i<lines.length&&!/^```/.test(lines[i]))buf.push(lines[i++]);i++;out.push('<pre><code>'+esc(buf.join('\n'))+'</code></pre>');continue;}
    if((m=/^(#{1,6})\s+(.*)/.exec(l))){out.push('<h'+m[1].length+'>'+inline(m[2])+'</h'+m[1].length+'>');i++;continue;}
    if(/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)){out.push('<hr>');i++;continue;}
    if(/^\s*[-*+]\s+/.test(l)){var it=[];while(i<lines.length&&/^\s*[-*+]\s+/.test(lines[i]))it.push(inline(lines[i++].replace(/^\s*[-*+]\s+/,'')));out.push('<ul><li>'+it.join('</li><li>')+'</li></ul>');continue;}
    if(/^\s*\d+[.)]\s+/.test(l)){var ot=[];while(i<lines.length&&/^\s*\d+[.)]\s+/.test(lines[i]))ot.push(inline(lines[i++].replace(/^\s*\d+[.)]\s+/,'')));out.push('<ol><li>'+ot.join('</li><li>')+'</li></ol>');continue;}
    if(/^>\s?/.test(l)){var q=[];while(i<lines.length&&/^>\s?/.test(lines[i]))q.push(lines[i++].replace(/^>\s?/,''));out.push('<blockquote>'+md(q.join('\n'))+'</blockquote>');continue;}
    if(/^\|/.test(l)){var rows=[];while(i<lines.length&&/^\|/.test(lines[i]))rows.push(lines[i++]);var cells=function(r){return r.replace(/^\||\|$/g,'').split('|').map(function(c){return inline(c.trim());});};var head=cells(rows[0]);var body=rows.slice(1).filter(function(r){return !/^\|?\s*:?-{2,}/.test(r);});out.push('<table><thead><tr><th>'+head.join('</th><th>')+'</th></tr></thead><tbody>'+body.map(function(r){return '<tr><td>'+cells(r).join('</td><td>')+'</td></tr>';}).join('')+'</tbody></table>');continue;}
    if(!l.trim()){i++;continue;}
    var p=[];while(i<lines.length&&lines[i].trim()&&!block.test(lines[i]))p.push(lines[i++]);
    if(!p.length)p.push(lines[i++]);
    out.push('<p>'+inline(p.join(' '))+'</p>');
  }
  return out.join('\n');
}
var src=document.getElementById('src').textContent;
document.getElementById('out').innerHTML=md(src);
var h=document.querySelector('h1');if(h)document.title=h.textContent;
})();
</script></body></html>
"##;

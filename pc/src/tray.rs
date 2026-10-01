//! `ccnotify tray` (Linux): a system tray icon for the daemon, the
//! counterpart of the macOS menu bar app in `menubar/`. Its menu shows the
//! service status, a pairing QR code, the paired phones and the Claude Code
//! sessions. Everything comes from the daemon's control socket.
//!
//! The icon is a StatusNotifierItem (KDE, Xfce, Cinnamon, MATE, LXQt…; GNOME
//! needs the AppIndicator extension).

use std::collections::HashSet;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use ksni::menu::{CheckmarkItem, MenuItem, StandardItem, SubMenu};
use ksni::TrayMethods;
use qrcode::{Color, EcLevel, QrCode};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio::time::MissedTickBehavior;

use crate::config::now_ms;
use crate::{cli, control, install, paths};

const TIMEOUT: Duration = Duration::from_secs(3);
/// `sessions` may read transcripts (up to 4 MB each).
const SESSIONS_TIMEOUT: Duration = Duration::from_secs(15);
/// Seconds between status polls, and between phone / session polls.
const STATUS_EVERY: u64 = 5;
const DETAILS_EVERY: u64 = 15;
/// How long "Paired with …" stays in the menu.
const PAIRED_SHOWN: Duration = Duration::from_secs(60);
const MAX_SESSIONS: usize = 10;
/// Claude's last reply inside a session's submenu: line width and count.
const REPLY_LINE_CHARS: usize = 60;
const REPLY_MAX_LINES: usize = 6;

const DESKTOP_ENTRY_NAME: &str = "ccnotify";
const DESKTOP_ENTRY_COMMENT: &str = "Claude Code notifications: tray icon";

// ---------------------------------------------------------------------------
// What the menu shows
// ---------------------------------------------------------------------------

#[derive(Clone, Default, PartialEq)]
struct View {
    /// None while the daemon is not answering.
    status: Option<Status>,
    devices: Vec<Device>,
    sessions: Vec<Session>,
    pairing: Option<PairingView>,
    /// One line of feedback for the last action.
    notice: String,
    autostart: bool,
    /// Minutes since the epoch when the menu was last opened: redraws it
    /// then, so the sessions' "5m ago" stay current.
    minute: u64,
}

#[derive(Clone, Default, PartialEq)]
struct Status {
    name: String,
    port: u64,
    hosts: Vec<String>,
    devices: u64,
    connected: u64,
    pending: u64,
}

#[derive(Clone, PartialEq)]
struct Device {
    id: String,
    name: String,
}

#[derive(Clone, PartialEq)]
struct Session {
    title: String,
    project: String,
    state: String,
    listening: bool,
    queued: u64,
    last_ts: u64,
    last_text: String,
}

#[derive(Clone, PartialEq)]
enum PairingView {
    /// The QR code is open; the code is valid for this many more minutes.
    Waiting { minutes_left: u64 },
    PairedWith(String),
}

enum Action {
    /// The menu is about to open.
    Refresh,
    Pair,
    ShowQr,
    CancelPairing,
    Revoke(String),
    Test,
    Service { restart: bool },
    ToggleAutostart,
    Quit,
}

fn str_of(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

fn u64_of(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// A request to the daemon; None unless it answers `"ok": true`. Blocking.
fn call(req: Value, timeout: Duration) -> Option<Value> {
    let resp = control::request(&req, timeout).ok()?;
    (resp.get("ok").and_then(Value::as_bool) == Some(true)).then_some(resp)
}

fn list_of(resp: Option<Value>, key: &str) -> Vec<Value> {
    resp.and_then(|r| r.get(key).and_then(Value::as_array).cloned())
        .unwrap_or_default()
}

fn load_status() -> Option<Status> {
    let r = call(json!({"cmd": "status"}), TIMEOUT)?;
    Some(Status {
        name: str_of(&r, "name"),
        port: u64_of(&r, "port"),
        hosts: r
            .get("hosts")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default(),
        devices: u64_of(&r, "devices"),
        connected: u64_of(&r, "connected"),
        pending: u64_of(&r, "pending"),
    })
}

fn load_devices() -> Vec<Device> {
    list_of(call(json!({"cmd": "devices"}), TIMEOUT), "devices")
        .iter()
        .map(|d| Device {
            id: str_of(d, "id"),
            name: str_of(d, "name"),
        })
        .collect()
}

fn load_sessions() -> Vec<Session> {
    list_of(call(json!({"cmd": "sessions"}), SESSIONS_TIMEOUT), "sessions")
        .iter()
        .take(MAX_SESSIONS)
        .map(|s| Session {
            title: str_of(s, "title"),
            project: str_of(s, "project"),
            state: str_of(s, "state"),
            listening: s.get("listening").and_then(Value::as_bool) == Some(true),
            queued: u64_of(s, "queued"),
            last_ts: u64_of(s, "last_ts"),
            last_text: str_of(s, "last_text"),
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Tray icon + menu
// ---------------------------------------------------------------------------

struct Tray {
    view: View,
    actions: mpsc::UnboundedSender<Action>,
}

impl Tray {
    fn send(&self, action: Action) {
        let _ = self.actions.send(action);
    }

    fn waiting(&self) -> bool {
        self.view.status.as_ref().is_some_and(|s| s.pending > 0)
            || self.view.sessions.iter().any(|s| s.state == "waiting")
    }

    fn summary(&self) -> String {
        match &self.view.status {
            None => "Service not running".to_string(),
            Some(s) => format!("{} of {} phones connected", s.connected, s.devices),
        }
    }
}

/// A menu label shown as is: dbusmenu treats `_` as an access-key marker.
fn label(text: &str) -> String {
    text.replace('_', "__")
}

fn info<T>(text: &str) -> MenuItem<T> {
    StandardItem {
        label: label(text),
        enabled: false,
        ..Default::default()
    }
    .into()
}

fn item(text: &str, action: impl Fn() -> Action + Send + 'static) -> MenuItem<Tray> {
    StandardItem {
        label: label(text),
        activate: Box::new(move |tray: &mut Tray| tray.send(action())),
        ..Default::default()
    }
    .into()
}

/// Same names as the phone app's state chips.
fn state_label(state: &str) -> &'static str {
    match state {
        "working" => "Working",
        "waiting" => "Needs you",
        "ended" => "Closed",
        _ => "Finished",
    }
}

/// Wrap `text` at word boundaries into at most `max_lines` lines.
fn wrap(text: &str, width: usize, max_lines: usize) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && line.chars().count() + 1 + word.chars().count() > width {
            lines.push(std::mem::take(&mut line));
            if lines.len() == max_lines {
                break;
            }
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() && lines.len() < max_lines {
        lines.push(line);
    }
    lines
}

fn session_menu(s: &Session) -> MenuItem<Tray> {
    let title = if s.title.is_empty() { &s.project } else { &s.title };
    let mut detail = format!("{} · {}", s.project, cli::ago(now_ms(), s.last_ts));
    if s.listening {
        detail.push_str(" · phone can reply");
    }
    if s.queued > 0 {
        detail.push_str(&format!(" · {} queued", s.queued));
    }
    let mut lines = vec![info(&detail)];
    let reply = wrap(&s.last_text, REPLY_LINE_CHARS, REPLY_MAX_LINES);
    if !reply.is_empty() {
        lines.push(MenuItem::Separator);
        lines.extend(reply.iter().map(|l| info(l)));
    }
    SubMenu {
        label: label(&format!("{}: {}", state_label(&s.state), title)),
        submenu: lines,
        ..Default::default()
    }
    .into()
}

impl ksni::Tray for Tray {
    /// A left click opens the menu too.
    const MENU_ON_ACTIVATE: bool = true;

    fn id(&self) -> String {
        "ccnotify".to_string()
    }

    fn title(&self) -> String {
        "ccnotify".to_string()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        let look = if self.view.status.is_none() {
            IconLook::Stopped
        } else if self.waiting() {
            IconLook::Waiting
        } else {
            IconLook::Normal
        };
        [22, 32, 48].iter().map(|&size| bell_icon(size, look)).collect()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "ccnotify".to_string(),
            description: self.summary(),
            ..Default::default()
        }
    }

    fn menu_about_to_show(&mut self) {
        self.send(Action::Refresh);
    }

    fn watcher_offline(&self, reason: ksni::OfflineReason) -> bool {
        eprintln!(
            "ccnotify: no system tray to show the icon in yet ({reason:?}). \
             GNOME needs the \"AppIndicator and KStatusNotifierItem Support\" extension."
        );
        // Keep running: the icon appears when a tray comes up.
        true
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let view = &self.view;
        let mut menu: Vec<MenuItem<Self>> = Vec::new();

        match &view.status {
            Some(s) => {
                let address = match s.hosts.first() {
                    Some(host) => format!("{host}:{}", s.port),
                    None => format!("port {}", s.port),
                };
                menu.push(info(&format!("{} · {address}", s.name)));
                menu.push(info(&self.summary()));
                if s.pending > 0 {
                    let plural = if s.pending == 1 { "" } else { "s" };
                    menu.push(info(&format!(
                        "{} prompt{plural} waiting for an answer",
                        s.pending
                    )));
                }
            }
            None => {
                menu.push(info("The ccnotify service is not running"));
                menu.push(item("Start Service", || Action::Service { restart: false }));
            }
        }
        if !view.notice.is_empty() {
            menu.push(info(&view.notice));
        }

        if view.status.is_some() {
            menu.push(MenuItem::Separator);
            match &view.pairing {
                None => menu.push(item("Pair a Phone…", || Action::Pair)),
                Some(PairingView::Waiting { minutes_left }) => {
                    menu.push(info(&format!(
                        "Scan the QR code with the ccnotify app ({minutes_left} min left)"
                    )));
                    menu.push(item("Show the QR Code Again", || Action::ShowQr));
                    menu.push(item("Cancel Pairing", || Action::CancelPairing));
                }
                Some(PairingView::PairedWith(name)) => {
                    menu.push(info(&format!("Paired with {name}")));
                    menu.push(item("Pair Another Phone…", || Action::Pair));
                }
            }

            let phones: Vec<MenuItem<Self>> = if view.devices.is_empty() {
                vec![info("No phone paired yet")]
            } else {
                view.devices
                    .iter()
                    .map(|d| {
                        let id = d.id.clone();
                        SubMenu {
                            label: label(&d.name),
                            submenu: vec![item("Unpair", move || Action::Revoke(id.clone()))],
                            ..Default::default()
                        }
                        .into()
                    })
                    .collect()
            };
            menu.push(
                SubMenu {
                    label: format!("Phones ({})", view.devices.len()),
                    submenu: phones,
                    ..Default::default()
                }
                .into(),
            );

            menu.push(MenuItem::Separator);
            if view.sessions.is_empty() {
                menu.push(info("No Claude Code sessions yet"));
            }
            menu.extend(view.sessions.iter().map(session_menu));

            menu.push(MenuItem::Separator);
            menu.push(item("Send Test Notification", || Action::Test));
            menu.push(item("Restart Service", || Action::Service { restart: true }));
        }

        menu.push(MenuItem::Separator);
        menu.push(
            CheckmarkItem {
                label: "Start at Login".to_string(),
                checked: view.autostart,
                activate: Box::new(|tray: &mut Tray| tray.send(Action::ToggleAutostart)),
                ..Default::default()
            }
            .into(),
        );
        menu.push(item("Quit", || Action::Quit));
        menu
    }
}

// ---------------------------------------------------------------------------
// Icon: a bell, drawn here so it does not depend on the icon theme
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum IconLook {
    Normal,
    /// Grey with a slash: the daemon is not running.
    Stopped,
    /// With a red dot: Claude Code waits for an answer.
    Waiting,
}

/// Terracotta, like the phone app.
const BELL_COLOR: [u8; 3] = [0xD9, 0x77, 0x57];
const STOPPED_COLOR: [u8; 3] = [0x8C, 0x8C, 0x8C];
const DOT_COLOR: [u8; 3] = [0xE5, 0x48, 0x4D];

fn in_circle(u: f32, v: f32, cu: f32, cv: f32, r: f32) -> bool {
    (u - cu).powi(2) + (v - cv).powi(2) <= r * r
}

/// The bell's silhouette in the unit square (v grows downwards).
fn in_bell(u: f32, v: f32) -> bool {
    let off = (u - 0.5).abs();
    let knob = in_circle(u, v, 0.5, 0.13, 0.06) || (off <= 0.035 && (0.13..=0.2).contains(&v));
    let dome = v <= 0.44 && in_circle(u, v, 0.5, 0.44, 0.27);
    // Widens towards the rim.
    let body = (0.44..=0.72).contains(&v) && off <= 0.27 + 0.1 * ((v - 0.44) / 0.28).powi(2);
    let rim = (0.70..=0.78).contains(&v) && off <= 0.4;
    let clapper = v >= 0.8 && in_circle(u, v, 0.5, 0.8, 0.1);
    knob || dome || body || rim || clapper
}

/// A diagonal bar from the top left to the bottom right, `half_width` thick
/// on each side.
fn in_slash(u: f32, v: f32, half_width: f32) -> bool {
    let (au, av, bu, bv) = (0.14_f32, 0.1_f32, 0.86_f32, 0.92_f32);
    let (du, dv) = (bu - au, bv - av);
    let t = (((u - au) * du + (v - av) * dv) / (du * du + dv * dv)).clamp(0.0, 1.0);
    in_circle(u, v, au + t * du, av + t * dv, half_width)
}

/// `size`×`size` ARGB32 pixels, anti-aliased by 4×4 supersampling.
fn bell_icon(size: i32, look: IconLook) -> ksni::Icon {
    const SUB: i32 = 4;
    let color = if look == IconLook::Stopped { STOPPED_COLOR } else { BELL_COLOR };
    let mut data = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            // Sum of the covering samples' colours, and their count.
            let mut sum = [0u32; 3];
            let mut covered = 0u32;
            for sy in 0..SUB {
                for sx in 0..SUB {
                    let u = (x as f32 + (sx as f32 + 0.5) / SUB as f32) / size as f32;
                    let v = (y as f32 + (sy as f32 + 0.5) / SUB as f32) / size as f32;
                    let sample = if look == IconLook::Waiting && in_circle(u, v, 0.77, 0.25, 0.2) {
                        Some(DOT_COLOR)
                    } else if look == IconLook::Stopped && in_slash(u, v, 0.1) {
                        // The slash, with a gap that separates it from the bell.
                        in_slash(u, v, 0.045).then_some(color)
                    } else if in_bell(u, v) {
                        Some(color)
                    } else {
                        None
                    };
                    if let Some(c) = sample {
                        covered += 1;
                        for i in 0..3 {
                            sum[i] += u32::from(c[i]);
                        }
                    }
                }
            }
            let alpha = (covered * 255 / (SUB * SUB) as u32) as u8;
            data.push(alpha);
            for channel in sum {
                data.push(if covered == 0 { 0 } else { (channel / covered) as u8 });
            }
        }
    }
    ksni::Icon {
        width: size,
        height: size,
        data,
    }
}

// ---------------------------------------------------------------------------
// Pairing QR code (a PNG opened in the image viewer)
// ---------------------------------------------------------------------------

/// Pixels per QR module, and the white border in modules.
const QR_SCALE: usize = 8;
const QR_QUIET_ZONE: usize = 4;

/// Next to the control socket (`$XDG_RUNTIME_DIR`), readable by the user only.
fn qr_file() -> PathBuf {
    paths::socket_path().with_file_name("ccnotify-pair.png")
}

fn qr_png(payload: &str) -> Result<Vec<u8>> {
    let code = QrCode::with_error_correction_level(payload.as_bytes(), EcLevel::M)?;
    let modules = code.width();
    let colors = code.to_colors();
    let size = (modules + 2 * QR_QUIET_ZONE) * QR_SCALE;
    // One bit per pixel, rows padded to whole bytes; 1 is white.
    let row_bytes = size.div_ceil(8);
    let mut bits = vec![0xFFu8; row_bytes * size];
    for (i, color) in colors.iter().enumerate() {
        if *color != Color::Dark {
            continue;
        }
        let (mx, my) = (i % modules + QR_QUIET_ZONE, i / modules + QR_QUIET_ZONE);
        for y in my * QR_SCALE..(my + 1) * QR_SCALE {
            for x in mx * QR_SCALE..(mx + 1) * QR_SCALE {
                bits[y * row_bytes + x / 8] &= !(0x80 >> (x % 8));
            }
        }
    }
    Ok(png_1bit(size as u32, row_bytes, &bits))
}

/// A 1-bit greyscale PNG. The pixel data is stored uncompressed, so no
/// compression library is needed.
fn png_1bit(size: u32, row_bytes: usize, bits: &[u8]) -> Vec<u8> {
    // Every scanline starts with its filter type (0: none).
    let mut raw = Vec::with_capacity(bits.len() + size as usize);
    for row in bits.chunks(row_bytes) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    // zlib stream of stored deflate blocks (at most 65535 bytes each).
    let mut zlib = vec![0x78, 0x01];
    let mut blocks = raw.chunks(0xFFFF).peekable();
    while let Some(block) = blocks.next() {
        let len = block.len() as u16;
        zlib.push(u8::from(blocks.peek().is_none()));
        zlib.extend_from_slice(&len.to_le_bytes());
        zlib.extend_from_slice(&(!len).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut header = Vec::new();
    header.extend_from_slice(&size.to_be_bytes());
    header.extend_from_slice(&size.to_be_bytes());
    // Bit depth 1, greyscale, deflate, no filter, no interlace.
    header.extend_from_slice(&[1, 0, 0, 0, 0]);

    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png_chunk(&mut png, b"IHDR", &header);
    png_chunk(&mut png, b"IDAT", &zlib);
    png_chunk(&mut png, b"IEND", &[]);
    png
}

fn png_chunk(png: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    png.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = png.len();
    png.extend_from_slice(kind);
    png.extend_from_slice(data);
    let crc = crc32(&png[start..]);
    png.extend_from_slice(&crc.to_be_bytes());
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in data {
        a = (a + u32::from(byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    (b << 16) | a
}

/// Run a desktop helper (`xdg-open`, `notify-send`) without waiting for it.
fn spawn_helper(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

// ---------------------------------------------------------------------------
// Start at login + application menu entry
// ---------------------------------------------------------------------------

fn desktop_entry(bin: &Path) -> String {
    format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name={DESKTOP_ENTRY_NAME}\n\
         Comment={DESKTOP_ENTRY_COMMENT}\n\
         Exec={}\n\
         Icon=preferences-system-notifications\n\
         Terminal=false\n\
         Categories=Utility;\n",
        install::bin_command(bin, "tray")
    )
}

/// The installed binary if there is one, else the running one.
fn tray_binary() -> PathBuf {
    let installed = paths::installed_bin();
    if installed.exists() {
        installed
    } else {
        std::env::current_exe().unwrap_or(installed)
    }
}

/// Add "ccnotify" to the desktop's application menu (`ccnotify install`).
pub fn install_launcher(bin: &Path) -> Result<()> {
    let path = paths::launcher_entry();
    paths::write_atomic(&path, desktop_entry(bin).as_bytes(), 0o644)
        .with_context(|| format!("writing {}", path.display()))
}

/// Remove the application menu and start-at-login entries
/// (`ccnotify uninstall`). Returns the removed files.
pub fn remove_entries() -> Vec<PathBuf> {
    [paths::launcher_entry(), paths::autostart_entry()]
        .into_iter()
        .filter(|path| fs::remove_file(path).is_ok())
        .collect()
}

fn autostart_enabled() -> bool {
    paths::autostart_entry().exists()
}

fn set_autostart(enabled: bool) -> Result<()> {
    let path = paths::autostart_entry();
    if enabled {
        paths::write_atomic(&path, desktop_entry(&tray_binary()).as_bytes(), 0o644)
            .with_context(|| format!("writing {}", path.display()))
    } else if path.exists() {
        fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))
    } else {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

/// A pairing code whose QR code is open.
struct Pairing {
    /// Devices that were paired before: a new id means the phone scanned it.
    known: HashSet<String>,
    expires: Instant,
    /// When a phone paired with it (the menu then says so for a while).
    paired_at: Option<Instant>,
}

struct App {
    view: View,
    pairing: Option<Pairing>,
    handle: ksni::Handle<Tray>,
}

/// Run blocking daemon requests off the async threads.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    tokio::task::spawn_blocking(f).await.ok()
}

impl App {
    /// Redraw the icon and the menu if anything changed.
    async fn publish(&mut self, last: &mut View) {
        if self.view != *last {
            *last = self.view.clone();
            let view = self.view.clone();
            self.handle.update(move |tray| tray.view = view).await;
        }
    }

    async fn refresh(&mut self, details: bool) {
        self.view.status = blocking(load_status).await.flatten();
        if self.view.status.is_none() {
            self.view.devices.clear();
            self.view.sessions.clear();
        } else if details {
            self.view.devices = blocking(load_devices).await.unwrap_or_default();
            self.view.sessions = blocking(load_sessions).await.unwrap_or_default();
        }
    }

    async fn start_pairing(&mut self) {
        self.stop_pairing();
        let started = blocking(|| -> Result<(HashSet<String>, u64)> {
            let known = load_devices().into_iter().map(|d| d.id).collect();
            let reply = call(json!({"cmd": "pair"}), TIMEOUT)
                .ok_or_else(|| anyhow!("the service did not answer"))?;
            let payload = str_of(&reply, "qr");
            if payload.is_empty() {
                bail!("the service returned no pairing code");
            }
            paths::write_atomic(&qr_file(), &qr_png(&payload)?, 0o600)?;
            Ok((known, u64_of(&reply, "expires_in").max(1)))
        })
        .await;
        match started {
            Some(Ok((known, seconds))) => {
                self.pairing = Some(Pairing {
                    known,
                    expires: Instant::now() + Duration::from_secs(seconds),
                    paired_at: None,
                });
                self.show_qr();
            }
            Some(Err(e)) => self.view.notice = format!("Could not start pairing: {e:#}"),
            None => {}
        }
    }

    fn show_qr(&mut self) {
        let file = qr_file();
        let file = file.to_string_lossy();
        self.view.notice = if spawn_helper("xdg-open", &[&file]) {
            String::new()
        } else {
            format!("Open {file} to see the QR code")
        };
    }

    fn stop_pairing(&mut self) {
        self.pairing = None;
        self.view.pairing = None;
        let _ = fs::remove_file(qr_file());
    }

    /// Once a second while pairing: has a phone used the code, or has it
    /// expired?
    async fn poll_pairing(&mut self) {
        let Some(pairing) = &self.pairing else {
            return;
        };
        let (expires, paired_at) = (pairing.expires, pairing.paired_at);
        if let Some(at) = paired_at {
            if at.elapsed() > PAIRED_SHOWN {
                self.stop_pairing();
            }
            return;
        }
        let now = Instant::now();
        if now >= expires {
            self.stop_pairing();
            self.view.notice = "The pairing code expired".to_string();
            return;
        }
        let known = pairing.known.clone();
        let devices = blocking(load_devices).await.unwrap_or_default();
        match devices.into_iter().find(|d| !known.contains(&d.id)) {
            Some(new) => {
                if let Some(pairing) = &mut self.pairing {
                    pairing.paired_at = Some(now);
                }
                let _ = fs::remove_file(qr_file());
                spawn_helper("notify-send", &["ccnotify", &format!("Paired with {}", new.name)]);
                self.view.pairing = Some(PairingView::PairedWith(new.name));
                self.refresh(true).await;
            }
            None => {
                let left = expires.duration_since(now).as_secs();
                self.view.pairing = Some(PairingView::Waiting {
                    minutes_left: left.div_ceil(60),
                });
            }
        }
    }

    /// False to quit.
    async fn act(&mut self, action: Action) -> bool {
        match action {
            Action::Refresh => {
                self.view.minute = now_ms() / 60_000;
                self.refresh(true).await;
            }
            Action::Pair => {
                self.start_pairing().await;
                self.poll_pairing().await;
            }
            Action::ShowQr => self.show_qr(),
            Action::CancelPairing => self.stop_pairing(),
            Action::Revoke(id) => {
                // "Paired with …" may be about the phone being removed.
                if self.pairing.as_ref().is_some_and(|p| p.paired_at.is_some()) {
                    self.stop_pairing();
                }
                let done = blocking(move || call(json!({"cmd": "revoke", "id": id}), TIMEOUT))
                    .await
                    .flatten()
                    .is_some();
                self.view.notice =
                    if done { "Phone unpaired" } else { "Could not unpair the phone" }.to_string();
                self.refresh(true).await;
            }
            Action::Test => {
                let event = json!({
                    "kind": "stop",
                    "project": "ccnotify",
                    "cwd": "",
                    "session": "test",
                    "message": "Test notification from ccnotify",
                    "detail": "",
                });
                let sent = blocking(move || call(json!({"cmd": "emit", "event": event}), TIMEOUT))
                    .await
                    .flatten()
                    .is_some();
                self.refresh(false).await;
                let connected = self.view.status.as_ref().map_or(0, |s| s.connected);
                self.view.notice = match (sent, connected) {
                    (false, _) => "The service is not running".to_string(),
                    (true, 0) => "Sent, but no phone is connected right now".to_string(),
                    (true, n) => format!("Test notification sent to {n} phone(s)"),
                };
            }
            Action::Service { restart } => {
                let verb = if restart { "restart" } else { "start" };
                let started = blocking(move || {
                    Command::new("systemctl")
                        .args(["--user", verb, "ccnotify"])
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .status()
                        .is_ok_and(|s| s.success())
                })
                .await
                .unwrap_or(false);
                // The daemon needs a moment to bind its socket.
                tokio::time::sleep(Duration::from_millis(1500)).await;
                self.refresh(true).await;
                self.view.notice = if self.view.status.is_some() {
                    String::new()
                } else if started {
                    "The service did not start: journalctl --user -u ccnotify".to_string()
                } else {
                    "The service is not installed: run `ccnotify install`".to_string()
                };
            }
            Action::ToggleAutostart => {
                if let Err(e) = set_autostart(!autostart_enabled()) {
                    self.view.notice = format!("{e:#}");
                }
                self.view.autostart = autostart_enabled();
            }
            Action::Quit => return false,
        }
        true
    }
}

/// Only one tray icon per user: hold a lock file while running.
fn lock_single_instance() -> Result<File> {
    let path = paths::socket_path().with_file_name("ccnotify-tray.lock");
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let file = File::create(&path).with_context(|| format!("creating {}", path.display()))?;
    if file.try_lock().is_err() {
        bail!("the ccnotify tray icon is already running");
    }
    Ok(file)
}

pub fn run() -> Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("starting tokio runtime")?;
    rt.block_on(run_async())
}

async fn run_async() -> Result<()> {
    let _lock = lock_single_instance()?;
    let (actions, mut inbox) = mpsc::unbounded_channel::<Action>();

    let view = View {
        autostart: autostart_enabled(),
        ..View::default()
    };
    let tray = Tray {
        view: view.clone(),
        actions,
    };
    // Started at login, the icon may come up before the desktop's tray does.
    let handle = tray
        .assume_sni_available(true)
        .spawn()
        .await
        .map_err(|e| anyhow!("starting the tray icon: {e}"))?;

    let mut app = App {
        view,
        pairing: None,
        handle,
    };
    let mut published = app.view.clone();
    app.refresh(true).await;
    app.publish(&mut published).await;

    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut seconds = 0u64;
    loop {
        tokio::select! {
            action = inbox.recv() => {
                let Some(action) = action else { break };
                if !app.act(action).await {
                    break;
                }
            }
            _ = tick.tick() => {
                seconds += 1;
                if seconds % DETAILS_EVERY == 0 {
                    app.refresh(true).await;
                } else if seconds % STATUS_EVERY == 0 {
                    app.refresh(false).await;
                }
                app.poll_pairing().await;
            }
        }
        app.publish(&mut published).await;
        if app.handle.is_closed() {
            break;
        }
    }

    app.stop_pairing();
    // Let the reply to the menu click that quit us go out first.
    tokio::time::sleep(Duration::from_millis(100)).await;
    app.handle.shutdown().await;
    Ok(())
}

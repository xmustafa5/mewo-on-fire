//! v2.6: headless Claude Code sessions for the build autopilot. Claude
//! Desktop's deep link only types the prompt in and waits for Enter; the
//! command-line tool runs it to the end by itself. The hooks still report
//! the session, so it shows on the console and the phones like any other.

use std::collections::HashMap;
use std::fs::{self, File};
use std::path::PathBuf;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Mutex;

use crate::{config::now_ms, paths};

/// Exit codes of the runs that finished, by pid.
static EXITS: Mutex<Option<HashMap<u32, i32>>> = Mutex::new(None);

/// What a message calls this computer.
const HERE: &str = if cfg!(target_os = "macos") { "this Mac" } else { "this PC" };

/// Where the Claude Code command is on this computer, when it is installed.
pub fn claude_bin() -> Option<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/.local/bin/claude"),
        "/opt/homebrew/bin/claude".to_string(),
        "/usr/local/bin/claude".to_string(),
        format!("{home}/.claude/local/claude"),
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|p| p.is_file())
}

/// v2.9: the Mac stays awake while a build runs. `caffeinate -i` tied to
/// the daemon's own pid prevents idle sleep; it is stopped when no build
/// is on. (A closed lid still sleeps a MacBook unless it is plugged in
/// with an external display: keep the lid open.)
static AWAKE: Mutex<Option<std::process::Child>> = Mutex::new(None);

pub fn keep_awake(on: bool) {
    let mut g = AWAKE.lock().unwrap_or_else(|p| p.into_inner());
    let alive = g.as_mut().map(|c| c.try_wait().ok().flatten().is_none()).unwrap_or(false);
    if on && !alive {
        *g = Command::new("caffeinate").args(["-i", "-w", &std::process::id().to_string()]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().ok();
    } else if !on && alive {
        if let Some(mut c) = g.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Signed in? The command keeps its sign-in in the login keychain under
/// "Claude Code-credentials" on macOS, in `~/.claude/.credentials.json` on
/// Linux (only whether the file is there is looked at); without it every
/// run stops at once.
pub fn signed_in() -> bool {
    if !cfg!(target_os = "macos") {
        let dir = std::env::var("CLAUDE_CONFIG_DIR").ok().filter(|d| !d.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".claude"));
        return dir.join(".credentials.json").is_file() || std::env::var("ANTHROPIC_API_KEY").is_ok_and(|k| !k.is_empty());
    }
    Command::new("security").args(["find-generic-password", "-s", "Claude Code-credentials"]).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
}

/// What stands in the way of a headless run, in one line; nothing when
/// it can run.
pub fn ready() -> Result<(), String> {
    if claude_bin().is_none() {
        return Err(format!("Claude Code is not installed on {HERE}: run the installer from claude.ai (curl -fsSL https://claude.ai/install.sh | bash)"));
    }
    if !signed_in() {
        return Err("Claude Code is installed but not signed in: run `claude` in a terminal, then `/login`, once".to_string());
    }
    Ok(())
}

/// The model for a plan tier: the account's default for Tier 1, Sonnet
/// for Tier 2, Haiku for Tier 3 (policy 9.1 moves a repeat one tier up).
pub fn model_for(tier: u8) -> Option<&'static str> {
    match tier {
        2 => Some("sonnet"),
        3 => Some("haiku"),
        _ => None,
    }
}

/// launchd and systemd give the daemon a short PATH; a session needs
/// where Homebrew, the installer and the user put their tools.
fn session_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Library/Developer/CommandLineTools/usr/bin:{}", std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".to_string()))
}

/// Starts a session in `folder` that runs `prompt` to the end with
/// permissions skipped (the Mewo guard hook still refuses pushes to
/// main). Returns its pid; its output goes to `<state>/runs/<tag>-<ts>.log`.
pub fn spawn(folder: &str, prompt: &str, model: Option<&str>, tag: &str) -> Result<u32, String> {
    ready()?;
    let bin = claude_bin().ok_or_else(|| format!("Claude Code is not installed on {HERE}"))?;
    if !std::path::Path::new(folder).is_dir() {
        return Err(format!("No such folder on {HERE}: {folder}"));
    }
    let dir = paths::state_dir().join("runs");
    let _ = fs::create_dir_all(&dir);
    let safe: String = tag.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let log = dir.join(format!("{safe}-{}.log", now_ms()));
    let out = File::create(&log).map_err(|e| e.to_string())?;
    let err = File::create(log.with_extension("err")).map_err(|e| e.to_string())?;
    let mut cmd = outliving(&bin);
    cmd.current_dir(folder).arg("-p").arg(prompt).arg("--dangerously-skip-permissions").arg("--output-format").arg("text");
    if let Some(m) = model {
        cmd.arg("--model").arg(m);
    }
    cmd.env("PATH", session_path()).env("MEWO_HEADLESS", "1").stdin(Stdio::null()).stdout(out).stderr(err);
    // The pinned GitHub account, whatever gh has active.
    cmd.envs(crate::github::envs());
    // Its own process group (launchd) and scope (systemd): a daemon restart must not take the session down.
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|e| format!("could not start claude: {e}"))?;
    let pid = child.id();
    // Reap it when it ends, and remember how it ended.
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        let mut g = EXITS.lock().unwrap_or_else(|p| p.into_inner());
        g.get_or_insert_with(HashMap::new).insert(pid, code);
    });
    Ok(pid)
}

/// v3.0: the Mewo Session window (console/linux/mewo-session) and, v3.1,
/// the page of its chat, written next to the state when a session opens,
/// so they always match the daemon.
const SESSION_WINDOW: &str = include_str!("../console/linux/mewo-session");
const SESSION_CHAT: &str = include_str!("../console/linux/mewo-session-chat.html");

/// The console's colours, for a terminal that is not the Mewo Session
/// window: foreground, background, cursor, then the sixteen ANSI colours.
const COLOURS: &str = "printf '\\033]10;#dbeafe\\007\\033]11;#04070c\\007\\033]12;#4fd1ff\\007\\033]4;0;#0b1220;1;#ff3d1f;2;#3dd68c;3;#ffb347;4;#2f6bff;5;#b98cff;6;#4fd1ff;7;#dbeafe;8;#3a4a5e;9;#ff6b35;10;#6ee7a8;11;#ffd08a;12;#6b93ff;13;#d4b0ff;14;#8fe3ff;15;#ffffff\\007'";

/// v3.0: a session you watch ("Build with me"): Claude Code in a window of
/// its own, in `folder`, with `prompt` as its first message. On Linux it is
/// the Mewo Session window, its header following the session: since v3.1 a
/// chat drawn the way the Claude Code extension draws it, over Claude Code
/// in its stream mode (the script's `chat` argument); without WebKitGTK,
/// or with `session_terminal` in config.json, Claude Code in a terminal in
/// that window; elsewhere a terminal app in the console's colours.
/// Permissions are skipped as for a headless run, but a question waits for
/// you, in the window and on the phones. A small script under
/// `<state>/runs/` records its pid and then becomes Claude Code, so the
/// returned pid is the session's own: alive while the window is open.
/// `info` carries what the header shows (n, goal, feature, workspace,
/// branch, model_label, title).
pub fn spawn_visible(folder: &str, prompt: &str, model: Option<&str>, tag: &str, info: serde_json::Value) -> Result<u32, String> {
    ready()?;
    let bin = claude_bin().ok_or_else(|| format!("Claude Code is not installed on {HERE}"))?;
    if !std::path::Path::new(folder).is_dir() {
        return Err(format!("No such folder on {HERE}: {folder}"));
    }
    let dir = paths::state_dir().join("runs");
    let _ = fs::create_dir_all(&dir);
    let safe: String = tag.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let base = format!("{safe}-{}", now_ms());
    let prompt_file = dir.join(format!("{base}.prompt"));
    let pid_file = dir.join(format!("{base}.pid"));
    let script = dir.join(format!("{base}.sh"));
    fs::write(&prompt_file, prompt).map_err(|e| e.to_string())?;
    let title = info.get("title").and_then(serde_json::Value::as_str).unwrap_or(tag).to_string();
    let sq = |s: &str| format!("'{}'", s.replace('\'', r"'\''"));
    let mut sh = String::from("#!/bin/sh\n# Mewo on Fire: a build session to watch (Build with me).\n");
    sh.push_str(&format!("export PATH={}\n", sq(&session_path())));
    // The pinned GitHub account, read from gh's store here: no token on disk.
    let user = crate::github::user();
    if let (Some(gh), false) = (crate::prs::gh_path(), user.is_empty()) {
        sh.push_str(&format!("GH_TOKEN=$(env -u GH_TOKEN {} auth token --user {} 2>/dev/null) && [ -n \"$GH_TOKEN\" ] && export GH_TOKEN\n", sq(&gh.to_string_lossy()), sq(&user)));
    }
    sh.push_str(&format!("echo $$ > {}\n", sq(&pid_file.to_string_lossy())));
    let model_arg = model.map(|m| format!(" --model {m}")).unwrap_or_default();
    // The chat: JSON lines on stdin and stdout; the window sends the prompt and answers what asks.
    sh.push_str(&format!(
        "if [ \"$1\" = chat ]; then\n  cd {} || exit 1\n  exec {} -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio --dangerously-skip-permissions{}\nfi\n",
        sq(folder),
        sq(&bin.to_string_lossy()),
        model_arg
    ));
    sh.push_str(&format!("printf '\\033]0;%s\\007' {}\n", sq(&title)));
    sh.push_str(COLOURS);
    sh.push('\n');
    sh.push_str(&format!("cd {} || exit 1\n", sq(folder)));
    sh.push_str(&format!(
        "exec {} --dangerously-skip-permissions{} \"$(cat {})\"\n",
        sq(&bin.to_string_lossy()),
        model_arg,
        sq(&prompt_file.to_string_lossy())
    ));
    fs::write(&script, sh).map_err(|e| e.to_string())?;
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    }
    let script_s = script.to_string_lossy().into_owned();
    let mut info = info;
    if let Some(o) = info.as_object_mut() {
        o.insert("prompt_file".into(), prompt_file.to_string_lossy().into_owned().into());
        o.insert("model".into(), model.unwrap_or("").into());
        o.insert("mode".into(), if crate::config::session_terminal() { "terminal" } else { "chat" }.into());
    }
    if !open_session_window(folder, &script_s, &dir.join(format!("{base}.json")), info) {
        open_terminal(&script_s)?;
    }
    // The window takes a moment; its script writes the pid first thing.
    for _ in 0..60 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        if let Some(pid) = fs::read_to_string(&pid_file).ok().and_then(|t| t.trim().parse::<u32>().ok()).filter(|p| *p != 0) {
            return Ok(pid);
        }
    }
    Err(format!("No window opened on {HERE} for the session"))
}

/// The Mewo Session window, when this computer can show it (Linux with
/// GTK 3 for Python and WebKitGTK for the chat or VTE for the terminal),
/// started so a restart of the daemon leaves it open. False: use a
/// terminal app.
fn open_session_window(folder: &str, script: &str, info_file: &std::path::Path, mut info: serde_json::Value) -> bool {
    if cfg!(target_os = "macos") {
        return false;
    }
    let Some(python) = find_tool("python3") else { return false };
    let check = "import gi\ngi.require_version('Gtk', '3.0')\nfrom gi.repository import Gtk\ntry:\n    gi.require_version('WebKit2', '4.1')\n    from gi.repository import WebKit2\nexcept (ValueError, ImportError):\n    gi.require_version('Vte', '2.91')\n    from gi.repository import Vte";
    if !Command::new(&python).args(["-c", check]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false) {
        return false;
    }
    let window = paths::state_dir().join("mewo-session");
    let chat = paths::state_dir().join("mewo-session-chat.html");
    for (path, text) in [(&window, SESSION_WINDOW), (&chat, SESSION_CHAT)] {
        if fs::read_to_string(path).ok().as_deref() != Some(text) && fs::write(path, text).is_err() {
            return false;
        }
    }
    let data = std::env::var("XDG_DATA_HOME").ok().filter(|d| !d.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/share"));
    if let Some(o) = info.as_object_mut() {
        o.insert("folder".into(), folder.into());
        o.insert("script".into(), script.into());
        o.insert("socket".into(), paths::socket_path().to_string_lossy().into_owned().into());
        o.insert("icon".into(), data.join("mewo-on-fire/console/mewo-console.png").to_string_lossy().into_owned().into());
        // Grouped with Mewo Console in the dock.
        o.insert("app_id".into(), "com.torchcorp.mewo-on-fire.console".into());
    }
    if fs::write(info_file, info.to_string()).is_err() {
        return false;
    }
    let mut cmd = outliving(&python);
    cmd.arg(&window).arg(info_file);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
    match cmd.spawn() {
        Ok(mut child) => {
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            true
        }
        Err(_) => false,
    }
}

/// A command that outlives a restart of the daemon. Stopping a systemd
/// service ends every process in its cgroup, whatever its process group,
/// and `mewo install` restarts the service; so under systemd a session, a
/// review or a window starts in a scope of its own. `systemd-run --scope`
/// becomes the command, so the pid, the exit code, the folder, the
/// environment and the output stay the program's. Under launchd, and when
/// the daemon runs outside systemd, its own process group is enough.
fn outliving(program: &std::path::Path) -> Command {
    if cfg!(target_os = "linux") && std::env::var_os("INVOCATION_ID").is_some() {
        if let Some(run) = find_tool("systemd-run") {
            let mut c = Command::new(run);
            c.args(["--user", "--scope", "--quiet", "--collect", "--"]).arg(program);
            return c;
        }
    }
    Command::new(program)
}

/// A tool on the session PATH (the daemon's own is short).
fn find_tool(name: &str) -> Option<PathBuf> {
    session_path().split(':').chain(["/usr/bin", "/bin"]).map(|d| PathBuf::from(d).join(name)).find(|p| p.is_file())
}

/// Runs `script` in a new terminal window: Terminal on macOS; on Linux
/// the desktop's default terminal (xdg-terminal-exec), else the first
/// known one installed.
fn open_terminal(script: &str) -> Result<(), String> {
    let s = script.to_string();
    let tries: Vec<(&str, Vec<String>)> = if cfg!(target_os = "macos") {
        vec![("open", vec!["-a".into(), "Terminal".into(), s])]
    } else {
        vec![
            ("xdg-terminal-exec", vec![s.clone()]),
            ("ptyxis", vec!["--new-window".into(), "--".into(), s.clone()]),
            ("gnome-terminal", vec!["--".into(), s.clone()]),
            ("konsole", vec!["-e".into(), s.clone()]),
            ("xfce4-terminal", vec!["-x".into(), s.clone()]),
            ("kitty", vec![s.clone()]),
            ("alacritty", vec!["-e".into(), s.clone()]),
            ("x-terminal-emulator", vec!["-e".into(), s.clone()]),
            ("xterm", vec!["-e".into(), s]),
        ]
    };
    for (name, args) in tries {
        let Some(bin) = find_tool(name) else { continue };
        let mut cmd = outliving(&bin);
        cmd.args(&args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
        if let Ok(mut child) = cmd.spawn() {
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            return Ok(());
        }
    }
    Err(format!("No terminal app found on {HERE} to open the session in"))
}

/// Still running?
pub fn alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    if EXITS.lock().unwrap_or_else(|p| p.into_inner()).as_ref().map(|m| m.contains_key(&pid)).unwrap_or(false) {
        return false;
    }
    Command::new("kill").arg("-0").arg(pid.to_string()).stdout(Stdio::null()).stderr(Stdio::null()).status().map(|s| s.success()).unwrap_or(false)
}

/// How a run ended, when it did.
pub fn exit_code(pid: u32) -> Option<i32> {
    EXITS.lock().unwrap_or_else(|p| p.into_inner()).as_ref().and_then(|m| m.get(&pid).copied())
}

//! ccnotify — Claude Code notifications to your phone over the LAN.
//! See ../PROTOCOL.md for the wire contract.

mod ask;
mod cli;
mod config;
mod control;
mod daemon;
mod hook;
mod install;
mod listen;
mod mdns;
mod net;
mod paths;
mod relay;
mod requests;
mod server;
mod sessions;
mod store;
mod suggest;
mod transcript;
mod uploads;
#[cfg(target_os = "linux")]
mod tray;

const HELP: &str = "\
ccnotify - Claude Code notifications on your phone (LAN only)

Usage: ccnotify <command>

Commands:
  install        Install binary to ~/.local/bin, the background service (systemd user
                 unit on Linux, launchd agent on macOS) and Claude Code hooks
  pair           Show a QR code to pair a phone (waits until paired)
  devices        List paired phones
  revoke <id>    Unpair a phone
  status         Show daemon status
  sessions       List Claude Code sessions (state, listening, queued phone messages)
  chat <session> Show the last 20 chat items of a session (id prefix from `sessions`)
  test           Send a test notification
  test-ask       Send a test permission request and print the phone's answer
  relay <url>    Use a relay so phones also connect away from the LAN (`relay off`
                 to stop; see relay/ for the relay itself)
  relay-server [port]
                 Be the relay: run this on a machine the internet can reach
  suggestions on|off
                 Have Claude end its replies with suggested next messages, shown
                 as buttons in the app
  tray           Show a system tray icon: status, pairing QR code, phones, sessions
                 (Linux; on macOS use the menu bar app in menubar/)
  uninstall      Remove hooks and the background service (keeps config and history)
  daemon         Run the daemon in the foreground (normally started by systemd / launchd)
  hook           Claude Code hook entry point (reads hook JSON on stdin)
  ask            Claude Code PermissionRequest hook (answer prompts from the phone)
  listen         Claude Code Stop hook (continue the session from the phone)
  help           Show this help
";

#[cfg(target_os = "linux")]
fn tray() -> anyhow::Result<()> {
    tray::run()
}

#[cfg(not(target_os = "linux"))]
fn tray() -> anyhow::Result<()> {
    anyhow::bail!("`ccnotify tray` is for Linux; on macOS use the menu bar app (pc/menubar/install.sh)")
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    if cmd == "hook" {
        hook::run();
    }
    if cmd == "ask" {
        ask::run();
    }
    if cmd == "listen" {
        listen::run();
    }

    let result = match cmd {
        "daemon" => daemon::run(),
        "pair" => cli::pair(),
        "devices" => cli::devices(),
        "revoke" => match args.get(1) {
            Some(id) => cli::revoke(id),
            None => {
                eprintln!("usage: ccnotify revoke <device-id>   (see `ccnotify devices`)");
                std::process::exit(2);
            }
        },
        "status" => cli::status(),
        "sessions" => cli::sessions(),
        "chat" => match args.get(1) {
            Some(prefix) => cli::chat(prefix),
            None => {
                eprintln!("usage: ccnotify chat <session-id-prefix>   (see `ccnotify sessions`)");
                std::process::exit(2);
            }
        },
        "test" => cli::test(),
        "test-ask" => cli::test_ask(),
        "relay" => match args.get(1) {
            Some(url) => cli::relay(url),
            None => {
                eprintln!("usage: ccnotify relay <wss://…>   or   ccnotify relay off");
                std::process::exit(2);
            }
        },
        "relay-server" => {
            let port = args.get(1).and_then(|p| p.parse().ok()).unwrap_or(8787);
            relay::serve(port)
        }
        "suggestions" => match args.get(1).map(String::as_str) {
            Some("on") => cli::suggestions(true),
            Some("off") => cli::suggestions(false),
            _ => {
                eprintln!("usage: ccnotify suggestions on|off");
                std::process::exit(2);
            }
        },
        "tray" => tray(),
        "install" => install::install(),
        "uninstall" => install::uninstall(),
        "help" | "-h" | "--help" => {
            print!("{HELP}");
            Ok(())
        }
        "version" | "-V" | "--version" => {
            println!("ccnotify {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        other => {
            eprintln!("unknown command: {other}\n");
            eprint!("{HELP}");
            std::process::exit(2);
        }
    };

    if let Err(e) = result {
        eprintln!("error: {e:#}");
        std::process::exit(1);
    }
}

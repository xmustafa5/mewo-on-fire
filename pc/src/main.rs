//! Mewo on Fire — Claude Code notifications to your phone over the LAN.
//! See ../PROTOCOL.md for the wire contract.

mod artifacts;
mod ask;
mod cli;
mod config;
mod control;
mod daemon;
mod dashboard;
mod desktop;
mod flow;
mod hook;
mod install;
mod listen;
mod mdns;
mod net;
mod notes;
mod paths;
mod peers;
mod plane;
mod policy;
mod prs;
mod relay;
mod requests;
mod runner;
mod server;
mod sessions;
mod store;
mod suggest;
mod transcript;
mod uploads;
#[cfg(target_os = "linux")]
mod tray;

const HELP: &str = "\
Mewo on Fire - Claude Code notifications on your phone (LAN only)

Usage: mewo <command>

Commands:
  install        Install binary to ~/.local/bin, the background service (systemd user
                 unit on Linux, launchd agent on macOS) and Claude Code hooks
  pair           Show a QR code to pair a phone (waits until paired)
  devices        List paired phones
  revoke <id>    Unpair a phone
  status         Show daemon status
  dashboard [port]
                 Operations console in your browser: sessions as a live network,
                 counts, feed (on this machine only; default port 47824)
  sessions       List Claude Code sessions (state, listening, queued phone messages)
  chat <session> Show the last 20 chat items of a session (id prefix from `sessions`)
  test           Send a test notification
  demo           Put a sample session (with its chat) and event in the app, for a
                 first look without Claude Code running
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
    anyhow::bail!("`mewo tray` is for Linux; on macOS use the menu bar app (pc/menubar/install.sh)")
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
                eprintln!("usage: mewo revoke <device-id>   (see `mewo devices`)");
                std::process::exit(2);
            }
        },
        "status" => cli::status(),
        "dashboard" => {
            let port = args
                .iter()
                .skip(1)
                .find_map(|a| a.parse::<u16>().ok())
                .unwrap_or(dashboard::DEFAULT_PORT);
            dashboard::run(port, !args.iter().any(|a| a == "--no-open"))
        }
        "sessions" => cli::sessions(),
        "chat" => match args.get(1) {
            Some(prefix) => cli::chat(prefix),
            None => {
                eprintln!("usage: mewo chat <session-id-prefix>   (see `mewo sessions`)");
                std::process::exit(2);
            }
        },
        "test" => cli::test(),
        "demo" => cli::demo(),
        "test-ask" => cli::test_ask(),
        "relay" => match args.get(1) {
            Some(url) => cli::relay(url),
            None => {
                eprintln!("usage: mewo relay <wss://…>   or   mewo relay off");
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
                eprintln!("usage: mewo suggestions on|off");
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
            println!("mewo {}", env!("CARGO_PKG_VERSION"));
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

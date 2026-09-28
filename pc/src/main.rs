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
mod requests;
mod server;
mod sessions;
mod store;
mod transcript;

const HELP: &str = "\
ccnotify - Claude Code notifications on your phone (LAN only)

Usage: ccnotify <command>

Commands:
  install        Install binary to ~/.local/bin, systemd user service and Claude Code hooks
  pair           Show a QR code to pair a phone (waits until paired)
  devices        List paired phones
  revoke <id>    Unpair a phone
  status         Show daemon status
  sessions       List Claude Code sessions (state, listening, queued phone messages)
  chat <session> Show the last 20 chat items of a session (id prefix from `sessions`)
  test           Send a test notification
  test-ask       Send a test permission request and print the phone's answer
  uninstall      Remove hooks and the systemd service (keeps config and history)
  daemon         Run the daemon in the foreground (normally started by systemd)
  hook           Claude Code hook entry point (reads hook JSON on stdin)
  ask            Claude Code PermissionRequest hook (answer prompts from the phone)
  listen         Claude Code Stop hook (continue the session from the phone)
  help           Show this help
";

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

//! ccnotify — Claude Code notifications to your phone over the LAN.
//! See ../PROTOCOL.md for the wire contract.

mod cli;
mod config;
mod control;
mod daemon;
mod hook;
mod install;
mod mdns;
mod net;
mod paths;
mod server;
mod store;

const HELP: &str = "\
ccnotify - Claude Code notifications on your phone (LAN only)

Usage: ccnotify <command>

Commands:
  install        Install binary to ~/.local/bin, systemd user service and Claude Code hooks
  pair           Show a QR code to pair a phone (waits until paired)
  devices        List paired phones
  revoke <id>    Unpair a phone
  status         Show daemon status
  test           Send a test notification
  uninstall      Remove hooks and the systemd service (keeps config and history)
  daemon         Run the daemon in the foreground (normally started by systemd)
  hook           Claude Code hook entry point (reads hook JSON on stdin)
  help           Show this help
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    if cmd == "hook" {
        hook::run();
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
        "test" => cli::test(),
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

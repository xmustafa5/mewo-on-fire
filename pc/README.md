# ccnotify (PC side)

Single Rust binary: daemon + CLI + Claude Code hook. Sends Claude Code
"finished", "needs input" and "session ended" events to paired phones over the
LAN (TLS WebSocket, certificate pinned via the QR code). See `../PROTOCOL.md`.

## Build

```sh
cargo build --release
```

Static (musl) build that runs on any Linux:

```sh
rustup target add x86_64-unknown-linux-musl
cargo build --release --target x86_64-unknown-linux-musl
```

## Install and pair

```sh
./target/release/ccnotify install        # or ./target/x86_64-unknown-linux-musl/release/ccnotify install
ccnotify pair                            # scan the QR code with the app
```

`install`:
- copies the binary to `~/.local/bin/ccnotify`
- writes `~/.config/systemd/user/ccnotify.service` and runs
  `systemctl --user enable --now ccnotify`
- adds `Stop`, `Notification` and `SessionEnd` hooks to `~/.claude/settings.json`
  (existing hooks are kept; a backup is written to `settings.json.bak-ccnotify`)

Without systemd, run `~/.local/bin/ccnotify daemon` yourself (e.g. from your
session autostart).

## Commands

| Command | What it does |
|---|---|
| `ccnotify pair` | Show a QR code (and the raw payload) and wait until a phone pairs |
| `ccnotify devices` | List paired phones |
| `ccnotify revoke <id>` | Unpair a phone |
| `ccnotify status` | Daemon status: addresses, port, cert fingerprint, connected phones |
| `ccnotify test` | Send a test notification |
| `ccnotify daemon` | Run the daemon in the foreground |
| `ccnotify uninstall` | Remove hooks and the systemd service |

Logs: `journalctl --user -u ccnotify -f`

## Firewall

The phone connects to TCP port `47821`; discovery uses mDNS (UDP 5353).

```sh
sudo ufw allow 47821/tcp
# or
sudo firewall-cmd --permanent --add-port=47821/tcp --add-service=mdns && sudo firewall-cmd --reload
```

## Files

- `~/.config/ccnotify/` — `config.json`, `cert.der`, `key.der`, `devices.json`
- `~/.local/state/ccnotify/events.json` — last 500 events
- `$XDG_RUNTIME_DIR/ccnotify.sock` — local control socket

## Uninstall

```sh
ccnotify uninstall
```

Removes only the ccnotify hook entries and the systemd service. Config,
pairings and history are kept; delete `~/.config/ccnotify`,
`~/.local/state/ccnotify` and `~/.local/bin/ccnotify` for a full removal.

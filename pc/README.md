# ccnotify (PC side)

Single Rust binary: daemon + CLI + Claude Code hooks. Sends Claude Code
"finished", "needs input" and "session ended" events to paired phones over the
LAN (TLS WebSocket, certificate pinned via the QR code), lets you answer
permission prompts, questions and plan approvals from the phone, shows each
session's chat on the phone and lets you continue a session from the phone.
See `../PROTOCOL.md`.

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
- adds `Stop`, `Notification`, `SessionEnd` and `UserPromptSubmit` hooks
  (`ccnotify hook`, async), a `PermissionRequest` hook (`ccnotify ask`, timeout
  24 h) and a second `Stop` hook (`ccnotify listen`, async + `asyncRewake`,
  timeout 24 h) to `~/.claude/settings.json` (existing hooks are kept; a backup
  is written to `settings.json.bak-ccnotify`). Re-running `install` only adds
  what is missing, so a machine with older ccnotify hooks just gets the new ones.

`ccnotify ask` forwards each permission prompt / `AskUserQuestion` question /
plan approval to the connected phones and waits. The first answer wins: if you
answer on the phone, Claude Code gets that decision; if you answer on the PC
first, Claude Code stops the hook and the phone notification is withdrawn.
With no phone connected (or the daemon down) it returns immediately and the
normal prompt is shown.

`ccnotify listen` runs in the background after every Claude reply and waits
for a message from the phone. A message sent from the phone's chat screen (or
the Reply action of a "finished" notification) is handed to it; it exits with
code 2 and Claude Code wakes the session with the text, as if you had typed it.
Messages sent while Claude is busy are queued and delivered after its next
reply. Typing on the PC cancels the waiting hook. While Claude is running
agents at `xhigh`/`max` effort the session is read-only from the phone.
Sessions only become "listening" after the hooks are installed and Claude has
replied once (restart open sessions or send one message from the PC).

The daemon keeps a small session registry (`sessions.json`) and reads the
chat from Claude Code's transcript files (last 4 MB) on demand.

Without systemd, run `~/.local/bin/ccnotify daemon` yourself (e.g. from your
session autostart).

## Commands

| Command | What it does |
|---|---|
| `ccnotify pair` | Show a QR code (and the raw payload) and wait until a phone pairs |
| `ccnotify devices` | List paired phones |
| `ccnotify revoke <id>` | Unpair a phone |
| `ccnotify status` | Daemon status: addresses, port, cert fingerprint, connected phones, pending requests, sessions |
| `ccnotify sessions` | List Claude Code sessions: state, listening, queued phone messages, last activity |
| `ccnotify chat <session>` | Print the last 20 chat items of a session (id prefix from `sessions`) |
| `ccnotify test` | Send a test notification |
| `ccnotify test-ask` | Send a test permission request (`echo hello from ccnotify`) and print the phone's answer |
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
- `~/.local/state/ccnotify/sessions.json` — last 50 sessions (state, queued
  and recorded phone messages)
- `$XDG_RUNTIME_DIR/ccnotify.sock` — local control socket

## Uninstall

```sh
ccnotify uninstall
```

Removes only the ccnotify hook entries and the systemd service. Config,
pairings and history are kept; delete `~/.config/ccnotify`,
`~/.local/state/ccnotify` and `~/.local/bin/ccnotify` for a full removal.

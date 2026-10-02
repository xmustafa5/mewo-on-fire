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

On macOS the same `cargo build --release` works (Rust from rustup or
`brew install rust`). For one binary that runs on both Apple silicon and Intel
Macs:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo build --release --target aarch64-apple-darwin --target x86_64-apple-darwin
lipo -create -output ccnotify target/{aarch64,x86_64}-apple-darwin/release/ccnotify
```

## Install and pair

```sh
./target/release/ccnotify install        # or ./target/x86_64-unknown-linux-musl/release/ccnotify install
ccnotify pair                            # scan the QR code with the app
```

`install`:
- copies the binary to `~/.local/bin/ccnotify`
- Linux: writes `~/.config/systemd/user/ccnotify.service` and runs
  `systemctl --user enable --now ccnotify`
- macOS: writes `~/Library/LaunchAgents/com.torchcorp.ccnotify.plist` and
  loads it with `launchctl bootstrap gui/<uid>`. The daemon starts at login
  and is restarted if it crashes.
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

Without systemd (or, on macOS, without a desktop login, e.g. over SSH), run
`~/.local/bin/ccnotify daemon` yourself (e.g. from your session autostart).

## Claude desktop app

The hooks are in `~/.claude/settings.json`, which the Code tab of the Claude
desktop app reads too: its local sessions notify the phone, show up under
**Sessions** with the title the app gave them, and can be answered and
continued from the phone like terminal sessions. A session that was already
open before `ccnotify install` may need a restart to pick the hooks up. Cloud
sessions and Cowork sessions do not run on your machine and are not covered.

## Menu bar app (macOS)

`menubar/` is a small menu bar app for the daemon. Its bell icon shows whether
the service runs (crossed out when it does not, with a dot when a prompt is
waiting for an answer). Click it for:

- the Mac's name, address and how many phones are connected
- **Pair a Phone…**: the pairing QR code, with **Copy Code** for the app's
  "Paste code instead"
- the paired phones, with a button to unpair each
- the Claude Code sessions with their state; click one to read Claude's last reply
- **⋯**: send a test notification, restart the service, open the log, open at login

```sh
./menubar/install.sh
```

builds it (needs Xcode or its command line tools, macOS 13 or later), installs
it as `~/Applications/ccnotify.app` and opens it. It only talks to the daemon's
local control socket; the daemon itself is still installed with
`ccnotify install`.

## Tray icon (Linux)

`ccnotify tray` is the same thing for Linux desktops: a bell in the system
tray (grey and crossed out when the service is not running, with a red dot when
a prompt is waiting for an answer). Its menu has:

- the PC's name, address and how many phones are connected
- **Pair a Phone…**: opens the pairing QR code in your image viewer; the menu
  says "Paired with …" when a phone has scanned it
- **Phones**: the paired phones, each with **Unpair**
- the Claude Code sessions with their state; open one to read Claude's last reply
- **Send Test Notification**, **Restart Service**, **Start at Login**, **Quit**

`ccnotify install` adds "ccnotify" to the desktop's application menu; start it
from there or run `ccnotify tray`, then tick **Start at Login**.

The icon uses the StatusNotifierItem protocol: KDE Plasma, Xfce, Cinnamon,
MATE, LXQt and most panels show it out of the box; GNOME needs the
"AppIndicator and KStatusNotifierItem Support" extension.

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
| `ccnotify tray` | Linux: show the tray icon (status, pairing QR code, phones, sessions) |
| `ccnotify daemon` | Run the daemon in the foreground |
| `ccnotify uninstall` | Remove hooks and the systemd service / launchd agent |

Logs: `journalctl --user -u ccnotify -f` on Linux, `tail -f ~/Library/Logs/ccnotify.log` on macOS.

Restart the daemon: `systemctl --user restart ccnotify` on Linux,
`launchctl kickstart -k gui/$(id -u)/com.torchcorp.ccnotify` on macOS.

## Firewall

The phone connects to TCP port `47821`; discovery uses mDNS (UDP 5353).

```sh
sudo ufw allow 47821/tcp
# or
sudo firewall-cmd --permanent --add-port=47821/tcp --add-service=mdns && sudo firewall-cmd --reload
```

On macOS the firewall is per application. If it is on (System Settings →
Network → Firewall) and the phone cannot connect:

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ~/.local/bin/ccnotify
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp ~/.local/bin/ccnotify
```

If macOS asks whether ccnotify may find devices on your local network, allow
it (System Settings → Privacy & Security → Local Network).

If another program already uses port `47821` (the log says "Address already in
use"), set another `"port"` in `~/.config/ccnotify/config.json`, restart the
daemon and pair again.

## Files

- `~/.config/ccnotify/` — `config.json`, `cert.der`, `key.der`, `devices.json`
- `~/.local/state/ccnotify/events.json` — last 500 events
- `~/.local/state/ccnotify/sessions.json` — last 50 sessions (state, queued
  and recorded phone messages)
- `~/.local/state/ccnotify/uploads/` — pictures sent from a phone with a
  message, per session; deleted after 7 days
- `$XDG_RUNTIME_DIR/ccnotify.sock` — local control socket (Linux)
- `~/.local/state/ccnotify/ccnotify.sock` — local control socket (macOS)

## Uninstall

```sh
ccnotify uninstall
```

Removes only the ccnotify hook entries, the systemd service / launchd agent and,
on Linux, the tray icon's application-menu and start-at-login entries. Config,
pairings and history are kept; delete `~/.config/ccnotify`,
`~/.local/state/ccnotify` and `~/.local/bin/ccnotify` for a full removal.

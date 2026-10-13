# Mewo on Fire (PC side)

Single Rust binary: daemon + CLI + Claude Code hooks. Sends Claude Code
"finished", "needs input" and "session ended" events to paired phones over the
LAN (TLS WebSocket, certificate pinned via the QR code), lets you answer
permission prompts, questions and plan approvals from the phone, shows each
session's chat on the phone and lets you continue a session from the phone.
See `../PROTOCOL.md`.

## Install a release

On Linux (x86_64) or macOS, without building anything:

```sh
curl -fsSL https://www.mewo-on-fire.com/install.sh | sh
```

It downloads the build for this computer and runs `mewo install`. The
bell then shows in the top bar / system tray (Linux) or the menu bar (macOS)
and starts at every login. Pair a phone from the bell's menu.

On a Mac, prefer this command over downloading the archive in a browser: the
builds are not notarized, so Gatekeeper refuses a binary that a browser
downloaded until you run `xattr -dr com.apple.quarantine mewo mewo-on-fire.app`.

## Publish a release

`.github/workflows/release.yml` builds a static Linux binary
(`mewo-on-fire-linux-x86_64.tar.gz`) and a universal macOS binary with the menu
bar app (`mewo-on-fire-macos.tar.gz`). Pushing a tag publishes them and
`install.sh` as a GitHub release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

`install.sh` downloads from public release URLs, so the repository (or a
separate repository that holds the releases, see `MEWO_REPO` in
`install.sh`) must be public.

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
lipo -create -output mewo target/{aarch64,x86_64}-apple-darwin/release/mewo
```

## Install and pair

```sh
./target/release/mewo install        # or ./target/x86_64-unknown-linux-musl/release/mewo install
mewo pair                            # scan the QR code with the app
```

`install`:
- copies the binary to `~/.local/bin/mewo`
- Linux: writes `~/.config/systemd/user/mewo-on-fire.service` and runs
  `systemctl --user enable --now mewo-on-fire`
- macOS: writes `~/Library/LaunchAgents/com.torchcorp.mewo-on-fire.plist` and
  loads it with `launchctl bootstrap gui/<uid>`. The daemon starts at login
  and is restarted if it crashes.
- adds `Stop`, `Notification`, `SessionEnd` and `UserPromptSubmit` hooks
  (`mewo hook`, async), a `PermissionRequest` hook (`mewo ask`, timeout
  24 h) and a second `Stop` hook (`mewo listen`, async + `asyncRewake`,
  timeout 24 h) to `~/.claude/settings.json` (existing hooks are kept; a backup
  is written to `settings.json.bak-mewo-on-fire`). Re-running `install` only adds
  what is missing, so a machine with older Mewo on Fire hooks just gets the new ones.
- on a machine that still has ccnotify (the name before v0.2): stops its
  service, moves `~/.config/ccnotify` and `~/.local/state/ccnotify` to the new
  folders (paired phones stay paired), points its hooks in `settings.json` at
  `mewo` and makes `~/.local/bin/ccnotify` a link to it, so Claude Code
  sessions that are already open keep working.

`mewo ask` forwards each permission prompt / `AskUserQuestion` question /
plan approval to the connected phones and waits. The first answer wins: if you
answer on the phone, Claude Code gets that decision; if you answer on the PC
first, Claude Code stops the hook and the phone notification is withdrawn.
With no phone connected (or the daemon down) it returns immediately and the
normal prompt is shown.

`mewo listen` runs in the background after every Claude reply and waits
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
`~/.local/bin/mewo daemon` yourself (e.g. from your session autostart).

## Claude desktop app

The hooks are in `~/.claude/settings.json`, which the Code tab of the Claude
desktop app reads too: its local sessions notify the phone, show up under
**Sessions** with the title the app gave them, and can be answered and
continued from the phone like terminal sessions. A session that was already
open before `mewo install` may need a restart to pick the hooks up. Cloud
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

A release ships it next to the binary, and `mewo install` copies it to
`~/Applications/mewo-on-fire.app` and opens it. From source:

```sh
./menubar/install.sh
```

builds it (needs Xcode or its command line tools, macOS 13 or later), installs
it as `~/Applications/mewo-on-fire.app` and opens it. Either way it opens at login
from its first launch on (turn that off with **Open at Login** in its **⋯**
menu). It only talks to the daemon's local control socket; the daemon itself
is still installed with `mewo install`.

## Tray icon (Linux)

`mewo tray` is the same thing for Linux desktops: a bell in the system
tray (grey and crossed out when the service is not running, with a red dot when
a prompt is waiting for an answer). Its menu has:

- the PC's name, address and how many phones are connected
- **Pair a Phone…**: opens the pairing QR code in your image viewer; the menu
  says "Paired with …" when a phone has scanned it
- **Phones**: the paired phones, each with **Unpair**
- the Claude Code sessions with their state; open one to read Claude's last reply
- **Send Test Notification**, **Restart Service**, **Start at Login**, **Quit**

`mewo install` adds "Mewo on Fire" to the desktop's application menu and
starts the icon. A first install also turns on **Start at Login**; untick it to
keep the icon from starting at login (updates keep that choice). Updating
restarts a running icon with the new binary. Without a desktop session (over
SSH) the icon is not started; run `mewo tray` from the desktop.

The icon uses the StatusNotifierItem protocol: KDE Plasma, Xfce, Cinnamon,
MATE, LXQt and most panels show it out of the box; GNOME needs the
"AppIndicator and KStatusNotifierItem Support" extension.

## Commands

| Command | What it does |
|---|---|
| `mewo pair` | Show a QR code (and the raw payload) and wait until a phone pairs |
| `mewo devices` | List paired phones |
| `mewo revoke <id>` | Unpair a phone |
| `mewo status` | Daemon status: addresses, port, cert fingerprint, connected phones, pending requests, sessions |
| `mewo sessions` | List Claude Code sessions: state, listening, queued phone messages, last activity |
| `mewo chat <session>` | Print the last 20 chat items of a session (id prefix from `sessions`) |
| `mewo test` | Send a test notification |
| `mewo test-ask` | Send a test permission request (`echo hello from Mewo on Fire`) and print the phone's answer |
| `mewo tray` | Linux: show the tray icon (status, pairing QR code, phones, sessions) |
| `mewo daemon` | Run the daemon in the foreground |
| `mewo uninstall` | Remove hooks and the systemd service / launchd agent |

Logs: `journalctl --user -u mewo-on-fire -f` on Linux, `tail -f ~/Library/Logs/mewo-on-fire.log` on macOS.

Restart the daemon: `systemctl --user restart mewo-on-fire` on Linux,
`launchctl kickstart -k gui/$(id -u)/com.torchcorp.mewo-on-fire` on macOS.

## Operations console (`mewo dashboard`)

```sh
mewo dashboard            # opens http://127.0.0.1:47824 in your browser
mewo dashboard 5050       # another port; --no-open to just print the URL
```

A page for your screen, Iron Man style: every session as a node around
your PC, lit by state (working, needs you, finished, closed), with activity
flowing along the edges; counts, phones, relay and the live feed of events
and requests beside it. It is served by that command on this machine only
(nothing listens beyond localhost) and reads the daemon over the control
socket, so it also works with a daemon from before the rename, just without
the feed. Honours the system's Reduce Motion setting.

**As a Mac app** (no browser, no server): [`console/`](console/) wraps the
same page in a window of its own, with a Dock icon and full screen, fed
straight from the daemon's socket.

```sh
pc/console/install.sh      # builds and installs "~/Applications/Mewo Console.app", then opens it
```

**On Linux** the same script installs [`console/linux/`](console/linux/): a
GTK + WebKitGTK window (needs `python3-gi` and `gir1.2-webkit2-4.1`, there on a
stock Ubuntu desktop) that runs `mewo dashboard` on a free localhost port for
itself and shows its page. It lands in the application menu as "Mewo Console"
and as `mewo-console`; the tray's **Open Console** opens it (or the browser
page when it is not installed). Ctrl+R reloads, F11 is full screen.

**Build with me** (beside Build everything on a feature's build) opens each
session of the plan in a Mewo Session window of its own, where you watch
Claude work and answer its questions. On Linux the window is a chat in the
look of the Claude Code extension: Claude's text as it is written, every
tool call with its input and output, edits as diffs, questions and
permission prompts as buttons (your phone gets them too; the first answer
wins), and a composer with the model, the permission mode, `@` for a file,
`/` for a command, pasted images, Enter to send and Esc to stop. A file
Claude names opens in VS Code at its line. On the console, a session that
has such a window open gets **Show the session**, which brings it forward.
It needs GTK 3 and WebKitGTK for
Python (`python3-gi`, `gir1.2-webkit2-4.1`: what the console itself needs).
Without WebKitGTK, or with `"session_terminal": true` in
`~/.config/mewo-on-fire/config.json`, the window shows Claude Code in a
terminal instead (`gir1.2-vte-2.91`); on a Mac the session opens in
Terminal in the console's colours.

Claude Desktop for Linux works like the Mac app: sessions are tagged from
`~/.config/Claude/claude-code-sessions`, **Open** and **New session** go
through its `claude://` handler (`xdg-open`), and the build autopilot's
headless runs count `~/.claude/.credentials.json` as signed in.

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
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ~/.local/bin/mewo
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp ~/.local/bin/mewo
```

If macOS asks whether `mewo` may find devices on your local network, allow
it (System Settings → Privacy & Security → Local Network).

If another program already uses port `47821` (the log says "Address already in
use"), set another `"port"` in `~/.config/mewo-on-fire/config.json`, restart the
daemon and pair again.

## Suggested next messages

```sh
mewo suggestions on     # or: off
```

Claude Code suggests a next prompt in its own window, but keeps it there. With
this on, Mewo on Fire asks Claude (through the UserPromptSubmit hook) to end each
reply with a line that Markdown does not display, holding one to three
suggested next messages; the app shows them as buttons. It costs a few dozen
tokens per reply and applies to every Claude Code session on this PC, from
the next prompt on. In a plain terminal the line is visible as
`[next]: # "…"`.

## Pull requests in the chat

With the [GitHub CLI](https://cli.github.com) installed and logged in on the
PC (`gh auth login`), a session's chat on the phone shows the open pull
requests of its repository above the input, with the size of the change and
whether CI passes; one tap lists the checks or asks Claude to fix them.
Nothing to configure: the daemon runs `gh` in the session's folder when a
phone asks.

## Away from the local network

The phone reaches the PC at any of the addresses the daemon tells it about
(`mewo status` lists them). It uses the local network when it is there
and falls back to the others elsewhere. There are two ways to give it one
that works from outside:

**A relay** — nothing to install on the phone. The daemon and the phone both
connect out to a small relay on the internet, which passes the (still
encrypted) connection between them. This also works when the PC cannot be
reached from the internet at all, which is the usual case at home.
[`relay/`](../relay/) has the relay (free on Cloudflare, or on a machine of
your own) and how to deploy it; then:

```sh
mewo relay wss://mewo-on-fire-relay.<you>.workers.dev
```

**A VPN** — with [Tailscale](https://tailscale.com) on the PC and the phone,
the daemon finds its Tailscale address by itself. For another VPN or a DNS
name, list it in `~/.config/mewo-on-fire/config.json` and restart the daemon:

```json
{ "extra_hosts": ["mac.example.ts.net"] }
```

A paired phone learns new addresses the next time it connects at home. The
PC has to be awake, and the phone still needs the app running to get
notifications (see the mobile README).

## Files

- `~/.config/mewo-on-fire/` — `config.json`, `cert.der`, `key.der`, `devices.json`
- `~/.local/state/mewo-on-fire/events.json` — last 500 events
- `~/.local/state/mewo-on-fire/sessions.json` — last 50 sessions (state, queued
  and recorded phone messages)
- `~/.local/state/mewo-on-fire/uploads/` — pictures sent from a phone with a
  message, per session; deleted after 7 days
- `$XDG_RUNTIME_DIR/mewo-on-fire.sock` — local control socket (Linux)
- `~/.local/state/mewo-on-fire/mewo-on-fire.sock` — local control socket (macOS)

## Uninstall

```sh
mewo uninstall
```

Removes only the mewo hook entries, the systemd service / launchd agent,
the tray icon (Linux: stops it and removes its application-menu and
start-at-login entries) and the menu bar app (macOS:
`~/Applications/mewo-on-fire.app`). Config,
pairings and history are kept; delete `~/.config/mewo-on-fire`,
`~/.local/state/mewo-on-fire` and `~/.local/bin/mewo` for a full removal.

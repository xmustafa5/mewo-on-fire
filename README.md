# Mewo on Fire — Claude Code → phone notifications over your Wi-Fi

Get a phone notification when a Claude Code session on any of your Linux PCs or Macs:

- ✅ **finishes a reply** (`Stop` hook)
- ⏳ **needs your input**: permission prompt, question, idle (`Notification` hook)
- ⏹ **closes** (`SessionEnd` hook)

Everything stays on your local network. There is no cloud and no account.

```
Claude Code ──hook──▶ Mewo on Fire (Rust; systemd user service / launchd agent) ──wss + pinned TLS──▶ Mewo on Fire app (Flutter; Android, iOS)
```

| Folder | What |
|---|---|
| [pc/](pc/) | Rust binary `mewo`: daemon, CLI and Claude Code hook. Runs on Linux and macOS. |
| [pc/menubar/](pc/menubar/) | macOS menu bar app: service status, pairing QR code, phones and sessions. On Linux the same is built in: `mewo tray`. |
| [mobile/](mobile/) | Flutter app for Android and iOS, with an Apple Watch app (see [mobile/README.md](mobile/README.md#apple-watch)). On iOS, background delivery is opt-in (see [mobile/README.md](mobile/README.md#ios)). |
| [relay/](relay/) | Relay for using the app away from the PC's network (Cloudflare Worker, or `mewo relay-server`); see [pc/README.md](pc/README.md#away-from-the-local-network). |
| [web/](web/) | Next.js download site: landing page, `install.sh` and download links for the latest release. |
| [PROTOCOL.md](PROTOCOL.md) | Wire format both sides follow. |

## Quick start

**On each PC**

```bash
curl -fsSL https://www.mewo-on-fire.com/install.sh | sh
```

This installs the latest release (Linux x86_64 or macOS): the background
service, the Claude Code hooks and a bell icon in the top bar / menu bar that
starts at every login. Pair a phone from the bell's menu, or with
`mewo pair`.

To build from source instead:

```bash
cd pc
cargo build --release
./target/release/mewo install   # background service + Claude Code hooks + bell icon
mewo pair                       # shows a QR code
```

`install` sets up a systemd user service on Linux and a launchd agent on macOS.

If a firewall is on, open the port:

- ufw: `sudo ufw allow 47821/tcp`
- firewalld: `sudo firewall-cmd --permanent --add-port=47821/tcp --add-service=mdns && sudo firewall-cmd --reload`
- macOS: allow incoming connections for `~/.local/bin/mewo` (see [pc/README.md](pc/README.md#firewall))

**On the phone**

1. `cd mobile && flutter run --release`, or build an APK with `flutter build apk --release`.
   For an iPhone, see [mobile/README.md](mobile/README.md#ios).
2. Allow notifications and, on Android, "ignore battery optimization".
3. Tap **Pair PC** and scan the QR code.

Test it with `mewo test`.

## Notes

- The hooks live in `~/.claude/settings.json`, so they cover Claude Code in a terminal, in the IDE extensions and in the Code tab of the Claude desktop app. Sessions that the desktop app runs elsewhere (cloud sessions, Cowork) do not run on your machine and are not covered.
- Your existing hooks, including the desktop popup script, are kept. `mewo install` only adds its own entries and backs up `~/.claude/settings.json` to `settings.json.bak-mewo-on-fire` first.
- The phone and PC must be on the same network. Guest Wi-Fi and routers with "AP/client isolation" block the connection.
- Xiaomi, Samsung and other phones that kill background apps need extra settings. See https://dontkillmyapp.com.
- To remove: `mewo uninstall`, which removes the hooks and the service and keeps the pairing data.

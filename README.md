# ccnotify — Claude Code → phone notifications over your Wi-Fi

Get a phone notification when a Claude Code session on any of your Linux PCs:

- ✅ **finishes a reply** (`Stop` hook)
- ⏳ **needs your input**: permission prompt, question, idle (`Notification` hook)
- ⏹ **closes** (`SessionEnd` hook)

Everything stays on your local network. There is no cloud and no account.

```
Claude Code ──hook──▶ ccnotify (Rust, systemd user service) ──wss + pinned TLS──▶ ccnotify app (Flutter, Android)
```

| Folder | What |
|---|---|
| [pc/](pc/) | Rust binary `ccnotify`: daemon, CLI and Claude Code hook. Runs on any Linux. |
| [mobile/](mobile/) | Flutter app. Android now; iOS only while the app is open. |
| [PROTOCOL.md](PROTOCOL.md) | Wire format both sides follow. |

## Quick start

**On each PC**

```bash
cd pc
cargo build --release
./target/release/ccnotify install   # systemd user service + Claude Code hooks
ccnotify pair                       # shows a QR code
```

If a firewall is on, open the port:

- ufw: `sudo ufw allow 47821/tcp`
- firewalld: `sudo firewall-cmd --permanent --add-port=47821/tcp --add-service=mdns && sudo firewall-cmd --reload`

**On the phone**

1. `cd mobile && flutter run --release`, or build an APK with `flutter build apk --release`.
2. Allow notifications and "ignore battery optimization".
3. Tap **Pair PC** and scan the QR code.

Test it with `ccnotify test`.

## Notes

- Your existing hooks, including the desktop popup script, are kept. `ccnotify install` only adds its own entries and backs up `~/.claude/settings.json` to `settings.json.bak-ccnotify` first.
- The phone and PC must be on the same network. Guest Wi-Fi and routers with "AP/client isolation" block the connection.
- Xiaomi, Samsung and other phones that kill background apps need extra settings. See https://dontkillmyapp.com.
- To remove: `ccnotify uninstall`, which removes the hooks and the service and keeps the pairing data.

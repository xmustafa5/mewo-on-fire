# ccnotify (mobile)

Android and iOS app that pairs with one or more PCs (Linux or macOS) running
the `ccnotify` daemon and shows a notification when Claude Code finishes, needs your input, or a session
closes. You can also answer Claude Code's permission prompts, questions and
plan approvals from the phone, read each session's chat, and continue a
session by sending it a message. LAN only; the phone connects to the PC over `wss://` and accepts the
PC's certificate only if it matches the pinned fingerprint. The wire format is
defined in `../PROTOCOL.md`.

## Build and run

```sh
# Needed once if Android is disabled in your Flutter config
# (`flutter config --list` shows enable-android: false):
flutter config --enable-android

flutter pub get
flutter run                     # debug build on a connected phone
flutter build apk --release     # build/app/outputs/flutter-apk/app-release.apk
```

The release build is signed with the debug key. Set up your own signing config
in `android/app/build.gradle.kts` before you distribute it.

## First run

1. On first launch the app asks for the **notification** permission (Android 13+)
   and for an exemption from **battery optimization**. Allow both, or Android
   will cut the background connection.
2. A persistent notification that reads "Listening for Claude Code sessions"
   appears while the background service is running. The service uses the
   `connectedDevice` foreground-service type and starts again after a reboot.

## Pairing

1. On the PC, run `ccnotify install` once, then `ccnotify pair`.
2. In the app, tap **Pair PC** and scan the QR code. You can also tap **Paste code
   instead** and paste the JSON line that `ccnotify pair` prints.
3. The phone and the PC must be on the same network. Codes can be used once and
   are valid for 5 minutes.

To pair several PCs, repeat the steps on each PC. Removing a PC in the app stops
notifications from it. To revoke a phone from the PC side, run `ccnotify revoke`.
The app then shows that PC as "Unpaired".

## Behaviour

- The app reconnects with an exponential backoff from 1 s to 60 s. It reconnects
  at once when the network changes or when you open the app. If every stored
  address fails 3 times in a row, it looks up the PC by mDNS (`_ccnotify._tcp`)
  and uses the new address.
- Events that the PC replays after a disconnect always go to History. They
  trigger a notification only if they are less than 30 minutes old.
- In **Settings**, you can turn each event kind on or off. To mute a project,
  long-press one of its events in History.

## Answering prompts from the phone

This needs a PC daemon with protocol v1.1 (`ccnotify install` adds the
`PermissionRequest` hook). When Claude Code shows a permission prompt, asks a
question, or wants a plan approved, the phone shows a notification that stays
until the prompt is answered:

- **Permission**: **Allow**, **Deny**, and **Always** when Claude Code offers it
- **Question**: one button per option, if there is a single single-choice
  question with at most 3 options
- **Plan**: **Approve** or **Reject**

The buttons answer without opening the app. Tap the notification itself to
open the answer screen. It shows the full command, diff or plan, all
questions (multiple choice and "Other…" free text), and an optional message for
Claude when you deny or reject. Pending prompts are also listed under
**Waiting for you** at the top of the PCs tab. The badge on the PCs tab counts
them.

The first answer wins, from the phone or the PC. If you answer on the PC, the
notification goes away. If the phone is offline when you answer, it sends the
answer when it reconnects. To get these prompts only in the app list, without
a notification, turn off **Settings → Answer prompts from phone**.

## Session chat and continuing from the phone

This needs a PC daemon with protocol v1.2. After updating ccnotify on the PC,
run `ccnotify install` again. It adds the `listen` Stop hook and the
`UserPromptSubmit` hook.

- The **Sessions** tab lists the Claude Code sessions of all paired PCs,
  newest first. Each row shows the title, project, PC, state (**Working**,
  **Finished**, **Needs you** or **Closed**), Claude's last reply, and a badge
  that counts messages still queued. Pull down to refresh.
- Tap a session to open its chat. Your prompts appear on the right, and
  messages sent from the phone are marked "📱 from phone". Claude's replies
  appear on the left as Markdown, and you can select the text. Tool calls show
  as grey one-line entries. Consecutive tool calls are collapsed into one line;
  tap it to expand them. The chat refreshes on its own when the session changes
  or Claude finishes a reply. You can also pull down to refresh it.
- Type in the box at the bottom to continue the session. Each message shows its
  status: **Sending…**, **Delivered**, **Queued** (Claude gets it when it
  finishes the current reply), or **Rejected** with the reason. The box is
  disabled for closed sessions. It is also disabled while Claude runs agents
  at high effort (read-only until it finishes).
- Tapping a "finished", "needs input" or "session closed" notification opens
  that session's chat. So does tapping a History item that belongs to a
  session.
- "Finished" notifications have a **Reply** button. Type a message into the
  notification without opening the app. The notification then changes to
  "Sent: …", "Queued: …" or "Couldn't send: <reason>".

The app fetches chats when you open them and does not store them on the phone.
If the PC is offline, a message waits up to a minute for it to reconnect.

## Battery and OEM notes

Some phones stop background apps even when they run a foreground service.
Xiaomi, Samsung, Huawei, OnePlus and Oppo are known for this. If notifications
stop arriving:

- set the app's battery usage to **Unrestricted** or **No restrictions** (see
  Settings → Battery optimization)
- turn on **Autostart** where the phone has that setting
- lock the app in the recent-apps screen

For steps for each phone model, see https://dontkillmyapp.com.

## iOS

```sh
flutter pub get
flutter run --release           # on a connected iPhone
```

Open `ios/Runner.xcworkspace` in Xcode once and pick your team under
**Signing & Capabilities** (a free Apple ID works; the app then has to be
re-installed every 7 days). The app needs iOS 15 or later.

On first launch allow **notifications**, and allow **local network** access
when iOS asks for it while pairing. Without it the phone cannot reach the PC;
change it under Settings → Privacy & Security → Local Network.

Everything works as on Android, with these differences:

- **Background.** iOS has no foreground service and suspends an app shortly
  after you leave it. By default ccnotify stays connected while it is open and
  for about 25 seconds after; what you missed is fetched when you open it
  again (History, and a notification for events of the last 30 minutes). To
  get notifications with the phone in your pocket, turn on **Settings → Stay
  connected in the background**. The app then plays silent audio while it is
  in the background, which keeps it running. This uses more battery, and
  Apple does not accept it in App Store apps (fine for a build you install
  yourself). Swiping the app away in the app switcher stops it either way.
  Real push notifications would need Apple's servers and a paid developer
  account, which this LAN-only project does not use.
- **Notification buttons.** Pull the banner down, or long-press the
  notification, to see them. Permission prompts have **Allow**, **Always
  allow** and **Deny**; plans have **Approve** and **Reject**; "finished"
  notifications have **Reply**. Everything that lets Claude Code go on asks
  for Face ID / the passcode when the phone is locked. Questions have no
  buttons on iOS: tap the notification and answer in the app.
- **Reply.** iOS removes the notification when you send the reply. The result
  ("Sent: …", "Queued: …" or "Couldn't send: …") arrives as a new, quiet
  notification; only a failure makes a sound.
- There is no persistent "Listening…" notification and no start on boot: open
  the app once after restarting the phone.
- The Simulator has no camera: use **Paste code instead**.

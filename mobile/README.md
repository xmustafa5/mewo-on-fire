# Mewo on Fire (mobile)

Android and iOS app that pairs with one or more PCs (Linux or macOS) running
the `mewo` daemon and shows a notification when Claude Code finishes, needs your input, or a session
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

1. On the PC, run `mewo install` once, then `mewo pair`.
2. In the app, tap **Pair PC** and scan the QR code. You can also tap **Paste code
   instead** and paste the JSON line that `mewo pair` prints.
3. The phone and the PC must be on the same network. Codes can be used once and
   are valid for 5 minutes.

To pair several PCs, repeat the steps on each PC. Removing a PC in the app stops
notifications from it. To revoke a phone from the PC side, run `mewo revoke`.
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

This needs a PC daemon with protocol v1.1 (`mewo install` adds the
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

This needs a PC daemon with protocol v1.2. After updating Mewo on Fire on the PC,
run `mewo install` again. It adds the `listen` Stop hook and the
`UserPromptSubmit` hook.

- The **Sessions** tab lists the Claude Code sessions of all paired PCs,
  newest first. Each row shows the title, project, PC, state (**Working**,
  **Finished**, **Needs you** or **Closed**), Claude's last reply, and a badge
  that counts messages still queued. Pull down to refresh.
- Tap a session to open its chat. Your prompts appear on the right, and
  messages sent from the phone are marked "📱 from phone". Claude's replies
  appear on the left. Tool calls show
  as grey one-line entries. Consecutive tool calls are collapsed into one line;
  tap it to expand them. The chat refreshes on its own when the session changes
  or Claude finishes a reply. You can also pull down to refresh it.
- Messages are shown as Markdown (code blocks, tables, lists, quotes).
  Pictures you pasted into Claude on the PC appear in the chat; tap one to see
  it in full.
- Tap the picture button next to the box to attach up to four photos from the
  library or the camera. They are saved on the PC, and Claude is told where
  to find them.
- Long-press a message for its options: **Reply** (quotes the message above
  yours), **Copy** and **Select text**. A message that was rejected can be
  sent again or removed from there.
- **Suggestions**: with `mewo suggestions on` on the PC, Claude's reply
  comes with up to three suggested next messages, shown as buttons above the
  box. Tap one to put it in the box, then send or change it. (On the watch
  they are under the chat; a tap asks before it sends.)
- While the keyboard is open, the keyboard button left of the box closes it
  (so does dragging the chat).
- iOS: while the box is empty, the send button is a **microphone**. Tap it,
  speak (up to two minutes) and tap **Done**: the phone turns the recording
  into text and puts it in the box, for a look before you send it. The
  language button switches between English and Arabic, and "It was …" under
  the result reads the same recording in the other language. Claude Code
  gets text, not a recording.
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
  after you leave it. By default Mewo on Fire stays connected while it is open and
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

## Siri and Shortcuts (iOS 16.4 or later)

"Hey Siri, **tell Claude Code**" (or "message Claude Code"): Siri asks what
you want to say and sends it to a session. The app also answers to "CC
Notify".

Which session:

- none named: the one that was active last. When several were active within
  half an hour of it, Siri asks "Which session?".
- "tell Claude Code **in mewo-on-fire**": the session of that project
  (sessions are called by their project, which is short enough to say).
- In the Shortcuts app, the **Tell Claude Code** action takes a message and a
  session; a shortcut with a fixed session can get a name or a button of its
  own.

The message is sent in the background while the app is running (also away
from home, through a relay). When the app is closed, it is put in the app's
queue and Siri opens the app to send it. Siri hears the message in its own
language: for Arabic with an English Siri, use the microphone in the chat.

The same phrases work with Siri on the Apple Watch. The watch sends through
the iPhone; when the iPhone cannot be asked at that moment, the message is
handed to it and sent as soon as it can (Siri says so).

## Apple Watch

The iPhone app carries a watch app (`ios/MewoWatch`, SwiftUI, watchOS 10
or later). It installs with the iPhone app: if it does not show up on the
watch, open the **Watch** app on the iPhone and install **Mewo on Fire** under
"Available Apps".

- The first screen lists what Claude is **waiting for** and the **sessions**
  of all paired PCs.
- Open a waiting prompt to answer it: **Allow** / **Always allow** / **Deny**,
  **Approve** / **Reject**, or the options of a question (several questions
  and "choose all that apply" work too). **Deny, say why**, **Reject, say
  why** and **Other… say it** take your answer by voice.
- Open a session to read its chat: your messages on the right, Claude's on the
  left (with code blocks), tool calls as one grey line. **Earlier messages**
  loads the page above. The chat checks for news every few seconds while it
  is on screen.
- **Reply by voice** records a message (up to two minutes): tap it, speak,
  tap **Done**. The recording goes to the iPhone, which turns it into text
  (watchOS has no speech recognition); the watch shows the text, and **Send**
  sends it. Claude Code gets text, not a recording. The globe button switches
  between English and Arabic, **It was …** reads the same recording in the
  other language, **Say it again** records anew, and **Type instead** opens
  the watch's keyboard. The first time, allow the microphone on the watch and
  **Speech Recognition** on the iPhone (the iPhone app asks when you open it).

The watch never talks to a PC. Everything goes through the iPhone app over
WatchConnectivity: `ios/Runner/WatchBridge.swift` hands the watch's commands to
`lib/watch_bridge.dart`, which answers them from the app's state. So:

- The iPhone has to be in reach of the watch, and on the PC's network.
- A command from the watch wakes the iPhone app up when iOS has suspended it,
  and the app reconnects to the PC first (a few seconds). If the app was
  closed in the app switcher, or the phone was restarted, open it once.
  With **Stay connected in the background** on, the watch's lists also stay
  up to date by themselves.
- Notifications on the watch are the iPhone's (iOS shows them on the watch
  while the phone is locked), with the same buttons.

To install on a real watch from Xcode, the watch has to be registered for
development like the phone: with the iPhone connected to the Mac, turn on
**Developer Mode** on the watch (Settings → Privacy & Security) and let Xcode
prepare it (Window → Devices and Simulators), then build the `Runner` scheme
for the iPhone. The watch target uses the bundle id
`<app bundle id>.watchkitapp`; if you change the app's bundle id, change it
there and in `ios/MewoWatch/Info.plist` (`WKCompanionAppBundleIdentifier`).


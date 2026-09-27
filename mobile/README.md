# ccnotify (mobile)

Android app that pairs with one or more PCs running the `ccnotify` daemon and
shows a notification when Claude Code finishes, needs your input, or a session
closes. LAN only; the phone connects to the PC over `wss://` and accepts the
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

The iOS project builds, and the camera, local-network and Bonjour usage keys
are already set in `Info.plist`. iOS does not allow a permanent background
socket, so notifications arrive only **while the app is open** (in the
foreground). Treat iOS as a later target.

import Flutter
import UIKit
import WatchConnectivity

/// Relays between the Apple Watch app (ios/CcnotifyWatch) and Dart
/// (lib/watch_bridge.dart). The watch has no connection to a PC of its own:
/// its commands arrive here as WatchConnectivity messages (which also wake
/// this app up when it is suspended) and are answered by Dart; Dart pushes
/// the list of waiting prompts and sessions, kept by the system for the
/// watch as the application context.
///
/// Payloads are UTF-8 JSON as `Data`: `["q": …]` in, `["r": …]` back
/// (`["e": "<reason>"]` when Dart could not be asked), `["state": …]` pushed.
/// Recorded voice (`["v": …]`) is turned into text here: see WatchVoice.swift.
final class WatchBridge: NSObject, WCSessionDelegate {
  static let shared = WatchBridge()

  private var channel: FlutterMethodChannel?
  /// The newest snapshot, sent again when a watch (app) shows up.
  private var snapshot: Data?

  /// At launch, so that messages which started the app are delivered.
  func start() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.watchIsThere() }
  }

  /// With the watch app installed: hand it the lists, and get the permission
  /// its voice messages need.
  private func watchIsThere() {
    pushSnapshot()
    let session = WCSession.default
    if session.activationState == .activated, session.isWatchAppInstalled {
      WatchVoice.shared.askPermissionIfNeeded()
    }
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ccnotify/watch", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "context":
        if let data = (call.arguments as? FlutterStandardTypedData)?.data {
          self?.snapshot = data
          self?.pushSnapshot()
          SiriSessions.store(snapshot: data)  // Siri offers the same sessions
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// A command for Dart from this side of the app (Siri): the same ones the
  /// watch sends. Nil when Dart is not running.
  @MainActor
  func run(_ body: [String: Any]) async -> [String: Any]? {
    guard let channel, let request = try? JSONSerialization.data(withJSONObject: body) else {
      return nil
    }
    let app = UIApplication.shared
    var task = UIBackgroundTaskIdentifier.invalid
    task = app.beginBackgroundTask(withName: "ccnotify.siri") {
      app.endBackgroundTask(task)
      task = .invalid
    }
    defer {
      // Whatever Dart still has to write to the PC.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if task != .invalid { app.endBackgroundTask(task) }
      }
    }
    let result: Any? = await withCheckedContinuation { continuation in
      channel.invokeMethod("command", arguments: FlutterStandardTypedData(bytes: request)) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = (result as? FlutterStandardTypedData)?.data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func pushSnapshot() {
    guard let snapshot, WCSession.isSupported() else { return }
    let session = WCSession.default
    guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
    else { return }
    do {
      try session.updateApplicationContext(["state": snapshot])
    } catch {
      NSLog("ccnotify: watch context not sent: \(error.localizedDescription)")
    }
  }

  // MARK: WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    DispatchQueue.main.async { self.watchIsThere() }
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  /// Another watch was paired: talk to that one.
  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  /// The watch app was installed (or a watch paired).
  func sessionWatchStateDidChange(_ session: WCSession) {
    DispatchQueue.main.async { self.watchIsThere() }
  }

  /// A message the watch could not wait for an answer to (Siri on the watch
  /// in the background): sent now by Dart, or left in the app's queue for
  /// when the app comes up.
  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let request = userInfo["q"] as? Data else { return }
    DispatchQueue.main.async {
      if let channel = self.channel {
        channel.invokeMethod("command", arguments: FlutterStandardTypedData(bytes: request))
        return
      }
      guard let body = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
        body["cmd"] as? String == "send",
        let pcId = body["pcId"] as? String, let sessionId = body["sessionId"] as? String,
        let text = body["text"] as? String
      else { return }
      SiriSessions.queue(pcId: pcId, sessionId: sessionId, text: text)
    }
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    if let audio = message["v"] as? Data {
      DispatchQueue.main.async {
        WatchVoice.shared.receive(message, audio: audio, reply: replyHandler)
      }
      return
    }
    guard let request = message["q"] as? Data else {
      replyHandler(["e": "bad_request"])
      return
    }
    DispatchQueue.main.async {
      // No Flutter engine: the app was started in the background and has
      // never been on screen.
      guard let channel = self.channel else {
        replyHandler(["e": "open_app"])
        return
      }
      // Dart connects to the PC and waits for its answer: stay awake for it.
      let app = UIApplication.shared
      var task = UIBackgroundTaskIdentifier.invalid
      let finish = {
        if task != .invalid {
          app.endBackgroundTask(task)
          task = .invalid
        }
      }
      task = app.beginBackgroundTask(withName: "ccnotify.watch", expirationHandler: finish)
      channel.invokeMethod("command", arguments: FlutterStandardTypedData(bytes: request)) {
        result in
        if let reply = (result as? FlutterStandardTypedData)?.data {
          replyHandler(["r": reply])
        } else {
          // Dart has not started listening yet.
          replyHandler(["e": "open_app"])
        }
        // Whatever Dart still has to write to the PC.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
      }
    }
  }
}

import Flutter
import UIKit
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notification buttons (Allow / Deny / Reply…) are handled by a Dart
    // isolate of its own, which needs the plugins too.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Banners while the app is open, and taps / buttons on notifications.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    add(BackgroundKeepAlive.shared)
    WatchBridge.shared.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // lib/watch_bridge.dart
    WatchBridge.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
    // lib/voice_input.dart
    VoiceInput.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())

    // lib/ios_background.dart
    let channel = FlutterMethodChannel(
      name: "ccnotify/background",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setKeepAlive":
        BackgroundKeepAlive.shared.setEnabled(call.arguments as? Bool ?? false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

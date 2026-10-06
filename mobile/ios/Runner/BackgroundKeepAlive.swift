import AVFoundation
import Flutter
import UIKit

/// Keeps Mewo on Fire running while it is not on screen.
///
/// iOS suspends an app a few seconds after it leaves the foreground, which
/// closes the connections to the PCs. Two things are done about that:
///
/// - Always: a short background task (about 25 s) when the app goes to the
///   background or iOS wakes it for a notification button, so an answer or a
///   message that is on its way still gets sent.
/// - Opt-in (Settings → "Stay connected in the background"): silent audio is
///   played while the app is in the background. With the `audio` background
///   mode this keeps the app, and so the connections, alive.
final class BackgroundKeepAlive: NSObject, FlutterApplicationLifeCycleDelegate {
  static let shared = BackgroundKeepAlive()

  private static let graceSeconds: TimeInterval = 25

  private var enabled = false
  private var player: AVAudioPlayer?
  private var graceTask: UIBackgroundTaskIdentifier = .invalid

  private override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(willResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(audioInterrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(
      self, selector: #selector(mediaServicesReset),
      name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
  }

  /// Turns the silent-audio keep-alive on or off (from the Dart setting).
  func setEnabled(_ on: Bool) {
    enabled = on
    if !on {
      stopAudio()
    } else if UIApplication.shared.applicationState != .active {
      startAudio()
    }
  }

  // MARK: - App lifecycle

  /// Audio has to start before the app is in the background: iOS refuses to
  /// start playback from there.
  @objc private func willResignActive() {
    if enabled { startAudio() }
  }

  @objc private func didEnterBackground() {
    if enabled { startAudio() }
    beginGrace()
  }

  @objc private func didBecomeActive() {
    stopAudio()
    endGrace()
  }

  /// A notification button woke the app: give it time to reconnect and send.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // The completion handler is called by flutter_local_notifications.
    if UIApplication.shared.applicationState != .active {
      beginGrace()
    }
  }

  // MARK: - Background task

  private func beginGrace() {
    guard graceTask == .invalid else { return }
    graceTask = UIApplication.shared.beginBackgroundTask(withName: "mewo-on-fire.grace") {
      [weak self] in self?.endGrace()
    }
    let task = graceTask
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceSeconds) { [weak self] in
      guard let self = self, self.graceTask == task else { return }
      self.endGrace()
    }
  }

  private func endGrace() {
    guard graceTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(graceTask)
    graceTask = .invalid
  }

  // MARK: - Silent audio

  private func startAudio() {
    if player?.isPlaying == true { return }
    do {
      let session = AVAudioSession.sharedInstance()
      // Mixes with whatever else is playing instead of interrupting it.
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      if player == nil {
        let p = try AVAudioPlayer(data: Self.silentWav())
        p.numberOfLoops = -1
        p.volume = 0
        player = p
      }
      player?.play()
    } catch {
      NSLog("mewo: keep-alive audio could not start: \(error)")
    }
  }

  private func stopAudio() {
    guard let p = player, p.isPlaying else { return }
    p.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  /// A phone call or Siri stopped the audio: start again when it is over.
  @objc private func audioInterrupted(_ note: Notification) {
    guard enabled,
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .ended,
      UIApplication.shared.applicationState != .active
    else { return }
    startAudio()
  }

  @objc private func mediaServicesReset() {
    player = nil
    if enabled && UIApplication.shared.applicationState != .active {
      startAudio()
    }
  }

  /// Two seconds of silence: 8 kHz, mono, 16-bit PCM in a WAV container.
  private static func silentWav() -> Data {
    let sampleRate: UInt32 = 8000
    let dataSize: UInt32 = sampleRate * 2 * 2
    var wav = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
    }
    wav.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + dataSize)
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))  // fmt chunk size
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(sampleRate)
    append(sampleRate * 2)  // byte rate
    append(UInt16(2))  // block align
    append(UInt16(16))  // bits per sample
    wav.append(contentsOf: Array("data".utf8))
    append(dataSize)
    wav.append(Data(count: Int(dataSize)))
    return wav
  }
}

import AVFoundation
import Flutter
import Speech
import UIKit

/// Voice messages in the phone app (lib/voice_input.dart): records with the
/// microphone, then turns the recording into text the same way as for the
/// watch (WatchVoice.swift). Channel `ccnotify/voice`:
/// - `start` → recording; fails with `mic_denied`, `speech_denied`, `failed`
/// - `stop` (language, e.g. "en-US") → the text; fails with `too_short`,
///   `speech_unavailable`, `no_speech`…
/// - `again` (language) → the last recording once more, in another language
/// - `cancel` → drops the recording
final class VoiceInput {
  static let shared = VoiceInput()

  /// Longer than this is cut off (and transcribed as it is).
  private static let maxSeconds: TimeInterval = 120

  private var recorder: AVAudioRecorder?
  private var last: Data?
  private let file = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-message.m4a")

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ccnotify/voice", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "start":
        self.start(result)
      case "stop":
        self.stop(language: call.arguments as? String ?? "en-US", result)
      case "again":
        guard let last = self.last else {
          result(FlutterError(code: "no_speech", message: nil, details: nil))
          return
        }
        self.transcribe(last, language: call.arguments as? String ?? "en-US", result)
      case "cancel":
        self.finishRecording()
        self.last = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(_ result: @escaping FlutterResult) {
    let fail: (String) -> Void = { code in
      result(FlutterError(code: code, message: nil, details: nil))
    }
    // Both questions are asked up front, while the app is on screen.
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          guard granted else { return fail("mic_denied") }
          guard status == .authorized else { return fail("speech_denied") }
          do {
            try self.record()
            result(nil)
          } catch {
            NSLog("ccnotify: recording could not start: \(error)")
            self.finishRecording()
            fail("failed")
          }
        }
      }
    }
  }

  private func record() throws {
    finishRecording()
    last = nil
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)
    // Small, and plenty for speech.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1,
    ]
    let recorder = try AVAudioRecorder(url: file, settings: settings)
    guard recorder.record(forDuration: Self.maxSeconds) else {
      throw NSError(domain: "ccnotify.voice", code: 1)
    }
    self.recorder = recorder
  }

  /// Stops the recorder and gives the audio session back (music goes on).
  @discardableResult
  private func finishRecording() -> TimeInterval {
    guard let recorder else { return 0 }
    let seconds = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    return seconds
  }

  private func stop(language: String, _ result: @escaping FlutterResult) {
    // `currentTime` is 0 once the time limit stopped it: then the file tells.
    let recorded = recorder != nil
    let seconds = finishRecording()
    let audio = recorded ? try? Data(contentsOf: file) : nil
    try? FileManager.default.removeItem(at: file)
    guard let audio, seconds == 0 || seconds >= 0.5, audio.count > 2000 else {
      result(FlutterError(code: "too_short", message: nil, details: nil))
      return
    }
    last = audio
    transcribe(audio, language: language, result)
  }

  private func transcribe(_ audio: Data, language: String, _ result: @escaping FlutterResult) {
    WatchVoice.shared.transcribe(audio, language: language) { reply in
      if let text = reply["text"] as? String {
        result(text)
      } else {
        result(FlutterError(code: reply["e"] as? String ?? "no_speech", message: nil, details: nil))
      }
    }
  }
}

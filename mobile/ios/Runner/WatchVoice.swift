import Speech
import UIKit

/// Voice messages from the Apple Watch. watchOS has no speech recognition of
/// its own, so the watch records, sends the audio here in pieces, and this
/// turns it into text (on the phone itself when the language allows it).
/// The watch shows the text and sends it like any other message.
///
/// Pieces: `["v": <audio>, "id": …, "last": Bool, "lang": "en-US"]`. Every
/// piece is answered with `["ok": true]`, the last one with `["text": …]` or
/// `["e": "speech_denied" | "speech_unavailable" | "no_speech"]`.
final class WatchVoice {
  static let shared = WatchVoice()

  /// Audio received so far, by recording id.
  private var pieces: [String: Data] = [:]
  /// Kept alive while they work.
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?

  /// The system only asks for speech recognition while the app is on screen,
  /// so ask as soon as there is a watch to use it.
  func askPermissionIfNeeded() {
    guard SFSpeechRecognizer.authorizationStatus() == .notDetermined,
      UIApplication.shared.applicationState == .active
    else { return }
    SFSpeechRecognizer.requestAuthorization { _ in }
  }

  /// Main thread.
  func receive(_ message: [String: Any], audio: Data, reply: @escaping ([String: Any]) -> Void) {
    let id = message["id"] as? String ?? ""
    var data = pieces[id] ?? Data()
    data.append(audio)
    guard message["last"] as? Bool == true else {
      pieces = [id: data]  // one recording at a time: drop what an abandoned one left
      reply(["ok": true])
      return
    }
    pieces = [:]
    transcribe(data, language: message["lang"] as? String ?? "en-US", reply: reply)
  }

  /// The text of a recording: `["text": …]` or `["e": <reason>]`. Also used
  /// for voice messages recorded on the phone (VoiceInput.swift).
  func transcribe(_ audio: Data, language: String, reply: @escaping ([String: Any]) -> Void) {
    let app = UIApplication.shared
    var background = UIBackgroundTaskIdentifier.invalid
    var answered = false
    let finish: ([String: Any]) -> Void = { answer in
      guard !answered else { return }
      answered = true
      reply(answer)
      self.task = nil
      self.recognizer = nil
      if background != .invalid {
        app.endBackgroundTask(background)
        background = .invalid
      }
    }
    background = app.beginBackgroundTask(withName: "ccnotify.voice") { finish(["e": "no_speech"]) }

    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .notDetermined && app.applicationState != .active {
      finish(["e": "speech_denied"])  // cannot ask from the background
      return
    }
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          finish(["e": "speech_denied"])
          return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
          recognizer.isAvailable
        else {
          finish(["e": "speech_unavailable"])
          return
        }
        let file = FileManager.default.temporaryDirectory
          .appendingPathComponent("watch-voice-\(UUID().uuidString).m4a")
        do {
          try audio.write(to: file)
        } catch {
          finish(["e": "no_speech"])
          return
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        if #available(iOS 16, *) { request.addsPunctuation = true }
        // Nothing leaves the phone when the language is installed on it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.recognizer = recognizer
        self.task = recognizer.recognitionTask(with: request) { result, error in
          DispatchQueue.main.async {
            if let result, result.isFinal {
              try? FileManager.default.removeItem(at: file)
              let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
              finish(text.isEmpty ? ["e": "no_speech"] : ["text": text])
            } else if error != nil {
              try? FileManager.default.removeItem(at: file)
              finish(["e": "no_speech"])
            }
          }
        }
      }
    }
  }
}

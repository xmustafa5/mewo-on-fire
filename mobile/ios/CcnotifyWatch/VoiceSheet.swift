import SwiftUI
import WatchKit

/// The languages a voice message can be spoken in.
enum VoiceLanguage: String, CaseIterable {
  case english = "en-US"
  case arabic = "ar-SA"

  var title: String {
    switch self {
    case .english: return "English"
    case .arabic: return "العربية"
    }
  }

  var other: VoiceLanguage { self == .english ? .arabic : .english }

  /// The watch's own language to begin with.
  static var initial: VoiceLanguage {
    (Locale.preferredLanguages.first ?? "").hasPrefix("ar") ? .arabic : .english
  }
}

/// A button that takes a spoken message: tap, speak, check the text, send.
struct VoiceButton<Label: View>: View {
  let prompt: String
  @ViewBuilder let label: () -> Label
  let onSubmit: (String) -> Void

  @State private var open = false

  var body: some View {
    Button {
      open = true
    } label: {
      label()
    }
    .sheet(isPresented: $open) {
      VoiceSheet(prompt: prompt) { text in
        open = false
        onSubmit(text)
      }
    }
  }
}

/// Records as soon as it opens. Stopping sends the recording to the iPhone,
/// which turns it into text (the watch cannot); the text is shown before it
/// is sent, with a second try in the other language or by typing.
struct VoiceSheet: View {
  let prompt: String
  let onSubmit: (String) -> Void

  private enum Phase: Equatable {
    case recording
    case working
    case review(String)
    case failed(String)
  }

  @EnvironmentObject private var link: PhoneLink
  @StateObject private var recorder = VoiceRecorder()
  @AppStorage("voiceLanguage") private var languageCode = VoiceLanguage.initial.rawValue
  @State private var phase = Phase.recording
  @State private var audio: Data?

  private var language: VoiceLanguage { VoiceLanguage(rawValue: languageCode) ?? .english }

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        switch phase {
        case .recording: recordingView
        case .working: ProgressView("Turning it into text…")
        case .review(let text): reviewView(text)
        case .failed(let message): failedView(message)
        }
      }
      .scenePadding(.horizontal)
    }
    .task { await record() }
    .onChange(of: recorder.recording) {
      // Stopped by itself: the time was up.
      if !recorder.recording, phase == .recording { finish() }
    }
    .onDisappear { _ = recorder.stop() }
  }

  private var recordingView: some View {
    VStack(spacing: 8) {
      Text(prompt)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Image(systemName: "mic.fill")
        .font(.title)
        .foregroundStyle(.red)
        .padding(14)
        .background(.red.opacity(0.15 + 0.35 * recorder.level), in: Circle())
        .scaleEffect(1 + 0.25 * recorder.level)
        .animation(.easeOut(duration: 0.1), value: recorder.level)
      Text(Self.clock(recorder.seconds))
        .font(.body.monospacedDigit())
      Button {
        finish()
      } label: {
        Label("Done", systemImage: "stop.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .disabled(!recorder.recording)
      Button {
        languageCode = language.other.rawValue
      } label: {
        Label(language.title, systemImage: "globe")
          .font(.footnote)
      }
    }
  }

  private func reviewView(_ text: String) -> some View {
    VStack(spacing: 8) {
      Text(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      Button {
        onSubmit(text)
      } label: {
        Label("Send", systemImage: "paperplane.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      Button {
        Task { await record() }
      } label: {
        Label("Say it again", systemImage: "mic.fill")
      }
      if audio != nil {
        Button {
          languageCode = language.other.rawValue
          Task { await transcribe() }
        } label: {
          Label("It was \(language.other.title)", systemImage: "globe")
        }
      }
      typeInstead
    }
  }

  private func failedView(_ message: String) -> some View {
    VStack(spacing: 8) {
      Text(message)
        .font(.footnote)
        .foregroundStyle(.orange)
      Button {
        Task { await record() }
      } label: {
        Label("Try again", systemImage: "mic.fill")
      }
      if audio != nil {
        Button {
          languageCode = language.other.rawValue
          Task { await transcribe() }
        } label: {
          Label("It was \(language.other.title)", systemImage: "globe")
        }
      }
      typeInstead
    }
  }

  /// The watch's own text input: keyboard, scribble or its dictation.
  private var typeInstead: some View {
    TextFieldLink(prompt: Text(prompt)) {
      Label("Type instead", systemImage: "keyboard")
    } onSubmit: { text in
      let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !typed.isEmpty { onSubmit(typed) }
    }
  }

  private static func clock(_ seconds: Double) -> String {
    String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }

  private func record() async {
    audio = nil
    phase = .recording
    do {
      try await recorder.start()
      WKInterfaceDevice.current().play(.start)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func finish() {
    guard phase == .recording else { return }
    let seconds = recorder.seconds
    audio = recorder.stop()
    WKInterfaceDevice.current().play(.stop)
    guard audio != nil, seconds >= 0.5 else {
      audio = nil
      phase = .failed("That was too short.")
      return
    }
    phase = .working
    Task { await transcribe() }
  }

  private func transcribe() async {
    guard let audio else { return }
    phase = .working
    do {
      phase = .review(try await link.transcribe(audio: audio, language: language.rawValue))
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

import AVFoundation

/// Records a voice message with the watch's microphone.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
  /// Longer than this is cut off (and sent as it is).
  static let maxSeconds = 120.0

  @Published private(set) var recording = false
  @Published private(set) var seconds = 0.0
  /// 0…1, how loud it is right now.
  @Published private(set) var level = 0.0

  private var recorder: AVAudioRecorder?
  private var timer: Timer?
  private let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice.m4a")

  func start() async throws {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw LinkError(text: "Allow the microphone for ccnotify in the watch's Settings → Privacy")
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)
    // Small enough to cross to the phone quickly, plenty for speech.
    var settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 24000,
    ]
    var recorder = try? AVAudioRecorder(url: file, settings: settings)
    if recorder?.record(forDuration: Self.maxSeconds) != true {
      // An encoder that does not take that bit rate: let it choose.
      settings[AVEncoderBitRateKey] = nil
      recorder = try AVAudioRecorder(url: file, settings: settings)
      guard recorder?.record(forDuration: Self.maxSeconds) == true else {
        throw LinkError(text: "Could not start recording")
      }
    }
    recorder?.isMeteringEnabled = true
    self.recorder = recorder
    recording = true
    seconds = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func tick() {
    guard let recorder else { return }
    if recorder.isRecording {
      seconds = recorder.currentTime
      recorder.updateMeters()
      // -50 dB (quiet) … 0 dB (loud)
      level = Double(max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50)))
    } else {
      recording = false  // the time was up
    }
  }

  /// Stops and returns the recording (nil when there is none).
  func stop() -> Data? {
    timer?.invalidate()
    timer = nil
    guard let recorder else { return nil }
    recorder.stop()
    self.recorder = nil
    recording = false
    try? AVAudioSession.sharedInstance().setActive(false)
    defer { try? FileManager.default.removeItem(at: file) }
    return try? Data(contentsOf: file)
  }
}

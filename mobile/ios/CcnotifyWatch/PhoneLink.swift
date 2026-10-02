import Foundation
import WatchConnectivity

struct LinkError: LocalizedError {
  let text: String
  var errorDescription: String? { text }
}

/// The connection to the iPhone app (ios/Runner/WatchBridge.swift), which
/// does everything on the watch's behalf. Commands are messages answered by
/// the phone (sending one wakes the iPhone app up); the lists of the first
/// screen also arrive on their own, as the application context, whenever the
/// phone has news.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
  @Published private(set) var state: WatchState?
  /// Why the lists may be out of date.
  @Published private(set) var problem: String?
  @Published private(set) var refreshing = false

  override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  /// Asks the phone for the lists (it reconnects to the PCs if it has to).
  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    do {
      state = try await command(["cmd": "state"], as: StateReply.self).state
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  /// The newest page of a chat, or the one above the line with id `before`.
  /// `have`: the `sig` of the newest page already shown.
  func chat(pcId: String, sessionId: String, before: String? = nil, have: String? = nil) async throws
    -> ChatReply
  {
    var body: [String: Any] = ["cmd": "chat", "pcId": pcId, "sessionId": sessionId]
    if let before { body["before"] = before }
    if let have { body["have"] = have }
    return try await command(body, as: ChatReply.self)
  }

  func send(pcId: String, sessionId: String, text: String) async throws -> SendReply {
    try await command(
      ["cmd": "send", "pcId": pcId, "sessionId": sessionId, "text": text], as: SendReply.self)
  }

  /// `answer` as PROTOCOL.md v1.1 "Answer": `["action": "allow"]`,
  /// `["answers": [question: label]]`…
  func answer(pcId: String, requestId: String, answer: [String: Any]) async throws {
    let reply = try await command(
      ["cmd": "answer", "pcId": pcId, "requestId": requestId, "answer": answer],
      as: AnswerReply.self)
    // Without waiting for the phone's next push.
    guard var state, let i = state.requests.firstIndex(where: { $0.pcId == pcId && $0.id == requestId })
    else { return }
    if reply.resolved {
      state.requests.remove(at: i)
    } else {
      state.requests[i].answered = true
    }
    self.state = state
  }

  /// The text of a recorded voice message. The iPhone does the recognizing
  /// (watchOS cannot); the audio crosses in pieces small enough for a message.
  func transcribe(audio: Data, language: String) async throws -> String {
    let id = UUID().uuidString
    let size = 45_000
    var offset = 0
    while true {
      let end = min(offset + size, audio.count)
      let last = end == audio.count
      let reply = try await message([
        "v": audio.subdata(in: offset..<end), "id": id, "last": last, "lang": language,
      ])
      if let text = reply["text"] as? String { return text }
      if let code = reply["e"] as? String { throw LinkError(text: Self.text(code: code)) }
      if last { throw LinkError(text: Self.text(code: nil)) }
      offset = end
    }
  }

  /// One message to the iPhone app and its answer.
  private func message(_ body: [String: Any]) async throws -> [String: Any] {
    guard WCSession.isSupported() else { throw LinkError(text: "No iPhone") }
    let session = WCSession.default
    guard session.activationState == .activated else {
      throw LinkError(text: "Connecting to the iPhone…")
    }
    guard session.isReachable else { throw LinkError(text: "iPhone not reachable") }
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[String: Any], Error>) in
      session.sendMessage(
        body,
        replyHandler: { reply in continuation.resume(returning: reply) },
        errorHandler: { error in
          continuation.resume(throwing: LinkError(text: Self.text(error: error)))
        })
    }
  }

  private func command<T: Decodable>(_ body: [String: Any], as type: T.Type) async throws -> T {
    let answer = try await message(["q": try JSONSerialization.data(withJSONObject: body)])
    guard let reply = answer["r"] as? Data else {
      throw LinkError(text: Self.text(code: answer["e"] as? String))
    }
    if let failure = try? JSONDecoder().decode(Failure.self, from: reply), !failure.error.isEmpty {
      throw LinkError(text: failure.error)
    }
    do {
      return try JSONDecoder().decode(T.self, from: reply)
    } catch {
      throw LinkError(text: "Update ccnotify on the iPhone")
    }
  }

  private nonisolated static func text(code: String?) -> String {
    switch code {
    case "open_app": return "Open ccnotify on the iPhone once"
    case "speech_denied":
      return "Open ccnotify on the iPhone once and allow Speech Recognition"
    case "speech_unavailable": return "The iPhone cannot recognize this language right now"
    case "no_speech": return "Could not make out any words"
    default: return "The iPhone app could not answer"
    }
  }

  private nonisolated static func text(error: Error) -> String {
    switch (error as? WCError)?.code {
    case .notReachable?: return "iPhone not reachable"
    case .messageReplyTimedOut?: return "The iPhone did not answer"
    case .companionAppNotInstalled?: return "Install ccnotify on the iPhone"
    case .payloadTooLarge?: return "Too much to send at once"
    default: return error.localizedDescription
    }
  }

  private func apply(context: Data?) {
    guard let context, let decoded = try? JSONDecoder().decode(WatchState.self, from: context)
    else { return }
    state = decoded
  }
}

extension PhoneLink: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    // What the phone left for us while this app was not running.
    let context = session.receivedApplicationContext["state"] as? Data
    Task { @MainActor in
      self.apply(context: context)
      await self.refresh()
    }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    let context = applicationContext["state"] as? Data
    Task { @MainActor in
      self.apply(context: context)
      self.problem = nil
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let reachable = session.isReachable
    Task { @MainActor in
      // Losing it is only reported once something fails: the lists stay.
      if reachable { await self.refresh() }
    }
  }
}

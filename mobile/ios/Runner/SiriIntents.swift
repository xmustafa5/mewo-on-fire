import AppIntents
import UIKit

// Siri and Shortcuts: "Tell Claude Code …" sends a message to a session.
//
// Which session: the one named in the phrase ("… in <project>") or picked in
// the shortcut; else the one that was active last — or, when several were
// active in the last half hour, Siri asks.
//
// The sessions come from the snapshot Dart pushes for the watch (kept in the
// user defaults so that it is there when Siri starts the app), and the
// message goes the watch's way too: WatchBridge → lib/watch_bridge.dart.
// When Dart is not running (the app was closed), the message is left in the
// app's queue of messages to send and the app is brought up to send it.

/// The sessions Siri can offer, from the last snapshot.
enum SiriSessions {
  static let snapshotKey = "ccn_siri_snapshot"
  /// "Recently active" for the question which session is meant.
  private static let recentMs = 30 * 60 * 1000

  static func store(snapshot: Data) {
    UserDefaults.standard.set(snapshot, forKey: snapshotKey)
    if #available(iOS 16.4, *) {
      CcnotifyShortcuts.updateAppShortcutParameters()
    }
  }

  private struct Snapshot: Decodable {
    struct Session: Decodable {
      var pcId: String
      var id: String
      var title: String
      var project: String
      var state: String
      var readOnly: Bool
      var lastTs: Int
    }
    var sessions: [Session]
  }

  /// Sessions a message can be sent to, the one active last first.
  @available(iOS 16.0, *)
  static func open() -> [SessionEntity] {
    guard let data = UserDefaults.standard.data(forKey: snapshotKey),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    else { return [] }
    return snapshot.sessions
      .filter { $0.state != "ended" && !$0.readOnly }
      .sorted { $0.lastTs > $1.lastTs }
      .map {
        SessionEntity(
          id: "\($0.pcId)|\($0.id)", pcId: $0.pcId, sessionId: $0.id, title: $0.title,
          project: $0.project, state: $0.state, lastTs: $0.lastTs)
      }
  }

  /// The sessions "the current one" could mean: the newest, and the others
  /// that were active within half an hour of it.
  @available(iOS 16.0, *)
  static func current() -> [SessionEntity] {
    let sessions = open()
    guard let newest = sessions.first else { return [] }
    return sessions.filter { newest.lastTs - $0.lastTs <= recentMs }
  }

  /// Leaves a message for the app to send when it starts (the same queue as
  /// for a reply typed into a notification: `Store.queueSend` in Dart).
  static func queue(pcId: String, sessionId: String, text: String) {
    let clientId = (0..<16).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
    let message: [String: Any] = [
      "cmd": "send", "pc_id": pcId, "session_id": sessionId, "text": text, "client_id": clientId,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else { return }
    UserDefaults.standard.set(json, forKey: "queued_send_\(clientId)")
  }
}

/// A Claude Code session, as Siri and the Shortcuts app show it. It is named
/// by its project ("mewo-on-fire"): short enough to say, unlike its title.
@available(iOS 16.0, *)
struct SessionEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
  static var defaultQuery = SessionQuery()

  let id: String
  let pcId: String
  let sessionId: String
  let title: String
  let project: String
  let state: String
  let lastTs: Int

  /// What it is called when spoken to or about.
  var name: String { project.isEmpty ? title : project }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: "\(project.isEmpty ? state : "\(title) · \(state)")")
  }
}

@available(iOS 16.0, *)
struct SessionQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [SessionEntity] {
    SiriSessions.open().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [SessionEntity] {
    SiriSessions.open()
  }

  /// A spoken or typed name: part of the project or of the title.
  func entities(matching string: String) async throws -> [SessionEntity] {
    let wanted = string.lowercased()
    return SiriSessions.open().filter {
      $0.project.lowercased().contains(wanted) || $0.title.lowercased().contains(wanted)
    }
  }
}

@available(iOS 16.0, *)
struct TellClaudeIntent: AppIntent {
  static var title: LocalizedStringResource = "Tell Claude Code"
  static var description = IntentDescription(
    "Sends a message to a Claude Code session on your PC.")
  static var openAppWhenRun = false

  /// In the background when Dart is running; else the app comes up.
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

  @Parameter(title: "Message", requestValueDialog: "What do you want to tell Claude?")
  var message: String

  @Parameter(
    title: "Session",
    description: "Leave empty for the session that was active last.")
  var session: SessionEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Tell Claude Code \(\.$message)") {
      \.$session
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      throw $message.needsValueError("What do you want to tell Claude?")
    }
    let target: SessionEntity
    if let session {
      target = session
    } else {
      let current = SiriSessions.current()
      guard let newest = current.first else {
        return .result(
          dialog: "I don't know of a Claude Code session. Open ccnotify once so it can look.")
      }
      target =
        current.count > 1
        ? try await $session.requestDisambiguation(among: current, dialog: "Which session?")
        : newest
    }

    let command: [String: Any] = [
      "cmd": "send", "pcId": target.pcId, "sessionId": target.sessionId, "text": text,
    ]
    guard let reply = await WatchBridge.shared.run(command) else {
      // The app is not running: it sends the message when it comes up.
      SiriSessions.queue(pcId: target.pcId, sessionId: target.sessionId, text: text)
      if #available(iOS 26.0, *) {
        try await continueInForeground("ccnotify has to open to send this.", alwaysConfirm: false)
        return .result(dialog: "Sending it to \(target.name).")
      }
      return .result(dialog: "Open ccnotify: the message is sent as soon as it starts.")
    }
    if let error = reply["error"] as? String, !error.isEmpty {
      return .result(dialog: "Not sent: \(error)")
    }
    switch reply["status"] as? String {
    case "delivered":
      return .result(dialog: "Sent to \(target.name).")
    case "queued":
      return .result(dialog: "Queued for \(target.name). Claude gets it when it finishes.")
    case "sending":
      return .result(dialog: "On its way to \(target.name); the PC has not answered yet.")
    default:
      let reason = reply["reason"] as? String ?? ""
      return .result(dialog: "Not sent\(reason.isEmpty ? "." : ": \(reason)")")
    }
  }
}

/// The phrases that work without setting anything up. The app answers to
/// "Claude Code" too (`INAlternativeAppNames` in Info.plist).
@available(iOS 16.4, *)
struct CcnotifyShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: TellClaudeIntent(),
      phrases: [
        "Tell \(.applicationName)",
        "Message \(.applicationName)",
        "Tell \(.applicationName) in \(\.$session)",
        "Message \(.applicationName) in \(\.$session)",
      ],
      shortTitle: "Tell Claude Code",
      systemImageName: "bubble.left.and.text.bubble.right")
  }
}

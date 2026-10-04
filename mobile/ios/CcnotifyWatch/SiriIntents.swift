import AppIntents
import WatchConnectivity

// Siri on the watch: "Tell Claude Code …" sends a message to a session, the
// same way the watch app does (through the iPhone). Which session: the one
// named in the phrase ("… in <project>"), else the one active last — or,
// when several were active in the last half hour, Siri asks.
//
// When the iPhone cannot be asked right now (Siri runs this in the
// background, where the phone is often not "reachable"), the message is
// handed to the iPhone as a transfer, which it sends when it can.

@available(watchOS 10.0, *)
struct WatchSessionEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
  static var defaultQuery = WatchSessionQuery()

  let id: String
  let pcId: String
  let sessionId: String
  let title: String
  let project: String
  let state: String
  let lastTs: Int

  /// Called by its project: short enough to say.
  var name: String { project.isEmpty ? title : project }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: "\(project.isEmpty ? state : "\(title) · \(state)")")
  }

  init(_ s: Session) {
    id = "\(s.pcId)|\(s.id)"
    pcId = s.pcId
    sessionId = s.id
    title = s.title
    project = s.project
    state = s.state
    lastTs = s.lastTs
  }
}

@available(watchOS 10.0, *)
struct WatchSessionQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [WatchSessionEntity] {
    await PhoneLink.shared.sessionsForSiri().map(WatchSessionEntity.init).filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [WatchSessionEntity] {
    await PhoneLink.shared.sessionsForSiri().map(WatchSessionEntity.init)
  }

  func entities(matching string: String) async throws -> [WatchSessionEntity] {
    let wanted = string.lowercased()
    return await PhoneLink.shared.sessionsForSiri().map(WatchSessionEntity.init).filter {
      $0.project.lowercased().contains(wanted) || $0.title.lowercased().contains(wanted)
    }
  }
}

@available(watchOS 10.0, *)
struct TellClaudeWatchIntent: AppIntent {
  static var title: LocalizedStringResource = "Tell Claude Code"
  static var description = IntentDescription(
    "Sends a message to a Claude Code session on your PC, through your iPhone.")
  static var openAppWhenRun = false

  @Parameter(title: "Message", requestValueDialog: "What do you want to tell Claude?")
  var message: String

  @Parameter(title: "Session", description: "Leave empty for the session that was active last.")
  var session: WatchSessionEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Tell Claude Code \(\.$message)") {
      \.$session
    }
  }

  /// "Recently active" for the question which session is meant.
  private static let recentMs = 30 * 60 * 1000

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      throw $message.needsValueError("What do you want to tell Claude?")
    }
    let link = PhoneLink.shared
    let sessions = await link.sessionsForSiri().map(WatchSessionEntity.init)
    let target: WatchSessionEntity
    if let session {
      target = session
    } else {
      guard let newest = sessions.first else {
        return .result(
          dialog: "I don't know of a Claude Code session yet. Open ccnotify on the watch once.")
      }
      let current = sessions.filter { newest.lastTs - $0.lastTs <= Self.recentMs }
      target =
        current.count > 1
        ? try await $session.requestDisambiguation(among: current, dialog: "Which session?")
        : newest
    }
    do {
      let reply = try await link.send(pcId: target.pcId, sessionId: target.sessionId, text: text)
      switch reply.status {
      case "delivered":
        return .result(dialog: "Sent to \(target.name).")
      case "queued":
        return .result(dialog: "Queued for \(target.name). Claude gets it when it finishes.")
      case "sending":
        return .result(dialog: "On its way to \(target.name); the PC has not answered yet.")
      default:
        let reason = reply.reason
        return .result(dialog: "Not sent\(reason.isEmpty ? "." : ": \(reason)")")
      }
    } catch {
      // Not reachable from here: the iPhone takes it from its queue.
      if link.handOver(pcId: target.pcId, sessionId: target.sessionId, text: text) {
        return .result(dialog: "Handed to your iPhone for \(target.name); it sends it when it can.")
      }
      return .result(dialog: "Not sent: \(error.localizedDescription)")
    }
  }
}

/// Works without setting anything up; the app answers to "Claude Code" too
/// (`INAlternativeAppNames` in Info.plist).
@available(watchOS 10.0, *)
struct CcnotifyWatchShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: TellClaudeWatchIntent(),
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

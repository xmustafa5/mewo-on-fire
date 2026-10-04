import Foundation

// What the iPhone app sends (mobile/lib/watch_bridge.dart), as JSON.

/// The lists of the first screen.
struct WatchState: Codable, Equatable {
  var running: Bool
  var pcs: [Pc]
  var requests: [Request]
  var sessions: [Session]
}

struct Pc: Codable, Equatable {
  var id: String
  var name: String
  var status: String // connected | connecting | offline | unpaired
}

/// A prompt Claude Code is waiting on: permission, question or plan.
struct Request: Codable, Equatable {
  var pcId: String
  var pcName: String
  var id: String
  var ts: Int
  var kind: String
  var project: String
  var session: String // first 8 characters of the session id
  var tool: String
  var title: String
  var detail: String
  var always: Bool // "Always allow" can be offered
  var answered: Bool // answered from the phone or watch, not confirmed yet
  var questions: [Question]

  var key: String { "\(pcId):\(id)" }
}

struct Question: Codable, Equatable {
  var question: String
  var key: String // what the answer is filed under
  var header: String
  var multi: Bool
  var options: [Option]
}

struct Option: Codable, Equatable {
  var label: String
  var description: String
}

struct Session: Codable, Equatable {
  var pcId: String
  var pcName: String
  var id: String
  var short: String
  var title: String
  var project: String
  var state: String // working | idle | waiting | ended
  var listening: Bool
  var readOnly: Bool
  var lastTs: Int
  var lastText: String
  var queued: Int

  var key: String { "\(pcId):\(id)" }
}

/// One row of a chat: a message, or a run of tool calls as one line.
struct ChatLine: Codable, Equatable {
  var id: String
  var role: String // user | assistant | tool | phone
  var text: String
  var ts: Int
  var status: String // of a message sent from here that is not in the chat yet
}

// Answers to the commands.

struct StateReply: Decodable {
  var state: WatchState
}

/// A page of a chat, oldest line first. `same`: nothing new since `sig`.
struct ChatReply: Decodable {
  var same: Bool?
  var sig: String?
  var more: Bool?
  var items: [ChatLine]?
  /// What Claude suggests to say next (newest page only).
  var suggestions: [String]?
  var warning: String?
}

struct SendReply: Decodable {
  var status: String // delivered | queued | rejected
  var reason: String
}

struct AnswerReply: Decodable {
  var resolved: Bool
}

struct Failure: Decodable {
  var error: String
}

extension Int {
  /// "5 min ago" for a unix time in milliseconds.
  var ago: String {
    guard self > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(self) / 1000)
    if Date().timeIntervalSince(date) < 60 { return "now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

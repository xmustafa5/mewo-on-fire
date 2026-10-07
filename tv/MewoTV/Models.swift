import Foundation

// What the PC sends (PROTOCOL.md), as the TV app keeps it.

/// A PC this TV is paired with (saved in the user defaults).
struct PairedPc: Codable, Equatable {
  var id: String
  var name: String
  var hosts: [String]
  var port: Int
  /// SHA-256 of the PC's certificate (hex), pinned.
  var fp: String
  var token: String
  var deviceId: String
}

struct Session: Codable, Equatable, Identifiable {
  var id: String
  var short: String
  var project: String
  var title: String
  var state: String // working | idle | waiting | ended
  var listening: Bool
  var readOnly: Bool
  var lastTs: Int
  var lastText: String
  var queued: Int

  enum CodingKeys: String, CodingKey {
    case id, short, project, title, state, listening, queued
    case readOnly = "read_only"
    case lastTs = "last_ts"
    case lastText = "last_text"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    short = try c.decodeIfPresent(String.self, forKey: .short) ?? ""
    project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
    listening = try c.decodeIfPresent(Bool.self, forKey: .listening) ?? false
    readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    lastTs = try c.decodeIfPresent(Int.self, forKey: .lastTs) ?? 0
    lastText = try c.decodeIfPresent(String.self, forKey: .lastText) ?? ""
    queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
  }

  var displayTitle: String {
    if !title.isEmpty { return title }
    if !project.isEmpty { return project }
    return short.isEmpty ? String(id.prefix(8)) : short
  }

  var stateLabel: String {
    switch state {
    case "working": return "Working"
    case "waiting": return "Needs you"
    case "ended": return "Closed"
    default: return "Finished"
    }
  }
}

struct ChatItem: Codable, Equatable, Identifiable {
  var id: String
  var ts: Int
  var role: String // user | assistant | tool | phone
  var text: String
  var tool: String?
  var suggestions: [String]?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    ts = try c.decodeIfPresent(Int.self, forKey: .ts) ?? 0
    role = try c.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    tool = try c.decodeIfPresent(String.self, forKey: .tool)
    suggestions = try c.decodeIfPresent([String].self, forKey: .suggestions)
  }
}

struct RequestOption: Codable, Equatable {
  var label: String
  var description: String?
}

struct RequestQuestion: Codable, Equatable {
  var question: String
  var header: String?
  var options: [RequestOption]?
  var multiSelect: Bool?
}

/// A prompt Claude Code is waiting on: permission, question or plan.
struct CcRequest: Codable, Equatable, Identifiable {
  var id: String
  var ts: Int
  var kind: String
  var project: String
  var session: String // first 8 characters of the session id
  var tool: String?
  var title: String?
  var summary: String?
  var detail: String?
  var canAllowAlways: Bool?
  var questions: [RequestQuestion]?

  enum CodingKeys: String, CodingKey {
    case id, ts, kind, project, session, tool, title, summary, detail, questions
    case canAllowAlways = "can_allow_always"
  }

  var kindLabel: String {
    switch kind {
    case "question": return "Question"
    case "plan": return "Plan approval"
    default: return "Permission"
    }
  }
}

struct CcEvent: Codable, Equatable {
  var id: Int
  var ts: Int
  var kind: String
  var project: String
  var message: String?
  var sessionId: String?

  enum CodingKeys: String, CodingKey {
    case id, ts, kind, project, message
    case sessionId = "session_id"
  }
}

extension Int {
  /// "5 min ago" for a unix time in milliseconds.
  var ago: String {
    guard self > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(self) / 1000)
    if Date().timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }

  var clock: String {
    guard self > 0 else { return "" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(self) / 1000))
  }
}

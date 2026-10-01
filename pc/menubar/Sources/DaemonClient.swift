import Foundation

/// Client of the daemon's local control socket (see PROTOCOL.md): one
/// newline-terminated JSON request per connection, one JSON line back.
/// Blocking: call it off the main thread.
enum DaemonClient {
  /// The daemon is not answering on its socket.
  struct NotRunning: Error {}
  struct BadReply: Error {}

  static let launchdLabel = "com.torchcorp.ccnotify"

  /// Same rule as `paths::socket_path()` in the daemon (macOS).
  static var socketPath: String {
    let path = NSHomeDirectory() + "/.local/state/ccnotify/ccnotify.sock"
    if path.utf8.count <= 103 { return path }
    let env = ProcessInfo.processInfo.environment
    return "/tmp/ccnotify-\(env["USER"] ?? env["LOGNAME"] ?? "user").sock"
  }

  static var logPath: String { NSHomeDirectory() + "/Library/Logs/ccnotify.log" }

  static func request(_ request: [String: Any], timeout: Int = 3) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NotRunning() }
    defer { close(fd) }

    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    let tvSize = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    // The zeroed remainder of sun_path terminates the string.
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw NotRunning() }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw NotRunning() }

    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(0x0A)
    let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == line.count else { throw BadReply() }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(fd, &buffer, buffer.count)
      if n <= 0 { break }
      reply.append(buffer, count: n)
      if buffer[..<n].contains(0x0A) { break }
    }
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
      throw BadReply()
    }
    return object
  }

  /// Like `request`, but a reply without `"ok": true` is nil.
  static func ok(_ request: [String: Any], timeout: Int = 3) -> [String: Any]? {
    guard let reply = try? self.request(request, timeout: timeout), reply["ok"] as? Bool == true
    else { return nil }
    return reply
  }
}

// MARK: - Replies

/// `status` reply.
struct DaemonStatus: Equatable {
  var name: String
  var port: Int
  var hosts: [String]
  var devices: Int
  var connected: Int
  var pending: Int

  init(_ j: [String: Any]) {
    name = j["name"] as? String ?? ""
    port = j["port"] as? Int ?? 0
    hosts = j["hosts"] as? [String] ?? []
    devices = j["devices"] as? Int ?? 0
    connected = j["connected"] as? Int ?? 0
    pending = j["pending"] as? Int ?? 0
  }
}

/// A paired phone (`devices` reply).
struct PairedDevice: Identifiable, Equatable {
  var id: String
  var name: String
  var paired: Date

  init(_ j: [String: Any]) {
    id = j["id"] as? String ?? ""
    name = j["name"] as? String ?? ""
    paired = Date(timeIntervalSince1970: (j["created"] as? Double ?? 0) / 1000)
  }
}

/// A Claude Code session (PROTOCOL.md v1.2 "Session").
struct ClaudeSession: Identifiable, Equatable {
  var id: String
  var project: String
  var title: String
  var state: String
  var listening: Bool
  var lastActive: Date
  var lastText: String
  var queued: Int

  init(_ j: [String: Any]) {
    id = j["id"] as? String ?? ""
    project = j["project"] as? String ?? ""
    title = j["title"] as? String ?? ""
    state = j["state"] as? String ?? ""
    listening = j["listening"] as? Bool ?? false
    lastActive = Date(timeIntervalSince1970: (j["last_ts"] as? Double ?? 0) / 1000)
    lastText = j["last_text"] as? String ?? ""
    queued = j["queued"] as? Int ?? 0
  }
}

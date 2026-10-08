import Foundation

/// Client of the daemon's local control socket (see PROTOCOL.md): one
/// newline-terminated JSON request per connection, one JSON line back.
/// Blocking: call it off the main thread. Also reads a daemon from before
/// the rename (`ccnotify`), which has no `events` / `requests`.
enum DaemonClient {
  struct NotRunning: Error {}
  struct BadReply: Error {}

  /// Sockets to try, this daemon's first, then legacy ones.
  static var candidates: [(path: String, legacy: Bool)] {
    let home = NSHomeDirectory()
    let env = ProcessInfo.processInfo.environment
    let user = env["USER"] ?? env["LOGNAME"] ?? "user"
    return [
      (home + "/.local/state/mewo-on-fire/mewo-on-fire.sock", false),
      ("/tmp/mewo-on-fire-\(user).sock", false),
      (home + "/.local/state/ccnotify/ccnotify.sock", true),
      ("/tmp/ccnotify-\(user).sock", true),
    ]
  }

  static func request(at socketPath: String, _ request: [String: Any], timeout: Int = 3) throws -> [String: Any] {
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

  /// A list field of a reply, or empty when the daemon does not know the command.
  private static func list(at path: String, _ cmd: [String: Any], _ key: String) -> [Any] {
    guard let r = try? request(at: path, cmd), r["ok"] as? Bool == true else { return [] }
    return r[key] as? [Any] ?? []
  }

  /// Everything the page shows, from the first daemon that answers; the
  /// same shape as `mewo dashboard`'s `/api/state`.
  static func collect() -> [String: Any] {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    var problem = ""
    for c in candidates where FileManager.default.fileExists(atPath: c.path) {
      do {
        let status = try request(at: c.path, ["cmd": "status"])
        return [
          "ok": true,
          "daemon": status,
          "sessions": list(at: c.path, ["cmd": "sessions"], "sessions"),
          "events": list(at: c.path, ["cmd": "events", "limit": 120], "events"),
          "requests": list(at: c.path, ["cmd": "requests"], "requests"),
          "legacy": c.legacy,
          "now": now,
          "version": version,
        ]
      } catch {
        problem = "The daemon at \(c.path) is not answering."
      }
    }
    if problem.isEmpty {
      problem = "No daemon found. Is Mewo on Fire installed and running? (`mewo status`)"
    }
    return ["ok": false, "error": problem, "now": now, "version": version]
  }
}

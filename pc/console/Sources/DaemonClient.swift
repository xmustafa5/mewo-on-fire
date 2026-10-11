import AppKit
import Foundation

/// Client of the daemon's local control socket (see PROTOCOL.md): one
/// newline-terminated JSON request per connection, one JSON line back.
/// Blocking: call it off the main thread. Also reads a daemon from before
/// the rename (`ccnotify`), which has no `events` / `requests`.
enum DaemonClient {
  struct NotRunning: Error {}
  struct BadReply: Error {}

  /// Sockets to try: this daemon's (the same rule as `paths::socket_path()`:
  /// the state folder, or /tmp only when the home path is too long for a
  /// socket), then a legacy `ccnotify` daemon's.
  static var candidates: [(path: String, legacy: Bool)] {
    let home = NSHomeDirectory()
    let env = ProcessInfo.processInfo.environment
    let user = env["USER"] ?? env["LOGNAME"] ?? "user"
    let state = home + "/.local/state/mewo-on-fire/mewo-on-fire.sock"
    let current = state.utf8.count <= 103 ? state : "/tmp/mewo-on-fire-\(user).sock"
    let legacyState = home + "/.local/state/ccnotify/ccnotify.sock"
    let legacy = legacyState.utf8.count <= 103 ? legacyState : "/tmp/ccnotify-\(user).sock"
    return [(current, false), (legacy, true)]
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

  /// Claude Desktop's own records: Claude Code session id → the app's
  /// `local_…` id, for sessions the daemon did not tag itself.
  private static var desktopCache: (at: Date, map: [String: String])?
  static func desktopIds() -> [String: String] {
    if let c = desktopCache, Date().timeIntervalSince(c.at) < 30 { return c.map }
    var out: [String: String] = [:]
    let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
    let fm = FileManager.default
    for account in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
      let a = root + "/" + account
      for org in (try? fm.contentsOfDirectory(atPath: a)) ?? [] {
        let o = a + "/" + org
        for name in (try? fm.contentsOfDirectory(atPath: o)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
          guard let data = fm.contents(atPath: o + "/" + name),
                let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cli = j["cliSessionId"] as? String, !cli.isEmpty,
                let desktop = j["sessionId"] as? String, desktop.hasPrefix("local_") else { continue }
          out[cli] = desktop
        }
      }
    }
    desktopCache = (Date(), out)
    return out
  }

  private static func tagged(_ sessions: [Any]) -> [Any] {
    let ids = desktopIds()
    if ids.isEmpty { return sessions }
    return sessions.map { any in
      guard var s = any as? [String: Any], let id = s["id"] as? String else { return any }
      if (s["desktop"] as? String ?? "").isEmpty, let d = ids[id] { s["desktop"] = d }
      return s
    }
  }

  /// A new Claude Code session in Claude Desktop with [prompt] as its first
  /// message: through this daemon when it runs (its log sees it), else by
  /// opening the link from here (a legacy daemon has no such command).
  static func newSession(cwd: String, prompt: String) -> [String: Any] {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return ["ok": false, "error": "The first message is empty"] }
    for c in candidates where !c.legacy && FileManager.default.fileExists(atPath: c.path) {
      if let r = try? request(at: c.path, ["cmd": "new_session", "cwd": cwd, "prompt": text], timeout: 10) {
        return ["ok": r["ok"] as? Bool ?? false, "error": r["error"] as? String ?? ""]
      }
    }
    guard FileManager.default.fileExists(atPath: "/Applications/Claude.app")
      || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Applications/Claude.app") else {
      return ["ok": false, "error": "Claude Desktop is not installed on this Mac"]
    }
    var items = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "source", value: "mewo")]
    if !cwd.isEmpty {
      guard FileManager.default.fileExists(atPath: cwd) else { return ["ok": false, "error": "No such folder: \(cwd)"] }
      items.append(URLQueryItem(name: "folder", value: cwd))
    }
    var comps = URLComponents(); comps.scheme = "claude"; comps.host = "code"; comps.path = "/new"; comps.queryItems = items
    guard let url = comps.url else { return ["ok": false, "error": "Could not build the link"] }
    var opened = false
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { opened = NSWorkspace.shared.open(url); done.signal() }
    done.wait()
    return opened ? ["ok": true] : ["ok": false, "error": "Claude Desktop did not take the link"]
  }

  /// Roles, apps and workspaces that come with `features`.
  private static func featuresMeta(at path: String) -> [String: Any] {
    guard let r = try? request(at: path, ["cmd": "features"], timeout: 20), r["ok"] as? Bool == true else { return [:] }
    return ["roles": r["roles"] ?? [:], "apps": r["apps"] ?? [:], "role_names": r["role_names"] ?? [], "workspaces": r["workspaces"] ?? []]
  }

  /// A control request from the page, to this daemon (not a legacy one):
  /// the pipeline view's commands only.
  static func forward(_ req: [String: Any]) -> [String: Any] {
    let allowed = ["features", "sign", "plan_status", "scan", "set_check", "start_session", "request_sign", "flow_next", "flow_set", "estimate", "estimates_done", "export_handoff", "uat_user", "release", "close_branches", "new_feature", "set_role", "rollback", "unsign", "prds", "set_prd", "set_design", "flow_redo", "notes", "note_add", "note_set", "note_remove", "notes_send", "peers", "peer_scan", "peer_pair", "peer_remove", "new_session", "plane_config", "plane_test", "plane_status", "plane_members", "plane_projects", "plane_signin", "plane_mine", "plane_tasks", "plane_task_add", "plane_task_done", "plane_sync", "plane_disconnect"]
    guard let cmd = req["cmd"] as? String, allowed.contains(cmd) else { return ["ok": false, "error": "not a console command"] }
    for c in candidates where !c.legacy && FileManager.default.fileExists(atPath: c.path) {
      if let r = try? request(at: c.path, req, timeout: 20) { return r }
      return ["ok": false, "error": "The daemon did not answer"]
    }
    return ["ok": false, "error": "The daemon is not running"]
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
          "sessions": tagged(list(at: c.path, ["cmd": "sessions"], "sessions")),
          "events": list(at: c.path, ["cmd": "events", "limit": 120], "events"),
          "requests": list(at: c.path, ["cmd": "requests"], "requests"),
          "features": c.legacy ? [] : list(at: c.path, ["cmd": "features"], "features"),
          "features_meta": c.legacy ? [:] : featuresMeta(at: c.path),
          "peers": c.legacy ? [] : list(at: c.path, ["cmd": "peers"], "peers"),
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

import CryptoKit
import Foundation

/// The TV's own connection to a PC (PROTOCOL.md): a WebSocket over TLS with
/// the PC's certificate pinned by its SHA-256, the device token, then the
/// frames the phone app uses too (sessions, chat, requests, answers, send).
@MainActor
final class PcClient: NSObject, ObservableObject {
  static let shared = PcClient()
  private static let pcKey = "paired_pc"

  @Published private(set) var pc: PairedPc?
  @Published private(set) var status = "Not paired" // Connected | Connecting… | Offline | Not paired
  @Published private(set) var connected = false
  @Published private(set) var sessions: [Session] = []
  @Published private(set) var requests: [CcRequest] = []
  /// Chats by session id, as last fetched.
  @Published private(set) var chats: [String: [ChatItem]] = [:]
  @Published private(set) var chatTitles: [String: String] = [:]
  @Published private(set) var lastSendResult: (clientId: String, status: String, reason: String)?
  @Published private(set) var lastEvent: CcEvent?

  private var session: URLSession!
  private var task: URLSessionWebSocketTask?
  private var pinnedFp = ""
  private var acceptAnyCert = false
  private var seenFp = ""
  private var reconnectDelay: TimeInterval = 1
  private var since = 0
  private var stopped = true
  private var hostIndex = 0
  private var pairContinuation: CheckedContinuation<[String: Any], Error>?

  private override init() {
    super.init()
    session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    if let data = UserDefaults.standard.data(forKey: Self.pcKey),
      let saved = try? JSONDecoder().decode(PairedPc.self, from: data)
    {
      pc = saved
      since = UserDefaults.standard.integer(forKey: "since_\(saved.id)")
    }
  }

  // MARK: pairing

  /// Pairs with the PC at `host` using the code from `mewo pair` (or
  /// `ccnotify pair`). The certificate seen then is pinned from now on.
  func pair(host: String, port: Int, code: String, name: String) async throws {
    stop()
    pinnedFp = ""
    acceptAnyCert = true
    seenFp = ""
    defer { acceptAnyCert = false }
    let ws = session.webSocketTask(with: URL(string: "wss://\(Self.bracket(host)):\(port)/")!)
    ws.resume()
    let frame: [String: Any] = ["type": "pair", "code": code, "device_name": "Apple TV"]
    try await ws.send(.string(Self.json(frame)))
    let reply = try await Self.receiveJson(ws)
    ws.cancel(with: .normalClosure, reason: nil)
    guard reply["type"] as? String == "paired",
      let token = reply["token"] as? String, let deviceId = reply["device_id"] as? String,
      let pcId = reply["pc_id"] as? String
    else {
      let error = reply["error"] as? String ?? "no answer"
      throw ClientError(text: error == "invalid_code" ? "Wrong or expired code" : "Pairing failed: \(error)")
    }
    let paired = PairedPc(
      id: pcId, name: reply["name"] as? String ?? name, hosts: [host], port: port, fp: seenFp,
      token: token, deviceId: deviceId)
    pc = paired
    since = (reply["last_id"] as? Int) ?? 0
    UserDefaults.standard.set(since, forKey: "since_\(pcId)")
    UserDefaults.standard.set(try? JSONEncoder().encode(paired), forKey: Self.pcKey)
    start()
  }

  func unpair() {
    stop()
    pc = nil
    sessions = []
    requests = []
    chats = [:]
    status = "Not paired"
    UserDefaults.standard.removeObject(forKey: Self.pcKey)
  }

  // MARK: connection

  func start() {
    guard let pc, stopped else { return }
    stopped = false
    pinnedFp = pc.fp
    reconnectDelay = 1
    status = "Connecting…"
    Task { await loop() }
  }

  func stop() {
    stopped = true
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    connected = false
  }

  private func loop() async {
    while !stopped, let pc {
      let host = pc.hosts[hostIndex % max(1, pc.hosts.count)]
      hostIndex += 1
      let outcome = await runSession(host: host, port: pc.port, token: pc.token)
      connected = false
      if stopped { return }
      if outcome == .unauthorized {
        status = "Unpaired on the PC"
        return
      }
      status = "Offline"
      try? await Task.sleep(for: .seconds(reconnectDelay))
      reconnectDelay = min(reconnectDelay * 2, 30)
    }
  }

  private enum Outcome { case failed, closed, unauthorized }

  private func runSession(host: String, port: Int, token: String) async -> Outcome {
    guard let url = URL(string: "wss://\(Self.bracket(host)):\(port)/") else { return .failed }
    let ws = session.webSocketTask(with: url)
    task = ws
    ws.resume()
    do {
      try await ws.send(.string(Self.json(["type": "auth", "token": token, "since": since])))
      var outcome = Outcome.closed
      while !stopped {
        let frame = try await Self.receiveJson(ws)
        if frame["type"] as? String == "error" && frame["error"] as? String == "unauthorized" {
          outcome = .unauthorized
          break
        }
        handle(frame)
      }
      ws.cancel(with: .normalClosure, reason: nil)
      return outcome
    } catch {
      ws.cancel(with: .abnormalClosure, reason: nil)
      return .failed
    }
  }

  private func handle(_ f: [String: Any]) {
    switch f["type"] as? String {
    case "hello":
      connected = true
      status = "Connected"
      reconnectDelay = 1
      if let hosts = f["hosts"] as? [String], !hosts.isEmpty, var pc, hosts != pc.hosts {
        pc.hosts = hosts
        self.pc = pc
        UserDefaults.standard.set(try? JSONEncoder().encode(pc), forKey: Self.pcKey)
      }
      send(["type": "sessions"])
    case "event":
      if let ev = decode(CcEvent.self, f["event"]) {
        if ev.id > since {
          since = ev.id
          if let pc { UserDefaults.standard.set(since, forKey: "since_\(pc.id)") }
        }
        lastEvent = ev
        if ev.kind == "stop", let sid = ev.sessionId, chats[sid] != nil { fetchChat(sid) }
      }
    case "sessions":
      if let list = f["sessions"] as? [Any] {
        sessions = list.compactMap { decode(Session.self, $0) }.sorted { $0.lastTs > $1.lastTs }
      }
    case "session":
      if let s = decode(Session.self, f["session"]) {
        sessions.removeAll { $0.id == s.id }
        sessions.append(s)
        sessions.sort { $0.lastTs > $1.lastTs }
        if chats[s.id] != nil { fetchChat(s.id) }
      }
    case "chat":
      if let sid = f["session_id"] as? String, let items = f["items"] as? [Any] {
        chats[sid] = items.compactMap { decode(ChatItem.self, $0) }.filter {
          !$0.text.isEmpty || $0.role == "tool"
        }
        if let title = f["title"] as? String, !title.isEmpty { chatTitles[sid] = title }
      }
    case "request":
      if let r = decode(CcRequest.self, f["request"]) {
        requests.removeAll { $0.id == r.id }
        requests.insert(r, at: 0)
      }
    case "resolved":
      if let id = f["request_id"] as? String { requests.removeAll { $0.id == id } }
    case "send_result":
      lastSendResult = (
        f["client_id"] as? String ?? "", f["status"] as? String ?? "rejected",
        f["reason"] as? String ?? "")
    default:
      break
    }
  }

  // MARK: commands

  func refreshSessions() { send(["type": "sessions"]) }

  func fetchChat(_ sessionId: String) {
    send(["type": "get_chat", "session_id": sessionId, "limit": 100])
  }

  /// Sends `text` to a session; the result arrives as `lastSendResult`.
  @discardableResult
  func sendMessage(_ sessionId: String, _ text: String) -> String {
    let clientId = (0..<16).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
    send(["type": "send", "session_id": sessionId, "text": text, "client_id": clientId])
    return clientId
  }

  func answer(_ requestId: String, _ answer: [String: Any]) {
    send(["type": "answer", "request_id": requestId, "answer": answer])
    requests.removeAll { $0.id == requestId }
  }

  private func send(_ frame: [String: Any]) {
    guard let task else { return }
    task.send(.string(Self.json(frame))) { _ in }
  }

  // MARK: helpers

  private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
    guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func json(_ frame: [String: Any]) -> String {
    String(data: (try? JSONSerialization.data(withJSONObject: frame)) ?? Data(), encoding: .utf8) ?? "{}"
  }

  private static func receiveJson(_ ws: URLSessionWebSocketTask) async throws -> [String: Any] {
    while true {
      let message = try await ws.receive()
      let data: Data
      switch message {
      case .string(let s): data = Data(s.utf8)
      case .data(let d): data = d
      @unknown default: continue
      }
      if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
    }
  }

  private static func bracket(_ host: String) -> String {
    host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
  }
}

struct ClientError: LocalizedError {
  let text: String
  var errorDescription: String? { text }
}

extension PcClient: URLSessionDelegate {
  /// The PC's certificate is self-signed: it is trusted by its fingerprint
  /// (pinned when pairing), not by a certificate authority.
  nonisolated func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust,
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
    else { return (.cancelAuthenticationChallenge, nil) }
    let der = SecCertificateCopyData(leaf) as Data
    let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    let ok = await MainActor.run { () -> Bool in
      if self.acceptAnyCert {
        self.seenFp = fp
        return true
      }
      return fp == self.pinnedFp
    }
    return ok ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
  }
}

import AppKit
import CoreImage.CIFilterBuiltins
import Foundation

/// A pairing code being shown as a QR code.
struct Pairing: Equatable {
  /// QR payload (also what the app's "Paste code instead" takes).
  var payload: String
  var image: NSImage?
  var expires: Date
  /// Devices that were paired before; a new id means the phone scanned it.
  var known: Set<String>
  /// Name of the phone that paired with this code.
  var pairedWith: String?
}

/// State of the menu: polls the daemon and runs the actions.
@MainActor
final class AppModel: ObservableObject {
  /// Nil while the daemon is not answering.
  @Published private(set) var status: DaemonStatus?
  @Published private(set) var devices: [PairedDevice] = []
  @Published private(set) var sessions: [ClaudeSession] = []
  @Published private(set) var pairing: Pairing?
  /// One line of feedback for the last action.
  @Published var notice: String?

  private var timer: Timer?
  private var ticks = 0
  private var wasVisible = false

  init() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    refresh()
  }

  /// SF Symbol of the menu bar item.
  var menuBarSymbol: String {
    guard let status else { return "bell.slash" }
    let waiting = status.pending > 0 || sessions.contains { $0.state == "waiting" }
    return waiting ? "bell.badge" : "bell"
  }

  /// The menu's window is open (the status item is a window of its own).
  private var menuVisible: Bool {
    NSApp.windows.contains { $0.isVisible && $0.className != "NSStatusBarWindow" }
  }

  /// Refreshes when the menu opens, then every 3 s while it is open and
  /// every 15 s (status only) while it is closed. While a QR code is shown,
  /// checks every second whether a phone used it.
  private func tick() {
    ticks += 1
    let visible = menuVisible
    defer { wasVisible = visible }
    if pairing != nil {
      pollPairing()
    } else if (visible && !wasVisible) || ticks % (visible ? 3 : 15) == 0 {
      refresh()
    }
  }

  // MARK: - Polling

  /// Phones and sessions are only fetched while the menu is open (`detailed`):
  /// listing the sessions makes the daemon re-read changed transcripts.
  func refresh(detailed: Bool? = nil) {
    let detailed = detailed ?? menuVisible
    Task {
      let loaded = await Task.detached { Self.load(detailed: detailed) }.value
      status = loaded.status
      if status == nil {
        devices = []
        sessions = []
      } else if detailed {
        devices = loaded.devices
        sessions = loaded.sessions
      }
    }
  }

  private struct Loaded {
    var status: DaemonStatus?
    var devices: [PairedDevice] = []
    var sessions: [ClaudeSession] = []
  }

  private nonisolated static func load(detailed: Bool) -> Loaded {
    guard let reply = DaemonClient.ok(["cmd": "status"]) else { return Loaded() }
    var loaded = Loaded(status: DaemonStatus(reply))
    guard detailed else { return loaded }
    loaded.devices = loadDevices()
    // May read transcripts: give it longer.
    let sessions = DaemonClient.ok(["cmd": "sessions"], timeout: 15)?["sessions"]
    loaded.sessions = (sessions as? [[String: Any]] ?? []).map(ClaudeSession.init)
    return loaded
  }

  private nonisolated static func loadDevices() -> [PairedDevice] {
    let list = DaemonClient.ok(["cmd": "devices"])?["devices"] as? [[String: Any]]
    return (list ?? []).map(PairedDevice.init)
  }

  // MARK: - Pairing

  func startPairing() {
    notice = nil
    Task {
      let result = await Task.detached { () -> (String, Int, [PairedDevice])? in
        let known = Self.loadDevices()
        guard let reply = DaemonClient.ok(["cmd": "pair"]),
          let payload = reply["qr"] as? String, !payload.isEmpty
        else { return nil }
        return (payload, reply["expires_in"] as? Int ?? 300, known)
      }.value
      guard let (payload, seconds, known) = result else {
        notice = "Could not get a pairing code from the service."
        return
      }
      pairing = Pairing(
        payload: payload,
        image: Self.qrCode(payload),
        expires: Date().addingTimeInterval(TimeInterval(seconds)),
        known: Set(known.map(\.id)))
    }
  }

  func stopPairing() {
    pairing = nil
    refresh()
  }

  func copyPairingCode() {
    guard let payload = pairing?.payload else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(payload, forType: .string)
    notice = "Pairing code copied."
  }

  /// A device that was not there when the code was made has paired with it.
  private func pollPairing() {
    guard let current = pairing, current.pairedWith == nil, current.expires > Date() else { return }
    Task {
      let list = await Task.detached { Self.loadDevices() }.value
      guard pairing?.payload == current.payload,
        let new = list.first(where: { !current.known.contains($0.id) })
      else { return }
      pairing?.pairedWith = new.name
      devices = list
    }
  }

  private static func qrCode(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    else { return nil }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }

  // MARK: - Actions

  func revoke(_ device: PairedDevice) {
    Task {
      let done = await Task.detached {
        DaemonClient.ok(["cmd": "revoke", "id": device.id]) != nil
      }.value
      notice = done ? "Removed \(device.name)." : "Could not remove \(device.name)."
      refresh()
    }
  }

  func sendTest() {
    Task {
      let connected = await Task.detached { () -> Int? in
        let event: [String: Any] = [
          "kind": "stop", "project": "mewo-on-fire", "cwd": "", "session": "test",
          "message": "Test notification from Mewo on Fire", "detail": "",
        ]
        guard DaemonClient.ok(["cmd": "emit", "event": event]) != nil else { return nil }
        return DaemonClient.ok(["cmd": "status"])?["connected"] as? Int ?? 0
      }.value
      switch connected {
      case nil: notice = "The service is not running."
      case 0: notice = "Sent, but no phone is connected right now."
      case let n?: notice = "Test notification sent to \(n) phone\(n == 1 ? "" : "s")."
      }
    }
  }

  /// Starts the daemon's launchd agent (`restart`: also when it is running).
  func startService(restart: Bool = false) {
    notice = nil
    Task {
      let started = await Task.detached { () -> Bool in
        let target = "gui/\(getuid())/\(DaemonClient.launchdLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = restart ? ["kickstart", "-k", target] : ["kickstart", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
      }.value
      if !started {
        notice = "The service is not installed. Run `mewo install` in a terminal."
        return
      }
      // The daemon needs a moment to bind its socket.
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      refresh()
      try? await Task.sleep(nanoseconds: 500_000_000)
      if status == nil {
        notice = "The service did not start. See the log for the reason."
      }
    }
  }

  func openLog() {
    NSWorkspace.shared.open(URL(fileURLWithPath: DaemonClient.logPath))
  }
}

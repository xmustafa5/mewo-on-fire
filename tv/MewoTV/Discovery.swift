import Foundation
import Network

/// A PC found on the network (the daemon advertises `_ccnotify._tcp`).
struct FoundPc: Identifiable, Equatable {
  var id: String { name }
  let name: String
  let host: String
  let port: Int
}

/// Looks for PCs on the local network with Bonjour.
@MainActor
final class Discovery: ObservableObject {
  @Published private(set) var found: [FoundPc] = []
  private var browser: NWBrowser?
  private var connections: [NWConnection] = []

  func start() {
    stop()
    let browser = NWBrowser(for: .bonjour(type: "_ccnotify._tcp", domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in
        for result in results { self?.resolve(result) }
      }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
    for c in connections { c.cancel() }
    connections = []
  }

  /// Bonjour gives a service name; connecting once (and hanging up) tells
  /// the address and port behind it.
  private func resolve(_ result: NWBrowser.Result) {
    guard case .service(let name, _, _, _) = result.endpoint else { return }
    let connection = NWConnection(to: result.endpoint, using: .tcp)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      if case .ready = state,
        let path = connection.currentPath, case .hostPort(let host, let port) = path.remoteEndpoint
      {
        var address = "\(host)"
        if let i = address.firstIndex(of: "%") { address = String(address[..<i]) }
        let pc = FoundPc(name: name, host: address, port: Int(port.rawValue))
        Task { @MainActor in
          self.found.removeAll { $0.name == name }
          self.found.append(pc)
          self.found.sort { $0.name < $1.name }
        }
        connection.cancel()
      } else if case .failed = state {
        connection.cancel()
      }
    }
    connections.append(connection)
    connection.start(queue: .main)
  }
}

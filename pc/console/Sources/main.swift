import AppKit
import WebKit

/// The operations console as a Mac app: one dark window with the same page
/// `mewo dashboard` serves, fed straight from the daemon's control socket
/// (no HTTP server, nothing listening). Dock icon, full screen, ⌘R reloads.
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
  private var window: NSWindow!
  private var web: WKWebView!
  private var timer: Timer?
  private var ready = false
  private var inFlight = false
  private let queue = DispatchQueue(label: "mewo.console.daemon", qos: .userInitiated)

  func applicationDidFinishLaunching(_ note: Notification) {
    NSApp.appearance = NSAppearance(named: .darkAqua)
    buildMenu()

    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "mewo")
    config.setURLSchemeHandler(ArtifactSchemeHandler(), forURLScheme: "mewo-artifact")
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.setValue(false, forKey: "drawsBackground")

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Mewo on Fire — Operations"
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(red: 0.016, green: 0.027, blue: 0.047, alpha: 1)
    window.minSize = NSSize(width: 880, height: 560)
    window.collectionBehavior = [.fullScreenPrimary]
    window.contentView = web
    window.isReleasedWhenClosed = false
    if !window.setFrameUsingName("MewoConsole") { window.center() }
    window.setFrameAutosaveName("MewoConsole")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    load()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private func load() {
    ready = false
    guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
      web.loadHTMLString("<body style='background:#04070c;color:#dbeafe;font:14px -apple-system;padding:40px'>index.html is missing from the app bundle. Run pc/console/install.sh again.</body>", baseURL: nil)
      return
    }
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }

  // MARK: page ↔ daemon

  /// The page says "ready" once its script is up; from then on it gets the
  /// state every two seconds.
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.body as? String == "ready" {
      ready = true
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.push() }
      push()
      return
    }
    // {"cmd": "daemon", "id", "req"}: a control request for the daemon (the pipeline view).
    if let m = message.body as? [String: Any], m["cmd"] as? String == "daemon",
       let id = m["id"] as? String, let req = m["req"] as? [String: Any] {
      queue.async { [weak self] in
        let reply = DaemonClient.forward(req)
        let json = (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
        let safeId = id.filter { $0.isLetter || $0.isNumber }
        DispatchQueue.main.async { self?.web.evaluateJavaScript("window.__reply('\(safeId)', \(json))", completionHandler: nil) }
      }
      return
    }
    // {"cmd": "new_session", "cwd", "prompt"}: the console's New session form.
    if let m = message.body as? [String: Any], m["cmd"] as? String == "new_session" {
      let cwd = m["cwd"] as? String ?? ""
      let prompt = m["prompt"] as? String ?? ""
      queue.async { [weak self] in
        let reply = DaemonClient.newSession(cwd: cwd, prompt: prompt)
        let json = (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
        DispatchQueue.main.async { self?.web.evaluateJavaScript("window.__newSessionResult(\(json))", completionHandler: nil) }
      }
      return
    }
    // {"cmd": "open", "url": "claude://…"}: a session clicked on the graph.
    if let m = message.body as? [String: Any], m["cmd"] as? String == "open",
       let raw = m["url"] as? String, let url = URL(string: raw),
       ["claude", "https", "http"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
  }

  /// Links the page navigates to (claude://…) go to the app that owns them.
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = action.request.url, let scheme = url.scheme, scheme != "file", scheme != "mewo-artifact" {
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  private func push() {
    guard ready, !inFlight else { return }
    inFlight = true
    queue.async { [weak self] in
      let state = DaemonClient.collect()
      // A JSON object is a JavaScript object literal: handed over as is.
      let json = (try? JSONSerialization.data(withJSONObject: state))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false,\"error\":\"could not encode the state\"}"
      DispatchQueue.main.async {
        guard let self else { return }
        self.inFlight = false
        self.web.evaluateJavaScript("window.__apply(\(json))") { _, error in
          if let error { NSLog("mewo-console: page rejected the state: %@", error.localizedDescription) }
        }
      }
    }
  }

  // MARK: menu

  @objc private func reload() { load() }

  private func buildMenu() {
    let main = NSMenu()

    let app = NSMenuItem(); main.addItem(app)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Mewo Console", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Mewo Console", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Mewo Console", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    app.submenu = appMenu

    let view = NSMenuItem(); main.addItem(view)
    let viewMenu = NSMenu(title: "View")
    let reloadItem = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "r")
    reloadItem.target = self
    viewMenu.addItem(reloadItem)
    let full = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    full.keyEquivalentModifierMask = [.command, .control]
    viewMenu.addItem(full)
    view.submenu = viewMenu

    let win = NSMenuItem(); main.addItem(win)
    let winMenu = NSMenu(title: "Window")
    winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    win.submenu = winMenu
    NSApp.windowsMenu = winMenu

    NSApp.mainMenu = main
  }
}

/// `mewo-artifact://a/<id>/<path>`: the daemon's copy of what a session
/// published, from its state folder, so the page can show a design, a page
/// or a document in an iframe without a server.
extension AppDelegate {
  // The page's alert() and confirm(): without these a WKWebView answers
  // confirm() with false, and a button that asks first does nothing.
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let a = NSAlert()
    a.messageText = message
    a.addButton(withTitle: "OK")
    a.runModal()
    completionHandler()
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let a = NSAlert()
    a.messageText = message
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Cancel")
    completionHandler(a.runModal() == .alertFirstButtonReturn)
  }
}

final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
  static let root = URL(fileURLWithPath: NSHomeDirectory() + "/.local/state/mewo-on-fire/artifacts").standardizedFileURL

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let file = Self.root.appendingPathComponent(parts.joined(separator: "/")).standardizedFileURL.path
    let inside = parts.count >= 2 && !parts.contains("..") && file.hasPrefix(Self.root.path + "/")
    guard inside, let data = FileManager.default.contents(atPath: file) else {
      reply(task, url, 404, "text/plain; charset=utf-8", Data("not found".utf8))
      return
    }
    reply(task, url, 200, Self.mime(file), data)
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

  private func reply(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ type: String, _ data: Data) {
    let headers = ["Content-Type": type, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  static func mime(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "md", "txt", "csv": return "text/plain; charset=utf-8"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "mp4": return "video/mp4"
    case "pdf": return "application/pdf"
    default: return "application/octet-stream"
    }
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

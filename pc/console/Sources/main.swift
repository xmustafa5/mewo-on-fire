import AppKit
import WebKit

/// The operations console as a Mac app: one window with the same page
/// `mewo dashboard` serves, fed straight from the daemon's control socket
/// (no HTTP server, nothing listening). It follows the system's light or dark
/// appearance, and the page's toolbar is the titlebar: the traffic lights sit
/// at its left end and its empty part moves the window. Dock icon, full
/// screen, ⌘R reloads.
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
  private var window: NSWindow!
  private var web: DragWebView!
  private var timer: Timer?
  private var ready = false
  private var inFlight = false
  private let queue = DispatchQueue(label: "mewo.console.daemon", qos: .userInitiated)

  /// The height of the page's toolbar (header#toolbar), in points.
  private static let toolbarHeight: CGFloat = 52

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()

    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "mewo")
    // Before the page's own script runs: it adds body.mac and leaves room at
    // the toolbar's left end for the traffic lights.
    config.userContentController.addUserScript(WKUserScript(
      source: "window.mewoHost = 'mac';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.setURLSchemeHandler(ArtifactSchemeHandler(), forURLScheme: "mewo-artifact")
    web = DragWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.setValue(false, forKey: "drawsBackground")

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    // The title stays for the Window menu and Mission Control; the page
    // draws everything up to the top edge.
    window.title = "Mewo on Fire — Operations"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    // The page's --bg in each appearance: what shows before it paints and
    // at the edges while resizing.
    window.backgroundColor = NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        : .white
    }
    window.minSize = NSSize(width: 880, height: 560)
    window.collectionBehavior = [.fullScreenPrimary]
    window.contentView = web
    window.isReleasedWhenClosed = false
    if !window.setFrameUsingName("MewoConsole") { window.center() }
    window.setFrameAutosaveName("MewoConsole")
    observeWindow()
    window.makeKeyAndOrderFront(nil)
    placeTrafficLights()
    NSApp.activate(ignoringOtherApps: true)
    load()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private func load() {
    ready = false
    // The new page reports its own toolbar once it is up.
    web.toolbar = .zero
    web.controls = []
    guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
      // No toolbar to report here: the whole top band moves the window.
      web.toolbar = CGRect(x: 0, y: 0, width: 100_000, height: Self.toolbarHeight)
      web.loadHTMLString("<body style='color-scheme:light dark;font:14px -apple-system;padding:60px 40px'>index.html is missing from the app bundle. Run pc/console/install.sh again.</body>", baseURL: nil)
      return
    }
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }

  // MARK: window

  /// AppKit lays the titlebar out again after a resize and on leaving full
  /// screen, which puts the traffic lights back at its own 28-point height.
  private func observeWindow() {
    let center = NotificationCenter.default
    for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
      center.addObserver(self, selector: #selector(windowDidLayOutTitlebar(_:)), name: name, object: window)
    }
    center.addObserver(self, selector: #selector(windowWillEnterFullScreen(_:)), name: NSWindow.willEnterFullScreenNotification, object: window)
    center.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
  }

  @objc private func windowDidLayOutTitlebar(_ note: Notification) { placeTrafficLights() }

  /// The titlebar views whose frame changes call placeTrafficLights again.
  private var watched: [NSView] = []
  private var placeQueued = false

  /// AppKit also lays the titlebar out on its own, as when the appearance
  /// changes: the container drops back to its own height and takes the
  /// buttons up out of the window. Any move of the container or the close
  /// button puts them back on the next turn of the run loop.
  private func watchTitlebar(_ views: [NSView]) {
    guard views != watched else { return }
    let center = NotificationCenter.default
    for view in watched { center.removeObserver(self, name: NSView.frameDidChangeNotification, object: view) }
    for view in views {
      view.postsFrameChangedNotifications = true
      center.addObserver(self, selector: #selector(titlebarDidMove(_:)), name: NSView.frameDidChangeNotification, object: view)
    }
    watched = views
  }

  @objc private func titlebarDidMove(_ note: Notification) {
    guard !placeQueued else { return }
    placeQueued = true
    DispatchQueue.main.async { [weak self] in
      self?.placeQueued = false
      self?.placeTrafficLights()
    }
  }

  // In full screen the traffic lights are gone, and so is their gap in the toolbar.
  @objc private func windowWillEnterFullScreen(_ note: Notification) { setPageFullScreen(true) }
  @objc private func windowDidExitFullScreen(_ note: Notification) { setPageFullScreen(false) }

  private func setPageFullScreen(_ on: Bool) {
    web.evaluateJavaScript("document.body && document.body.classList.toggle('fullscreen', \(on))", completionHandler: nil)
  }

  /// A reload in full screen: the new page needs body.fullscreen again.
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if window.styleMask.contains(.fullScreen) { setPageFullScreen(true) }
  }

  /// Centres the close, minimise and zoom buttons in the page's 52-point
  /// toolbar, the way a Mac app with a unified toolbar has them: the titlebar
  /// container grows to the toolbar's height, and the buttons sit 20 points
  /// in from the left edge with their native spacing. Frames are only set
  /// when they differ, so the frame-change watch settles after one pass.
  private func placeTrafficLights() {
    guard !window.styleMask.contains(.fullScreen),
          let close = window.standardWindowButton(.closeButton),
          let mini = window.standardWindowButton(.miniaturizeButton),
          let zoom = window.standardWindowButton(.zoomButton),
          let container = close.superview?.superview, let frameView = container.superview else { return }
    watchTitlebar([container, close])
    let band = Self.toolbarHeight
    var frame = container.frame
    frame.size.height = band
    frame.origin.y = frameView.isFlipped ? 0 : frameView.bounds.height - band
    if container.frame != frame { container.frame = frame }

    let step = mini.frame.minX - close.frame.minX > 0 ? mini.frame.minX - close.frame.minX : 20
    let top = window.frame.height
    for (i, button) in [close, mini, zoom].enumerated() {
      guard let parent = button.superview else { continue }
      // Laid out in window coordinates (bottom-left origin), then handed to
      // the button's parent in its own.
      let size = button.frame.size
      let rect = NSRect(x: 20 + CGFloat(i) * step, y: top - band + (band - size.height) / 2, width: size.width, height: size.height)
      let origin = parent.convert(rect, from: nil).origin
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
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
    // {"cmd": "drag_regions", "toolbar": [x, y, w, h], "controls": [[x, y, w, h], …]}:
    // where the page's toolbar and the controls on it are, for DragWebView.
    if let m = message.body as? [String: Any], m["cmd"] as? String == "drag_regions" {
      web.toolbar = Self.rect(m["toolbar"]) ?? .zero
      web.controls = (m["controls"] as? [Any] ?? []).compactMap { Self.rect($0) }
      return
    }
    // {"cmd": "open", "url": "claude://…"}: a session clicked on the graph.
    if let m = message.body as? [String: Any], m["cmd"] as? String == "open",
       let raw = m["url"] as? String, let url = URL(string: raw),
       ["claude", "https", "http"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
  }

  /// [x, y, w, h] from the page. JavaScript numbers arrive as NSNumber,
  /// integer or not; anything else is not a rectangle.
  private static func rect(_ value: Any?) -> CGRect? {
    guard let parts = value as? [Any], parts.count == 4 else { return nil }
    let n = parts.compactMap { ($0 as? NSNumber)?.doubleValue }.filter(\.isFinite)
    guard n.count == 4 else { return nil }
    return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
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

/// The page, with the empty part of its toolbar acting as the titlebar: a
/// drag there moves the window and a double click zooms it. The page reports
/// where its toolbar and the controls on it are (`drag_regions`) in page
/// coordinates: top-left origin, CSS pixels, which are points here.
final class DragWebView: WKWebView {
  var toolbar = CGRect.zero
  var controls: [CGRect] = []

  // Only mouseDown below moves the window; left to AppKit, a click on a
  // button in the titlebar band could start a drag too.
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    guard let window, !window.styleMask.contains(.fullScreen),
          toolbar.contains(point), !controls.contains(where: { $0.contains(point) }) else {
      super.mouseDown(with: event)
      return
    }
    if event.clickCount == 2 { Self.doubleClickTitlebar(window) } else { window.performDrag(with: event) }
  }

  /// What a double click on a titlebar does, as set in System Settings ›
  /// Desktop & Dock; zoom unless it says minimise or nothing.
  private static func doubleClickTitlebar(_ window: NSWindow) {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.performMiniaturize(nil)
    case "None": break
    default: window.performZoom(nil)
    }
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

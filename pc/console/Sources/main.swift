import AppKit
import WebKit

/// The operations console as a Mac app: one dark window with the same page
/// `mewo dashboard` serves, fed straight from the daemon's control socket
/// (no HTTP server, nothing listening). Dock icon, full screen, ⌘R reloads.
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
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
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
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
    guard message.body as? String == "ready" else { return }
    ready = true
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.push() }
    push()
  }

  private func push() {
    guard ready, !inFlight else { return }
    inFlight = true
    queue.async { [weak self] in
      let state = DaemonClient.collect()
      // Handed over as a JSON string, parsed on the page: no escaping surprises.
      let wrapped = (try? JSONSerialization.data(withJSONObject: [state]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[{\"ok\":false,\"error\":\"could not encode the state\"}]"
      DispatchQueue.main.async {
        guard let self else { return }
        self.inFlight = false
        self.web.evaluateJavaScript("window.__apply(JSON.parse(\(wrapped))[0])", completionHandler: nil)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

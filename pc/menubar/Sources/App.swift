import ServiceManagement
import SwiftUI

/// Menu bar companion of the Mewo on Fire daemon: service status, pairing QR
/// code, paired phones and the Claude Code sessions. Everything comes from
/// the daemon's control socket; the app keeps no state of its own.
@main
struct MewoMenuBarApp: App {
  @StateObject private var model = AppModel()

  init() {
    Self.openAtLoginOnFirstLaunch()
  }

  /// A fresh install opens at login; after that the "Open at Login" toggle
  /// decides.
  private static func openAtLoginOnFirstLaunch() {
    let key = "openAtLoginDefaultApplied"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    try? SMAppService.mainApp.register()
  }

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      Image(systemName: model.menuBarSymbol)
    }
    .menuBarExtraStyle(.window)
  }
}

import SwiftUI

/// Menu bar companion of the ccnotify daemon: service status, pairing QR
/// code, paired phones and the Claude Code sessions. Everything comes from
/// the daemon's control socket; the app keeps no state of its own.
@main
struct CcnotifyMenuBarApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      Image(systemName: model.menuBarSymbol)
    }
    .menuBarExtraStyle(.window)
  }
}

import SwiftUI

/// Mewo on Fire on the Apple Watch: the prompts Claude Code is waiting on, the
/// sessions and their chats, and replies by voice. Everything goes through
/// the iPhone app (see PhoneLink.swift) — the watch never talks to a PC.
@main
struct MewoWatchApp: App {
  @StateObject private var link = PhoneLink.shared

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(link)
    }
  }
}

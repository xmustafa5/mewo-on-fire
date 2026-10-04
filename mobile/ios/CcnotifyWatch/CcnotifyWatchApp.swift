import SwiftUI

/// ccnotify on the Apple Watch: the prompts Claude Code is waiting on, the
/// sessions and their chats, and replies by voice. Everything goes through
/// the iPhone app (see PhoneLink.swift) — the watch never talks to a PC.
@main
struct CcnotifyWatchApp: App {
  @StateObject private var link = PhoneLink()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(link)
    }
  }
}

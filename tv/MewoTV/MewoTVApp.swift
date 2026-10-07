import SwiftUI

/// Mewo on Fire on the Apple TV: the sessions and chats of a paired PC on
/// the big screen, prompts answered with the remote, and messages typed (or
/// dictated) with the Siri Remote. It connects to the PC itself, like the
/// phone does (PcClient.swift).
@main
struct MewoTVApp: App {
  @StateObject private var client = PcClient.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(client)
    }
  }
}

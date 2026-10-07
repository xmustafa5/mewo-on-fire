import SwiftUI

/// Sessions on the left, the chosen session's chat on the right; prompts
/// Claude is waiting on first in the list.
struct ContentView: View {
  @EnvironmentObject private var client: PcClient
  @State private var selected: String?
  @State private var selectedRequest: String?
  /// Opens where you left off.
  @AppStorage("last_session") private var lastSession = ""

  var body: some View {
    if client.pc == nil {
      PairView()
    } else {
      HStack(spacing: 0) {
        sidebar
          .frame(width: 560)
        Divider()
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .onAppear { client.start() }
      .onChange(of: client.sessions.map(\.id)) { _, ids in
        if selected == nil, selectedRequest == nil, ids.contains(lastSession) { open(lastSession) }
      }
    }
  }

  private func open(_ sessionId: String) {
    selected = sessionId
    selectedRequest = nil
    lastSession = sessionId
    client.fetchChat(sessionId)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Image(systemName: client.connected ? "circle.fill" : "circle")
          .foregroundStyle(client.connected ? .green : .secondary)
          .font(.caption)
        Text(client.pc?.name ?? "")
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Text(client.status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 40)
      .padding(.top, 40)
      .padding(.bottom, 10)
      List {
        if !client.requests.isEmpty {
          Section("Waiting for you") {
            ForEach(client.requests) { r in
              Button {
                selectedRequest = r.id
                selected = nil
              } label: {
                HStack {
                  Image(systemName: r.kind == "question" ? "questionmark.circle" : r.kind == "plan" ? "list.clipboard" : "lock")
                  VStack(alignment: .leading) {
                    Text(r.project).lineLimit(1)
                    Text(r.title ?? r.kindLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
              }
            }
          }
        }
        Section("Sessions") {
          ForEach(client.sessions) { s in
            Button {
              open(s.id)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Circle().fill(Self.color(s.state)).frame(width: 12, height: 12)
                  Text(s.displayTitle).lineLimit(1)
                }
                Text("\(s.project) · \(s.stateLabel) · \(s.lastTs.ago)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
          }
        }
        Section {
          Button {
            client.refreshSessions()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          Button(role: .destructive) {
            client.unpair()
          } label: {
            Label("Unpair this PC", systemImage: "link.badge.minus")
          }
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let id = selectedRequest, let r = client.requests.first(where: { $0.id == id }) {
      RequestView(request: r)
    } else if let id = selected {
      ChatView(sessionId: id)
        .id(id)
    } else {
      VStack(spacing: 16) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.system(size: 80))
          .foregroundStyle(.secondary)
        Text("Choose a session")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  static func color(_ state: String) -> Color {
    switch state {
    case "working": return .orange
    case "waiting": return .yellow
    case "idle": return .green
    default: return .gray
    }
  }
}

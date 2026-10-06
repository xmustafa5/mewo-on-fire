import SwiftUI

enum Route: Hashable {
  case request(pcId: String, id: String)
  case chat(pcId: String, sessionId: String)
}

/// First screen: what Claude is waiting on, then the sessions.
struct RootView: View {
  @EnvironmentObject private var link: PhoneLink
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        if let problem = link.problem {
          Section {
            Label(problem, systemImage: "iphone.slash")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }
        if let state = link.state {
          if !state.requests.isEmpty {
            Section("Waiting for you") {
              ForEach(state.requests, id: \.key) { request in
                NavigationLink(value: Route.request(pcId: request.pcId, id: request.id)) {
                  RequestRow(request: request)
                }
              }
            }
          }
          Section("Sessions") {
            if state.sessions.isEmpty {
              Text("No Claude Code sessions yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ForEach(state.sessions, id: \.key) { session in
              NavigationLink(value: Route.chat(pcId: session.pcId, sessionId: session.id)) {
                SessionRow(session: session)
              }
            }
          }
          Section {
            ForEach(state.pcs, id: \.id) { pc in
              HStack {
                Image(systemName: "desktopcomputer")
                Text(pc.name).lineLimit(1)
                Spacer()
                Text(pc.status)
                  .foregroundStyle(pc.status == "connected" ? .green : .secondary)
              }
              .font(.footnote)
            }
          }
        } else if link.problem == nil {
          HStack {
            ProgressView()
            Text("Asking the iPhone…").font(.footnote)
          }
        }
        Button {
          Task { await link.refresh() }
        } label: {
          Label(link.refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(link.refreshing)
      }
      .navigationTitle("Mewo on Fire")
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .request(let pcId, let id):
          RequestView(pcId: pcId, requestId: id)
        case .chat(let pcId, let sessionId):
          ChatView(pcId: pcId, sessionId: sessionId)
        }
      }
    }
    .onChange(of: scenePhase) {
      // Wrist raised or app reopened: the lists may be hours old.
      if scenePhase == .active { Task { await link.refresh() } }
    }
  }
}

struct RequestRow: View {
  let request: Request

  static func icon(_ kind: String) -> String {
    switch kind {
    case "question": return "questionmark.circle"
    case "plan": return "list.clipboard"
    default: return "lock"
    }
  }

  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: Self.icon(request.kind))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(request.project.isEmpty ? "Claude Code" : request.project)
          .font(.headline)
          .lineLimit(1)
        Text(request.title.isEmpty ? request.detail : request.title)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if request.answered {
          Text("Answer sent…")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

struct SessionRow: View {
  let session: Session

  static func color(_ state: String) -> Color {
    switch state {
    case "working": return .orange
    case "waiting": return .yellow
    case "idle": return .green
    default: return .gray
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Circle()
          .fill(Self.color(session.state))
          .frame(width: 8, height: 8)
        Text(session.title)
          .font(.headline)
          .lineLimit(1)
      }
      if !session.lastText.isEmpty {
        Text(session.lastText)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Text([session.state, session.lastTs.ago].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

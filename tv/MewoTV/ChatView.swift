import SwiftUI

/// One session's chat: Claude on the left, you on the right, tool calls as
/// grey lines. The box at the bottom sends a message (the Siri Remote's
/// keyboard can take dictation).
struct ChatView: View {
  let sessionId: String
  @EnvironmentObject private var client: PcClient

  @State private var draft = ""
  @State private var notice: String?
  @State private var pendingClientId: String?

  private var session: Session? { client.sessions.first { $0.id == sessionId } }
  private var items: [ChatItem] { client.chats[sessionId] ?? [] }
  private var requests: [CcRequest] {
    client.requests.filter { $0.session == String(sessionId.prefix(8)) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text(client.chatTitles[sessionId] ?? session?.displayTitle ?? "Chat")
            .font(.title2.bold())
            .lineLimit(1)
          if let s = session {
            Text("\(s.project) · \(s.stateLabel)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button {
          client.fetchChat(sessionId)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
      .padding(.horizontal, 60)
      .padding(.top, 40)
      .padding(.bottom, 16)

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
              Text(client.chats[sessionId] == nil ? "Loading the chat…" : "No messages yet.")
                .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
              LineView(item: item)
                .id(item.id)
            }
            ForEach(requests) { r in
              RequestCard(request: r)
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .padding(.horizontal, 60)
          .padding(.bottom, 20)
        }
        .onChange(of: items.count) { _, _ in
          withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
      }

      composer
        .padding(.horizontal, 60)
        .padding(.vertical, 24)
        .background(.thinMaterial)
    }
    .onChange(of: client.lastSendResult?.clientId) { _, _ in
      guard let r = client.lastSendResult, r.clientId == pendingClientId else { return }
      switch r.status {
      case "delivered": notice = "Delivered"
      case "queued": notice = "Queued — Claude gets it when it finishes"
      default: notice = "Not sent: \(r.reason.isEmpty ? "the PC refused it" : r.reason)"
      }
      pendingClientId = nil
    }
  }

  @ViewBuilder private var composer: some View {
    if let s = session, s.state == "ended" {
      Label("This session is closed.", systemImage: "lock").foregroundStyle(.secondary)
    } else if let s = session, s.readOnly {
      Label("Read-only until Claude finishes its agents.", systemImage: "lock").foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        if let last = items.last, last.role == "assistant", let suggestions = last.suggestions,
          !suggestions.isEmpty, session?.state != "working"
        {
          HStack {
            ForEach(suggestions, id: \.self) { s in
              Button {
                send(s)
              } label: {
                Label(s, systemImage: "sparkles")
              }
            }
          }
        }
        HStack(spacing: 20) {
          TextField("Message Claude…", text: $draft)
            .frame(maxWidth: .infinity)
          Button {
            send(draft)
          } label: {
            Label("Send", systemImage: "paperplane.fill")
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let notice {
          Text(notice).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func send(_ text: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    pendingClientId = client.sendMessage(sessionId, t)
    notice = "Sending…"
    draft = ""
  }
}

private struct LineView: View {
  let item: ChatItem

  var body: some View {
    if item.role == "tool" {
      Label(item.tool.map { "\($0): \(item.text)" } ?? item.text, systemImage: "wrench.and.screwdriver")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    } else {
      let mine = item.role != "assistant"
      HStack {
        if mine { Spacer(minLength: 200) }
        VStack(alignment: .leading, spacing: 6) {
          MessageText(blocks: Block.parse(item.text))
            .font(.body)
          Text(item.role == "phone" ? "from phone · \(item.ts.clock)" : item.ts.clock)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(mine ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        if !mine { Spacer(minLength: 200) }
      }
    }
  }
}

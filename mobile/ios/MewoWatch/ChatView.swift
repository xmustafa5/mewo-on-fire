import SwiftUI
import WatchKit

/// One session's chat, newest message at the bottom, with a reply by voice
/// (see VoiceSheet.swift). Prompts the session is waiting on are listed under
/// the messages.
struct ChatView: View {
  let pcId: String
  let sessionId: String

  @EnvironmentObject private var link: PhoneLink
  @Environment(\.scenePhase) private var scenePhase

  @State private var rows: [Row] = []
  @State private var more = false
  @State private var sig: String?
  @State private var loaded = false
  @State private var loading = false
  @State private var error: String?
  @State private var sending = false
  @State private var notice: String?
  /// What Claude suggests to say next, and the one tapped (asked about
  /// before it is sent: a tap on a watch is easily a slip).
  @State private var suggestions: [String] = []
  @State private var picked: String?

  /// A chat line with its text already parsed.
  struct Row: Identifiable {
    let line: ChatLine
    let blocks: [Block]
    var id: String { line.id }

    init(_ line: ChatLine) {
      self.line = line
      blocks = line.role == "tool" ? [] : Block.parse(line.text)
    }
  }

  private var session: Session? {
    link.state?.sessions.first { $0.pcId == pcId && $0.id == sessionId }
  }

  private var requests: [Request] {
    let short = String(sessionId.prefix(8))
    return (link.state?.requests ?? [])
      .filter { $0.pcId == pcId && $0.session == short }
      .sorted { $0.ts < $1.ts }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          if more {
            Button {
              Task { await loadEarlier(proxy) }
            } label: {
              Label("Earlier messages", systemImage: "arrow.up")
                .font(.footnote)
            }
            .disabled(loading)
          }
          ForEach(rows) { row in
            LineView(row: row)
              .id(row.id)
          }
          if !loaded {
            if let error {
              Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
              Button("Try again") { Task { await load() } }
            } else {
              HStack {
                ProgressView()
                Text("Loading the chat…").font(.footnote)
              }
            }
          } else {
            if rows.isEmpty {
              Text("No messages yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let error {
              Text(error)
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            ForEach(requests, id: \.key) { request in
              NavigationLink(value: Route.request(pcId: request.pcId, id: request.id)) {
                RequestRow(request: request)
              }
            }
            composer
          }
        }
        .scenePadding(.horizontal)
      }
      .defaultScrollAnchor(.bottom)
    }
    .navigationTitle(session?.title ?? "Chat")
    .confirmationDialog(
      picked ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
      titleVisibility: .visible
    ) {
      Button("Send") {
        if let picked { send(picked) }
        picked = nil
      }
      Button("Cancel", role: .cancel) { picked = nil }
    }
    .task { await poll() }
    .onChange(of: session?.lastTs) { Task { await load() } }
    .onChange(of: session?.state) { Task { await load() } }
  }

  @ViewBuilder
  private var composer: some View {
    if let blocked {
      Label(blocked, systemImage: "lock")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      ForEach(suggestions, id: \.self) { suggestion in
        Button {
          picked = suggestion
        } label: {
          Label(suggestion, systemImage: "sparkles")
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(sending)
      }
      VoiceButton(prompt: "Message to Claude") {
        Label(sending ? "Sending…" : "Reply by voice", systemImage: "mic.fill")
          .frame(maxWidth: .infinity)
      } onSubmit: { text in
        send(text)
      }
      .buttonStyle(.borderedProminent)
      .disabled(sending)
      if let notice {
        Text(notice)
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if let hint {
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var blocked: String? {
    guard let session else { return nil }
    if session.state == "ended" { return "This session is closed." }
    if session.readOnly { return "Read-only until Claude finishes its agents." }
    return nil
  }

  private var hint: String? {
    guard let session else { return nil }
    if session.state == "working" || session.state == "waiting" {
      return "Claude is busy — a message waits until it finishes."
    }
    if session.state == "idle" && !session.listening {
      return "This session is not listening for messages."
    }
    return nil
  }

  /// Loads the chat, then looks for news every few seconds while it is on
  /// screen (the phone only pushes while its app is running).
  private func poll() async {
    await load()
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(8))
      if Task.isCancelled { break }
      if scenePhase == .active { await load() }
    }
  }

  /// Fetches the newest page; lines of earlier pages stay.
  private func load() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await link.chat(pcId: pcId, sessionId: sessionId, have: sig)
      loaded = true
      error = (page.warning ?? "").isEmpty ? nil : page.warning
      if page.same == true { return }
      let newest = Self.rows(page.items ?? [], without: [])
      // Where the page starts among the lines already here.
      if let head = newest.first, let k = rows.firstIndex(where: { $0.id == head.id }), k > 0 {
        rows = Array(rows[..<k]) + newest
      } else {
        rows = newest
        more = page.more ?? false
      }
      sig = page.sig
      suggestions = page.suggestions ?? []
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func loadEarlier(_ proxy: ScrollViewProxy) async {
    guard !loading, more, let top = rows.first?.id else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await link.chat(pcId: pcId, sessionId: sessionId, before: top)
      rows = Self.rows(page.items ?? [], without: Set(rows.map(\.id))) + rows
      more = page.more ?? false
      // Stay at the line that was at the top.
      proxy.scrollTo(top, anchor: .top)
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Lines as rows; an id is shown once.
  private static func rows(_ lines: [ChatLine], without shown: Set<String>) -> [Row] {
    var seen = shown
    return lines.filter { seen.insert($0.id).inserted }.map(Row.init)
  }

  private func send(_ text: String) {
    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !sending else { return }
    sending = true
    notice = nil
    suggestions = []
    Task {
      do {
        let reply = try await link.send(pcId: pcId, sessionId: sessionId, text: message)
        switch reply.status {
        case "delivered":
          notice = "Delivered"
          WKInterfaceDevice.current().play(.success)
        case "queued":
          notice = "Queued — Claude gets it when it finishes"
          WKInterfaceDevice.current().play(.success)
        case "sending":
          notice = "Sent — no answer from the PC yet"
        default:
          notice = "Not sent: \(reply.reason.isEmpty ? "the PC refused it" : reply.reason)"
          WKInterfaceDevice.current().play(.failure)
        }
      } catch {
        notice = "Not sent: \(error.localizedDescription)"
        WKInterfaceDevice.current().play(.failure)
      }
      sending = false
      sig = nil
      await load()
    }
  }
}

/// A message bubble (yours on the right, Claude's on the left), or a tool
/// line in grey.
private struct LineView: View {
  let row: ChatView.Row

  var body: some View {
    let line = row.line
    if line.role == "tool" {
      Label(line.text, systemImage: "wrench.and.screwdriver")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    } else {
      let mine = line.role != "assistant"
      VStack(alignment: .leading, spacing: 2) {
        MessageText(blocks: row.blocks)
          .font(.footnote)
        if !line.status.isEmpty {
          Text(line.status)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      .background(
        mine ? AnyShapeStyle(.tint.opacity(0.45)) : AnyShapeStyle(.gray.opacity(0.28)),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
      .padding(mine ? .leading : .trailing, 14)
    }
  }
}

import ServiceManagement
import SwiftUI

/// The window under the menu bar item.
struct MenuView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HeaderView(model: model)
      Divider()
      if let status = model.status {
        if status.pending > 0 {
          Label(
            "\(status.pending) prompt\(status.pending == 1 ? "" : "s") waiting for an answer",
            systemImage: "exclamationmark.bubble.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
        }
        if let pairing = model.pairing {
          PairingView(model: model, pairing: pairing)
        } else {
          PhonesView(model: model)
          Divider()
          SectionTitle("Sessions")
          ScrollView {
            SessionsView(sessions: model.sessions)
          }
          .frame(maxHeight: 300)
        }
      } else {
        NotRunningView(model: model)
      }
      if let notice = model.notice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 340)
    .onAppear { model.refresh(detailed: true) }
  }
}

struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
  }
}

// MARK: - Header

struct HeaderView: View {
  @ObservedObject var model: AppModel
  @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(model.status == nil ? Color.red : Color.green)
        .frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.status?.name ?? "ccnotify").font(.headline).lineLimit(1)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Menu {
        Button("Send Test Notification") { model.sendTest() }
          .disabled(model.status == nil)
        Button("Restart Service") { model.startService(restart: true) }
        Button("Open Log") { model.openLog() }
        Divider()
        Toggle("Open at Login", isOn: $opensAtLogin)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .onChange(of: opensAtLogin) { enabled in
      do {
        if enabled {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        model.notice = "Could not change the login item: \(error.localizedDescription)"
      }
    }
  }

  private var subtitle: String {
    guard let status = model.status else { return "Service not running" }
    let address = status.hosts.first.map { "\($0):\(status.port)" } ?? "port \(status.port)"
    return "\(address) · \(status.connected) of \(status.devices) phones connected"
  }
}

struct NotRunningView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("The ccnotify service is not running, so phones get no notifications.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Start Service") { model.startService() }
          .keyboardShortcut(.defaultAction)
        Button("Open Log") { model.openLog() }
      }
    }
  }
}

// MARK: - Phones and pairing

struct PhonesView: View {
  @ObservedObject var model: AppModel
  /// Id of the phone whose removal is being confirmed.
  @State private var removing: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionTitle("Phones")
      if model.devices.isEmpty {
        Text("No phone paired yet.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(model.devices) { device in
        HStack {
          Image(systemName: "iphone")
          VStack(alignment: .leading, spacing: 0) {
            Text(device.name).font(.callout).lineLimit(1)
            Text("Paired \(relativeTime(device.paired))").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if removing == device.id {
            Button("Cancel") { removing = nil }
            Button("Remove", role: .destructive) {
              removing = nil
              model.revoke(device)
            }
          } else {
            Button {
              removing = device.id
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Unpair this phone")
          }
        }
      }
      Button {
        model.startPairing()
      } label: {
        Label("Pair a Phone…", systemImage: "qrcode")
      }
    }
  }
}

struct PairingView: View {
  @ObservedObject var model: AppModel
  let pairing: Pairing

  var body: some View {
    VStack(spacing: 8) {
      if let name = pairing.pairedWith {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
        Text("Paired with \(name)").font(.headline)
        Button("Done") { model.stopPairing() }.keyboardShortcut(.defaultAction)
      } else {
        // Re-evaluated every second for the countdown.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let left = Int(pairing.expires.timeIntervalSince(context.date))
          if left > 0, let image = pairing.image {
            Text("Scan with the ccnotify app").font(.headline)
            Image(nsImage: image)
              .interpolation(.none)
              .resizable()
              .frame(width: 230, height: 230)
              .padding(10)
              .background(Color.white)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Pair PC → scan. Expires in \(left / 60):\(String(format: "%02d", left % 60)).")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("This code has expired.").font(.headline)
          }
        }
        HStack {
          Button("Cancel") { model.stopPairing() }
          if pairing.expires > Date() {
            Button("Copy Code") { model.copyPairingCode() }
              .help("For \"Paste code instead\" in the app")
          } else {
            Button("New Code") { model.startPairing() }.keyboardShortcut(.defaultAction)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Sessions

struct SessionsView: View {
  let sessions: [ClaudeSession]
  /// Id of the session whose last reply is shown.
  @State private var expanded: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if sessions.isEmpty {
        Text("No Claude Code sessions yet. They appear after the next prompt or reply.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(sessions) { session in
        SessionRow(session: session, expanded: expanded == session.id)
          .contentShape(Rectangle())
          .onTapGesture { expanded = expanded == session.id ? nil : session.id }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionRow: View {
  let session: ClaudeSession
  let expanded: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: look.symbol).foregroundStyle(look.color).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(session.title.isEmpty ? session.project : session.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if expanded && !session.lastText.isEmpty {
          Text(session.lastText)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
      }
      Spacer(minLength: 4)
      Text(look.label)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(look.color.opacity(0.18))
        .foregroundStyle(look.color)
        .clipShape(Capsule())
    }
  }

  private var detail: String {
    var parts = [session.project, relativeTime(session.lastActive)]
    if session.listening { parts.append("phone can reply") }
    if session.queued > 0 { parts.append("\(session.queued) queued") }
    return parts.joined(separator: " · ")
  }

  /// Same names as the phone app's state chips.
  private var look: (label: String, symbol: String, color: Color) {
    switch session.state {
    case "working": return ("Working", "arrow.triangle.2.circlepath", .blue)
    case "waiting": return ("Needs you", "exclamationmark.circle.fill", .orange)
    case "ended": return ("Closed", "stop.circle", .gray)
    default: return ("Finished", "checkmark.circle.fill", .green)
    }
  }
}

/// "5 min. ago"
func relativeTime(_ date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}

import SwiftUI

/// Pairing on the TV: pick the PC found on the network (or type its
/// address), then the code shown by `mewo pair` on the PC.
struct PairView: View {
  @EnvironmentObject private var client: PcClient
  @StateObject private var discovery = Discovery()

  @State private var host = ""
  @State private var port = "47821"
  @State private var code = ""
  @State private var name = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    HStack(alignment: .top, spacing: 60) {
      VStack(alignment: .leading, spacing: 24) {
        Text("Pair with a PC")
          .font(.largeTitle.bold())
        Text("On the PC run **mewo pair** (or **ccnotify pair**). It shows a QR code and, under it, a pairing code.")
          .font(.title3)
          .foregroundStyle(.secondary)
        Text("PCs on this network")
          .font(.headline)
        if discovery.found.isEmpty {
          HStack {
            ProgressView()
            Text("Looking…").foregroundStyle(.secondary)
          }
        }
        ForEach(discovery.found) { pc in
          Button {
            host = pc.host
            port = String(pc.port)
            name = pc.name
          } label: {
            HStack {
              Image(systemName: "desktopcomputer")
              VStack(alignment: .leading) {
                Text(pc.name)
                Text("\(pc.host):\(pc.port)").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if host == pc.host { Image(systemName: "checkmark") }
            }
          }
        }
      }
      .frame(maxWidth: 700, alignment: .leading)

      VStack(alignment: .leading, spacing: 24) {
        TextField("PC address", text: $host)
        TextField("Port", text: $port)
        TextField("Pairing code (16 characters)", text: $code)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button {
          Task { await pair() }
        } label: {
          Label(busy ? "Pairing…" : "Pair", systemImage: "link")
        }
        .disabled(busy || host.isEmpty || code.count < 8)
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .frame(maxWidth: 700)
    }
    .padding(60)
    .onAppear { discovery.start() }
    .onDisappear { discovery.stop() }
  }

  private func pair() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await client.pair(
        host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 47821,
        code: code.trimmingCharacters(in: .whitespaces).lowercased(),
        name: name.isEmpty ? host : name)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

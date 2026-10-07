import SwiftUI

/// Answers one prompt: Allow / Always / Deny, Approve / Reject, or a
/// question's options.
struct RequestView: View {
  let request: CcRequest
  @EnvironmentObject private var client: PcClient

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(request.project.isEmpty ? "Claude Code" : request.project)
          .font(.largeTitle.bold())
        Text("\(request.kindLabel) · \(request.ts.ago)")
          .foregroundStyle(.secondary)
        if let title = request.title, !title.isEmpty, request.kind != "question" {
          Text(title).font(.title2)
        }
        if request.kind == "question" {
          QuestionAnswers(request: request)
        } else {
          if let detail = request.detail ?? request.summary, !detail.isEmpty {
            Text(detail)
              .font(.system(.body, design: .monospaced))
              .padding(20)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.gray.opacity(0.2))
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
          RequestButtons(request: request)
        }
      }
      .padding(60)
    }
  }
}

/// The yes / no buttons of a permission or plan prompt.
struct RequestButtons: View {
  let request: CcRequest
  @EnvironmentObject private var client: PcClient

  var body: some View {
    HStack(spacing: 20) {
      if request.kind == "plan" {
        Button { client.answer(request.id, ["action": "approve"]) } label: { Label("Approve", systemImage: "checkmark") }
        Button(role: .destructive) { client.answer(request.id, ["action": "reject"]) } label: { Label("Reject", systemImage: "xmark") }
      } else {
        Button { client.answer(request.id, ["action": "allow"]) } label: { Label("Allow", systemImage: "checkmark") }
        if request.canAllowAlways == true {
          Button { client.answer(request.id, ["action": "allow_always"]) } label: { Label("Always allow", systemImage: "checkmark.seal") }
        }
        Button(role: .destructive) { client.answer(request.id, ["action": "deny"]) } label: { Label("Deny", systemImage: "xmark") }
      }
    }
  }
}

/// The options of a question; several questions are answered together.
struct QuestionAnswers: View {
  let request: CcRequest
  @EnvironmentObject private var client: PcClient
  @State private var picked: [Int: Set<Int>] = [:]

  var body: some View {
    let questions = request.questions ?? []
    if questions.isEmpty {
      Text("This question can only be answered on the PC or the phone.").foregroundStyle(.secondary)
    } else {
      ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
        VStack(alignment: .leading, spacing: 12) {
          if let h = q.header, !h.isEmpty { Text(h).font(.caption).foregroundStyle(.tint) }
          Text(q.question).font(.title3)
          ForEach(Array((q.options ?? []).enumerated()), id: \.offset) { j, o in
            Button {
              var set = picked[i] ?? []
              if q.multiSelect == true {
                if set.contains(j) { set.remove(j) } else { set.insert(j) }
              } else {
                set = [j]
              }
              picked[i] = set
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(o.label)
                  if let d = o.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if picked[i]?.contains(j) ?? false { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
              }
            }
          }
        }
      }
      Button {
        if let answers { client.answer(request.id, ["answers": answers]) }
      } label: {
        Label("Send", systemImage: "paperplane.fill")
      }
      .disabled(answers == nil)
    }
  }

  private var answers: [String: String]? {
    var out: [String: String] = [:]
    for (i, q) in (request.questions ?? []).enumerated() {
      let labels = (picked[i] ?? []).sorted().compactMap { j in (q.options ?? [])[safe: j]?.label }
      if labels.isEmpty { return nil }
      out[q.question] = labels.joined(separator: ", ")
    }
    return out
  }
}

/// A prompt shown inside the chat it belongs to, with its buttons.
struct RequestCard: View {
  let request: CcRequest

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(request.title ?? request.kindLabel, systemImage: request.kind == "plan" ? "list.clipboard" : "lock")
        .font(.headline)
      if request.kind == "question" {
        QuestionAnswers(request: request)
      } else {
        if let s = request.summary, !s.isEmpty {
          Text(s).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
        }
        RequestButtons(request: request)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.yellow.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

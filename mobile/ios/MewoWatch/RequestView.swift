import SwiftUI
import WatchKit

/// Answers one prompt: Allow / Deny, Approve / Reject, or the options of a
/// question. "Say why" and "Other" take a spoken answer (VoiceSheet.swift).
struct RequestView: View {
  let pcId: String
  let requestId: String

  @EnvironmentObject private var link: PhoneLink
  @Environment(\.dismiss) private var dismiss

  @State private var sending = false
  @State private var sent = false
  @State private var error: String?
  /// Chosen options and the spoken answer, by question index.
  @State private var picked: [Int: Set<Int>] = [:]
  @State private var spoken: [Int: String] = [:]

  private var request: Request? {
    link.state?.requests.first { $0.pcId == pcId && $0.id == requestId }
  }

  var body: some View {
    Group {
      if sent {
        gone("Answer sent", icon: "checkmark.circle.fill")
      } else if let request {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            header(request)
            if request.kind == "question" {
              questions(request)
            } else {
              detail(request)
              buttons(request)
            }
            if let error {
              Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
            }
          }
          .scenePadding(.horizontal)
          .disabled(sending || request.answered)
        }
      } else {
        gone("Claude is no longer waiting for this", icon: "checkmark.circle")
      }
    }
    .navigationTitle(title)
  }

  private var title: String {
    switch request?.kind {
    case "question"?: return "Question"
    case "plan"?: return "Plan"
    case .some: return "Permission"
    case nil: return "Answered"
    }
  }

  private func gone(_ text: String, icon: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.largeTitle)
        .foregroundStyle(.green)
      Text(text)
        .multilineTextAlignment(.center)
    }
  }

  private func header(_ r: Request) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(r.project.isEmpty ? "Claude Code" : r.project)
        .font(.headline)
      Text([r.pcName, r.ts.ago].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.caption2)
        .foregroundStyle(.secondary)
      if !r.title.isEmpty && r.kind != "question" {
        Text(r.title)
          .font(.footnote)
          .padding(.top, 2)
      }
      if r.answered {
        Label("Answer sent, waiting for the PC", systemImage: "clock")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func detail(_ r: Request) -> some View {
    if r.kind == "plan" {
      MessageText(blocks: Block.parse(r.detail))
        .font(.footnote)
    } else if !r.detail.isEmpty {
      Text(r.detail)
        .font(.system(.caption2, design: .monospaced))
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }
  }

  @ViewBuilder
  private func buttons(_ r: Request) -> some View {
    if r.kind == "plan" {
      Button {
        submit(["action": "approve"])
      } label: {
        Label("Approve", systemImage: "checkmark")
      }
      .tint(.green)
      Button(role: .destructive) {
        submit(["action": "reject"])
      } label: {
        Label("Reject", systemImage: "xmark")
      }
      VoiceButton(prompt: "Feedback for Claude") {
        Label("Reject, say why", systemImage: "mic.fill")
      } onSubmit: { text in
        submit(["action": "reject", "message": text])
      }
    } else {
      Button {
        submit(["action": "allow"])
      } label: {
        Label("Allow", systemImage: "checkmark")
      }
      .tint(.green)
      if r.always {
        Button {
          submit(["action": "allow_always"])
        } label: {
          Label("Always allow", systemImage: "checkmark.seal")
        }
      }
      Button(role: .destructive) {
        submit(["action": "deny"])
      } label: {
        Label("Deny", systemImage: "xmark")
      }
      VoiceButton(prompt: "Reason for Claude") {
        Label("Deny, say why", systemImage: "mic.fill")
      } onSubmit: { text in
        submit(["action": "deny", "message": text])
      }
    }
  }

  // MARK: questions

  @ViewBuilder
  private func questions(_ r: Request) -> some View {
    if r.questions.isEmpty {
      Text("This question can only be answered on the PC.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    } else {
      ForEach(Array(r.questions.enumerated()), id: \.offset) { i, question in
        if i > 0 { Divider() }
        if !question.header.isEmpty {
          Text(question.header)
            .font(.caption2)
            .foregroundStyle(.tint)
        }
        Text(question.question)
          .font(.headline)
        if question.multi {
          Text("Choose all that apply")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(question.options.enumerated()), id: \.offset) { j, option in
          Button {
            pick(i, j, multi: question.multi)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                if !option.description.isEmpty {
                  Text(option.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 4)
              if picked[i]?.contains(j) ?? false {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }
          }
        }
        VoiceButton(prompt: "Your answer") {
          HStack {
            Label(spoken[i] ?? "Other… say it", systemImage: "mic.fill")
              .lineLimit(3)
            Spacer(minLength: 4)
            if spoken[i] != nil {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        } onSubmit: { text in
          let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !answer.isEmpty else { return }
          spoken[i] = answer
          if !question.multi { picked[i] = [] }
        }
      }
      let answers = self.answers(r)
      Button {
        if let answers { submit(["answers": answers]) }
      } label: {
        Label("Send", systemImage: "paperplane.fill")
      }
      .tint(.green)
      .disabled(answers == nil)
    }
  }

  private func pick(_ i: Int, _ j: Int, multi: Bool) {
    if multi {
      var chosen = picked[i] ?? []
      if chosen.contains(j) { chosen.remove(j) } else { chosen.insert(j) }
      picked[i] = chosen
    } else {
      picked[i] = [j]
      spoken[i] = nil
    }
  }

  /// `[question: answer]`, or nil while a question has no answer.
  private func answers(_ r: Request) -> [String: String]? {
    var out: [String: String] = [:]
    for (i, question) in r.questions.enumerated() {
      var labels = (picked[i] ?? []).sorted().compactMap { j in
        j < question.options.count ? question.options[j].label : nil
      }
      if let other = spoken[i] { labels.append(other) }
      guard !labels.isEmpty else { return nil }
      out[question.key] = labels.joined(separator: ", ")
    }
    return out
  }

  private func submit(_ answer: [String: Any]) {
    guard !sending else { return }
    sending = true
    error = nil
    Task {
      do {
        try await link.answer(pcId: pcId, requestId: requestId, answer: answer)
        sent = true
        WKInterfaceDevice.current().play(.success)
        try? await Task.sleep(for: .seconds(1))
        dismiss()
      } catch {
        self.error = error.localizedDescription
        WKInterfaceDevice.current().play(.failure)
      }
      sending = false
    }
  }
}

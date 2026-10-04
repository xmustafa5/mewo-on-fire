import SwiftUI

/// A message split into paragraphs and code blocks.
enum Block: Equatable {
  /// `rtl`: written right to left (Arabic, Hebrew), shown from the right.
  case prose(AttributedString, rtl: Bool)
  case code(String)

  /// Markdown as far as a watch needs it: bold / italic / `code` / links
  /// inside lines, headings in bold, bullets, and fenced code in a box.
  static func parse(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var prose: [String] = []
    var code: [String]?

    func flushProse() {
      let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)
      // One block per paragraph (lines up to an empty one).
      for paragraph in prose.split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        let text = paragraph.joined(separator: "\n")
        blocks.append(
          .prose(
            (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text),
            rtl: isRightToLeft(text)))
      }
      prose = []
    }

    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        if let lines = code {
          blocks.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          flushProse()
          code = []
        }
      } else if code != nil {
        code?.append(line)
      } else if trimmed.hasPrefix("#") {
        let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        prose.append(title.isEmpty ? line : "**\(title)**")
      } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        let indent = line.prefix { $0 == " " }
        prose.append("\(indent)• \(trimmed.dropFirst(2))")
      } else {
        prose.append(line)
      }
    }
    // A fence left open (the message was cut): still code.
    if let lines = code, !lines.isEmpty { blocks.append(.code(lines.joined(separator: "\n"))) }
    flushProse()
    return blocks
  }
}

/// Whether the first letter of `text` belongs to a right-to-left script.
private func isRightToLeft(_ text: String) -> Bool {
  for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
    switch scalar.value {
    case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
    default: return false
    }
  }
  return false
}

struct MessageText: View {
  let blocks: [Block]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let text, let rtl):
          if rtl {
            Text(text)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } else {
            Text(text)
          }
        case .code(let code):
          Text(code)
            .font(.system(.caption2, design: .monospaced))
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
        }
      }
    }
  }
}

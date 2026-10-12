import SwiftUI

/// Jednoduchý blokový markdown pro odpovědi agenta:
/// nadpisy, odstavce, odrážky, číslované seznamy, tabulky, bloky kódu a oddělovače.
enum MarkdownBlock: Hashable {
    case heading(String, level: Int)
    case paragraph(String)
    case bullet(String, indent: Int)
    case numbered(String, number: String)
    case table([[String]])
    case code(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]? = nil

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph(); flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }

            if line.hasPrefix("|") {
                flushParagraph()
                let isSeparator = line.allSatisfy { "|-: ".contains($0) }
                if !isSeparator {
                    var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    table.append(cells)
                }
                continue
            }
            flushTable()

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(title, level: level))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                let indent = rawLine.prefix { $0 == " " }.count / 2
                blocks.append(.bullet(String(line.dropFirst(2)), indent: min(indent, 3)))
                continue
            }
            if let match = line.firstMatch(of: #/^(\d{1,3})[.)]\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.numbered(String(match.2), number: String(match.1)))
                continue
            }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let title, let level):
            Text(Self.inline(title))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .paragraph(let s):
            Text(Self.inline(s))
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Text(Self.inline(s))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let s, let number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(s))
            }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell))
                                    .fontWeight(index == 0 ? .semibold : .regular)
                                    .foregroundStyle(index == 0 ? .secondary : .primary)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .font(.footnote)
                .monospacedDigit()
                .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.footnote.monospaced())
                    .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider()
        }
    }
}

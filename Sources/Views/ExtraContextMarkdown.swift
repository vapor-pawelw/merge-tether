import SwiftUI

/// Block-level Markdown for app-only agent explanations, shared by the Mac and iOS apps.
/// Only http(s) links stay active; images and HTML are never loaded.
struct ExtraContextMarkdown: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ExtraContextMarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: ExtraContextMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            inline(text)
        case .item(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            inline(text).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
        case .code(let text):
            Text(verbatim: text).font(.callout.monospaced())
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        Text(ExtraContextMarkdownBlock.inline(text)).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ExtraContextMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case item(marker: String, text: String, indent: Int)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ source: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if ["---", "***", "___"].contains(trimmed) { flush(); blocks.append(.rule); continue }
            if trimmed.hasPrefix(">") {
                flush(); blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); continue
            }
            let indent = min(3, (line.prefix { $0 == " " }.count) / 2)
            if let item = item(trimmed, indent: indent) { flush(); blocks.append(item); continue }
            paragraph.append(trimmed)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Self? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    private static func item(_ line: String, indent: Int) -> Self? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return .item(marker: "•", text: String(line.dropFirst(2)), indent: indent)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .item(marker: digits + ".", text: String(rest.dropFirst(2)), indent: indent)
    }

    static func inline(_ text: String) -> AttributedString {
        guard var rendered = try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(text) }
        let unsafeLinks = rendered.runs.filter { run in
            guard let link = run.link else { return false }
            return !["http", "https"].contains(link.scheme?.lowercased() ?? "")
        }.map(\.range)
        for range in unsafeLinks { rendered[range].link = nil }
        let images = rendered.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in images { rendered[range].imageURL = nil }
        return rendered
    }
}

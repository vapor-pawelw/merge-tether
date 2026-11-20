import Foundation
import SwiftUI

/// Formats GitLab Markdown as native text that can be displayed with a single line limit.
public enum SafeMarkdown {
    public static func render(_ source: String) -> AttributedString? {
        guard let parsed = parse(source, syntax: .full) else { return nil }
        var rendered = AttributedString()
        var previous = Block(components: [])
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let block = Block(components: intent?.components ?? [])
            if !rendered.characters.isEmpty {
                rendered.append(AttributedString(block.separator(after: previous)))
            }
            rendered.append(AttributedString(block.prefix(after: previous)))
            rendered.append(block.styledText(parsed[range]))
            previous = block
        }
        return rendered
    }

    static func parse(
        _ source: String, syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
    ) -> AttributedString? {
        guard var text = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: syntax)) else { return nil }
        let unsafeLinks = text.runs.filter { run in
            guard let link = run.link else { return false }
            return !["http", "https"].contains(link.scheme?.lowercased() ?? "")
        }.map(\.range)
        for range in unsafeLinks { text[range].link = nil }
        let images = text.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in images { text[range].imageURL = nil }
        return text
    }

    private struct Block {
        let components: [PresentationIntent.IntentType]

        var cell: (table: Int, row: Int, column: Int)? {
            guard components.count >= 3, case .tableCell(let column) = components[0].kind else { return nil }
            return (components[2].identity, components[1].identity, column)
        }

        var listItems: [PresentationIntent.IntentType] {
            components.filter {
                if case .listItem = $0.kind { return true }
                return false
            }
        }

        func separator(after previous: Self) -> String {
            if let cell, let previousCell = previous.cell {
                if cell.row == previousCell.row {
                    return String(repeating: " | ", count: cell.column - previousCell.column)
                }
                if cell.table == previousCell.table { return "\n" }
            }
            let sharesList = components.contains { component in
                switch component.kind {
                case .orderedList, .unorderedList: previous.components.contains(component)
                default: false
                }
            }
            return sharesList ? "\n" : "\n\n"
        }

        func prefix(after previous: Self) -> String {
            if let cell, cell.row != previous.cell?.row {
                return String(repeating: " | ", count: cell.column)
            }
            let quotes = components.count { $0.kind == .blockQuote }
            var prefix = String(repeating: "│ ", count: quotes)
            let items = listItems
            guard let item = items.first, case .listItem(let ordinal) = item.kind,
                  let index = components.firstIndex(of: item),
                  let list = components.dropFirst(index + 1).first else { return prefix }

            prefix += String(repeating: "  ", count: items.count - 1)
            if previous.components.contains(item) {
                return prefix + "  "
            }
            return prefix + (list.kind == .orderedList ? "\(ordinal). " : "• ")
        }

        func styledText(_ source: AttributedSubstring) -> AttributedString {
            var text = AttributedString()
            for run in source.runs {
                if run.inlinePresentationIntent?.contains(.softBreak) == true {
                    text.append(AttributedString("\n", attributes: run.attributes))
                } else {
                    text.append(AttributedString(source[run.range]))
                }
            }
            text.presentationIntent = nil

            switch components.first?.kind {
            case .header(let level):
                switch level {
                case 1: text.swiftUI.font = .title3.weight(.semibold)
                case 2: text.swiftUI.font = .headline
                default: text.swiftUI.font = .subheadline.weight(.semibold)
                }
            case .codeBlock:
                if text.characters.last?.isNewline == true { text.characters.removeLast() }
                text.swiftUI.font = .callout.monospaced()
            case .tableCell where components.dropFirst().first?.kind == .tableHeaderRow:
                text.swiftUI.font = .callout.weight(.semibold)
            default:
                break
            }
            return text
        }
    }
}

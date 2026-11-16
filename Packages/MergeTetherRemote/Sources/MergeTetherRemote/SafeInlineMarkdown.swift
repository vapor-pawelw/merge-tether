import Foundation

/// GitLab comment Markdown rendered inline: emphasis, code and web links only. Line breaks are kept,
/// non-web links are dropped and images are never loaded.
public enum SafeInlineMarkdown {
    public static func render(_ source: String) -> AttributedString? {
        guard var text = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return nil }
        let unsafeLinks = text.runs.filter { run in
            guard let link = run.link else { return false }
            return !["http", "https"].contains(link.scheme?.lowercased() ?? "")
        }.map(\.range)
        for range in unsafeLinks { text[range].link = nil }
        let imageRanges = text.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in imageRanges { text[range].imageURL = nil }
        return text
    }
}

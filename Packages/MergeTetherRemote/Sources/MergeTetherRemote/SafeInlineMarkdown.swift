import Foundation

/// GitLab comment Markdown rendered inline: emphasis, code and web links only. Line breaks are kept,
/// non-web links are dropped and images are never loaded.
public enum SafeInlineMarkdown {
    public static func render(_ source: String) -> AttributedString? {
        SafeMarkdown.parse(source, syntax: .inlineOnlyPreservingWhitespace)
    }
}

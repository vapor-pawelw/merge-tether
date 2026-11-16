import Foundation
import Testing
import MergeTetherRemote

@Suite struct SafeInlineMarkdownTests {
    @Test func commentMarkdownKeepsFormattingAndLineBreaksButDropsUnsafeLinksAndImages() throws {
        let rendered = try #require(SafeInlineMarkdown.render(
            "**Issue:**\nA `fetchPage` failure [docs](https://gitlab.example.test/a) [local](file:///etc/passwd) ![x](https://e.test/i.png)"))
        let text = String(rendered.characters)
        #expect(text.hasPrefix("Issue:\nA fetchPage failure"))
        #expect(!text.contains("**") && !text.contains("`"))
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let links = rendered.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://gitlab.example.test/a")!])
        #expect(rendered.runs.allSatisfy { $0.imageURL == nil })
    }
}

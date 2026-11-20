import Foundation
import SwiftUI
import Testing
import MergeTetherRemote

@Suite struct SafeMarkdownTests {
    @Test func rendersHeadingsParagraphsAndInlineFormatting() throws {
        let rendered = try #require(SafeMarkdown.render("""
            # Changes

            Details
            on two lines, with **emphasis** and `code`.

            Next steps
            ----------
            """))

        #expect(String(rendered.characters) == "Changes\n\nDetails\non two lines, with emphasis and code.\n\nNext steps")
        #expect(rendered.runs.first?.swiftUI.font == .title3.weight(.semibold))
        #expect(rendered.runs.last?.swiftUI.font == .headline)
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @Test func rendersListsQuotesAndLiteralCodeBlocks() throws {
        let rendered = try #require(SafeMarkdown.render("""
            3. Parent
               - Child
            4. Sibling

            > A quote

            ```sh
            # A code comment
            echo "*literal*"
            ```
            """))

        #expect(String(rendered.characters) == """
            3. Parent
              • Child
            4. Sibling

            │ A quote

            # A code comment
            echo "*literal*"
            """)
        #expect(rendered.runs.last?.swiftUI.font == .callout.monospaced())
    }

    @Test func keepsTableRowsAndCellsReadable() throws {
        let rendered = try #require(SafeMarkdown.render("""
            | Check | Result | Note |
            | --- | --- | --- |
            | Build | | Pending |
            | Tests | Pass | Done |
            """))

        #expect(String(rendered.characters) == "Check | Result | Note\nBuild |  | Pending\nTests | Pass | Done")
    }

    @Test func keepsWebLinksAndImageAltTextInFormattedBlocks() throws {
        let rendered = try #require(SafeMarkdown.render("""
            # [Docs](https://example.test/docs)

            > [Local](file:///private/local) ![Screenshot](https://example.test/image.png)
            """))

        #expect(String(rendered.characters) == "Docs\n\n│ Local Screenshot")
        #expect(rendered.runs.compactMap(\.link) == [URL(string: "https://example.test/docs")!])
        #expect(rendered.runs.allSatisfy { $0.imageURL == nil })
    }
}

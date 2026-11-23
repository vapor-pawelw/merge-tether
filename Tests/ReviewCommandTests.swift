import Foundation
import Testing
@testable import MergeTether

struct ReviewCommandTests {
    @Test func acceptsOnlyDocumentedReadOperations() throws {
        #expect(try ReviewCommand(arguments: ["context"]) == .context)
        #expect(try ReviewCommand(arguments: ["discussions"]) == .discussions)
        #expect(try ReviewCommand(arguments: ["work-item", "show", "team/service#17"]) == .workItem(project: "team/service", number: 17))
        #expect(try ReviewCommand(arguments: ["change", "show", "21"]) == .change(project: nil, number: 21))
        #expect(try ReviewCommand(arguments: ["file", "show", "Sources/Account.swift"]) == .file("Sources/Account.swift"))
        for arguments in [["merge"], ["api", "/user"], ["file", "show", "../outside"], ["work-item", "show", "https://other.test/team/a#1"], ["work-item", "show", "0"], ["diff", "--host", "other.test"]] {
            #expect(throws: ReviewCommand.Error.invalidArguments) { try ReviewCommand(arguments: arguments) }
        }
    }
}

extension ReviewCommandTests {
    @Test func renamedFileUsesTheNewSideOfTheDiff() {
        let diff = GitLabReviewDiff(oldPath: "old.swift", newPath: "new.swift", diff: "@@ -4,3 +4,4 @@\n context\n-old\n+replacement\n+addition\n end\n")
        #expect(diff.containsNewLine(5))
        #expect(diff.containsNewLine(6))
        #expect(!diff.containsNewLine(8))
    }

    @MainActor @Test func launchArgumentsKeepBuiltinExecutionOutOfTheReview() throws {
        let tool = URL(fileURLWithPath: "/example/MergeTether")
        let codex = try ReadOnlyReviewJob.arguments(for: .codex, model: nil, helper: tool, schema: tool, result: tool, thinking: nil)
        let claude = try ReadOnlyReviewJob.arguments(for: .claude, model: nil, helper: tool, schema: tool, result: tool, thinking: nil)
        #expect(codex.contains("read-only") && codex.contains("shell_tool") && codex.contains("approval_policy=\"never\""))
        #expect(codex.contains(#"mcp_servers.mergetether.command="/example/MergeTether""#))
        #expect(!codex.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(claude.contains("--restricted") && claude.contains("dontAsk") && claude.contains("mcp__mergetether__mergetether"))
        let index = try #require(claude.firstIndex(of: "--tools"))
        #expect(claude[index + 1].isEmpty)
        #expect(!claude.contains("--dangerously-skip-permissions"))
    }
}

import Foundation
import Testing
@testable import GitLabTodos

@Suite("Headless re-review verification")
struct ReReviewVerifierTests {
    @Test(arguments: AutomationAssistant.allCases)
    func readsStructuredResultAndRedactsEvidenceBeforeSendingIt(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        let result = #"{"notes":[{"noteID":10,"state":"addressed","reason":"The diff contains the correction"}]}"#
        try Data("""
            #!/bin/sh
            set -eu
            /bin/cat > "\(script.path).input"
            if [ "$1" = exec ]; then
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = -o ]; then shift; output="$1"; fi
                    shift
                done
                /usr/bin/printf '%s' '\(result)' > "$output"
            else
                /usr/bin/printf '%s' '{"is_error":false,"structured_output":\(result)}'
            fi
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"notes":[{"id":10,"author":{"id":7},"system":false,"body":"token=glpat-synthetic123456789"},{"id":11,"author":{"id":3},"system":false,"body":"Fixed"}]}]"#.utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40), title: "Example", diff: "Example diff", discussions: discussions)

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture-model", executable: script)

        #expect(try assessment.reviewers(in: discussions, authorID: 3) == [7: 10])
        let sent = try String(contentsOf: URL(fileURLWithPath: script.path + ".input"), encoding: .utf8)
        #expect(!sent.contains("glpat-synthetic123456789"))
        let start = try #require(sent.firstIndex(of: "{"))
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(sent[start...].utf8)) }
    }

    @Test func processRunnerPassesCompleteInputWithoutWaitingForAnInteractivePrompt() async throws {
        let bytes = Data(String(repeating: "Example input\n", count: 40_000).utf8)
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), environment: [:], timeout: 3, input: bytes)
        #expect(output.exitCode == 0 && output.stdout == bytes)
    }
}

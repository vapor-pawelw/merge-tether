import Foundation
import Testing
@testable import GitLabTodos

@Suite("Headless re-review verification")
struct ReReviewVerifierTests {
    @Test(arguments: AutomationAssistant.allCases)
    func constrainedProviderCannotSilentlyOmitAResolvedComment(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            sys.stdin.read()
            codex=args[0]=='exec'
            schema=json.load(open(args[args.index('--output-schema')+1])) if codex else json.loads(args[args.index('--json-schema')+1])
            notes=schema['properties']['notes']
            required=list(range(100,111))
            exact=notes.get('minItems')==11 and notes.get('maxItems')==11 and notes['items']['properties']['noteID'].get('enum')==required
            result={'notes':[{'noteID':n,'state':'addressed','reason':'Verified current correction','acceptanceNoteID':None} for n in (required if exact else required[1:])]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let notes = (100...110).map { id in
            "{\"id\":\(id),\"author\":{\"id\":7},\"system\":false,\"resolvable\":true,\"resolved\":\(id == 100),\"body\":\"Concern \(id)\"}"
        }.joined(separator: ",")
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data("[{\"notes\":[\(notes)]}]".utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic review", diff: "Verified corrections", discussions: discussions)
        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
        #expect(Set(assessment.notes.map(\.noteID)) == Set(100...110))
        #expect(try assessment.reviewers(in: discussions, authorID: 3) == [7: 110])
    }
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

    @Test(arguments: AutomationAssistant.allCases)
    func incompleteProviderResultGetsOneRetryWithCompleteCoverage(_ assistant: AutomationAssistant) async throws {
        try await withRetryFixture(alwaysIncomplete: false) { script, input, counter in
            let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
            let reviewers = try assessment.reviewers(in: input.discussions, authorID: input.authorID)
            let count = try String(contentsOf: counter, encoding: .utf8)
            #expect(Set(assessment.notes.map(\.noteID)) == [10, 20])
            #expect(reviewers == [7: 20])
            #expect(count == "2")
        }
    }

    @Test(arguments: AutomationAssistant.allCases)
    func consistentlyIncompleteProviderStopsAfterTwoAttempts(_ assistant: AutomationAssistant) async throws {
        try await withRetryFixture(alwaysIncomplete: true) { script, input, counter in
            await #expect(throws: ReReviewAssessment.ValidationError.self) {
                _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
            }
            let count = try String(contentsOf: counter, encoding: .utf8)
            #expect(count == "2")
        }
    }

    private func withRetryFixture(alwaysIncomplete: Bool,
                                  _ body: (URL, ReReviewVerifier.Input, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        let counter = folder.appending(path: "cli.count")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            sys.stdin.read()
            counter=pathlib.Path(__file__).with_suffix('.count')
            count=int(counter.read_text())+1 if counter.exists() else 1
            counter.write_text(str(count))
            ids=[10] if count==1 or \(alwaysIncomplete ? "True" : "False") else [10,20]
            result={'notes':[{'noteID':n,'state':'addressed','reason':'Verified correction','acceptanceNoteID':None} for n in ids]}
            if args[0]=='exec':
                with open(args[args.index('-o')+1],'w') as output: json.dump(result,output)
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
            [{"id":"review","notes":[
              {"id":10,"author":{"id":7},"system":false,"body":"First correction"},
              {"id":20,"author":{"id":7},"system":false,"body":"Second correction"},
              {"id":21,"author":{"id":3},"system":false,"body":"Both verified"}]}]
            """.utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic retry verification", diff: "Both corrections implemented", discussions: discussions)
        try await body(script, input, counter)
    }

    @Test func processRunnerPassesCompleteInputWithoutWaitingForAnInteractivePrompt() async throws {
        let bytes = Data(String(repeating: "Example input\n", count: 40_000).utf8)
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), environment: [:], timeout: 3, input: bytes)
        #expect(output.exitCode == 0 && output.stdout == bytes)
    }
}

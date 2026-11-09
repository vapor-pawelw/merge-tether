import Foundation
import Testing
@testable import GitLabTodos

@Suite("Headless re-review verification")
struct ReReviewVerifierTests {
    @Test(arguments: AutomationAssistant.allCases, ["exact", "missingIDs", "wrongID", "restored", "editedSource"])
    func ignoredConcernVerdictsRemainBoundToCurrentSourceAndActiveDecision(_ assistant: AutomationAssistant, _ scenario: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let script = folder.appending(path: "cli")
        let returnedIDs = scenario == "missingIDs" ? "None" : "['\(scenario == "wrongID" ? UUID().uuidString : id.uuidString)']"
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            evidence=json.loads(incoming[incoming.index('{'):])
            pathlib.Path(__file__+'.capture').write_text(json.dumps(evidence))
            result={'notes':[{'noteID':10,'state':'ignoredByUser','reason':'No other author obligation remains after the exact user decision.','ignoredDecisionIDs':\(returnedIDs),'acceptanceNoteID':None}]}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let body = "Confirm the optional release assumption. Other corrections must still be checked."
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,"body":"\#(scenario == "editedSource" ? "A newly edited obligation" : body)"}]}]"#.utf8))
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let decision = IgnoredFeedbackSuggestion(id: id, target: target, sourceNoteID: 10, sourceAuthorID: 7,
            sourceBody: body, sourceRevision: UserAttentionSnapshot.digest("7\n" + body),
            concernSummary: "Decline only the optional release assumption.", concernReason: "No other obligation is waived.", createdAt: Date())
        var input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40), title: "Synthetic precise concern",
            diff: "The current correction is present.", discussions: discussions,
            target: .init(host: target.host, projectID: 1, iid: 2,
                url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!, expectedUsername: "me"))
        input.ignoredSuggestions = scenario == "restored" ? [] : [decision]
        if scenario == "exact" {
            let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
            #expect(assessment.notes.first?.state == .ignoredByUser)
            #expect(assessment.notes.first?.ignoredDecisionIDs == [id])
            let captured = try String(contentsOf: URL(fileURLWithPath: script.path + ".capture"), encoding: .utf8)
            #expect(captured.contains(id.uuidString) && captured.contains(decision.concernReason))
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
            }
        }
    }

    @Test(arguments: AutomationAssistant.allCases, [false, true])
    func completedBlockedRunProofMustNameAnExactSuppliedAttempt(_ assistant: AutomationAssistant, wrongRun: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runID = UUID()
        let returnedID = wrongRun ? UUID() : runID
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            evidence=json.loads(incoming[incoming.index('{'):])
            pathlib.Path(__file__+'.capture').write_text(json.dumps(evidence))
            result={'notes':[{'noteID':10,'state':'addressed','reason':'The current correction and published reply satisfy the assigned feedback.','acceptanceNoteID':None}],'completedBlockedRunIDs':['\(returnedID.uuidString)']}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7},"system":false,"body":"Correct the error behavior; confirm release readiness before deployment."},{"id":11,"author":{"id":3},"system":false,"body":"The correction is verified and release readiness is documented as a later prerequisite."}]}]"#.utf8))
        var input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40), title: "Synthetic correction",
            diff: "Current verified source", discussions: discussions,
            target: .init(host: "gitlab.example.test", projectID: 1, iid: 2,
                url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!, expectedUsername: "me"))
        input.blockedFollowUps = [.init(runID: runID, selectedFeedbackIDs: [10],
            blocker: "External release confirmation is absent. token=glpat-syntheticblocked12345",
            summary: "The selected correction and published reply are complete.")]
        if wrongRun {
            await #expect(throws: ReReviewVerifier.VerificationError.incompleteEvidence) {
                _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
            }
        } else {
            let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
            #expect(assessment.completedBlockedRunIDs == [runID])
            let captured = try String(contentsOf: URL(fileURLWithPath: script.path + ".capture"), encoding: .utf8)
            #expect(captured.contains(runID.uuidString))
            #expect(!captured.contains("glpat-syntheticblocked12345"))
        }
    }

    @Test(arguments: AutomationAssistant.allCases)
    func externalSignoffInstructionsSeparateLaterDeploymentFromExplicitMergeConditions(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            codex=args[0]=='exec'
            instructions=incoming[:incoming.index('{')] if codex else args[args.index('-p')+1]
            pathlib.Path(__file__+'.capture').write_text(instructions)
            result={'notes':[{'noteID':n,'state':state,'reason':'Synthetic prompt-contract result','acceptanceNoteID':None} for n,state in [(10,'addressed'),(20,'blocking')]]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"later-release","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The corrected failure behavior is intentional. It is worth confirming the dependency with the release owner before deployment.","resolvable":true,"resolved":false},{"id":11,"author":{"id":3},"system":false,"body":"The verified correction returns the documented error and the deployment dependency is documented."}]},{"id":"merge-condition","notes":[{"id":20,"author":{"id":8,"username":"bob"},"system":false,"body":"Before merging, record the owner's required compatibility decision; the intended behavior is still undecided.","resolvable":true,"resolved":false}]}]"#.utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic consumer correction", description: "Deployment configuration is a later task.",
            diff: "The current correction preserves the documented error behavior.", discussions: discussions)

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })

        let instructions = try String(contentsOf: URL(fileURLWithPath: script.path + ".capture"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(instructions.contains("An external rollout, deployment or organizational signoff is not remaining author work solely because third-party confirmation is absent"))
        #expect(instructions.contains("Distinguish an explicit requirement before merge from a suggestion or a prerequisite before deployment"))
        #expect(instructions.contains("classify it addressed when no explicit in-MR action remains"))
        #expect(instructions.contains("Do not invent approval, erase a real defect, or waive an explicit before-merge condition"))
        let findings = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
            authorID: 3, approvedReviewerIDs: [])
        #expect(findings.first(where: { $0.id == 10 })?.state == .waitingAcceptance)
        #expect(findings.first(where: { $0.id == 20 })?.state == .needsChanges)
        #expect(assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: 3).isEmpty)
    }

    @Test func verifierOutputSeparatesAHumanExplanationFromTechnicalEvidence() throws {
        let data = Data(#"{"notes":[{"noteID":10,"state":"uncertain","reason":"Current account and commit match; missing independent regression evidence.","summary":"The reported fix could not be confirmed. Check the response before publishing."}]}"#.utf8)
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any])
        let note = try #require((encoded["notes"] as? [[String: Any]])?.first)
        #expect(note["summary"] as? String == "The reported fix could not be confirmed. Check the response before publishing.")
        #expect((note["reason"] as? String)?.contains("independent regression evidence") == true)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func explicitInformationalAcknowledgementProofSurvivesVerifierSanitization(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            sys.stdin.read()
            result={'notes':[{'noteID':10,'state':'informational','reason':'Pure positive acknowledgement with no outstanding request','summary':'The reviewer has no remaining requests.','acceptanceNoteID':None,'informationalAcknowledgementSafe':True,'informationalPurpose':'concreteCodeReviewFeedback'}]}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7},"system":false,"body":"This fixes my earlier concern."},{"id":11,"author":{"id":3},"system":false,"body":"Thanks."}]}]"#.utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic MR", description: nil, diff: "Current diff", discussions: discussions)

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })

        #expect(assessment.notes.first?.informationalAcknowledgementSafe == true)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any])
        let note = try #require((encoded["notes"] as? [[String: Any]])?.first)
        #expect(note["informationalPurpose"] as? String == "concreteCodeReviewFeedback")
        #expect(assessment.notes.first?.summary == "The reviewer has no remaining requests.")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(ReReviewVerifier.schema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let notes = try #require(properties["notes"] as? [String: Any])
        let fields = try #require(notes["items"] as? [String: Any])
        #expect((fields["required"] as? [String])?.contains("informationalAcknowledgementSafe") == true)
        #expect((fields["required"] as? [String])?.contains("informationalPurpose") == true)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func summaryAssessmentInstructionsUseRelatedThreadEvidenceWithoutDiscardingDistinctRequests(_ assistant: AutomationAssistant) async throws {
        // given
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            codex=args[0]=='exec'
            instructions=incoming[:incoming.index('{')] if codex else args[args.index('-p')+1]
            evidence=json.loads(incoming[incoming.index('{'):])
            pathlib.Path(__file__+'.capture').write_text(json.dumps({'instructions':instructions,'evidence':evidence}))
            result={'notes':[{'noteID':n,'state':state,'reason':'Synthetic result for prompt contract verification','acceptanceNoteID':None} for n,state in [(10,'informational'),(20,'addressed'),(30,'blocking')]]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
            [{"id":"summary","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":false,
              "body":"I left a question about the supported release in the inline review."}]},
             {"id":"release-finding","notes":[{"id":20,"author":{"id":7},"system":false,"resolvable":true,"resolved":true,
              "body":"Please confirm the supported release."},{"id":21,"author":{"id":3},"system":false,
              "body":"The published release tag contains the endpoint; the rollout section matches it."}]},
             {"id":"mixed-summary","notes":[{"id":30,"author":{"id":7},"system":false,"resolvable":false,
              "body":"The release question is fixed. Also document the rollback procedure before merging."}]}]
            """.utf8))
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic release requirement", description: "Rollout uses the supported release", diff: "Current diff", discussions: discussions)

        // when
        _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })

        // then
        let captured = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: script.path + ".capture"))) as? [String: Any])
        let instructions = try #require(captured["instructions"] as? String)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(instructions.contains("Correlate review summaries with the concrete findings they reference across ALL discussions"))
        #expect(instructions.contains("do not require a duplicate answer in the summary's own thread"))
        #expect(instructions.contains("A summary's distinct request, changed expectation or remaining condition stays blocking or uncertain"))
        #expect(instructions.contains("Identify the matching finding and evidence in reason"))
        #expect(instructions.contains("Referenced findings awaiting reviewer acceptance make informationalAcknowledgementSafe false"))
        let evidence = try #require(captured["evidence"] as? [String: Any])
        let sent = try JSONSerialization.data(withJSONObject: try #require(evidence["discussions"]))
        let received = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: sent)
        #expect(received.flatMap(\.notes).compactMap(\.id) == [10, 20, 21, 30])
    }

    @Test(arguments: AutomationAssistant.allCases, VerificationThinking.allCases)
    func verifierCanReadTheTargetWithFullCLIToolsWhileItsRoleStaysReadOnly(_ assistant: AutomationAssistant, _ thinking: VerificationThinking) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            codex=args[0]=='exec'
            instructions=incoming[:incoming.index('{')] if codex else args[args.index('-p')+1]
            evidence=json.loads(incoming[incoming.index('{'):])
            if codex:
                full='--dangerously-bypass-approvals-and-sandbox' in args and '--sandbox' not in args
                full=full and not any(args[i:i+2]==['--disable','shell_tool'] for i in range(len(args)-1))
            else:
                full='--dangerously-skip-permissions' in args and '--safe-mode' not in args
                full=full and args[args.index('--permission-prompts')+1]=='none' and args[args.index('--tools')+1]=='default'
                full=full and json.loads(args[args.index('--settings')+1])['sandbox']['enabled']==False
            text=instructions.lower()
            role='read-only verifier' in text and 'glab api' in text and 'do not publish' in text
            role=role and 'do not call tools' not in text and 'live evidence differs' in text and 'uncertain' in text
            target=evidence.get('target',{})
            bound=target.get('host')=='gitlab.example.test' and target.get('projectID')==1 and target.get('iid')==2
            bound=bound and target.get('expectedUsername')=='me' and evidence.get('semanticContextFingerprint')=='expected-context'
            pathlib.Path(__file__+'.capture').write_text(json.dumps({'args':args,'instructions':instructions,'evidence':evidence}))
            result={'notes':[{'noteID':10,'state':'addressed' if full and role and bound else 'uncertain','reason':'Live read available' if full and role and bound else 'Live MR read unavailable','acceptanceNoteID':None}]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7},"system":false,"body":"Please document the fallback"}]}]"#.utf8))
        var input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Synthetic MR", description: "Fallback is documented", diff: "No code changes", discussions: discussions,
            target: .init(host: "gitlab.example.test", projectID: 1, iid: 2,
                url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!, expectedUsername: "me"),
            semanticContextFingerprint: "expected-context")
        #expect(input.thinking == .high)
        input.thinking = thinking

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })

        #expect(assessment.notes.first?.state == .addressed)
        let captured = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: script.path + ".capture"))) as? [String: Any])
        let arguments = try #require(captured["args"] as? [String])
        if assistant == .codex {
            #expect(arguments.contains("model_reasoning_effort=\"\(thinking.rawValue)\""))
        } else {
            let effortIndex = try #require(arguments.firstIndex(of: "--effort"))
            #expect(arguments[effortIndex + 1] == thinking.rawValue)
        }
        let instructions = try #require(captured["instructions"] as? String)
        #expect(instructions.contains("Do not perform a fresh general code review or introduce new findings"))
        let normalized = instructions.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(normalized.contains("A supported explanation disputing a proposed remedy can be addressed without proving an undocumented business meaning"))
        #expect(normalized.contains("Check the separately alleged defect and any remaining author obligation before reaching that verdict"))
        #expect(normalized.contains("Distinguish work still owed by the author from evidence or acceptance requested from the reviewer"))
        #expect(normalized.contains("Name the exact missing fact and why accessible evidence cannot establish it"))
        #expect(!normalized.contains("then the useful next step for the user"))
        let evidence = try #require(captured["evidence"] as? [String: Any])
        let target = try #require(evidence["target"] as? [String: Any])
        #expect(target["url"] as? String == input.target?.url.absoluteString)
        #expect(evidence["headSHA"] as? String == input.headSHA)
        #expect(evidence["thinking"] as? String == thinking.rawValue)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func oversizedInlineEvidenceUsesTheMRTargetInsteadOfCreatingAFalseBlocker(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            evidence=json.loads(incoming[incoming.index('{'):])
            pathlib.Path(__file__+'.capture').write_text(json.dumps(evidence))
            result={'notes':[{'noteID':10,'state':'addressed','reason':'Verified description through the live MR target','acceptanceNoteID':None}]}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7},"system":false,"body":"Check the description"}]}]"#.utf8))
        var input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40),
            title: "Large MR", description: String(repeating: "Documented requirements\n", count: 12_000),
            diff: "Current diff", discussions: discussions)
        await #expect(throws: ReReviewVerifier.VerificationError.incompleteEvidence) {
            _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
        }
        input.target = .init(host: "gitlab.example.test", projectID: 1, iid: 2,
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!, expectedUsername: "me")
        input.semanticContextFingerprint = "expected-context"
        input.thinking = .low

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })

        #expect(assessment.notes.first?.state == .addressed)
        let sent = try Data(contentsOf: URL(fileURLWithPath: script.path + ".capture"))
        #expect(sent.count <= 180_000)
        let evidence = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(evidence["target"] != nil)
        #expect(evidence["headSHA"] as? String == input.headSHA)
        #expect(evidence["semanticContextFingerprint"] as? String == "expected-context")
        #expect(evidence["thinking"] as? String == "low")
    }

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
        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
        #expect(Set(assessment.notes.map(\.noteID)) == Set(100...110))
        #expect(try assessment.reviewers(in: discussions, authorID: 3) == [7: 110])
    }
    @Test(arguments: AutomationAssistant.allCases)
    func readsStructuredResultAndRedactsEvidenceBeforeSendingIt(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "cli")
        let result = #"{"notes":[{"noteID":10,"state":"addressed","reason":"The diff contains the correction; token=glpat-output123456789"}]}"#
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
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40), title: "Example",
            description: "Fallback documented here. token=glpat-description123456789", diff: "Example diff", discussions: discussions)

        let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture-model", executable: script, retryWait: { _ in })

        #expect(try assessment.reviewers(in: discussions, authorID: 3) == [7: 10])
        #expect(!assessment.notes[0].reason.contains("glpat-output123456789"))
        #expect(assessment.notes[0].reason.contains("The diff contains the correction"))
        let sent = try String(contentsOf: URL(fileURLWithPath: script.path + ".input"), encoding: .utf8)
        #expect(!sent.contains("glpat-synthetic123456789"))
        #expect(!sent.contains("glpat-description123456789"))
        #expect(sent.contains("Fallback documented here."))
        let start = try #require(sent.firstIndex(of: "{"))
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: Data(sent[start...].utf8)) }
    }

    @Test(arguments: AutomationAssistant.allCases)
    func incompleteProviderResultGetsOneRetryWithCompleteCoverage(_ assistant: AutomationAssistant) async throws {
        try await withRetryFixture(alwaysIncomplete: false) { script, input, counter in
            let delays = RetryDelays()
            let assessment = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script,
                                                           retryWait: { await delays.record($0) })
            let reviewers = try assessment.reviewers(in: input.discussions, authorID: input.authorID)
            let count = try String(contentsOf: counter, encoding: .utf8)
            #expect(Set(assessment.notes.map(\.noteID)) == [10, 20])
            #expect(reviewers == [7: 20])
            #expect(count == "2")
            #expect(await delays.values == [.seconds(1)])
        }
    }

    @Test(arguments: AutomationAssistant.allCases)
    func cancellationDuringRetryWaitPreventsAnotherProviderInvocation(_ assistant: AutomationAssistant) async throws {
        try await withRetryFixture(alwaysIncomplete: false) { script, input, counter in
            await #expect(throws: CancellationError.self) {
                _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script,
                                                   retryWait: { _ in throw CancellationError() })
            }
            let count = try String(contentsOf: counter, encoding: .utf8)
            #expect(count == "1")
        }
    }

    private actor RetryDelays {
        var values: [Duration] = []
        func record(_ delay: Duration) { values.append(delay) }
    }

    @Test(arguments: AutomationAssistant.allCases)
    func consistentlyIncompleteProviderStopsAfterTwoAttempts(_ assistant: AutomationAssistant) async throws {
        try await withRetryFixture(alwaysIncomplete: true) { script, input, counter in
            await #expect(throws: ReReviewAssessment.ValidationError.self) {
                _ = try await ReReviewVerifier.run(input, assistant: assistant, model: "fixture", executable: script, retryWait: { _ in })
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

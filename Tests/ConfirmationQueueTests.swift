import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct ConfirmationQueueTests {
    private let host = "gitlab.example.org"
    private let head = "0123456789012345678901234567890123456789"

    @MainActor
    private struct Harness {
        let folder: URL
        let defaults: UserDefaults
        let suite: String
        let settings: SettingsManager
        let monitor: MergeRequestAttentionMonitor

        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }

        func recordVerdict(_ verdict: String, head: String) throws {
            let folder = self.folder.appending(path: "verdicts/gitlab.example.org")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(contentsOf: self.folder.appending(path: "discussions.json")))
            let value = ReviewVerdict(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2, headSHA: head,
                                      verdict: try #require(ReviewVerdict.Kind(rawValue: verdict)),
                                      discussionFingerprint: ReviewVerdict.fingerprint(discussions))
            try JSONEncoder().encode(value).write(to: folder.appending(path: "1-2.json"))
        }

        func assess(noteID: Int, body: String) throws {
            let directory = folder.appending(path: "ai-assessments/gitlab.example.org")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = AICommentAssessment(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2,
                noteID: noteID, bodySHA256: AICommentAssessmentStore.digest(body), confidence: "very_high", evidence: "Verified AI provenance")
            try JSONEncoder().encode(record).write(to: directory.appending(path: "1-2-\(noteID).json"))
        }

        func verifyFollowUpDrafts() throws {
            let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
            let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
            let run = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Follow up", prompt: "", createdAt: Date(), allowsPush: false,
                                                       followUpPushAllowed: true)
            settings.assistantHandoffs.append(run)
            let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "drafts.json"))) as? [[String: Any]])
            let drafts = raw.filter { $0["author_id"] as? Int == 3 }.map {
                FollowUpVerification.DraftEvidence(id: $0["id"] as! Int, bodySHA256: AICommentAssessmentStore.digest($0["note"] as! String))
            }
            let receipt = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: run.id,
                host: work.host, projectID: 1, iid: 2, username: "me", userID: 3,
                headSHA: "0123456789012345678901234567890123456789", sourceProjectID: 1, sourceBranch: "fix",
                files: [.init(path: "Sources/A.swift", sha256: AICommentAssessmentStore.digest("fixed code\n"))], drafts: drafts)
            let url = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipt).write(to: url)
            try bindFollowUpDiscussions()
        }

        func log(_ name: String) -> String {
            (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? ""
        }

        func bindFollowUpDiscussions() throws {
            let url = folder.appending(path: "follow-up-verifications/gitlab.example.org/1-2-me.json")
            var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: Data(contentsOf: folder.appending(path: "discussions.json")))
            receipt["discussionFingerprint"] = ReviewVerdict.fingerprint(discussions)
            try JSONSerialization.data(withJSONObject: receipt).write(to: url)
        }

        func poll() async throws {
            monitor.refresh(host: "gitlab.example.org", username: "me", todos: [])
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading || monitor.isVerifyingReReview, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isLoading && !monitor.hasError)
        }

        func settleVerification() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isVerifyingReReview, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isVerifyingReReview)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// A GitLab stub where "me" (id 3) reviews MR !2, authored by someone else (id 9).
    private func makeHarness(assistantWorked: Bool, authored: Bool = false) throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let suite = "ConfirmationQueueTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var request = """
            {"id":2,"project_id":1,"iid":2,"author":{"id":9,"username":"alice","name":"Alice"},
             "title":"Fix","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2",
             "state":"opened","draft":false,"sha":"\(head)",
             "source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main",
             "detailed_merge_status":"mergeable","has_conflicts":false,
             "labels":[],"user":{"can_merge":true},"blocking_discussions_resolved":true}
            """
        if authored { request = request.replacingOccurrences(of: "\"id\":9,\"username\":\"alice\",\"name\":\"Alice\"", with: "\"id\":3,\"username\":\"me\",\"name\":\"Me\"") }
        try Data((authored ? "[\(request)]" : "[]").utf8).write(to: folder.appending(path: "authored.json"))
        try Data((authored ? "[]" : "[\(request)]").utf8).write(to: folder.appending(path: "reviewing.json"))
        try Data(request.utf8).write(to: folder.appending(path: "request.json"))
        try Data("[]".utf8).write(to: folder.appending(path: "drafts.json"))
        try Data(#"[{"user":{"id":3},"state":"reviewed"}]"#.utf8).write(to: folder.appending(path: "reviewers.json"))
        try Data("[]".utf8).write(to: folder.appending(path: "discussions.json"))
        try Data(#"{"id":8,"username":"GitLabDuo","bot":true}"#.utf8).write(to: folder.appending(path: "duo.json"))
        try Data("fixed code\n".utf8).write(to: folder.appending(path: "remote-file-content.txt"))
        try Data(head.utf8).write(to: folder.appending(path: "remote-head.txt"))
        try Data(#"{"id":3,"username":"me"}"#.utf8).write(to: folder.appending(path: "live-user.json"))
        let executable = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            case "$2" in
                /user) cat live-user.json ;;
                /merge_requests?scope=created_by_me*) cat authored.json ;;
                /merge_requests?scope=all*) cat reviewing.json ;;
                */draft_notes/bulk_publish)
                    echo published >> publish.log; echo '[]' > drafts.json
                    if [ -f published-discussions.json ]; then cp published-discussions.json discussions.json; fi ;;
                graphql)
                    echo requested >> re-review.log
                    echo '{"data":{"mergeRequestReviewerRereview":{"mergeRequest":{"iid":"2"},"errors":[]}}}' ;;
                */draft_notes/*/publish)
                    if [ -f fail-publish ]; then exit 1; fi
                    echo "$*" >> selected.log
                    draft="${2%/publish}"
                    draft="${draft##*/}"
                    /usr/bin/python3 -c 'import json,sys; p="drafts.json"; a=json.load(open(p)); json.dump([d for d in a if d["id"]!=int(sys.argv[1])],open(p,"w"))' "$draft"
                    if [ -f inject-unseen-draft ]; then
                        /usr/bin/python3 -c 'import json; p="drafts.json"; a=json.load(open(p)); a=[d for d in a if d["id"]!=99]; a.append(dict(id=99,author_id=3,note="/merge")); json.dump(a,open(p,"w"))'
                    fi
                    if [ -f published-discussions.json ]; then cp published-discussions.json discussions.json; fi
                    if [ -f fail-read-after-publish ]; then touch fail-next-draft-read; fi
                    echo '{}' ;;
                /users/8)
                    if [ -f slow-user-check ]; then echo entered >> user-check.log; sleep 0.5; fi
                    cat duo.json ;;
                */draft_notes*)
                    if [ -f fail-next-draft-read ]; then rm fail-next-draft-read; exit 1; fi
                    cat drafts.json ;;
                */raw_diffs) echo "verified diff fixture" ;;
                */reviewers*) cat reviewers.json ;;
                */discussions*)
                    if [ -f fail-discussion-read ]; then exit 1; fi
                    if [ -f edit-on-this-discussion ]; then
                        rm edit-on-this-discussion
                        /usr/bin/python3 -c 'import json; p="drafts.json"; a=json.load(open(p)); [d.update(note="/merge") for d in a if d["id"]==11]; json.dump(a,open(p,"w"))'
                    fi
                    if [ -f edit-after-next-discussion ]; then mv edit-after-next-discussion edit-on-this-discussion; fi
                    if [ -f capture-one-discussion ]; then
                        rm capture-one-discussion
                        cp discussions.json captured-discussions.json
                        touch discussion-captured
                        while [ ! -f release-discussion ]; do sleep 0.02; done
                        cat captured-discussions.json
                        exit 0
                    fi
                    if [ -f change-during-discussions ]; then
                        /usr/bin/python3 -c 'import json; p="drafts.json"; a=json.load(open(p)); [d.update(note="Edited while checking") for d in a if d["id"]==12]; json.dump(a,open(p,"w"))'
                    fi
                    cat discussions.json ;;
                */approve)
                    echo "$*" >> approve.log
                    echo '{"approved_by":[{"user":{"id":3}}]}' ;;
                /projects/1/repository/branches/fix) printf '{"commit":{"id":"'; cat remote-head.txt; printf '"}}' ;;
                /projects/1/repository/files/Sources%2FA.swift?ref=*)
                    if [ -f edit-during-proof ]; then
                        /usr/bin/python3 -c 'import json; p="drafts.json"; a=json.load(open(p)); [d.update(note="New unsupported local fix") for d in a if d["id"]==12]; json.dump(a,open(p,"w"))'
                    fi
                    /usr/bin/python3 -c 'import json,base64; print(json.dumps(dict(file_path="Sources/A.swift",encoding="base64",content=base64.b64encode(open("remote-file-content.txt","rb").read()).decode())))' ;;
                /projects/1/merge_requests/2) cat request.json ;;
                *) exit 100 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let settings = SettingsManager(defaults: defaults)
        // These tests isolate publication/re-review from the independent acceptance workflow.
        settings.automation.autoResolveAcceptedFeedback = false
        if assistantWorked {
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
            let key = AssistantAutomationRunner.ChatKey(
                assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead
            )
            settings.assistantChats[key] = "thread"
        }
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = host
        glab.currentUsername = "me"
        let monitor = MergeRequestAttentionMonitor(
            glab: glab, settings: settings, verdictDirectory: folder.appending(path: "verdicts"),
            aiAssessmentDirectory: folder.appending(path: "ai-assessments"), followUpDirectory: folder,
            canAutomate: { _ in !FileManager.default.fileExists(atPath: folder.appending(path: "assistant-unavailable").path) },
            verifyReReview: { input, _, _ in
                let log = folder.appending(path: "verification.log")
                let previous = (try? Data(contentsOf: log)) ?? Data()
                try (previous + Data("verified\n".utf8)).write(to: log)
                if FileManager.default.fileExists(atPath: folder.appending(path: "fail-verification").path) {
                    throw ReReviewVerifier.VerificationError.failed
                }
                return ReReviewAssessment(notes: input.discussions.flatMap(\.notes).filter {
                    $0.system != true && $0.author?.id != input.authorID
                }.compactMap { note in
                    note.id.map { .init(noteID: $0, state: .addressed, reason: "Verified fixture correction") }
                })
            }
        )
        return Harness(folder: folder, defaults: defaults, suite: suite, settings: settings, monitor: monitor)
    }

    private let draftJSON = #"""
        [{"id":11,"author_id":3,"note":"Handle nil here.","discussion_id":null,
          "position":{"new_path":"Sources/A.swift","new_line":12,"old_path":"Sources/A.swift","old_line":null}},
         {"id":12,"author_id":3,"note":"Thanks, looks fixed.","discussion_id":"abc","position":null},
         {"id":13,"author_id":8,"note":"Someone else's draft","discussion_id":null,"position":null}]
        """#

    @Test func draftsAppearWithPreviewsAndPublishOnlyWhenUnchanged() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()

        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.needsConfirmation && !item.canApprove)
        #expect(item.drafts.map(\.kind) == [.line("Sources/A.swift:12"), .reply])

        // A new draft appears after the user looked: nothing is published.
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "\"id\":13,\"author_id\":8", with: "\"id\":13,\"author_id\":3"))
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
        #expect(harness.monitor.currentItems.first?.drafts.count == 3)

        // Publishing what is shown sends a single bulk publish and clears the queue.
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("publish.log") == "published\n")
        #expect(harness.monitor.confirmationStates[item.id] == nil)
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == true)
    }

    private let othersThread = #"""
        [{"notes":[{"id":40,"author":{"id":8},"system":false,"body":"Please check this","resolvable":true,"resolved":false}]}]
        """#

    @Test func pendingDraftsLeaveReadyWhenDiscussionContentChanges() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)

        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        let stale = try #require(harness.monitor.currentItems.first)
        #expect(stale.section == .open)
        #expect(stale.drafts.count == 2)

        // A new completed review of the same head can make the drafts ready again.
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
    }

    @Test func visibleInboxRechecksCommentsEvenWhenDraftsHaveNotChanged() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentOpenItems.first?.section == .open)
    }

    @Test(arguments: [false, true])
    func draftsWithoutCurrentDiscussionEvidenceRemainAvailableOutsideReady(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: authored)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.section == .open)
        #expect(item.needsConfirmation && item.drafts.count == 2)
    }

    @Test func authorRepliesNeedCurrentDiscussionEvidence() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try harness.bindFollowUpDiscussions()
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)

        try harness.write("discussions.json", #"[{"notes":[{"id":50,"author":{"id":8},"body":"Another question","system":false,"resolvable":false}]}]"#)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func quickRefreshInvalidatesManualApprovalAfterNewComment() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.canApprove == true)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.canApprove != true)
        #expect(harness.log("approve.log").isEmpty)
    }

    @Test(arguments: ["fail-next-draft-read", "fail-discussion-read"])
    func failedQuickCheckKeepsDraftsOutsideReady(failure: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write(failure, "yes")
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func editedCommentsInvalidateDraftReadinessButResolutionChangesDoNot() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "Please check this", with: "Edited request"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test func quickRefreshChecksTheLiveHeadInsteadOfTheListSnapshot() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("request.json", harness.log("request.json").replacingOccurrences(of: head, with: String(repeating: "f", count: 40)))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test func delayedQuickCheckCannotOverwriteANewerFullPoll() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("capture-one-discussion", "yes")
        let quickCheck = Task { await harness.monitor.refreshPendingDrafts() }
        defer { try? harness.write("release-discussion", "yes") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: harness.folder.appending(path: "discussion-captured").path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: harness.folder.appending(path: "discussion-captured").path))
        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .open)
        try harness.write("release-discussion", "yes")
        await quickCheck.value
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test(arguments: [false, true])
    func automaticPublicationRejectsDraftsAfterNewComment(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: authored)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", draftJSON)
        if authored { try harness.verifyFollowUpDrafts() }
        else { try harness.recordVerdict("objections", head: head) }
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func automaticPublicationRechecksTheExactDraftAfterDiscussionCheck() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Checked finding"}]"#)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        // The full poll reads discussions once; the final publication check reads
        // them again, after its earlier draft read. The ID stays the same.
        try harness.write("edit-after-next-discussion", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.log("drafts.json").contains("/merge"))
    }

    @Test func manualApprovalNeedsANoObjectionsVerdictForTheCurrentHead() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("no_objections", head: String(repeating: "f", count: 40))
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove && !item.autoApproveReady)
        #expect(harness.log("approve.log").isEmpty)

        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").contains("sha=\(head)"))
        #expect(harness.monitor.currentItems.isEmpty)

        // Until GitLab reports the approval, the same head is not offered again.
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
    }

    @Test func approvalIsNotOfferedOnceApproved() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("reviewers.json", #"[{"user":{"id":3},"state":"approved"}]"#)
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.log("approve.log").isEmpty)
    }

    @Test func anAuthorReplyOnTheSameHeadInvalidatesTheEarlierVerdict() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove)
        try harness.write("discussions.json", #"[{"id":"reply","notes":[{"id":71,"author":{"id":9},"system":false,"body":"Please check this approach too","resolvable":false}]}]"#)
        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").isEmpty)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func autoApprovalIsOnByDefaultAndWaitsForEveryDiscussion() async throws {
        #expect(AutomationSettings().autoApproveEnabled)
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        // Waiting on others is not something the user has to confirm.
        #expect(harness.monitor.currentItems.isEmpty)

        // Another reviewer's thread gets resolved without our action.
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        try await harness.poll()
        #expect(harness.log("approve.log").contains("sha=\(head)"))
    }

    @Test func optingOutOneMergeRequestFallsBackToManualApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.autoApproveOptOuts.insert(
            .init(host: host, username: "me", projectID: 1, iid: 2)
        )
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.canApprove == true)
    }

    @Test func unavailableCLIBlocksAutomaticPublicationButKeepsManualPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("assistant-unavailable", "yes")
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)

        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(!harness.log("publish.log").isEmpty)
    }

    @Test func unavailableCLIBlocksAutomaticAIReplyPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("assistant-unavailable", "yes")
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func unavailableCLIBlocksAutomaticApprovalButKeepsManualApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("assistant-unavailable", "yes")
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        await harness.monitor.approve(.init(projectID: 1, iid: 2))
        #expect(!harness.log("approve.log").isEmpty)
    }

    @Test func automaticPublishingIsOffByDefaultAndWaitsForSettledDrafts() async throws {
        #expect(AutomationSettings().publishDraftsWithoutConfirmation == false)

        let manual = try makeHarness(assistantWorked: true)
        defer { manual.cleanUp() }
        try manual.write("drafts.json", draftJSON)
        try await manual.poll()
        try await manual.poll()
        #expect(manual.log("publish.log").isEmpty)

        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "looks fixed", with: "looks fixed now"))
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
    }
    private let duoDiscussion = #"[{"id":"abc","notes":[{"id":40,"body":"AI finding","author":{"id":8,"username":"GitLabDuo"},"system":false,"resolvable":true,"resolved":false}]}]"#

    @Test func duoRepliesPublishSelectivelyWithoutSendingOtherDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("selected.log").contains("--method PUT"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 1)
        try await harness.poll()
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
    }

    @Test func humanAICommentRequiresCurrentContentBoundAssessment() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        let human = duoDiscussion.replacingOccurrences(of: "GitLabDuo", with: "alice")
        try harness.write("discussions.json", human)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.assess(noteID: 40, body: "old text")
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.assess(noteID: 40, body: "AI finding")
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
    }

    @Test func aiPublicationRespectsScopeOptOutAndVerifiedDuoIdentity() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.publishAIRepliesWithoutConfirmation = true
        harness.settings.automation.scope.mode = .selected
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.scope.mode = .all
        try harness.write("duo.json", #"{"id":8,"username":"GitLabDuo","bot":false}"#)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
    }

    @Test func aiPublicationFailureKeepsDraftsAndReportsFailure() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.write("fail-publish", "yes")
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == .failed)
    }

    @Test func externalPublicationDisappearsWithoutFullPolling() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func editingReplyDuringEligibilityCheckPreventsPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("change-during-discussions", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func unmanagedAIRepliesStayPrivate() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func allCommentPublishingTakesPrecedenceOverAIOnly() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func automaticPublishingRejectsGitLabQuickActions() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "/submit_review approve"))
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
    }

    private func prepareAuthoredFeedback(_ harness: Harness) throws {
        harness.settings.automation.autoReReviewEnabled = true
        try harness.write("drafts.json", draftJSON)
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"reviewed"}]"#)
        try harness.write("duo.json", #"{"id":8,"username":"reviewer","bot":false,"state":"active"}"#)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"Review feedback","system":false,"resolvable":true,"resolved":false}]}]"#)
        try harness.write("published-discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"Review feedback","system":false,"resolvable":true,"resolved":false},{"id":41,"author":{"id":3},"body":"Verified correction","system":false}]}]"#)
    }


    @Test(arguments: [AssistantJobExecution.State.succeeded, .queued, .running, .blocked, .failed, .cancelled, .interrupted])
    func onlyCompletedHeadlessFeedbackStartsReReviewWithoutPublicationBaseline(state: AssistantJobExecution.State) async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        harness.settings.assistantHandoffs = [.init(id: UUID(), key: key, title: "Follow up", prompt: "", createdAt: Date(),
            allowsPush: false, feedbackNoteIDs: [40], execution: .init(state: state))]

        try await harness.poll()

        #expect(harness.log("re-review.log") == (state == .succeeded ? "requested\n" : ""))
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
    }

    @Test func legacyGUIReceiptIsNotCompletionProofForAutomaticReReview() async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        harness.settings.assistantHandoffs = [.init(id: UUID(), key: key, title: "Legacy", prompt: "", createdAt: Date(),
            allowsPush: false, relayComplete: true, openedAt: Date(), feedbackNoteIDs: [40])]

        try await harness.poll()

        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.log("verification.log").isEmpty)
    }

    @Test func disablingVerificationWaitsForExplicitConfirmationAndRejectsChangedDiscussions() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.autoVerifyReReview = false
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.canConfirmReReview)
        #expect(harness.log("verification.log").isEmpty && harness.log("re-review.log").isEmpty)
        let fingerprint = try #require(item.reReviewFingerprint)
        let previous = harness.log("discussions.json")
        try harness.write("discussions.json", previous.replacingOccurrences(of: "Review feedback", with: "Edited feedback"))
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
        try await harness.poll()
        let current = try #require(harness.monitor.currentOpenItems.first)
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: try #require(current.reReviewFingerprint))
        #expect(harness.log("re-review.log") == "requested\n")
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func failedVerificationIsVisibleCachedAndCanBeRetriedWithoutPublishingAnything() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("fail-verification", "yes")
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.reReviewReadiness == .failed && item.canConfirmReReview)
        #expect(harness.log("re-review.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("verification.log") == "verified\n")
        try FileManager.default.removeItem(at: harness.folder.appending(path: "fail-verification"))
        await harness.monitor.retryReReview(item.id)
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
    }
    @Test func unavailableCLIBlocksAutomaticReReviewButKeepsManualConfirmation() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("assistant-unavailable", "yes")
        try await harness.poll()
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log").isEmpty)
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.reReviewReadiness == .unavailable && item.canConfirmReReview)
        await harness.monitor.confirmReReview(item.id, head: head,
                                              fingerprint: try #require(item.reReviewFingerprint))
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func publishButtonImmediatelyRequestsEligibleReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.reReviewReadiness == nil)
        try await harness.poll()
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func browserPublicationImmediatelyRequestsEligibleReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        await harness.monitor.refreshPendingDrafts()
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func publicationAndPollingDoNotDuplicateReReviewRequests() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("slow-user-check", "yes")
        let publisher = Task { await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.log("user-check.log").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!harness.log("user-check.log").isEmpty)
        try await harness.poll()
        await publisher.value
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func automaticPublishAllLeavesNewUncheckedDraftsPrivateAndVisible() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("inject-unseen-draft", "yes")
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(!harness.log("selected.log").contains("/draft_notes/99/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [99])
    }

    @Test func automaticAIReplyPublicationImmediatelyRequestsEligibleReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Fixed","discussion_id":"abc"}]"#)
        try harness.assess(noteID: 40, body: "AI finding")
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"AI finding","system":false,"resolvable":true,"resolved":false}]}]"#)
        try harness.verifyFollowUpDrafts()
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func publishAllStillPublishesSafeRepliesAlongsideUnsafeDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Handle nil here.", with: "/merge"))
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
    }

    @Test func successfulPublicationStillRequestsReReviewAfterFinalReadFails() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Fixed","discussion_id":"abc"}]"#)
        try await harness.poll()
        try harness.verifyFollowUpDrafts()
        try harness.write("fail-read-after-publish", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
    }

    @Test(arguments: [false, true])
    func draftReplyPreviewsIdentifyOtherThreadParticipants(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: false, authored: authored)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8,"username":"GitLabDuo"},"system":false},{"id":41,"author":{"id":3,"username":"me"},"system":false},{"id":42,"author":{"id":9,"username":"alice"},"system":false},{"id":43,"author":{"id":8,"username":"GitLabDuo"},"system":false},{"id":44,"author":{"id":10,"username":"system-bot"},"system":true}]}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.replyRecipients["abc"] == "@GitLabDuo, @alice")
        #expect(item.replyRecipients["unknown"] == nil)
    }

    @Test(arguments: [true, false]) func automaticAuthorPublicationRejectsUnverifiedLocalOnlyDrafts(publishAll: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = publishAll
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "The local follow-up fixes the assertion."))
        try harness.write("discussions.json", duoDiscussion)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func authorFollowUpPushOffBlocksEvenPreviouslyVerifiedDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        harness.settings.automation.allowFollowUpPush = false
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == true)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func testedPushedCurrentHeadAllowsExactAuthorReplyDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test(arguments: ["content", "body", "head", "run", "duringProof"])
    func authorPublicationRejectsStaleOrMismatchedRemoteEvidence(change: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        if change == "content" { try harness.write("remote-file-content.txt", "old code") }
        if change == "duringProof" { try harness.write("edit-during-proof", "yes") }
        if change == "body" { try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "A different unsupported fix claim")) }
        if change == "head" { try harness.write("remote-head.txt", String(repeating: "b", count: 40)) }
        if change == "run" {
            var later = try #require(harness.settings.assistantHandoffs.last)
            later = .init(id: UUID(), key: later.key, title: "New unfinished run", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: true)
            harness.settings.assistantHandoffs.append(later)
        }
        try await harness.poll()
        try await harness.poll()
        let sent = harness.log("selected.log")
        if change == "body" || change == "duringProof" {
            #expect(!sent.contains("/draft_notes/12/publish"))
        } else { #expect(sent.isEmpty) }
        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == true)
    }

    @Test func approvalRechecksTheLiveGitLabAccountBeforePosting() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove)
        try harness.write("live-user.json", #"{"id":9,"username":"other"}"#)
        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .failed)
    }

}

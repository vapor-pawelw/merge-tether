import Foundation
import Testing
@testable import GitLabTodos

struct MRDiscussionSnapshotTests {
    @Test func authorIdentityRemainsIndependentOfAITextOrigin() throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"author":{"id":7,"username":"reviewer"},"system":false,"body":"AI-assisted human feedback"},{"id":2,"author":{"id":8,"username":"automation"},"system":false,"body":"Deterministic automation output"}]}]"#.utf8))
        let origins: [Int: MRDiscussionSnapshot.Origin] = [1: .assessed(evidence: "AI-assisted wording"), 2: .humanLikely(evidence: "No AI generation")]
        let snapshot = MRDiscussionSnapshot(discussions: discussions, drafts: [], origins: origins,
            authorKinds: [7: .regular, 8: .automation])
        let thread = try #require(snapshot.threads.first)
        #expect(thread.authorKinds[7] == .regular && thread.authorKinds[8] == .automation)
        #expect(thread.origins == origins)
        let unknown = MRDiscussionSnapshot(discussions: discussions, drafts: [], origins: origins)
        #expect(unknown.threads.first?.authorKinds.isEmpty == true)
    }

    @Test(arguments: ["addressed", "informational", "blocking", "uncertain", "ignoredByUser"])
    func feedbackStatusUsesAssessmentRatherThanResolutionReplyOrOrigin(_ state: String) throws {
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self,
            from: Data("{\"notes\":[{\"noteID\":1,\"state\":\"\(state)\",\"reason\":\"Current evidence\"}]}".utf8))
        let expected: MRDiscussionSnapshot.Feedback = switch state {
        case "addressed": .addressed
        case "informational": .informational
        case "blocking": .pending
        case "ignoredByUser": .ignored
        default: .needsVerification
        }
        for resolved in [false, true] {
            let thread = try presentationThread(notes: "[{\"id\":1,\"author\":{\"id\":7},\"resolvable\":true,\"resolved\":\(resolved)},{\"id\":2,\"author\":{\"id\":9,\"username\":\"me\"}}]",
                origins: [1: .verifiedAssistant], assessment: assessment, authorID: 9)
            #expect(thread.feedback == expected)
            #expect(thread.replySummary(currentUsername: "me").publishedReply == .published)
        }
    }

    @Test func missingOrPartialAssessmentsNeverClaimFeedbackAddressed() throws {
        let notes = #"[{"id":1,"author":{"id":7},"resolvable":true,"resolved":true},{"id":2,"author":{"id":8}},{"id":3,"author":{"id":9,"username":"me"}}]"#
        let partial = ReReviewAssessment(notes: [.init(noteID: 1, state: .addressed, reason: "Checked")])
        #expect(try presentationThread(notes: notes, authorID: 9).feedback == .needsVerification)
        #expect(try presentationThread(notes: notes, assessment: partial, authorID: 9).feedback == .needsVerification)
        #expect(try presentationThread(notes: notes, assessment: partial).feedback == .needsVerification)
        #expect(MRDiscussionSnapshot.Feedback.summarize(notes: [(nil, 7)], assessment: partial, authorID: 9) == .needsVerification)
        #expect(MRDiscussionSnapshot.Feedback.summarize(notes: [(1, nil)], assessment: partial, authorID: 9) == .needsVerification)
    }

    @Test func informationalAndIgnoredFeedbackNeverBecomeCodeFixClaims() {
        let notes: [(Int?, Int?)] = [(1, 7), (2, 8), (3, 9)]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 1, state: .addressed, reason: "Checked"),
            .init(noteID: 2, state: .ignoredByUser, reason: "Ignored")])
        #expect(MRDiscussionSnapshot.Feedback.summarize(notes: notes, assessment: assessment, authorID: 9) == .partlyIgnored)
        #expect(MRDiscussionSnapshot.Feedback.summarize(notes: [(3, 9)], assessment: nil, authorID: 9) == .notApplicable)
        let duplicate = ReReviewAssessment(notes: [.init(noteID: 1, state: .addressed, reason: "Checked"),
            .init(noteID: 1, state: .addressed, reason: "Duplicate")])
        #expect(MRDiscussionSnapshot.Feedback.summarize(notes: [(1, 7)], assessment: duplicate, authorID: 9) == .needsVerification)
    }

    @Test(arguments: [
        (#"{"new_path":"Sources/Views/File.swift","new_line":12}"#, "Sources/Views/File.swift:12", "File.swift:12"),
        (#"{"old_path":"Deleted/Old.swift","old_line":8}"#, "Deleted/Old.swift:8", "Old.swift:8"),
        (#"{"new_path":"Renamed/New.swift","old_path":"Old.swift","new_line":5,"old_line":2}"#, "Renamed/New.swift:5", "New.swift:5"),
        (#"{"new_path":"Sources/File.swift","old_line":3}"#, "Sources/File.swift:3", "File.swift:3"),
        (#"{"new_path":"Sources/File.swift"}"#, "Sources/File.swift", "File.swift"),
        (#"{"new_path":"dir/a%2Fb #c:part.swift","new_line":4}"#, "dir/a%2Fb #c:part.swift:4", "a%2Fb #c:part.swift:4"),
        (#"{"new_path":"dir/../literal\\name.swift","new_line":4}"#, #"dir/../literal\name.swift:4"#, #"literal\name.swift:4"#),
        (#"{"new_path":"Root.swift","new_line":0}"#, "Root.swift:0", "Root.swift:0")
    ])
    func compactLocationsPreserveExactFullMetadata(position: String, full: String, compact: String) throws {
        let decoded = try JSONDecoder().decode(GitLabDraftNote.Position.self, from: Data(position.utf8))
        let location = try #require(MRDiscussionLocation(position: decoded))
        #expect(location.full == full)
        #expect(location.compact == compact)
        let thread = try presentationThread(notes: "[{\"id\":1,\"position\":\(position)}]")
        #expect(thread.location == full)
    }

    @Test func missingPathsHaveNoLocationAndLiteralTrailingSlashesRemainIntact() throws {
        let position = try JSONDecoder().decode(GitLabDraftNote.Position.self, from: Data(#"{"new_line":8}"#.utf8))
        #expect(MRDiscussionLocation(position: nil) == nil)
        #expect(MRDiscussionLocation(position: position) == nil)
        #expect(MRDiscussionLocation(full: "literal/path/").compact == "literal/path/")
    }

    @Test func rootCommentAndSystemEventsNeverCountAsOurPublishedReply() throws {
        let thread = try presentationThread(notes: #"[{"id":1,"author":{"id":9,"username":"me"}},{"id":2,"system":true,"author":{"id":9,"username":"me"}},{"id":3,"author":{"id":7,"username":"reviewer"}}]"#)
        #expect(thread.replySummary(currentUsername: "me").publishedReply == .none)
        #expect(thread.replySummary(currentUsername: "reviewer").publishedReply == .published)
    }

    @Test func draftDoesNotCountAsPublishedAndCoexistsWithOwnPublishedReply() throws {
        let notes = #"[{"id":1,"author":{"id":7,"username":"reviewer"}},{"id":2,"author":{"id":9,"username":"me"}}]"#
        let drafts = #"[{"id":10,"author_id":9,"note":"Pending","discussion_id":"thread"}]"#
        let thread = try presentationThread(notes: notes, drafts: drafts)
        let own = thread.replySummary(currentUsername: "me")
        #expect(own.publishedReply == .published)
        #expect(own.draftCount == 1)
        let draftOnly = try presentationThread(notes: #"[{"id":1,"author":{"id":7,"username":"reviewer"}}]"#, drafts: drafts)
        #expect(draftOnly.replySummary(currentUsername: "me").publishedReply == .none)
        #expect(draftOnly.replySummary(currentUsername: "me").draftCount == 1)
        let withoutDraft = try presentationThread(notes: notes)
        #expect(withoutDraft.replySummary(currentUsername: "me").draftCount == 0)
    }

    @Test func anotherAuthorsReplyAndAIOriginNeverStandInForCurrentAccount() throws {
        let thread = try presentationThread(notes: #"[{"id":1,"author":{"id":7,"username":"reviewer"}},{"id":2,"author":{"id":8,"username":"agent"}}]"#, origins: [2: .verifiedAssistant])
        #expect(thread.replySummary(currentUsername: "me").publishedReply == .none)
        #expect(thread.replySummary(currentUsername: "agent").publishedReply == .published)
        #expect(thread.replySummary(currentUsername: "AGENT").publishedReply == .none)
    }

    @Test func newerCommentsDistinguishEarlierReplyFromReplyToLatestActivity() throws {
        let notes = #"[{"id":1,"author":{"id":7,"username":"reviewer"}},{"id":70,"created_at":"2026-11-10T12:00:00Z","author":{"id":9,"username":"me"}},{"id":2,"created_at":"invalid","author":{"id":7,"username":"reviewer"}}]"#
        let earlier = try presentationThread(notes: notes)
        #expect(earlier.replySummary(currentUsername: "me").publishedReply == .earlier)
        let repliedAgain = try presentationThread(notes: String(notes.dropLast()) + #",{"id":4,"author":{"id":9,"username":"me"}},{"id":5,"system":true}]"#)
        #expect(repliedAgain.replySummary(currentUsername: "me").publishedReply == .published)
    }

    @Test func unknownIdentityNeverClaimsNoReplyOrReplyToUnknownLatestAuthor() throws {
        let unknown = try presentationThread(notes: #"[{"id":1},{"id":2,"author":{"id":9,"name":"me"}}]"#)
        #expect(unknown.replySummary(currentUsername: "me").publishedReply == .unknown)
        let missingUsernames: [String?] = [nil, "", "  "]
        for username in missingUsernames {
            #expect(unknown.replySummary(currentUsername: username).publishedReply == .unavailable)
        }
        let earlier = try presentationThread(notes: #"[{"id":1},{"id":2,"author":{"id":9,"username":"me"}},{"id":3}]"#)
        #expect(earlier.replySummary(currentUsername: "me").publishedReply == .earlier)
        let ownLatest = try presentationThread(notes: #"[{"id":1},{"id":2},{"id":3,"author":{"id":9,"username":"me"}}]"#)
        #expect(ownLatest.replySummary(currentUsername: "me").publishedReply == .published)
        let rootOnly = try presentationThread(notes: #"[{"id":1}]"#)
        #expect(rootOnly.replySummary(currentUsername: "me").publishedReply == .none)
    }

    @Test func replySummaryDoesNotInterpretGeneralOrResolvedCommentsAsActionRequired() throws {
        for flags in [#""resolvable":false"#, #""resolvable":true,"resolved":true"#] {
            let thread = try presentationThread(notes: "[{\"id\":1,\(flags),\"author\":{\"id\":7,\"username\":\"reviewer\"}}]")
            #expect(thread.replySummary(currentUsername: "me").publishedReply == .none)
        }
    }

    @Test func wholeThreadAIRequiresCurrentEvidenceForEveryPublishedPost() throws {
        let notes = #"[{"id":1,"body":"Opening"},{"id":2,"body":"Reply"},{"id":3,"system":true,"body":"Resolved"}]"#
        let allAI = try presentationThread(notes: notes, origins: [1: .verifiedAssistant, 2: .assessed(evidence: "Current assessment")])
        #expect(allAI.originBadge == .ai)
        let nonAIOrigins: [[Int: MRDiscussionSnapshot.Origin]] = [
            [1: .verifiedAssistant],
            [1: .verifiedAssistant, 2: .humanLikely(evidence: "Conversational reply")],
            [1: .verifiedAssistant, 2: .uncertain(evidence: "Mixed signals")]
        ]
        for origins in nonAIOrigins {
            #expect(try presentationThread(notes: notes, origins: origins).originBadge != .ai)
        }
        #expect(try presentationThread(notes: notes, origins: [:]).originBadge == nil)
    }

    @Test func threadHumanRequiresAffirmativeManualEvidenceForEveryPost() throws {
        let notes = #"[{"id":1,"body":"Opening"},{"id":2,"body":"Reply"}]"#
        let manual: MRDiscussionSnapshot.Origin = .humanLikely(evidence: "Spontaneous personal exchange")
        #expect(try presentationThread(notes: notes, origins: [1: manual, 2: manual]).originBadge == .human)
        #expect(try presentationThread(notes: notes, origins: [1: manual]).originBadge == nil)
        #expect(try presentationThread(notes: notes, origins: [1: manual, 2: .uncertain(evidence: "Insufficient evidence")]).originBadge == nil)
    }

    @Test func knownMixturesAndMissingEvidenceHaveNoBadgeWhileExplicitUncertaintyRemainsVisible() throws {
        let notes = #"[{"id":1,"body":"Opening"},{"id":2,"body":"Reply"}]"#
        #expect(try presentationThread(notes: notes, origins: [1: .verifiedAssistant, 2: .humanLikely(evidence: "Manual")]).originBadge == nil)
        #expect(try presentationThread(notes: notes, origins: [1: .uncertain(evidence: "Mixed signals"), 2: .uncertain(evidence: "Insufficient evidence")]).originBadge == .uncertain)
        #expect(try presentationThread(notes: notes, origins: [1: .verifiedAssistant, 2: .uncertain(evidence: "Insufficient evidence")]).originBadge == .uncertain)
        #expect(try presentationThread(notes: notes, origins: [1: .uncertain(evidence: "Mixed signals")]).originBadge == nil)
        #expect(try presentationThread(notes: #"[{"id":1,"body":"Opening"},{"body":"Reply without an ID"}]"#, origins: [1: .verifiedAssistant]).originBadge == nil)
    }

    @Test func systemEventsAndPrivateDraftsDoNotParticipateInPublishedThreadOrigin() throws {
        let notes = #"[{"id":1,"body":"Opening"},{"id":2,"system":true,"body":"Pushed"}]"#
        let drafts = #"[{"id":10,"author_id":9,"note":"Private reply","discussion_id":"thread"}]"#
        let thread = try presentationThread(notes: notes, drafts: drafts, origins: [1: .verifiedAssistant, 2: .humanLikely(evidence: "System event")])
        #expect(thread.originBadge == .ai)
        #expect(thread.drafts.count == 1)
        let noPosts = MRDiscussionSnapshot.Thread(id: "system", discussionID: "system", notes: [], drafts: [], state: .general, location: nil, origins: [:], feedback: .notApplicable)
        #expect(noPosts.originBadge == nil)
    }

    @Test func indexedDraftMatchingPreservesAmbiguousIDsPositionsAndOrphanOrder() throws {
        // given
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"""
        [
          {"id":"same","notes":[{"id":10,"body":"Open","resolvable":true,"resolved":false},{"id":10,"body":"Repeated ID"}]},
          {"notes":[{"id":20,"body":"Unidentified"}]},
          {"id":"","notes":[{"id":30,"body":"Empty ID","resolvable":true,"resolved":true}]},
          {"id":"system","notes":[{"id":40,"body":"Pushed","system":true}]},
          {"id":"same","notes":[{"id":50,"body":"Duplicate discussion"}]}
        ]
        """#.utf8))
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"""
        [
          {"id":11,"author_id":9,"note":"First","discussion_id":"same"},
          {"id":12,"author_id":9,"note":"General"},
          {"id":13,"author_id":9,"note":"System-only thread","discussion_id":"system"},
          {"id":14,"author_id":9,"note":"Empty thread ID","discussion_id":""},
          {"id":15,"author_id":9,"note":"Missing thread","discussion_id":"missing"},
          {"id":11,"author_id":9,"note":"Duplicate draft ID","discussion_id":"same"},
          {"author_id":9,"note":"No draft ID","discussion_id":"same"}
        ]
        """#.utf8))
        let origins: [Int: MRDiscussionSnapshot.Origin] = [10: .verifiedAssistant, 30: .assessed(evidence: "AI"),
            40: .humanLikely(evidence: "System"), 50: .humanLikely(evidence: "Manual"), 999: .verifiedAssistant]
        // when
        let snapshot = MRDiscussionSnapshot(discussions: discussions, drafts: drafts, origins: origins)
        // then
        #expect(snapshot.threads.map(\.id) == ["discussion/same", "discussion/", "unidentified/1", "discussion/same"])
        #expect(snapshot.threads.map(\.state) == [.open, .resolved, .general, .general])
        #expect(snapshot.threads[0].notes.compactMap(\.id) == [10, 10])
        #expect(snapshot.threads[0].origins == [10: .verifiedAssistant])
        #expect(snapshot.threads[1].origins == [30: .assessed(evidence: "AI")])
        #expect(snapshot.threads[2].origins.isEmpty)
        #expect(snapshot.threads[3].origins == [50: .humanLikely(evidence: "Manual")])
        #expect(snapshot.threads[0].drafts == [drafts[0], drafts[5], drafts[6]])
        #expect(snapshot.threads[3].drafts == snapshot.threads[0].drafts)
        #expect(snapshot.threads[1].drafts.isEmpty && snapshot.threads[2].drafts.isEmpty)
        #expect(snapshot.standaloneDrafts == Array(drafts[1...4]))
    }

    @Test func rebuildingTheSameThreadIDsUsesCurrentDraftVersionsOriginAndServerOrder() throws {
        // given
        let original = try presentationThread(notes: #"[{"id":1,"body":"Opening"},{"id":2,"body":"Reply","author":{"id":9,"username":"me"}}]"#,
            drafts: #"[{"id":10,"author_id":9,"note":"Before","discussion_id":"thread"}]"#,
            origins: [1: .verifiedAssistant, 2: .assessed(evidence: "Previous body")])
        var selection = DraftPublicationSelection(selectingAll: original.drafts)
        // when
        let edited = try presentationThread(notes: #"[{"id":1,"body":"Edited opening"},{"id":2,"body":"Edited reply","author":{"id":9,"username":"me"}},{"id":3,"body":"New incoming","author":{"id":7,"username":"reviewer"}}]"#,
            drafts: #"[{"id":11,"author_id":9,"note":"New first","discussion_id":"thread"},{"id":10,"author_id":9,"note":"Edited second","discussion_id":"thread"}]"#,
            origins: [2: .humanLikely(evidence: "Current body")])
        selection.reconcile(with: edited.drafts)
        // then
        #expect(edited.id == original.id)
        #expect(edited.notes.compactMap(\.id) == [1, 2, 3])
        #expect(edited.origins == [2: .humanLikely(evidence: "Current body")])
        #expect(edited.originBadge == nil && original.originBadge == .ai)
        #expect(edited.drafts.compactMap(\.id) == [11, 10])
        #expect(edited.drafts.last?.note == "Edited second")
        #expect(selection.selectedDrafts(from: edited.drafts).isEmpty)
        #expect(edited.replySummary(currentUsername: "me").publishedReply == .earlier)
        #expect(edited.replySummary(currentUsername: "other").publishedReply == .none)
    }

    @Test(arguments: [
        ("AAA", MRDiscussionSnapshot.OriginBadge.ai), ("HHH", .human), ("UUU", .uncertain),
        ("AAU", .uncertain), ("UAA", .uncertain), ("AUA", .uncertain)
    ])
    func aggregateOriginRemainsConservativeAcrossPostOrder(sequence: String, expected: MRDiscussionSnapshot.OriginBadge) throws {
        let origins = originSequence(sequence)
        let thread = try presentationThread(notes: #"[{"id":1},{"id":2},{"id":3}]"#, origins: origins)
        #expect(thread.originBadge == expected)
    }

    @Test(arguments: ["AAH", "HAA", "AHA", "UUH", "HUU", "UHU", "AA?", "?AA", "HH?", "?HH", "UU?", "?UU"])
    func mixedHumanOrMissingEvidenceNeverGetsAnAggregateBadge(_ sequence: String) throws {
        let thread = try presentationThread(notes: #"[{"id":1},{"id":2},{"id":3}]"#, origins: originSequence(sequence))
        #expect(thread.originBadge == nil)
    }

    private func originSequence(_ sequence: String) -> [Int: MRDiscussionSnapshot.Origin] {
        var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
        for (index, value) in sequence.enumerated() {
            switch value {
            case "A": origins[index + 1] = .verifiedAssistant
            case "H": origins[index + 1] = .humanLikely(evidence: "Manual")
            case "U": origins[index + 1] = .uncertain(evidence: "Mixed signals")
            default: break
            }
        }
        return origins
    }

    @MainActor @Test(arguments: [
        ("1970-01-01T00:00:00Z", 0.0), ("1970-01-01T00:00:00.125Z", 0.125),
        ("1970-01-01T01:00:00+01:00", 0.0), ("1970-01-01T01:00:00.125+01:00", 0.125)
    ])
    func timestampsPreserveBothISOFormatsBeforeCurrentLocaleFormatting(raw: String, epoch: Double) {
        #expect(MRDiscussionTimestamp.display(raw) == Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
    }

    @MainActor @Test(arguments: ["", "invalid", "1970-01-01", "  "])
    func unavailableTimestampsRemainLiteral(_ raw: String) {
        #expect(MRDiscussionTimestamp.display(raw) == raw)
    }

    private func presentationThread(notes: String, drafts: String = "[]", origins: [Int: MRDiscussionSnapshot.Origin] = [:],
                                    assessment: ReReviewAssessment? = nil, authorID: Int? = nil) throws -> MRDiscussionSnapshot.Thread {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("[{\"id\":\"thread\",\"notes\":\(notes)}]".utf8))
        let pending = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(drafts.utf8))
        return try #require(MRDiscussionSnapshot(discussions: discussions, drafts: pending, origins: origins,
            assessment: assessment, authorID: authorID).threads.first)
    }

    @Test func groupsOpenResolvedAndGeneralWhilePreservingServerOrderWithinEachState() throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"""
        [
          {"id":"general-z","notes":[{"id":90,"body":"Please also update the docs","resolvable":false,"created_at":"2026-11-08T12:00:00Z"}]},
          {"id":"resolved-z","notes":[{"id":80,"resolvable":true,"resolved":true}]},
          {"id":"open-z","notes":[{"id":70,"resolvable":true,"resolved":false,"created_at":"2026-11-09T12:00:00Z"},{"id":2,"body":"Earlier reply","created_at":"2026-11-01T12:00:00Z"}]},
          {"id":"general-a","notes":[{"id":1,"resolvable":false,"created_at":"2026-11-10T12:00:00Z"}]},
          {"id":"open-a","notes":[{"id":3,"resolvable":true,"resolved":false,"created_at":"2026-11-01T12:00:00Z"}]},
          {"id":"resolved-a","notes":[{"id":4,"resolvable":true,"resolved":true}]}
        ]
        """#.utf8))
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Reply","discussion_id":"open-a"},{"id":11,"author_id":9,"note":"General reply","discussion_id":"general-a"}]"#.utf8))

        let snapshot = MRDiscussionSnapshot(discussions: discussions, drafts: drafts, origins: [:])

        #expect(snapshot.threads.map(\.discussionID) == ["open-z", "open-a", "resolved-z", "resolved-a", "general-z", "general-a"])
        #expect(snapshot.threads.first?.notes.compactMap(\.id) == [70, 2])
        #expect(snapshot.pendingPublication.threads.map(\.discussionID) == ["open-a", "general-a"])
        #expect(snapshot.remainingDiscussions.threads.map(\.discussionID) == ["open-z", "resolved-z", "resolved-a", "general-z"])
        #expect(snapshot.pendingPublication.threads.flatMap(\.drafts) == drafts)
    }

    @Test func classifiesByResolvableNotesRatherThanDiffPositionOrFeedbackMeaning() throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"""
        [
          {"id":"general-with-position","notes":[{"id":1,"body":"Please fix this","resolvable":false,"resolved":true,"position":{"new_path":"File.swift","new_line":8}}]},
          {"id":"resolved-without-position","notes":[{"id":2,"resolvable":true,"resolved":true},{"id":3,"body":"Non-resolvable reply","resolvable":false}]},
          {"id":"open-without-position","notes":[{"id":4,"resolvable":true,"resolved":false}]},
          {"id":"unknown-resolution","notes":[{"id":5,"resolvable":true}]},
          {"id":"partly-resolved","notes":[{"id":6,"resolvable":true,"resolved":true},{"id":7,"resolvable":true,"resolved":false}]},
          {"id":"general-unknown-resolvability","notes":[{"id":8,"body":"Please add tests"},{"id":9,"system":true,"resolvable":true,"resolved":false}]},
          {"id":"system-only","notes":[{"id":10,"system":true,"resolvable":true,"resolved":false}]}
        ]
        """#.utf8))

        let snapshot = MRDiscussionSnapshot(discussions: discussions, drafts: [], origins: [:])
        let states = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.discussionID, $0.state) })

        #expect(states["general-with-position"] == .general)
        #expect(states["general-unknown-resolvability"] == .general)
        #expect(states["resolved-without-position"] == .resolved)
        #expect(states["open-without-position"] == .open)
        #expect(states["unknown-resolution"] == .open)
        #expect(states["partly-resolved"] == .open)
        #expect(states["system-only"] == nil)
        #expect(snapshot.threads.first { $0.discussionID == "general-unknown-resolvability" }?.notes.compactMap(\.id) == [8])
    }

    @Test func missingStateGroupsKeepAllRemainingThreadsInServerOrder() throws {
        let discussions = try threads()
        for state in [MRDiscussionSnapshot.State.open, .resolved, .general] {
            let existing = MRDiscussionSnapshot(discussions: discussions, drafts: [], origins: [:])
            let ids = existing.threads.filter { $0.state == state }.map(\.discussionID)
            let subset = discussions.filter { ids.contains($0.id) }
            let snapshot = MRDiscussionSnapshot(discussions: subset, drafts: [], origins: [:])
            #expect(snapshot.threads.map(\.discussionID) == subset.map(\.id))
            #expect(snapshot.threads.allSatisfy { $0.state == state })
        }
        let empty = MRDiscussionSnapshot(discussions: [], drafts: [], origins: [:])
        #expect(empty.threads.isEmpty)
    }

    @Test func publicationContextAndOtherDiscussionsPartitionThePageWithoutDuplicateDrafts() throws {
        // given
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"active"},{"id":11,"author_id":9,"note":"General draft"},{"id":12,"author_id":9,"note":"Orphan reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: try threads(), drafts: drafts,
            origins: [2: .assessed(evidence: "Recorded assessment")])
        // when
        let publication = snapshot.pendingPublication
        let other = snapshot.remainingDiscussions
        // then
        #expect(publication.threads.map(\.discussionID) == ["active"])
        #expect(publication.threads.first?.notes.compactMap(\.id) == [2, 3])
        #expect(publication.threads.first?.origins[2] != nil)
        #expect(publication.threads.flatMap(\.drafts) + publication.standaloneDrafts == drafts)
        #expect(other.threads.map(\.discussionID) == ["done", "general"])
        #expect(other.threads.flatMap(\.drafts).isEmpty && other.standaloneDrafts.isEmpty)
    }

    private func threads() throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"done","notes":[{"id":1,"author":{"id":7,"username":"alice"},"body":"First finding","system":false,"resolvable":true,"resolved":true}]},{"id":"active","notes":[{"id":2,"author":{"id":7,"username":"alice"},"body":"Please check","system":false,"resolvable":true,"resolved":false,"position":{"new_path":"src/File.swift","new_line":12}},{"id":3,"author":{"id":9,"username":"me"},"body":"Author reply","system":false}]},{"id":"general","notes":[{"id":4,"author":{"id":7},"body":"Summary","system":false}]},{"id":"system","notes":[{"id":5,"system":true,"body":"pushed new commits"}]}]"#.utf8))
    }

    @Test func fullThreadsPreserveRepliesAndResolvedCommentsWithTheirPendingDrafts() throws {
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"active"},{"id":11,"author_id":9,"note":"General draft"},{"id":12,"author_id":9,"note":"Orphan reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: try threads(), drafts: drafts,
            origins: [2: .assessed(evidence: "Recorded assessment")])
        #expect(snapshot.threads.count == 3)
        let first = try #require(snapshot.threads.first)
        #expect(first.discussionID == "active")
        #expect(first.notes.compactMap(\.id) == [2, 3])
        #expect(first.drafts.compactMap(\.id) == [10])
        #expect(first.location == "src/File.swift:12")
        #expect(first.state == .open)
        #expect(first.origins[2] != nil && first.origins[3] == nil)
        #expect(snapshot.threads.first { $0.discussionID == "done" }?.state == .resolved)
        #expect(snapshot.threads.first { $0.discussionID == "general" }?.state == .general)
        #expect(snapshot.standaloneDrafts.compactMap(\.id) == [11, 12])
    }

    @Test func unavailableDiscussionContextNeverHidesPrivateDrafts() throws {
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: [], drafts: drafts, origins: [:])
        #expect(snapshot.standaloneDrafts == drafts)
        #expect(snapshot.pendingPublication.standaloneDrafts == drafts)
        #expect(snapshot.remainingDiscussions.standaloneDrafts.isEmpty)
    }

    @Test func onlyCurrentQualifyingConfidenceEvidenceCanLabelANote() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = try #require(threads().first?.notes.first)
        let path = AICommentAssessmentStore.fileURL(host: "gitlab.example.test", projectID: 1, iid: 2, noteID: 1, in: folder)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = AICommentAssessment(version: 1, host: "gitlab.example.test", projectID: 1, iid: 2, noteID: 1,
            bodySHA256: AICommentAssessmentStore.digest(note.body!), confidence: "very_high", evidence: "Explicit model attribution")
        try JSONEncoder().encode(record).write(to: path)
        #expect(AICommentAssessmentStore.assessment(for: note, host: "gitlab.example.test", projectID: 1, iid: 2, in: folder)?.evidence == record.evidence)
        var edited = note; edited.body = "Edited finding"
        #expect(AICommentAssessmentStore.assessment(for: edited, host: "gitlab.example.test", projectID: 1, iid: 2, in: folder) == nil)
        #expect(AICommentAssessmentStore.assessment(for: note, host: "other.example.test", projectID: 1, iid: 2, in: folder) == nil)
    }
}

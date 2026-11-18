import Foundation

/// The assistant's finished review verdict for one merge request head.
struct ReviewVerdict: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case noObjections = "no_objections"
        case objections
        case classifiedFindings = "classified_findings"
    }

    enum FindingLevel: String, Codable, Sendable {
        case none, nonCode = "non_code", minorCode = "minor_code", major

        var title: LocalizedStringResource? {
            switch self {
            case .none: nil
            case .nonCode: .Menu.menuConfirmFindingEditorial
            case .minorCode: .Menu.menuConfirmFindingMinorCode
            case .major: .Menu.menuConfirmFindingMajor
            }
        }

        func allows(_ threshold: AutoApprovalThreshold) -> Bool {
            switch self {
            case .none: true
            case .nonCode: threshold != .noIssues
            case .minorCode: threshold == .noMajorIssues
            case .major: false
            }
        }
    }

    struct Findings: Codable, Equatable, Sendable {
        let general: FindingLevel
        /// Each active discussion is classified as a whole, including replies from every participant.
        let discussions: [String: FindingLevel]
        let drafts: [String: FindingLevel]
    }

    let version: Int
    let host: String
    let projectID: Int
    let iid: Int
    let headSHA: String
    let verdict: Kind
    var discussionFingerprint: String? = nil
    var username: String? = nil
    var userID: Int? = nil
    var runID: UUID? = nil
    var nonBlockingDuoNotes: [String: String]? = nil

    /// A verified false positive can exempt only its own thread, including any replies from this reviewer.
    func duoAuthorID(for discussion: GitLabMergeRequestDiscussion, reviewerID: Int) -> Int? {
        let notes = discussion.notes.filter { $0.system != true }
        guard verdict == .noObjections, let source = notes.first, source.resolvable == true,
              let noteID = source.id, noteID > 0, let body = source.body,
              let digest = nonBlockingDuoNotes?[String(noteID)], digest == AICommentAssessmentStore.digest(body),
              let author = source.author, author.id > 0, author.id != reviewerID,
              author.username?.lowercased() == "gitlabduo",
              notes.dropFirst().allSatisfy({ $0.author?.id == reviewerID }) else { return nil }
        return author.id
    }
    var findings: Findings? = nil
    var semanticContextFingerprint: String? = nil
    var draftBodyDigests: [String: String]? = nil

    func hasCompleteFindings(in discussions: [GitLabMergeRequestDiscussion], drafts: [GitLabDraftNote]) -> Bool {
        guard verdict == .classifiedFindings else { return true }
        guard let findings, let draftBodyDigests, drafts.count == findings.drafts.count,
              drafts.allSatisfy({ draft in
                  guard let id = draft.id, let body = draft.note else { return false }
                  return findings.drafts[String(id)] != nil && draftBodyDigests[String(id)] == AICommentAssessmentStore.digest(body)
              }) else { return false }
        return GitLabMergeRequestDiscussion.activeForReview(discussions).allSatisfy { thread in
            guard let root = thread.reviewRoot else { return true }
            return root.id.map { findings.discussions[String($0)] != nil } == true
        }
    }


    /// `reviewerID` and `publishedDrafts` let comments the reviewer published from drafts after the
    /// verdict keep it valid: the verdict is recorded while its drafts still wait for confirmation.
    func approves(
        head: String, discussions: [GitLabMergeRequestDiscussion] = [],
        reviewerID: Int? = nil, publishedDrafts: Set<String> = []
    ) -> Bool {
        verdict == .noObjections && covers(head: head, discussions: discussions,
            reviewerID: reviewerID, publishedDrafts: publishedDrafts)
    }

    /// The verdict covers the checked head and the discussion evidence, regardless of findings.
    func covers(head: String, discussions: [GitLabMergeRequestDiscussion],
                reviewerID: Int? = nil, publishedDrafts: Set<String> = []) -> Bool {
        guard version == 1 && headSHA == head,
              Self.fingerprint(discussions) != nil else { return false }
        // Older receipts remain valid only when there is no discussion content to miss.
        guard let recorded = discussionFingerprint else {
            return discussions.flatMap(\.notes).allSatisfy { $0.system == true }
        }
        // Notes created after the verdict have the highest IDs, so try excluding the newest
        // of the reviewer's own published drafts one at a time.
        var ownPublished: [Int] = []
        if let reviewerID {
            for note in discussions.flatMap(\.notes) where note.system != true && note.author?.id == reviewerID {
                guard let id = note.id, let body = note.body,
                      publishedDrafts.contains(AICommentAssessmentStore.digest(body)) else { continue }
                ownPublished.append(id)
            }
        }
        ownPublished.sort(by: >)
        var excluded: Set<Int> = []
        if Self.fingerprint(discussions) == recorded { return true }
        for noteID in ownPublished {
            excluded.insert(noteID)
            if Self.fingerprint(discussions, excluding: excluded) == recorded { return true }
        }
        return false
    }

    static func fingerprint(_ discussions: [GitLabMergeRequestDiscussion], excluding excluded: Set<Int> = []) -> String? {
        var rows: [(Int, Int, String)] = []
        for note in discussions.flatMap(\.notes) where note.system != true {
            guard let id = note.id, id > 0, let authorID = note.author?.id, authorID > 0, let body = note.body else { return nil }
            guard !excluded.contains(id) else { continue }
            rows.append((id, authorID, AICommentAssessmentStore.digest(body)))
        }
        let content = rows.sorted { $0 < $1 }.map { "\($0.0):\($0.1):\($0.2)\n" }.joined()
        return AICommentAssessmentStore.digest(content)
    }
}

/// Raw helper records are candidates; automatic approval additionally requires the authenticated completion.
enum ReviewVerdictStore {
    struct RemainingFinding: Sendable, Equatable {
        let level: ReviewVerdict.FindingLevel
        var noteID: Int? = nil
        var summary: String? = nil
    }

    struct Publication: Sendable {
        let verdict: ReviewVerdict
        fileprivate let drafts: [GitLabDraftNote]
        fileprivate let beforeIDs: Set<Int>
        fileprivate let beforeFingerprint: String
        fileprivate let publishedDraftRoots: [String: Int]
    }
    private struct NormalizedPublication: Codable {
        let verdict: ReviewVerdict
        let fingerprint: String
        var publishedDraftRoots: [String: Int]? = nil
    }
    nonisolated static let directory = InstallationStorage.current.evidence
        .appending(path: "verdicts", directoryHint: .isDirectory)

    nonisolated static func fileURL(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> URL {
        directory.appending(path: host, directoryHint: .isDirectory).appending(path: "\(projectID)-\(iid).json")
    }

    nonisolated static func verdict(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> ReviewVerdict? {
        let url = fileURL(host: host, projectID: projectID, iid: iid, in: directory)
        guard let data = try? Data(contentsOf: url), data.count < 65_536,
              let verdict = try? JSONDecoder().decode(ReviewVerdict.self, from: data),
              verdict.host == host, verdict.projectID == projectID, verdict.iid == iid
        else { return nil }
        return verdict
    }

    nonisolated static func verdict(host: String, projectID: Int, iid: Int, user: GitLabAuthenticatedUser,
                                   in directory: URL = directory) -> ReviewVerdict? {
        guard let verdict = verdict(host: host, projectID: projectID, iid: iid, in: directory),
              verdict.username == user.username, verdict.userID == user.id else { return nil }
        return verdict
    }

    @MainActor
    static func authenticatedVerdict(host: String, projectID: Int, iid: Int, user: GitLabAuthenticatedUser,
                                     settings: SettingsManager?, in directory: URL = directory) -> ReviewVerdict? {
        guard let verdict = verdict(host: host, projectID: projectID, iid: iid, user: user, in: directory),
              let runID = verdict.runID, let settings,
              let run = settings.assistantHandoffs.first(where: { $0.id == runID }),
              run.key.work == .init(host: host, projectID: projectID, iid: iid), run.key.username == user.username,
              run.key.assistant == settings.automation.assistant, run.execution?.state == .succeeded,
              AssistantAutomationRunner.recordsReviewVerdict(for: run, history: settings.assistantHandoffs),
              AssistantJobJournal.reviewVerdict(for: run) == verdict else { return nil }
        return verdict
    }

    @MainActor
    static func authenticatedReviewDrafts(for verdict: ReviewVerdict, settings: SettingsManager?) -> [GitLabDraftNote]? {
        guard let runID = verdict.runID, let run = settings?.assistantHandoffs.first(where: { $0.id == runID }),
              AssistantJobJournal.reviewVerdict(for: run) == verdict else { return nil }
        return AssistantJobJournal.reviewDrafts(for: run)
    }

    @MainActor
    static func automaticallyApproves(_ verdict: ReviewVerdict, head: String,
        discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser,
        threshold: AutoApprovalThreshold = .noMajorIssues, semanticContextFingerprint: String? = nil,
        legacyDuoThreadsVerified: Bool = false,
        in directory: URL = directory) -> Bool {
        guard contentMatches(verdict, head: head, discussions: discussions, user: user, in: directory) else { return false }
        let active = GitLabMergeRequestDiscussion.activeForReview(discussions)
        switch verdict.verdict {
        case .objections:
            return false
        case .noObjections:
            // Older verdicts did not classify other participants' general comments or open findings.
            return active.allSatisfy { thread in
                thread.notes.allSatisfy { $0.system == true || ($0.author?.id == user.id && $0.resolvable != true) }
                    || (legacyDuoThreadsVerified && verdict.duoAuthorID(for: thread, reviewerID: user.id) != nil)
            }
        case .classifiedFindings:
            guard let findings = verdict.findings, findings.general.allows(threshold),
                  let semanticContextFingerprint, verdict.semanticContextFingerprint == semanticContextFingerprint else { return false }
            let publishedDraftRoots = Self.publishedDraftRoots(verdict, matching: discussions, in: directory)
            guard findings.drafts.allSatisfy({ publishedDraftRoots[$0.key] != nil || $0.value.allows(threshold) }) else { return false }
            let draftsByRoot = Dictionary(grouping: publishedDraftRoots, by: \.value)
            return active.allSatisfy { thread in
                guard let root = thread.reviewRoot else { return true }
                guard let id = root.id else { return false }
                let levels = findingLevels(findings, noteID: id, draftsByRoot: draftsByRoot)
                return !levels.isEmpty && levels.allSatisfy { $0.allows(threshold) }
            }
        }
    }

    @MainActor
    static func remainingFindings(_ verdict: ReviewVerdict, discussions: [GitLabMergeRequestDiscussion],
                                  in directory: URL = directory) -> [RemainingFinding] {
        guard let findings = verdict.findings else { return [] }
        let publishedDraftRoots = Self.publishedDraftRoots(verdict, matching: discussions, in: directory)
        let draftsByRoot = Dictionary(grouping: publishedDraftRoots, by: \.value)
        var remaining: [RemainingFinding] = findings.general == .none ? [] : [.init(level: findings.general)]
        for thread in GitLabMergeRequestDiscussion.activeForReview(discussions) {
            guard let note = thread.reviewRoot, let id = note.id else { continue }
            let levels = findingLevels(findings, noteID: id, draftsByRoot: draftsByRoot)
            for level in [ReviewVerdict.FindingLevel.major, .minorCode, .nonCode] where levels.contains(level) {
                remaining.append(.init(level: level, noteID: id,
                    summary: AgentExplanation.summary(note.body.map { String($0.prefix(AgentExplanation.maximumLength)) })))
            }
        }
        for id in findings.drafts.keys.sorted() where publishedDraftRoots[id] == nil {
            if let level = findings.drafts[id], level != .none { remaining.append(.init(level: level)) }
        }
        return remaining
    }

    @MainActor
    private static func publishedDraftRoots(_ verdict: ReviewVerdict, matching discussions: [GitLabMergeRequestDiscussion],
                                            in directory: URL) -> [String: Int] {
        let publication = normalizedPublication(verdict, in: directory)
        return publication?.fingerprint == ReviewVerdict.fingerprint(discussions) ? publication?.publishedDraftRoots ?? [:] : [:]
    }

    private static func findingLevels(_ findings: ReviewVerdict.Findings, noteID: Int,
                                      draftsByRoot: [Int: [Dictionary<String, Int>.Element]]) -> [ReviewVerdict.FindingLevel] {
        let draftLevels = (draftsByRoot[noteID] ?? []).compactMap { findings.drafts[$0.key] }
        return (findings.discussions[String(noteID)].map { [$0] } ?? []) + draftLevels
    }

    @MainActor
    static func contentMatches(_ verdict: ReviewVerdict, head: String,
        discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser, in directory: URL = directory) -> Bool {
        guard verdict.version == 1, verdict.headSHA == head,
              verdict.username == user.username, verdict.userID == user.id, verdict.runID != nil,
              let fingerprint = ReviewVerdict.fingerprint(discussions) else { return false }
        return fingerprint == verdict.discussionFingerprint || normalizedPublication(verdict, in: directory)?.fingerprint == fingerprint
    }

    @MainActor
    private static func normalizedPublication(_ verdict: ReviewVerdict, in directory: URL) -> NormalizedPublication? {
        let path = publicationURL(verdict, in: directory)
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 131_072,
              let data = try? Data(contentsOf: path),
              let payload = AssistantJobJournal.authenticatedEvidence(data, context: "review-publication-normalization"),
              let record = try? JSONDecoder().decode(NormalizedPublication.self, from: payload),
              record.verdict == verdict else { return nil }
        return record
    }

    @MainActor
    static func capturePublication(_ drafts: [GitLabDraftNote], verdict: ReviewVerdict,
        before: [GitLabMergeRequestDiscussion], reviewedDrafts: [GitLabDraftNote],
        user: GitLabAuthenticatedUser, in directory: URL = directory) -> Publication? {
        let notes = before.flatMap(\.notes), ids = notes.compactMap(\.id)
        guard contentMatches(verdict, head: verdict.headSHA, discussions: before, user: user, in: directory),
              !drafts.isEmpty, drafts.count <= 100, Set(drafts.compactMap(\.id)).count == drafts.count,
              drafts.allSatisfy({ reviewedDrafts.contains($0) }),
              drafts.allSatisfy({ ($0.id ?? 0) > 0 && $0.authorID == user.id && $0.note?.isEmpty == false }),
              ids.count == notes.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              let fingerprint = ReviewVerdict.fingerprint(before) else { return nil }
        let publication = normalizedPublication(verdict, in: directory)
        return .init(verdict: verdict, drafts: drafts, beforeIDs: Set(ids), beforeFingerprint: fingerprint,
            publishedDraftRoots: publication?.fingerprint == fingerprint ? publication?.publishedDraftRoots ?? [:] : [:])
    }

    @MainActor
    static func recordPublication(_ publication: Publication, after: [GitLabMergeRequestDiscussion],
        user: GitLabAuthenticatedUser, in directory: URL = directory) throws {
        guard publication.verdict.username == user.username, publication.verdict.userID == user.id else { return }
        let notes = after.flatMap { thread in thread.notes.map { (thread.id, $0) } }
        let ids = notes.compactMap { $0.1.id }
        guard ids.count == notes.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              publication.beforeIDs.isSubset(of: Set(ids)) else { return }
        let added = notes.filter { $0.1.system != true && $0.1.id.map { !publication.beforeIDs.contains($0) } == true }
        guard added.count == publication.drafts.count else { return }
        var matched: Set<Int> = []
        var publishedDraftRoots = publication.publishedDraftRoots
        for draft in publication.drafts {
            let candidates = added.filter { threadID, note in
                note.author?.id == user.id && note.author?.username == user.username && note.body == draft.note
                    && (draft.discussionID == nil || draft.discussionID == threadID)
                    && draft.position == note.position
            }
            guard candidates.count == 1, let id = candidates.first?.1.id, matched.insert(id).inserted else { return }
            if publication.verdict.verdict == .classifiedFindings {
                guard let draftID = draft.id, publication.verdict.findings?.drafts[String(draftID)] != nil,
                      let root = after.first(where: { $0.notes.contains { $0.id == id } })?.reviewRoot?.id else { return }
                publishedDraftRoots[String(draftID)] = root
            }
        }
        guard ReviewVerdict.fingerprint(after, excluding: matched) == publication.beforeFingerprint,
              let fingerprint = ReviewVerdict.fingerprint(after) else { return }
        let record = NormalizedPublication(verdict: publication.verdict, fingerprint: fingerprint,
            publishedDraftRoots: publishedDraftRoots.isEmpty ? nil : publishedDraftRoots)
        let data = try AssistantJobJournal.sealEvidence(JSONEncoder().encode(record), context: "review-publication-normalization")
        let path = publicationURL(publication.verdict, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
    }

    private nonisolated static func publicationURL(_ verdict: ReviewVerdict, in directory: URL) -> URL {
        fileURL(host: verdict.host, projectID: verdict.projectID, iid: verdict.iid, in: directory)
            .deletingPathExtension().appendingPathExtension("published.json")
    }

    nonisolated static func draftsURL(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> URL {
        directory.appending(path: host, directoryHint: .isDirectory).appending(path: "\(projectID)-\(iid).drafts.json")
    }

    /// Digests of the user's own drafts seen on this MR, so their published comments don't invalidate a verdict.
    nonisolated static func seenDrafts(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> Set<String> {
        let url = draftsURL(host: host, projectID: projectID, iid: iid, in: directory)
        guard let data = try? Data(contentsOf: url), data.count < 100_000,
              let digests = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(digests)
    }

    nonisolated static func rememberDrafts(_ drafts: [GitLabDraftNote], host: String, projectID: Int, iid: Int, in directory: URL = directory) {
        let known = seenDrafts(host: host, projectID: projectID, iid: iid, in: directory)
        let new = drafts.compactMap(\.note).map(AICommentAssessmentStore.digest).filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        let url = draftsURL(host: host, projectID: projectID, iid: iid, in: directory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Array(known.union(new)).sorted().suffix(500)).write(to: url, options: .atomic)
        } catch {
            Log.monitor.error("Could not remember review drafts: \(String(describing: error), privacy: .private)")
        }
    }

    /// Added to every review prompt so MergeTether knows when a review of a given head is finished.
    nonisolated static func recordingInstructions(host: String, projectID: Int, iid: Int, username: String, runID: UUID) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "Automation/evidence.py").path ?? "<MergeTether.app>/Contents/Resources/Automation/evidence.py"
        let command = InstallationStorage.current.helperEnvironmentPrefix + " /usr/bin/python3 -B '"
            + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            Check factual concerns raised by other reviewers against the current MR head. For a claim that a file is missing from the change, verify its exact path in the full changed-file list or a Git diff pinned to the MR's base and head. Generated, collapsed or omitted diff output can hide a file that is included. Check the actual file at that head when its content matters.

            For an active GitLab Duo thread, classify it as `none` only when evidence disproves its claims and the entire thread has no remaining concern. This applies to a resolvable thread started by the verified GitLab Duo bot that contains only the source note and any replies from my account. Verify the author via `/users/<id>` (`bot: true`, username `GitLabDuo`). Leave Duo's thread open. An optional private reply answers the specific concern in the required review language, links directly to the checked evidence at the reviewed commit and says explicitly that the concern requires no change.

            Record the verdict after reviewing the exact head, MR title and description, and every active discussion from all participants. Check earlier findings and replies only in active threads. A resolved thread is closed: skip the whole thread, even if its wording is still visible. Never re-open it, reply to it, verify its concern, or repeat it as a new finding. Independently review the assigned code changes.
            Save every warranted finding as a private draft. Record `classified_findings` with `--findings-json` and a JSON object containing `general`, `discussions`, and `drafts`. Classify each active discussion, including general comments and any reviewer's comments, by its first non-system note ID. Read the whole active thread and classify its strongest remaining concern. Classify each current private draft by draft ID. Use `general` for the strongest remaining concern that has no discussion or draft, or `none` when there is no such concern. Use `none` for discussion text or draft replies without an outstanding issue, `non_code` for minor editorial or MR metadata issues, `minor_code` for nonessential code changes, and `major` for substantive issues or uncertainty about whether they are ruled out. Correctness, security, regressions, missing essential verification, or an explicit requirement before approval remain major even when raised outside the diff. A reviewer report requires checking its actual claims, including general comments. When you cannot safely assess the complete active evidence, record `objections`.
            Run the bundled helper `\(command) record-verdict \(host) \(projectID) \(iid) <HEAD_SHA> <VERDICT> --username \(username) --run-id \(runID.uuidString.lowercased())` with placeholders filled in and the findings JSON when classifying. Recheck the active discussion text and drafts before recording. The helper checks the live account, head and discussions. Its success response must include `discussionFingerprint`. Record a fresh verdict after each re-review. MergeTether authenticates the successful review and applies the user's approval setting. Do not approve directly or hand-write a receipt.
            """
    }
}

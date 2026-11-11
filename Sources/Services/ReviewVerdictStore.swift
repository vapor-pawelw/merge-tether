import Foundation

/// The assistant's finished review verdict for one merge request head.
struct ReviewVerdict: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case noObjections = "no_objections"
        case objections
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

    /// `reviewerID` and `publishedDrafts` let comments the reviewer published from drafts after the
    /// verdict keep it valid: the verdict is recorded while its drafts still wait for confirmation.
    func approves(
        head: String, discussions: [GitLabMergeRequestDiscussion] = [],
        reviewerID: Int? = nil, publishedDrafts: Set<String> = []
    ) -> Bool {
        verdict == .noObjections && covers(head: head, discussions: discussions,
            reviewerID: reviewerID, publishedDrafts: publishedDrafts)
    }

    /// Both outcomes prove the review ran; approval additionally requires no objections.
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
    struct Publication: Sendable {
        let verdict: ReviewVerdict
        fileprivate let drafts: [GitLabDraftNote]
        fileprivate let beforeIDs: Set<Int>
        fileprivate let beforeFingerprint: String
    }
    private struct NormalizedPublication: Codable {
        let verdict: ReviewVerdict
        let fingerprint: String
    }
    nonisolated static let directory = InstallationStorage.current.evidence
        .appending(path: "verdicts", directoryHint: .isDirectory)

    nonisolated static func fileURL(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> URL {
        directory.appending(path: host, directoryHint: .isDirectory).appending(path: "\(projectID)-\(iid).json")
    }

    nonisolated static func verdict(host: String, projectID: Int, iid: Int, in directory: URL = directory) -> ReviewVerdict? {
        let url = fileURL(host: host, projectID: projectID, iid: iid, in: directory)
        guard let data = try? Data(contentsOf: url), data.count < 4096,
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
        discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser, in directory: URL = directory) -> Bool {
        verdict.verdict == .noObjections && contentMatches(verdict, head: head, discussions: discussions, user: user, in: directory)
    }

    @MainActor
    static func contentMatches(_ verdict: ReviewVerdict, head: String,
        discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser, in directory: URL = directory) -> Bool {
        guard verdict.version == 1, verdict.headSHA == head,
              verdict.username == user.username, verdict.userID == user.id, verdict.runID != nil,
              let fingerprint = ReviewVerdict.fingerprint(discussions) else { return false }
        if fingerprint == verdict.discussionFingerprint { return true }
        let path = publicationURL(verdict, in: directory)
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
              let data = try? Data(contentsOf: path),
              let payload = AssistantJobJournal.authenticatedEvidence(data, context: "review-publication-normalization"),
              let record = try? JSONDecoder().decode(NormalizedPublication.self, from: payload),
              record.verdict == verdict else { return false }
        return record.fingerprint == fingerprint
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
        return .init(verdict: verdict, drafts: drafts, beforeIDs: Set(ids), beforeFingerprint: fingerprint)
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
        for draft in publication.drafts {
            let candidates = added.filter { threadID, note in
                note.author?.id == user.id && note.author?.username == user.username && note.body == draft.note
                    && (draft.discussionID == nil || draft.discussionID == threadID)
                    && draft.position == note.position
            }
            guard candidates.count == 1, let id = candidates.first?.1.id, matched.insert(id).inserted else { return }
        }
        guard ReviewVerdict.fingerprint(after, excluding: matched) == publication.beforeFingerprint,
              let fingerprint = ReviewVerdict.fingerprint(after) else { return }
        let record = NormalizedPublication(verdict: publication.verdict, fingerprint: fingerprint)
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
            When your review of the current head and all current discussions is finished and every warranted draft is saved, record your verdict for that exact head SHA: `no_objections` if you have no open findings, otherwise `objections`. MergeTether approves on my behalf only after a current `no_objections` verdict, with no pending drafts and every discussion resolved. A new comment or edited discussion invalidates the verdict even without a new commit. Record a new verdict after every re-review. Run the bundled standalone helper `\(command) record-verdict \(host) \(projectID) \(iid) <HEAD_SHA> <VERDICT> --username \(username) --run-id \(runID.uuidString.lowercased())` with placeholders filled in. It reads GitLab using the signed-in glab account, rechecks the account and MR head and binds the current discussion content. Its success response must include `discussionFingerprint`. No assistant plugin or MCP tool is needed. Do not hand-write a receipt without discussion evidence. Automatic approval also requires MergeTether to authenticate this exact verdict when this run finishes successfully.
            """
    }
}

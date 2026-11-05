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

    /// `reviewerID` and `publishedDrafts` let comments the reviewer published from drafts after the
    /// verdict keep it valid: the verdict is recorded while its drafts still wait for confirmation.
    func approves(
        head: String, discussions: [GitLabMergeRequestDiscussion] = [],
        reviewerID: Int? = nil, publishedDrafts: Set<String> = []
    ) -> Bool {
        guard version == 1 && verdict == .noObjections && headSHA == head,
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

/// Verdicts are written by the assistant: the Codex plugin's `record_review_verdict` tool,
/// or the shell fallback in the review instructions. They live next to the relay queue.
enum ReviewVerdictStore {
    nonisolated static let directory = URL.homeDirectory
        .appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Codex Desktop Relay/verdicts",
                   directoryHint: .isDirectory)

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
    nonisolated static func recordingInstructions(host: String, projectID: Int, iid: Int) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "merge-tether/relay.py").path ?? "<MergeTether.app>/Contents/Resources/merge-tether/relay.py"
        let command = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            When your review of the current head and all current discussions is finished and every warranted draft is saved, record your verdict for that exact head SHA: `no_objections` if you have no open findings, otherwise `objections`. MergeTether approves on my behalf only after a current `no_objections` verdict, with no pending drafts and every discussion resolved. A new comment or edited discussion invalidates the verdict even without a new commit. Record a new verdict after every re-review. Use `record_review_verdict` with host `\(host)`, projectID `\(projectID)`, iid `\(iid)`, headSHA and verdict; it binds the current GitLab discussion content automatically. Its success response must include `discussionFingerprint`; an older tool response without it needs the helper fallback. If that tool is unavailable or returns no fingerprint, run `python3 \(command) record-verdict \(host) \(projectID) \(iid) <HEAD_SHA> <VERDICT>` with placeholders filled in. Do not hand-write a receipt without discussion evidence.
            """
    }
}

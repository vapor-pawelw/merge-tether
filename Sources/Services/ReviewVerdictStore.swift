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

    func approves(head: String, discussions: [GitLabMergeRequestDiscussion] = []) -> Bool {
        guard version == 1 && verdict == .noObjections && headSHA == head,
              let current = Self.fingerprint(discussions) else { return false }
        // Older receipts remain valid only when there is no discussion content to miss.
        return discussionFingerprint.map { $0 == current } ?? discussions.flatMap(\.notes).allSatisfy { $0.system == true }
    }

    static func fingerprint(_ discussions: [GitLabMergeRequestDiscussion]) -> String? {
        var rows: [(Int, Int, String)] = []
        for note in discussions.flatMap(\.notes) where note.system != true {
            guard let id = note.id, id > 0, let authorID = note.author?.id, authorID > 0, let body = note.body else { return nil }
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

    /// Added to every review prompt so MergeTether knows when a review of a given head is finished.
    nonisolated static func recordingInstructions(host: String, projectID: Int, iid: Int) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "merge-tether/relay.py").path ?? "<MergeTether.app>/Contents/Resources/merge-tether/relay.py"
        let command = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            When your review of the current head and all current discussions is finished and every warranted draft is saved, record your verdict for that exact head SHA: `no_objections` if you have no open findings, otherwise `objections`. MergeTether approves on my behalf only after a current `no_objections` verdict, with no pending drafts and every discussion resolved. A new comment or edited discussion invalidates the verdict even without a new commit. Record a new verdict after every re-review. Use `record_review_verdict` with host `\(host)`, projectID `\(projectID)`, iid `\(iid)`, headSHA and verdict; it binds the current GitLab discussion content automatically. Its success response must include `discussionFingerprint`; an older tool response without it needs the helper fallback. If that tool is unavailable or returns no fingerprint, run `python3 \(command) record-verdict \(host) \(projectID) \(iid) <HEAD_SHA> <VERDICT>` with placeholders filled in. Do not hand-write a receipt without discussion evidence.
            """
    }
}

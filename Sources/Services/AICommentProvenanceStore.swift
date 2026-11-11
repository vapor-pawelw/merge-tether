import Foundation

/// Authorship facts for display only. These receipts never qualify a GitLab write.
enum AICommentProvenanceStore {
    struct Context: Codable, Equatable, Sendable {
        let host: String
        let username: String
        let userID: Int
        let projectID: Int
        let iid: Int

        var isValid: Bool {
            !host.isEmpty && !username.isEmpty && userID > 0 && projectID > 0 && iid > 0
        }
    }
    typealias DraftClaim = AssistantJobResult.GeneratedDraft
    private struct GeneratedDraft: Codable, Sendable {
        let version: Int
        let context: Context
        let runID: UUID
        let headSHA: String
        let draftID: Int
        let bodySHA256: String
        let discussionID: String?
        let position: GitLabDraftNote.Position?
        let resolveDiscussion: Bool?

        func matches(_ draft: GitLabDraftNote, context: Context) -> Bool {
            version == 1 && self.context == context && context.isValid && AICommentProvenanceStore.validHead(headSHA)
                && draft.id == draftID && draft.authorID == context.userID
                && draft.note.map(AICommentAssessmentStore.digest) == bodySHA256
                && draft.discussionID == discussionID && draft.position == position
                && draft.resolveDiscussion == resolveDiscussion
        }
    }
    fileprivate struct PublishedNote: Codable, Sendable {
        let version: Int
        let context: Context
        let runID: UUID
        let draftID: Int
        let noteID: Int
        let discussionID: String
        let bodySHA256: String
    }
    struct Snapshot: Sendable {
        fileprivate let context: Context
        fileprivate let notes: [Int: PublishedNote]

        func contains(_ note: GitLabMergeRequestDiscussion.Note, discussionID: String?) -> Bool {
            guard context.isValid, note.system != true, let id = note.id, id > 0,
                  note.author?.id == context.userID, note.author?.username == context.username,
                  let body = note.body, !body.isEmpty, let record = notes[id] else { return false }
            return record.version == 1 && record.context == context && record.noteID == id && record.draftID > 0 && record.discussionID == discussionID
                && record.bodySHA256 == AICommentAssessmentStore.digest(body)
        }
    }

    struct PreparedPublication: Sendable {
        fileprivate let context: Context
        fileprivate let drafts: [GitLabDraftNote]
        fileprivate let generated: [Int: UUID]
    }

    struct Publication: Sendable {
        fileprivate let context: Context
        fileprivate let drafts: [GitLabDraftNote]
        fileprivate let generated: [Int: UUID]
        fileprivate let beforeIDs: Set<Int>
    }

    nonisolated static let directory = ReviewVerdictStore.directory.deletingLastPathComponent()
        .appending(path: "display-comment-origins")

    nonisolated static func recordGenerated(_ claims: [DraftClaim], baseline: [GitLabDraftNote], current: [GitLabDraftNote],
        context: Context, runID: UUID, headSHA: String, in directory: URL = directory) throws {
        guard context.isValid, validHead(headSHA), claims.count <= 100,
              Set(claims.map(\.id)).count == claims.count,
              baseline.allSatisfy({ ($0.id ?? 0) > 0 && $0.authorID == context.userID && $0.note != nil }),
              Set(baseline.compactMap(\.id)).count == baseline.count else { return }
        for claim in claims where claim.id > 0 {
            let matches = current.filter { $0.id == claim.id }
            let previous = baseline.filter { $0.id == claim.id }
            guard matches.count == 1, previous.count <= 1, let draft = matches.first,
                  draft.authorID == context.userID, let body = draft.note, !body.isEmpty,
                  AICommentAssessmentStore.digest(body) == claim.bodySHA256,
                  previous.first?.note.map(AICommentAssessmentStore.digest) != claim.bodySHA256 else { continue }
            try remember(draft, context: context, runID: runID, headSHA: headSHA, in: directory)
        }
    }

    /// The caller supplies only receipts already authenticated as belonging to app-owned runs.
    nonisolated static func rememberSealed(_ draft: GitLabDraftNote, proof: FollowUpVerification,
        context: Context, request: GitLabMergeRequest, in directory: URL = directory) throws {
        let user = GitLabAuthenticatedUser(id: context.userID, username: context.username)
        guard context.isValid, proof.owns(draft, request: request, host: context.host, user: user) else { return }
        try remember(draft, context: context, runID: proof.runID, headSHA: proof.headSHA, in: directory)
    }

    private nonisolated static func remember(_ draft: GitLabDraftNote, context: Context, runID: UUID,
        headSHA: String, in directory: URL) throws {
        guard let id = draft.id, id > 0, let body = draft.note, !body.isEmpty else { return }
        let record = GeneratedDraft(version: 1, context: context, runID: runID, headSHA: headSHA, draftID: id,
            bodySHA256: AICommentAssessmentStore.digest(body), discussionID: draft.discussionID,
            position: draft.position, resolveDiscussion: draft.resolveDiscussion)
        try write(record, to: file(kind: "drafts", id: id, context: context, in: directory))
    }

    nonisolated static func generation(for draft: GitLabDraftNote, context: Context, in directory: URL = directory,
                                      legacyDirectory: URL? = nil) -> UUID? {
        guard context.isValid, let id = draft.id, id > 0 else { return nil }
        for source in displayDirectories(directory, legacyDirectory: legacyDirectory) {
            if let record: GeneratedDraft = read(file(kind: "drafts", id: id, context: context, in: source)),
               record.matches(draft, context: context) { return record.runID }
        }
        return nil
    }

    nonisolated static func preparePublication(_ drafts: [GitLabDraftNote], context: Context,
        request: GitLabMergeRequest? = nil, proofs: [FollowUpVerification] = [], in directory: URL = directory) -> PreparedPublication? {
        guard context.isValid, !drafts.isEmpty,
              drafts.allSatisfy({ ($0.id ?? 0) > 0 && $0.authorID == context.userID && $0.note?.isEmpty == false }),
              Set(drafts.compactMap(\.id)).count == drafts.count else { return nil }
        let user = GitLabAuthenticatedUser(id: context.userID, username: context.username)
        var generated: [Int: UUID] = [:]
        for draft in drafts {
            guard let id = draft.id else { continue }
            if let run = generation(for: draft, context: context, in: directory) { generated[id] = run }
            else if let request, let proof = proofs.first(where: { $0.owns(draft, request: request, host: context.host, user: user) }) {
                try? rememberSealed(draft, proof: proof, context: context, request: request, in: directory)
                if let run = generation(for: draft, context: context, in: directory) { generated[id] = run }
            }
        }
        guard !generated.isEmpty else { return nil }
        return .init(context: context, drafts: drafts, generated: generated)
    }

    nonisolated static func capturePublication(_ drafts: [GitLabDraftNote], context: Context,
        before: [GitLabMergeRequestDiscussion], in directory: URL = directory) -> Publication? {
        guard let prepared = preparePublication(drafts, context: context, in: directory) else { return nil }
        return capturePublication(prepared, before: before)
    }

    nonisolated static func capturePublication(_ prepared: PreparedPublication,
        before: [GitLabMergeRequestDiscussion]) -> Publication? {
        let notes = before.flatMap(\.notes)
        let ids = notes.compactMap(\.id)
        guard ids.count == notes.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              ReviewVerdict.fingerprint(before) != nil else { return nil }
        return .init(context: prepared.context, drafts: prepared.drafts, generated: prepared.generated, beforeIDs: Set(ids))
    }

    nonisolated static func recordPublished(_ publication: Publication, after: [GitLabMergeRequestDiscussion],
        in directory: URL = directory) throws {
        let context = publication.context
        let notes = after.flatMap { thread in thread.notes.map { (thread.id, $0) } }
        let ids = notes.compactMap { $0.1.id }
        guard ids.count == notes.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              publication.beforeIDs.isSubset(of: Set(ids)), ReviewVerdict.fingerprint(after) != nil else { return }
        let added = notes.filter { _, note in
            note.system != true && note.author?.id == context.userID
                && note.id.map { !publication.beforeIDs.contains($0) } == true
        }
        guard added.count == publication.drafts.count else { return }
        var records: [PublishedNote] = []
        var matched: Set<Int> = []
        for draft in publication.drafts {
            let candidates = added.filter { discussionID, note in
                note.author?.username == context.username && note.body == draft.note
                    && (draft.discussionID == nil || draft.discussionID == discussionID)
                    && (draft.position == nil || draft.position == note.position)
            }
            guard candidates.count == 1, let match = candidates.first,
                  let discussionID = match.0, !discussionID.isEmpty else { return }
            let note = match.1
            guard let noteID = note.id, let body = note.body,
                  matched.insert(noteID).inserted, let draftID = draft.id else { return }
            if let runID = publication.generated[draftID] {
                records.append(.init(version: 1, context: context, runID: runID, draftID: draftID,
                    noteID: noteID, discussionID: discussionID, bodySHA256: AICommentAssessmentStore.digest(body)))
            }
        }
        for record in records {
            try write(record, to: file(kind: "notes", id: record.noteID, context: context, in: directory))
        }
    }

    nonisolated static func snapshot(context: Context, in directory: URL = directory, legacyDirectory: URL? = nil) -> Snapshot {
        guard context.isValid else { return .init(context: context, notes: [:]) }
        var notes: [Int: PublishedNote] = [:]
        for source in displayDirectories(directory, legacyDirectory: legacyDirectory).reversed() {
            let folder = file(kind: "notes", id: 0, context: context, in: source).deletingLastPathComponent()
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]),
                  files.count <= 10_000 else { continue }
            for url in files where url.pathExtension == "json" {
                guard let record: PublishedNote = read(url), record.context == context, record.version == 1,
                      record.noteID > 0, url.deletingPathExtension().lastPathComponent == String(record.noteID) else { continue }
                notes[record.noteID] = record
            }
        }
        return .init(context: context, notes: notes)
    }

    private nonisolated static func displayDirectories(_ directory: URL, legacyDirectory: URL?) -> [URL] {
        if let legacyDirectory { return [directory, legacyDirectory] }
        guard directory.standardizedFileURL == Self.directory.standardizedFileURL,
              InstallationStorage.current.root != InstallationStorage.current.legacy.root else { return [directory] }
        return [directory, InstallationStorage.current.legacyEvidence.appending(path: "display-comment-origins")]
    }

    nonisolated static func isGenerated(_ note: GitLabMergeRequestDiscussion.Note, discussionID: String?, context: Context,
        in directory: URL = directory) -> Bool {
        snapshot(context: context, in: directory).contains(note, discussionID: discussionID)
    }

    private nonisolated static func validHead(_ head: String) -> Bool {
        [40, 64].contains(head.utf8.count) && head.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private nonisolated static func file(kind: String, id: Int, context: Context, in directory: URL) -> URL {
        let fields = [context.host, context.username, String(context.userID), String(context.projectID), String(context.iid)]
        let scope = AICommentAssessmentStore.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
        return directory.appending(path: scope).appending(path: kind).appending(path: "\(id).json")
    }

    private nonisolated static func read<T: Decodable>(_ url: URL) -> T? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
              let data = try? Data(contentsOf: url), data.count < 16_384 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

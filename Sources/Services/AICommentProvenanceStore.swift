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

        /// The draft that became this note, when the publication was recorded or reconciled.
        func draftID(forNote id: Int) -> Int? { notes[id]?.draftID }

        func contains(_ note: GitLabMergeRequestDiscussion.Note, discussionID: String?) -> Bool {
            guard context.isValid, note.system != true, let id = note.id, id > 0,
                  note.author?.id == context.userID, note.author?.username == context.username,
                  let body = note.body, !body.isEmpty, let record = notes[id] else { return false }
            return record.version == 1 && record.context == context && record.noteID == id && record.draftID > 0 && record.discussionID == discussionID
                && record.bodySHA256 == AICommentAssessmentStore.digest(body)
        }
    }

    /// App-only Markdown written by the agent for the user. It is read from local files for display
    /// and never enters a draft body, publication request or any other GitLab write.
    struct ExtraContexts: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let bodySHA256: String
            let markdown: String
        }
        var drafts: [Int: Entry] = [:]
        var notes: [Int: String] = [:]

        static let empty = ExtraContexts()
        var isEmpty: Bool { drafts.isEmpty && notes.isEmpty }

        /// A draft edited after generation no longer matches the text the context explained.
        func forDraft(_ draft: GitLabDraftNote) -> String? {
            guard let id = draft.id, let entry = drafts[id], let body = draft.note,
                  AICommentAssessmentStore.digest(body) == entry.bodySHA256 else { return nil }
            return entry.markdown
        }

        func forNote(_ id: Int?) -> String? { id.flatMap { notes[$0] } }

        /// Only a note whose current text still matches its publication receipt keeps the context.
        mutating func removeNote(_ id: Int) { notes[id] = nil }
    }

    private struct ExtraContextRecord: Codable, Sendable {
        let version: Int
        let context: Context
        let draftID: Int
        let bodySHA256: String
        let markdown: String
    }

    nonisolated static let extraContextLimit = 4_000

    nonisolated static func normalizedExtraContext(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > extraContextLimit ? String(trimmed.prefix(extraContextLimit)) : trimmed
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
            let contextFile = file(kind: "context", id: claim.id, context: context, in: directory)
            if let markdown = normalizedExtraContext(claim.extraContext) {
                // Display-only: a failed write never blocks the authorship receipt above.
                try? write(ExtraContextRecord(version: 1, context: context, draftID: claim.id,
                    bodySHA256: claim.bodySHA256, markdown: markdown), to: contextFile)
            } else {
                try? FileManager.default.removeItem(at: contextFile)
            }
        }
    }

    /// Loads the agent's app-only explanations for current drafts and the notes published from them.
    nonisolated static func extraContexts(context: Context, snapshot: Snapshot? = nil, in directory: URL = directory) -> ExtraContexts {
        guard context.isValid else { return .empty }
        let folder = file(kind: "context", id: 0, context: context, in: directory).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]),
              files.count <= 10_000 else { return .empty }
        var result = ExtraContexts()
        for url in files where url.pathExtension == "json" {
            guard let record: ExtraContextRecord = read(url, limit: 32_768), record.version == 1, record.context == context,
                  record.draftID > 0, url.deletingPathExtension().lastPathComponent == String(record.draftID),
                  let markdown = normalizedExtraContext(record.markdown) else { continue }
            result.drafts[record.draftID] = .init(bodySHA256: record.bodySHA256, markdown: markdown)
        }
        if let snapshot, snapshot.context == context {
            for (noteID, note) in snapshot.notes {
                guard let entry = result.drafts[note.draftID], entry.bodySHA256 == note.bodySHA256 else { continue }
                result.notes[noteID] = entry.markdown
            }
        }
        return result
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
                    && AICommentProvenanceStore.positionMatches(draft.position, note.position, reply: draft.discussionID != nil)
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

    /// GitLab returns replies with an empty `position` object; their thread, not the diff anchor, identifies them.
    private nonisolated static func positionMatches(_ draft: GitLabDraftNote.Position?,
        _ note: GitLabDraftNote.Position?, reply: Bool) -> Bool {
        guard !reply, let draft, draft.isAnchored else { return true }
        return draft == note
    }

    /// Links app-generated drafts to their published notes when the publication receipt was not recorded.
    /// A note qualifies only when it is the single exact-body note by this account in the draft's thread
    /// (or a new thread it starts), and no other generated draft claims it.
    nonisolated static func reconcile(_ discussions: [GitLabMergeRequestDiscussion], context: Context,
        in directory: URL = directory) -> Snapshot {
        let existing = snapshot(context: context, in: directory)
        guard context.isValid else { return existing }
        let folder = file(kind: "drafts", id: 0, context: context, in: directory).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]),
              files.count <= 10_000 else { return existing }
        let drafts: [GeneratedDraft] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let record: GeneratedDraft = read(url), record.version == 1, record.context == context, record.draftID > 0,
                  url.deletingPathExtension().lastPathComponent == String(record.draftID) else { return nil }
            return record
        }
        let linkedDrafts = Set(existing.notes.values.map(\.draftID))
        var claims: [Int: [PublishedNote]] = [:]
        for record in drafts where !linkedDrafts.contains(record.draftID) {
            var candidates: [PublishedNote] = []
            for thread in discussions {
                guard let threadID = thread.id, !threadID.isEmpty else { continue }
                let published = thread.notes.filter { $0.system != true }
                for (index, note) in published.enumerated() {
                    guard let id = note.id, id > 0, existing.notes[id] == nil,
                          note.author?.id == context.userID, note.author?.username == context.username,
                          let body = note.body, !body.isEmpty, AICommentAssessmentStore.digest(body) == record.bodySHA256 else { continue }
                    let placed = record.discussionID.map { $0 == threadID }
                        ?? (index == 0 && positionMatches(record.position, note.position, reply: false))
                    guard placed else { continue }
                    candidates.append(.init(version: 1, context: context, runID: record.runID, draftID: record.draftID,
                        noteID: id, discussionID: threadID, bodySHA256: record.bodySHA256))
                }
            }
            if candidates.count == 1, let match = candidates.first { claims[match.noteID, default: []].append(match) }
        }
        var notes = existing.notes
        for (noteID, records) in claims where records.count == 1 {
            guard let record = records.first else { continue }
            do { try write(record, to: file(kind: "notes", id: noteID, context: context, in: directory)) }
            catch { continue }
            notes[noteID] = record
        }
        return .init(context: context, notes: notes)
    }

    /// Display evidence is only useful while the MR is open; terminal MRs drop their whole scope.
    nonisolated static func removeMergeRequest(_ context: Context, in directory: URL = directory) {
        guard context.isValid else { return }
        let scope = file(kind: "notes", id: 0, context: context, in: directory)
            .deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: scope)
    }

    /// Removes scopes with no write since `cutoff`, covering MRs whose closure the app never observed.
    nonisolated static func pruneInactive(before cutoff: Date, in directory: URL = directory) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let manager = FileManager.default
        guard let scopes = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for scope in scopes where (try? scope.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && scope.lastPathComponent.utf8.count == 64 {
            let files = manager.enumerator(at: scope, includingPropertiesForKeys: keys)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
            let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            if newest.map({ $0 < cutoff }) ?? true { try? manager.removeItem(at: scope) }
        }
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

    private nonisolated static func read<T: Decodable>(_ url: URL, limit: Int = 16_384) -> T? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < limit,
              let data = try? Data(contentsOf: url), data.count < limit else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

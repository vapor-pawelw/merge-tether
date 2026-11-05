import Foundation

/// Content-bound evidence produced by the read-only verifier after a tested commit reached GitLab.
struct FollowUpVerification: Codable, Sendable {
    struct FileEvidence: Codable, Equatable, Sendable { let path: String; let sha256: String }
    struct DraftEvidence: Codable, Sendable { let id: Int; let bodySHA256: String }
    let version: Int
    let sealed: Bool
    let verificationID: UUID
    let runID: UUID
    let host: String
    let projectID: Int
    let iid: Int
    let username: String
    let userID: Int
    let headSHA: String
    let sourceProjectID: Int
    let sourceBranch: String
    let files: [FileEvidence]
    let drafts: [DraftEvidence]

    func covers(_ draft: GitLabDraftNote, request: GitLabMergeRequest, host: String, user: GitLabAuthenticatedUser, runID: UUID) -> Bool {
        version == 1 && sealed && self.runID == runID && self.host == host && projectID == request.projectID && iid == request.iid
            && username == user.username && userID == user.id && request.author.id == user.id && request.state == "opened"
            && headSHA == request.sha && sourceProjectID == request.sourceProjectID && sourceBranch == request.sourceBranch
            && draft.authorID == user.id && !files.isEmpty && files.count <= 20
            && drafts.contains { $0.id == draft.id && $0.bodySHA256 == AICommentAssessmentStore.digest(draft.note ?? "") }
    }
}

enum FollowUpVerificationStore {
    struct Run: Encodable {
        let version = 1
        let kind = "author_follow_up"
        let runID: UUID
        let host: String
        let projectID: Int
        let iid: Int
        let username: String
        let pushAllowed: Bool
    }

    nonisolated static let directory = ReviewVerdictStore.directory.deletingLastPathComponent()

    nonisolated static func recordURL(kind: String, work: AssistantAutomationRunner.MergeRequestWork, username: String, in directory: URL) -> URL {
        directory.appending(path: kind).appending(path: work.host).appending(path: "\(work.projectID)-\(work.iid)-\(username).json")
    }

    @MainActor
    static func latestRun(for work: AssistantAutomationRunner.MergeRequestWork, username: String, settings: SettingsManager) -> AssistantAutomationRunner.Handoff? {
        settings.assistantHandoffs.filter { $0.key.work == work && $0.key.username == username && $0.followUpPushAllowed != nil }
            .max { $0.createdAt < $1.createdAt }
    }

    @MainActor
    static func register(_ handoff: AssistantAutomationRunner.Handoff, pushAllowed: Bool, in directory: URL = directory) {
        guard let permission = handoff.followUpPushAllowed else { return }
        let work = handoff.key.work
        let record = Run(runID: handoff.id, host: work.host, projectID: work.projectID, iid: work.iid,
                         username: handoff.key.username, pushAllowed: pushAllowed && permission)
        let url = recordURL(kind: "follow-up-runs", work: work, username: handoff.key.username, in: directory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        } catch {
            Log.monitor.error("Could not register author follow-up verification: \(String(describing: error), privacy: .private)")
        }
    }

    @MainActor
    static func synchronizeRuns(settings: SettingsManager) {
        var newest: [String: AssistantAutomationRunner.Handoff] = [:]
        for handoff in settings.assistantHandoffs where handoff.followUpPushAllowed != nil {
            let key = "\(handoff.key.work.host)/\(handoff.key.work.projectID)/\(handoff.key.work.iid)/\(handoff.key.username)"
            if newest[key].map({ $0.createdAt < handoff.createdAt }) ?? true { newest[key] = handoff }
        }
        for handoff in newest.values { register(handoff, pushAllowed: settings.automation.allowFollowUpPush) }
    }

    nonisolated static func receipt(work: AssistantAutomationRunner.MergeRequestWork, username: String, in directory: URL) -> FollowUpVerification? {
        let url = recordURL(kind: "follow-up-verifications", work: work, username: username, in: directory)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1000000,
              let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(FollowUpVerification.self, from: data)
        else { return nil }
        return receipt
    }

    nonisolated static func recordingInstructions(work: AssistantAutomationRunner.MergeRequestWork, runID: UUID) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "merge-tether/author_follow_up.py").path ?? "<MergeTether.app>/Contents/Resources/merge-tether/author_follow_up.py"
        return """
        Mandatory author follow-up order, even without installed MR skills: implement justified fixes → test → commit → push the detached worktree HEAD to the exact verified remote MR source branch → re-fetch MR HEAD and verify the claimed source/test content remotely → only then save response drafts about those fixes. Preserve other local checkouts, worktrees and local branch refs; that isolation explicitly DOES NOT prohibit the authorized remote `HEAD:refs/heads/<source-branch>` push. Never treat a local commit as delivery.
        At the start AND immediately before any push, call `author_follow_up_status` with host/projectID/iid and this runID. If the current permission is off or the run has been superseded, stop with a chat-only report, save no completion drafts and do not push, regardless of earlier chat instructions. Check the expected remote source head before pushing and do not overwrite unexpected new commits.
        Before drafting, call `verify_author_follow_up` with host `\(work.host)`, projectID `\(work.projectID)`, iid `\(work.iid)`, runID `\(runID.uuidString.lowercased())`, the exact tested/pushed headSHA, and filesJSON: a JSON array of {path,sha256} for the actual committed source/test files backing the replies. Compute hashes from `git show <tested-sha>:<path>`, not uncommitted working files. The verifier reads GitLab and compares remote content. On success, save/re-fetch warranted private GitLab drafts, then call `record_author_follow_up_drafts` with host/projectID/iid, the returned verificationID and draftIDsJSON containing only those new or refreshed draft IDs. Unchanged legacy/user-created drafts are not proof and cannot be adopted automatically. When re-verifying later in this same run, include any still-pending drafts previously sealed in this run as well; their unchanged bodies can be re-bound only after fresh remote verification. The publisher checks account, run, remote head, source branch, file content and exact draft bodies again. If verification or a required push fails, is pending, or is disabled, save NO response drafts for that unfinished run; report the pending work in chat only. Do not publish comments yourself or expand existing publication permissions.
        If the tools are unavailable, check the current permission with `/usr/bin/python3 -B "\(helper)" status --host \(work.host) --project-id \(work.projectID) --iid \(work.iid) --run-id \(runID.uuidString.lowercased())` before editing and again before pushing. Use the bundled read-only helper for proof (it never pushes or publishes): `/usr/bin/python3 -B "\(helper)" verify --host \(work.host) --project-id \(work.projectID) --iid \(work.iid) --run-id \(runID.uuidString.lowercased()) --head-sha <tested-pushed-sha> --evidence-file <files.json>`, then after saving/re-reading drafts run the same helper with `seal --host \(work.host) --project-id \(work.projectID) --iid \(work.iid) --verification-id <returned-id> --draft-ids '[<draft-ids>]'`. Follow installed MR skills within these permissions; an explicit review-only/local-only request keeps the result in chat.
        """
    }
}

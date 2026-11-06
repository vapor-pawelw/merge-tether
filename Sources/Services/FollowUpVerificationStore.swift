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
    var discussionFingerprint: String? = nil

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
    static func canPush(_ handoff: AssistantAutomationRunner.Handoff, configuration: AutomationSettings) -> Bool {
        guard handoff.execution?.state.isActive == true, handoff.followUpPushAllowed == true,
              configuration.allowFollowUpPush, handoff.key.assistant == configuration.assistant else { return false }
        let work = handoff.key.work
        let target = MRAutomationScope.Target(host: work.host, username: handoff.key.username,
                                             projectID: work.projectID, iid: work.iid)
        return handoff.manual == true || configuration.scope.resolve(target).active
    }

    @MainActor
    static func register(_ handoff: AssistantAutomationRunner.Handoff, settings: SettingsManager, in directory: URL = directory) {
        guard handoff.followUpPushAllowed != nil else { return }
        let work = handoff.key.work
        let record = Run(runID: handoff.id, host: work.host, projectID: work.projectID, iid: work.iid,
                         username: handoff.key.username, pushAllowed: canPush(handoff, configuration: settings.automation))
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
    static func synchronizeRuns(settings: SettingsManager, in directory: URL = directory) {
        var newest: [String: AssistantAutomationRunner.Handoff] = [:]
        for handoff in settings.assistantHandoffs where handoff.followUpPushAllowed != nil {
            let key = "\(handoff.key.work.host)/\(handoff.key.work.projectID)/\(handoff.key.work.iid)/\(handoff.key.username)"
            if newest[key].map({ $0.createdAt < handoff.createdAt }) ?? true { newest[key] = handoff }
        }
        for handoff in newest.values { register(handoff, settings: settings, in: directory) }
    }

    nonisolated static func receipt(work: AssistantAutomationRunner.MergeRequestWork, username: String, in directory: URL) -> FollowUpVerification? {
        let url = recordURL(kind: "follow-up-verifications", work: work, username: username, in: directory)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1000000,
              let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(FollowUpVerification.self, from: data)
        else { return nil }
        return receipt
    }

    nonisolated static func recordingInstructions(work: AssistantAutomationRunner.MergeRequestWork, runID: UUID) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "Automation/author_follow_up.py").path ?? "<MergeTether.app>/Contents/Resources/Automation/author_follow_up.py"
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "/usr/bin/python3 -B \(quoted)"
        let target = "--host \(work.host) --project-id \(work.projectID) --iid \(work.iid)"
        let run = runID.uuidString.lowercased()
        return """
        Mandatory author follow-up order: implement justified fixes → test → commit → push the detached worktree HEAD to the exact verified remote MR source branch → re-fetch MR HEAD and verify the claimed source/test content remotely → only then save response drafts about those fixes. Preserve other local checkouts, worktrees and local branch refs; isolation explicitly DOES NOT prohibit the authorized remote `HEAD:refs/heads/<source-branch>` push. Never treat a local commit as delivery.
        Use the bundled standalone read-only proof helper; it never pushes or publishes and requires no assistant plugin or MCP tools.
        At the start AND immediately before any push, run `\(command) status \(target) --run-id \(run)`. If permission is off or the run has been superseded, stop, save no completion drafts and do not push regardless of earlier instructions. Check the expected remote source head before pushing and do not overwrite unexpected new commits.
        Before implementing, read and assess every current non-system discussion note and retain the `discussionFingerprint` from that status result for the snapshot you assessed. A later permission check must not silently replace the assessed snapshot. If comments change, assess all current feedback again before using its new fingerprint.
        Before drafting, create an evidence JSON file {discussionFingerprint,files}, using the assessed fingerprint and an array of {path,sha256} for the actual committed source/test files backing the replies. Compute hashes from `git show <tested-sha>:<path>`, not uncommitted working files. Run `\(command) verify \(target) --run-id \(run) --head-sha <tested-pushed-sha> --evidence-file <evidence.json>`. The verifier reads GitLab and compares remote content.
        Only after verification succeeds, save and re-fetch warranted private GitLab drafts. Then run `\(command) seal \(target) --verification-id <returned-id> --draft-ids '[<draft-ids>]'`, containing only those new or refreshed draft IDs. Unchanged legacy/user-created drafts cannot be adopted automatically. When re-verifying in this same run, include any still-pending drafts previously sealed by this run; unchanged bodies can be re-bound only after fresh remote verification.
        The publisher checks account, run, remote head, source branch, file content and exact draft bodies again. If sealing reports changed discussions, re-read and assess the new feedback, re-verify with its fingerprint, then explicitly edit or recreate every unsealed draft from that failed attempt before sealing. If verification or a required push fails, is pending, or is disabled, save NO response drafts for that unfinished run; report pending work only in the in-app result. Do not publish comments yourself or expand existing publication permissions. Follow applicable repository instructions within these permissions; an explicit review-only/local-only request keeps the result local.
        """
    }
}

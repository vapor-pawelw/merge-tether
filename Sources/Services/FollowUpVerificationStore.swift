import Foundation

/// Content-bound evidence produced by the read-only verifier after a tested commit reached GitLab.
struct FollowUpVerification: Codable, Equatable, Sendable {
    struct FileEvidence: Codable, Equatable, Sendable { let path: String; let sha256: String }
    struct DraftEvidence: Codable, Equatable, Sendable { let id: Int; let bodySHA256: String }
    struct RepairIntent: Codable, Equatable, Sendable { let draftID: Int; let bodySHA256: String }
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
    var semanticContextFingerprint: String? = nil
    var recoveryContextFingerprint: String? = nil
    var repairIntent: RepairIntent? = nil

    /// Historical identity establishes ownership only; fresh verification must establish current truth.
    func owns(_ draft: GitLabDraftNote, request: GitLabMergeRequest, host: String, user: GitLabAuthenticatedUser) -> Bool {
        version == 1 && sealed && self.host == host && projectID == request.projectID && iid == request.iid
            && username == user.username && userID == user.id && request.author.id == user.id && request.state == "opened"
            && sourceProjectID == request.sourceProjectID && sourceBranch == request.sourceBranch
            && draft.authorID == user.id && !files.isEmpty && files.count <= 20
            && drafts.contains { $0.id == draft.id && $0.bodySHA256 == AICommentAssessmentStore.digest(draft.note ?? "") }
    }

    func covers(_ draft: GitLabDraftNote, request: GitLabMergeRequest, host: String, user: GitLabAuthenticatedUser, runID: UUID) -> Bool {
        owns(draft, request: request, host: host, user: user) && self.runID == runID
            && headSHA == request.sha
            && (semanticContextFingerprint == nil || semanticContextFingerprint == request.semanticContextFingerprint)
            && (recoveryContextFingerprint == nil || recoveryContextFingerprint == request.draftProofRecoveryContextFingerprint)
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
        var draftAutomationAllowed = false
        var repairDrafts: [FollowUpVerification.DraftEvidence]? = nil
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
              configuration.allowAutomaticPublicActions, configuration.allowFollowUpPush,
              handoff.key.assistant == configuration.assistant else { return false }
        let work = handoff.key.work
        let target = MRAutomationScope.Target(host: work.host, username: handoff.key.username,
                                             projectID: work.projectID, iid: work.iid)
        return handoff.manual == true || configuration.scope.resolve(target).active
    }

    @MainActor
    static func register(_ handoff: AssistantAutomationRunner.Handoff, settings: SettingsManager, in directory: URL = directory) {
        guard handoff.followUpPushAllowed != nil else { return }
        let work = handoff.key.work
        let target = MRAutomationScope.Target(host: work.host, username: handoff.key.username,
            projectID: work.projectID, iid: work.iid)
        let record = Run(runID: handoff.id, host: work.host, projectID: work.projectID, iid: work.iid,
                         username: handoff.key.username, pushAllowed: canPush(handoff, configuration: settings.automation),
                         draftAutomationAllowed: handoff.manual == true || settings.automation.scope.allowsDraftAutomation(for: target),
                         repairDrafts: handoff.draftRepair.map { [.init(id: $0.draftID, bodySHA256: $0.bodySHA256)] })
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

    @MainActor
    static func publicationReceipts(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                    settings: SettingsManager, in directory: URL = directory) -> [FollowUpVerification] {
        guard settings.automation.allowAutomaticPublicActions, settings.automation.allowFollowUpPush,
              settings.automation.scope.resolve(.init(host: work.host, username: username,
                  projectID: work.projectID, iid: work.iid)).active else { return [] }
        return claimReceipts(work: work, username: username, settings: settings, in: directory)
    }

    /// Factual readiness is retained when delivery/publication permissions are turned off.
    @MainActor
    static func claimReceipts(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                              settings: SettingsManager, in directory: URL = directory) -> [FollowUpVerification] {
        recoveredReceipts(work: work, username: username, settings: settings, in: directory)
    }

    struct ReceiptReadInput: Sendable {
        let handoffs: [AssistantAutomationRunner.Handoff]
        let events: [MRAutomationEvent]
        let assistant: AutomationAssistant
        let authenticatedRecoveries: [String: Data]
        var legacyEvidenceDirectory: URL? = nil
    }

    @MainActor
    static func receiptReadInput(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                 settings: SettingsManager, in directory: URL = directory) -> ReceiptReadInput {
        let folder = recordURL(kind: "follow-up-proof-recoveries", work: work, username: username, in: directory).deletingPathExtension()
        let paths = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if !paths.isEmpty && !AssistantJobJournal.isKeyReady {
            Task { _ = await AssistantJobJournal.loadKey() }
        }
        var authenticated: [String: Data] = [:]
        for path in paths {
            guard path.pathExtension == "json", (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_500_000,
                  let data = try? Data(contentsOf: path),
                  let payload = AssistantJobJournal.authenticatedEvidence(data, context: "follow-up-proof-recovery") else { continue }
            authenticated[path.lastPathComponent] = payload
        }
        let legacy = directory.standardizedFileURL == Self.directory.standardizedFileURL
            && InstallationStorage.current.root != InstallationStorage.current.legacy.root
            ? InstallationStorage.current.legacy.evidence : nil
        return .init(handoffs: settings.assistantHandoffs.filter { $0.key.work == work && $0.key.username == username },
              events: settings.automationEvents, assistant: settings.automation.assistant,
              authenticatedRecoveries: authenticated, legacyEvidenceDirectory: legacy)
    }

    @MainActor
    static func contextReceipts(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                settings: SettingsManager, in directory: URL = directory) -> [FollowUpVerification] {
        contextReceipts(work: work, username: username,
            input: receiptReadInput(work: work, username: username, settings: settings, in: directory), in: directory)
    }

    nonisolated static func contextReceipts(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                           input: ReceiptReadInput, in directory: URL) -> [FollowUpVerification] {
        let runs = input.handoffs.filter {
            $0.key.work == work && $0.key.username == username && $0.followUpPushAllowed != nil
        }
        let origins = runs.filter { origin in
            origin.followUpPushAllowed == true && origin.execution?.state == .succeeded
                && origin.key.assistant == input.assistant
                && !runs.contains { $0.createdAt > origin.createdAt && $0.execution?.state != .succeeded }
        }
        let originIDs = Set(origins.map(\.id))
        let recovered = recoveryRecords(work: work, username: username, input: input, in: directory).map(\.proof)
        guard !originIDs.isEmpty else { return recovered }
        var candidates: [FollowUpVerification] = []
        let latest = recordURL(kind: "follow-up-verifications", work: work, username: username, in: directory)
        if let proof = readPublicationReceipt(at: latest) { candidates.append(proof) }
        let archive = recordURL(kind: "follow-up-verifications-archive", work: work, username: username,
                                in: directory).deletingPathExtension()
        for path in (try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []
            where path.pathExtension == "json" {
            if let proof = readPublicationReceipt(at: path),
               UUID(uuidString: path.deletingPathExtension().lastPathComponent) == proof.verificationID {
                candidates.append(proof)
            }
        }
        // Legacy helpers returned a machine receipt in the exact app-owned run directory.
        // Recover that receipt only for its known successful origin, never from worker prose.
        for origin in origins {
            let folder = directory.deletingLastPathComponent().appending(path: "Assistant Runs/\(origin.id.uuidString)")
            guard let workingDirectory = origin.execution?.workingDirectory,
                  URL(fileURLWithPath: workingDirectory).standardizedFileURL == folder.standardizedFileURL else { continue }
            let artifact = folder.appending(path: "seal-receipt.json")
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? artifact.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let proof = readPublicationReceipt(at: artifact), proof.runID == origin.id else { continue }
            candidates.append(proof)
        }
        var proofs: [UUID: FollowUpVerification] = [:]
        var ambiguous: Set<UUID> = []
        for proof in candidates where originIDs.contains(proof.runID) && proof.host == work.host
            && proof.projectID == work.projectID && proof.iid == work.iid && proof.username == username {
            if let existing = proofs[proof.verificationID], existing != proof {
                ambiguous.insert(proof.verificationID)
            } else { proofs[proof.verificationID] = proof }
        }
        return (Array(proofs.values.filter { !ambiguous.contains($0.verificationID) }) + recovered)
            .sorted { $0.verificationID.uuidString < $1.verificationID.uuidString }
    }

    private nonisolated static func readPublicationReceipt(at path: URL, requiresFingerprint: Bool = true) -> FollowUpVerification? {
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: path),
              let proof = try? JSONDecoder().decode(FollowUpVerification.self, from: data),
              proof.version == 1, proof.sealed, proof.userID > 0, proof.sourceProjectID > 0,
              !proof.sourceBranch.isEmpty, isHex(proof.headSHA, lengths: [40, 64]),
              (!requiresFingerprint || proof.discussionFingerprint.map({ isHex($0, lengths: [64]) }) == true),
              proof.discussionFingerprint.map({ isHex($0, lengths: [64]) }) != false,
              proof.semanticContextFingerprint.map({ isHex($0, lengths: [64]) }) != false,
              proof.recoveryContextFingerprint.map({ isHex($0, lengths: [64]) }) != false,
              !proof.files.isEmpty, proof.files.count <= 20, !proof.drafts.isEmpty, proof.drafts.count <= 100,
              Set(proof.files.map(\.path)).count == proof.files.count,
              Set(proof.drafts.map(\.id)).count == proof.drafts.count,
              proof.files.allSatisfy({ file in
                  !file.path.isEmpty && !file.path.hasPrefix("/")
                      && file.path.split(separator: "/", omittingEmptySubsequences: false)
                          .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
                      && !file.path.unicodeScalars.contains { $0.value < 32 }
                      && isHex(file.sha256, lengths: [64])
              }), proof.drafts.allSatisfy({ $0.id > 0 && isHex($0.bodySHA256, lengths: [64]) }) else { return nil }
        return proof
    }

    private nonisolated static func isHex(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    nonisolated static func recordingInstructions(work: AssistantAutomationRunner.MergeRequestWork, runID: UUID) -> String {
        let helper = Bundle.main.resourceURL?.appending(path: "Automation/author_follow_up.py").path ?? "<MergeTether.app>/Contents/Resources/Automation/author_follow_up.py"
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = InstallationStorage.current.helperEnvironmentPrefix + " /usr/bin/python3 -B \(quoted)"
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

extension FollowUpVerificationStore {
    /// Recovery verifies existing ownership; it never changes a legacy job's lifecycle or drafts.
    /// Extending the ordinary publication gate would trust stale claims; replaying a follow-up
    /// could repeat remote actions. A separate, content-bound assessment avoids both outcomes.
    struct RecoveryRecord: Codable {
        let version: Int
        let attemptID: String
        let assessmentID: UUID
        let assistant: AutomationAssistant
        let model: String
        let origin: FollowUpVerification
        let proof: FollowUpVerification
        let assessment: DraftProofRecoveryVerifier.Assessment
        var requestedDraftIDs: [Int]? = nil
    }

    @MainActor
    static func recoveryOrigins(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                settings: SettingsManager, in directory: URL = directory,
                                excludingRunID: UUID? = nil, excludingPredecessorID: UUID? = nil) -> [FollowUpVerification] {
        recoveryOrigins(work: work, username: username,
            input: receiptReadInput(work: work, username: username, settings: settings, in: directory), in: directory,
            excludingRunID: excludingRunID, excludingPredecessorID: excludingPredecessorID)
    }

    nonisolated static func recoveryOrigins(work: AssistantAutomationRunner.MergeRequestWork, username: String,
        input: ReceiptReadInput, in directory: URL, excludingRunID: UUID? = nil,
        excludingPredecessorID: UUID? = nil) -> [FollowUpVerification] {
        let runs = input.handoffs.filter {
            $0.id != excludingRunID && $0.id != excludingPredecessorID
                && $0.key.work == work && $0.key.username == username && $0.followUpPushAllowed != nil
        }
        let origins = runs.filter { origin in
            origin.followUpPushAllowed == true
                && (origin.execution == nil || origin.execution?.state == .succeeded || origin.execution?.state == .blocked)
        }
        guard !origins.isEmpty else { return [] }
        var paths: [URL] = []
        var archives: Set<URL> = []
        // Legacy records are candidates only for exact persisted runs; no legacy recovery authorizes publication.
        for evidence in [directory] + (input.legacyEvidenceDirectory.map { [$0] } ?? []) {
            paths.append(recordURL(kind: "follow-up-verifications", work: work, username: username, in: evidence))
            let archive = recordURL(kind: "follow-up-verifications-archive", work: work, username: username, in: evidence).deletingPathExtension()
            archives.insert(archive.standardizedFileURL)
            paths += ((try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
            for origin in origins {
                let folder = evidence.deletingLastPathComponent().appending(path: "Assistant Runs/\(origin.id.uuidString)")
                if let working = origin.execution?.workingDirectory,
                   URL(fileURLWithPath: working).standardizedFileURL == folder.standardizedFileURL,
                   (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                    paths.append(folder.appending(path: "seal-receipt.json"))
                }
            }
        }
        var unique: [UUID: FollowUpVerification] = [:]
        var ambiguous: Set<UUID> = []
        for path in paths {
            guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let proof = readPublicationReceipt(at: path, requiresFingerprint: false),
                  proof.host == work.host, proof.projectID == work.projectID, proof.iid == work.iid,
                  proof.username == username, let origin = origins.first(where: { $0.id == proof.runID }),
                  origin.execution?.state != .blocked || proof.discussionFingerprint != nil else { continue }
            if let repair = origin.draftRepair {
                guard proof.drafts.count == 1, proof.drafts[0].id == repair.draftID,
                      proof.drafts[0].bodySHA256 != repair.bodySHA256,
                      proof.repairIntent?.draftID == repair.draftID,
                      proof.repairIntent?.bodySHA256 == proof.drafts[0].bodySHA256,
                      proof.host == repair.origin.host, proof.username == repair.origin.username,
                      proof.userID == repair.origin.userID, proof.projectID == repair.origin.projectID,
                      proof.iid == repair.origin.iid, proof.sourceProjectID == repair.origin.sourceProjectID,
                      proof.sourceBranch == repair.origin.sourceBranch else { continue }
            }
            if archives.contains(path.deletingLastPathComponent().standardizedFileURL),
               UUID(uuidString: path.deletingPathExtension().lastPathComponent) != proof.verificationID { continue }
            if let previous = unique[proof.verificationID], previous != proof { ambiguous.insert(proof.verificationID) }
            else { unique[proof.verificationID] = proof }
        }
        let sealed = unique.values.filter { !ambiguous.contains($0.verificationID) }
        // A worker can finish its sealed replies while reporting publication as blocked.
        // Admit that ownership to read-only recovery, never directly to publication.
        // A newer sealed result at the same source revision must not strand sibling replies.
        let candidates = sealed.filter { proof in
            guard let origin = origins.first(where: { $0.id == proof.runID }) else { return false }
            return !runs.contains { later in
                later.draftRepair == nil && later.createdAt > origin.createdAt && later.execution?.state != .succeeded
                    && !hasSealedBlockedResult(later, matching: proof, assistant: origin.key.assistant, proofs: sealed)
                    && !hasSuccessfulEnvironmentReplacement(for: later, runs: runs, headSHA: proof.headSHA)
                    && !hasSuccessfulManualReplacement(for: later, runs: runs,
                        events: input.events, headSHA: proof.headSHA)
                    && !hasSuccessfulRepairReplacement(for: later, runs: runs)
            }
        }
        // A repair's declaration cannot manufacture provenance for an arbitrary existing user draft.
        // Its complete ancestry must lead back to an independently known ordinary app-owned seal.
        var trusted = candidates.filter { proof in origins.first(where: { $0.id == proof.runID })?.draftRepair == nil }
        var added = true
        while added {
            added = false
            for proof in candidates where !trusted.contains(proof) {
                guard let repair = origins.first(where: { $0.id == proof.runID })?.draftRepair,
                      trusted.contains(repair.origin) else { continue }
                trusted.append(proof); added = true
            }
        }
        return trusted.sorted { $0.verificationID.uuidString < $1.verificationID.uuidString }
    }

    private static func hasSealedBlockedResult(_ run: AssistantAutomationRunner.Handoff,
                                               matching proof: FollowUpVerification, assistant: AutomationAssistant,
                                               proofs: [FollowUpVerification]) -> Bool {
        run.execution?.state == .blocked && run.key.assistant == assistant
            && proofs.contains {
                $0.runID == run.id && $0.discussionFingerprint != nil && $0.userID == proof.userID
                    && $0.headSHA == proof.headSHA && $0.sourceProjectID == proof.sourceProjectID
                    && $0.sourceBranch == proof.sourceBranch
            }
    }

    private static func hasSuccessfulEnvironmentReplacement(for stopped: AssistantAutomationRunner.Handoff,
                                                            runs: [AssistantAutomationRunner.Handoff], headSHA: String) -> Bool {
        guard stopped.environmentRecoveryAttempted == true,
              stopped.execution?.state == .blocked || stopped.execution?.state == .failed else { return false }
        return runs.contains { replacement in
            replacement.environmentRecoveryOf == stopped.id && replacement.createdAt > stopped.createdAt
                && replacement.execution?.state == .succeeded && replacement.followUpPushAllowed == true
                && replacement.expectedHeadSHA == headSHA && replacement.key.work == stopped.key.work
                && replacement.key.username == stopped.key.username && replacement.key.assistant == stopped.key.assistant
        }
    }

    private static func hasSuccessfulRepairReplacement(for stopped: AssistantAutomationRunner.Handoff,
                                                        runs: [AssistantAutomationRunner.Handoff]) -> Bool {
        guard let context = stopped.draftRepair, let execution = stopped.execution, !execution.state.isActive else { return false }
        return runs.contains { replacement in
            replacement.manual == true && replacement.retryOf == stopped.id && replacement.createdAt > stopped.createdAt
                && replacement.key == stopped.key && replacement.workflow == .followUp
                && replacement.followUpPushAllowed == true && replacement.execution?.state == .succeeded
                && replacement.expectedHeadSHA == context.headSHA && replacement.draftRepair?.key == context.key
        }
    }

    /// Explicit retry lineage can retire a failed task's recovery fence, but never
    /// make its predecessor's claims true. Only recoveryOrigins uses this exception;
    /// the independent current-source verifier must still create publication proof.
    private static func hasSuccessfulManualReplacement(for stopped: AssistantAutomationRunner.Handoff,
                                                       runs: [AssistantAutomationRunner.Handoff],
                                                       events: [MRAutomationEvent], headSHA: String) -> Bool {
        guard stopped.execution?.state == .blocked || stopped.execution?.state == .failed,
              stopped.workflow == .followUp, stopped.followUpPushAllowed == true,
              stopped.expectedHeadSHA == headSHA,
              let task = stopped.taskPrompt, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let notes = stopped.feedbackNoteIDs, !notes.isEmpty, notes.allSatisfy({ $0 > 0 }),
              Set(notes).count == notes.count,
              let url = stopped.mergeRequestURL, url.isGitLabMergeRequest(host: stopped.key.work.host, iid: stopped.key.work.iid),
              stopped.reviewModel == nil, stopped.pipelineReservation == nil else { return false }
        let target = MRAutomationScope.Target(host: stopped.key.work.host, username: stopped.key.username,
            projectID: stopped.key.work.projectID, iid: stopped.key.work.iid)
        return runs.contains { replacement in
            replacement.createdAt > stopped.createdAt && replacement.execution?.state == .succeeded
                && replacement.manual == true && replacement.key == stopped.key
                && replacement.workflow == stopped.workflow && replacement.taskPrompt == task
                && replacement.expectedHeadSHA == stopped.expectedHeadSHA && replacement.mergeRequestURL == url
                && replacement.allowsPush == stopped.allowsPush && replacement.followUpPushAllowed == stopped.followUpPushAllowed
                && replacement.reviewModel == nil && replacement.pipelineReservation == nil
                && Set(replacement.feedbackNoteIDs ?? []) == Set(notes)
                && Set(replacement.feedbackTodos ?? []) == Set(stopped.feedbackTodos ?? [])
                && events.contains { event in
                    event.target == target && event.action == .retry && event.origin == .manual && event.state == .queued
                        && event.relatedJobID == stopped.id && event.jobID == replacement.id
                }
        }
    }

    static func validRecoveryScope(_ draftIDs: [Int], origin: FollowUpVerification) -> Bool {
        !draftIDs.isEmpty && draftIDs.count <= 100 && Set(draftIDs).count == draftIDs.count
            && Set(draftIDs).isSubset(of: Set(origin.drafts.map(\.id)))
    }

    static func recoveredProof(origin: FollowUpVerification, assessmentID: UUID, fingerprint: String,
                               semanticContext: String, recoveryContext: String, draftIDs: [Int]? = nil,
                               headSHA: String? = nil, files: [FollowUpVerification.FileEvidence]? = nil) -> FollowUpVerification {
        .init(version: 1, sealed: true, verificationID: assessmentID, runID: origin.runID,
            host: origin.host, projectID: origin.projectID, iid: origin.iid, username: origin.username,
            userID: origin.userID, headSHA: headSHA ?? origin.headSHA, sourceProjectID: origin.sourceProjectID,
            sourceBranch: origin.sourceBranch, files: files ?? origin.files,
            drafts: origin.drafts.filter { draftIDs.map(Set.init)?.contains($0.id) ?? true },
            discussionFingerprint: fingerprint, semanticContextFingerprint: semanticContext,
            recoveryContextFingerprint: recoveryContext, repairIntent: origin.repairIntent)
    }

    static func validRecoveryEvidence(headSHA: String, files: [FollowUpVerification.FileEvidence],
                                      origin: FollowUpVerification) -> Bool {
        isHex(headSHA, lengths: [40, 64]) && !files.isEmpty && files.count <= 20
            && files.map(\.path) == origin.files.map(\.path)
            && files.allSatisfy { isHex($0.sha256, lengths: [64]) }
            && (headSHA != origin.headSHA || files == origin.files)
    }

    @MainActor
    static func persistRecovery(_ record: RecoveryRecord, work: AssistantAutomationRunner.MergeRequestWork,
                                username: String, in directory: URL) throws {
        let folder = recordURL(kind: "follow-up-proof-recoveries", work: work, username: username, in: directory).deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sealed = try AssistantJobJournal.sealEvidence(JSONEncoder().encode(record), context: "follow-up-proof-recovery")
        try sealed.write(to: folder.appending(path: "\(record.attemptID).json"), options: .atomic)
    }

    @MainActor
    private static func recoveredReceipts(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                          settings: SettingsManager, in directory: URL) -> [FollowUpVerification] {
        recoveryRecords(work: work, username: username, settings: settings, in: directory).map(\.proof)
    }

    @MainActor
    static func recoveryRecords(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                settings: SettingsManager, in directory: URL) -> [RecoveryRecord] {
        recoveryRecords(work: work, username: username,
            input: receiptReadInput(work: work, username: username, settings: settings, in: directory), in: directory)
    }

    nonisolated private static func recoveryRecords(work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                                    input: ReceiptReadInput, in directory: URL) -> [RecoveryRecord] {
        let origins = recoveryOrigins(work: work, username: username, input: input, in: directory)
        guard !origins.isEmpty else { return [] }
        let folder = recordURL(kind: "follow-up-proof-recoveries", work: work, username: username, in: directory).deletingPathExtension()
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { path in
            guard path.pathExtension == "json", (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = input.authenticatedRecoveries[path.lastPathComponent],
                  let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data),
                  [1, 2].contains(record.version), path.deletingPathExtension().lastPathComponent == record.attemptID,
                  isHex(record.attemptID, lengths: [64]), origins.contains(record.origin),
                  record.assistant == input.assistant, !record.model.isEmpty,
                  record.assessmentID != record.origin.verificationID,
                  let fingerprint = record.proof.discussionFingerprint, isHex(fingerprint, lengths: [64]),
                  let context = record.proof.semanticContextFingerprint, isHex(context, lengths: [64]),
                  let recoveryContext = record.proof.recoveryContextFingerprint, isHex(recoveryContext, lengths: [64]) else { return nil }
            // Old records assessed their complete origin. New records retain that origin
            // unchanged and explicitly identify the exact subset independently assessed.
            let requested = record.requestedDraftIDs ?? record.origin.drafts.map(\.id)
            let valid = record.assessment.drafts.filter { $0.state == .valid }.map(\.draftID)
            guard validRecoveryScope(requested, origin: record.origin), !valid.isEmpty,
                  (try? DraftProofRecoveryVerifier.validate(record.assessment, draftIDs: requested)) != nil,
                  (record.version == 1 || validRecoveryEvidence(headSHA: record.proof.headSHA,
                      files: record.proof.files, origin: record.origin)),
                  record.proof == recoveredProof(origin: record.origin, assessmentID: record.assessmentID,
                      fingerprint: fingerprint, semanticContext: context, recoveryContext: recoveryContext, draftIDs: valid,
                      headSHA: record.version == 2 ? record.proof.headSHA : nil,
                      files: record.version == 2 ? record.proof.files : nil)
            else { return nil }
            return record
        }
    }
}


extension GitLabMergeRequest {
    /// Retargeting changes the meaning of current feedback even at the same source commit.
    var draftProofRecoveryContextFingerprint: String {
        UserAttentionSnapshot.digest(semanticContextFingerprint + "|\(projectID)|\(iid)|\(author.id)"
            + "|\(sourceProjectID ?? 0)|\(sourceBranch.utf8.count):\(sourceBranch)"
            + "|\(targetProjectID ?? 0)|\(targetBranch.utf8.count):\(targetBranch)"
            + "|\(webURL.absoluteString)|\(state)|\(draft.map(String.init) ?? "unknown")")
    }
}

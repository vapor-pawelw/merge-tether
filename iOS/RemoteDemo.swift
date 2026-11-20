#if DEBUG
import Foundation
import MergeTetherRemote

@MainActor enum RemoteDemo {
    static func makeModel() -> RemotePhoneModel? {
        let arguments = CommandLine.arguments
        let staleDetails = arguments.contains("--remote-preview-stale-details")
        let draftPreview = arguments.contains("--remote-preview-draft") || staleDetails
        let regenerationPreview = arguments.contains("--remote-preview-draft-regeneration")
        let manualDecisionPreview = arguments.contains("--remote-preview-manual-decision")
        let approvalPreview = arguments.contains("--remote-preview-approvals") || arguments.contains("--remote-preview-approval-reset")
        let slowResponses = arguments.contains("--remote-preview-slow")
        let boardPreview = arguments.contains("--remote-preview") || draftPreview || regenerationPreview || approvalPreview || manualDecisionPreview || slowResponses
        let previewBoard: RemoteBoard
        if regenerationPreview { previewBoard = regenerationBoard }
        else if draftPreview { previewBoard = draftBoard }
        else if approvalPreview || manualDecisionPreview { previewBoard = approvalBoard(reset: arguments.contains("--remote-preview-approval-reset")) }
        else { previewBoard = board }
        let connecting = arguments.contains("--remote-preview-connecting")
        let offline = arguments.contains("--remote-preview-offline")
        let failed = arguments.contains("--remote-preview-failed")
        guard boardPreview || connecting || offline || failed else { return nil }
        let invitation = try! RemotePairing.generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "A", count: 43))
        let pairing = try! RemotePairing(url: invitation.deepLink)
        var connections = 0
        let model = RemotePhoneModel(relayConfiguration: .init(rawOrigin: pairing.origin.absoluteString), loadPairing: { pairing }, savePairing: { _ in },
            loadRecovery: { nil }, saveRecovery: { _ in }, removeRecovery: {}, makeConnection: { _ in
            connections += 1
            return PreviewTransport(board: boardPreview ? previewBoard : nil, delay: connections > 1, failed: failed,
                staleDetails: staleDetails, slowResponses: slowResponses)
        }, now: { Date().addingTimeInterval(offline ? -46 : 0) })
        if boardPreview { model.state.receive(.init(type: .snapshot, challenge: model.state.challenge(), board: previewBoard)) }
        return model
    }

    private static var regenerationBoard: RemoteBoard {
        var preview = board
        preview.lanes[0].cards[0].drafts.append(.init(id: 2, body: "Can we explain the retry behavior in the release notes?"))
        preview.lanes[1].cards[0].id = "mr:2:17"
        preview.lanes[1].cards[0].drafts = [.init(id: 3, body: "Please show an error after a failed checkout.")]
        preview.draftRegeneration = PreviewTransport.regenerationControl(batch: nil, data: nil)
        return preview
    }

    static func approvalBoard(reset: Bool) -> RemoteBoard {
        var preview = board
        var card = preview.lanes[1].cards[0]
        card.detail = "Keep the previous confirmation visible while an interrupted request is retried."
        card.primaryCTA = .init(title: String(localized: .Board.boardDetails), destination: .overview)
        card.actions = []
        card.approvals = .init(completed: reset ? 1 : 2, required: 2)
        card.presentation?.approvalPeople = [
            .init(id: 2, name: "Sam Example", username: "sam", status: .approved),
            .init(id: 1, name: "Alex Example", username: "alex", status: reset ? .previouslyApproved : .approved),
            .init(id: 3, name: "Comment Author", username: "commenter", status: .commented)
        ]
        card.presentation?.viewerApprovalID = 1
        preview.lanes = [.init(id: .reviewed, cards: [card, preview.lanes[0].cards[1]])]
        return preview
    }

    static let draftBoard = RemoteBoard(hostSession: UUID(), account: "Demo", updatedAt: .now, lanes: [
        .init(id: .own, cards: [
            .init(id: "mr:1:44", title: "Draft: Keep account settings available across devices", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/44"),
                head: String(repeating: "a", count: 40),
                actions: [.init(id: "markReady", kind: .markReady, token: "preview",
                    confirmationText: String(localized: .Remote.remoteMarkReadyHelp))],
                needsAttention: false, mergeRequestIID: 44,
                primaryCTA: .init(title: String(localized: .Remote.remoteMarkReady), destination: .actions, actionID: "markReady"),
                presentation: .init(author: "Alex Example", repository: "payments-api", draftBadge: "DRAFT", authorUsername: "alex"))
        ])
    ])

    static let board = RemoteBoard(hostSession: UUID(), account: "Demo", updatedAt: .now, lanes: [
        .init(id: .own, cards: [
            .init(id: "mr:1:42", title: "Add a clearer payment confirmation", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/42")!,
                head: "a9f36b246dde", detail: String(localized: .MRHumanAction.mrHumanActionPublicationSingle),
                drafts: [.init(id: 1, body: "Handled the retry case and added coverage for the duplicate response.",
                    replyRecipients: [.init(name: "Alexandra Example With A Long Display Name", username: "reviewer1")])],
                actions: [.init(id: "publish", kind: .publish, token: "preview"), .init(id: "deleteDraft:1", kind: .deleteDraft, token: "preview"),
                          .init(id: "commentOrigin", kind: .setCommentOrigin, token: "preview"),
                          .init(id: "ignoreSuggestion:1", kind: .ignoreSuggestion, token: "preview",
                              confirmationText: "Keep the cached confirmation visible if a retry is interrupted.",
                              label: "Keep the cached confirmation visible if a retry is interrupted."),
                          .init(id: "ignoreSuggestion:2", kind: .ignoreSuggestion, token: "preview",
                              confirmationText: "Make the confirmation button label wrap on a compact screen.",
                              label: "Make the confirmation button label wrap on a compact screen.")],
                needsAttention: true, mergeRequestIID: 42,
                primaryCTA: .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewDrafts), destination: .drafts),
                presentation: .init(author: "Alex Example", repository: "payments-api",
                    authorUsername: "alex", assignedReviewerCount: 5),
                approvals: .init(completed: 2, required: 2, received: 5, requirementsSatisfied: false)),
            .init(id: "mr:1:43", title: "Keep cached account details available", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/43"),
                head: "b1c2d3e4", actions: [.init(id: "runReview", kind: .runReview, token: "preview",
                    confirmationText: String(localized: .Remote.remoteRunReviewHelp))],
                needsAttention: false, mergeRequestIID: 43,
                primaryCTA: .init(title: String(localized: .Remote.remoteRunReview), destination: .actions, actionID: "runReview"),
                presentation: .init(author: "Alex Example", repository: "payments-api", status: String(localized: .AuthorFeedback.authorFeedbackWaitingChip))),
        ]),
        .init(id: .reviewed, cards: [
            .init(id: "mr:1:17", title: "Handle interrupted checkout requests", project: "example/mobile-app",
                url: URL(string: "https://gitlab.example.org/example/mobile-app/-/merge_requests/17")!,
                head: "b72de9918a3f", detail: String(localized: .MRHumanAction.mrHumanActionApproval),
                actions: [.init(id: "approve", kind: .approve, token: "preview")],
                needsAttention: true, mergeRequestIID: 17,
                primaryCTA: .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewApproval), destination: .actions),
                presentation: .init(author: "Sam Example", repository: "mobile-app", authorUsername: "sam"), approvals: .init(completed: 2, required: 2)),
        ]),
        .init(id: .other, cards: [
            .init(id: "completion:merged", title: "Preserve payment history", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/41"),
                detail: "Merge request merged", actions: [.init(id: "seen", kind: .markDone, token: "preview")],
                needsAttention: false, mergeRequestIID: 41,
                presentation: .init(author: "Alex Example", repository: "payments-api", draftBadge: "Merged"))
        ]),
    ])

    static func details(for card: RemoteCard) -> RemoteMRDetails {
        let people = (1...5).map { index in
            RemoteApprovalPerson(id: index, name: index == 1 ? "Alexandra Example With A Long Display Name" : "Reviewer \(index)",
                username: "reviewer\(index)", status: .approved, changedAt: .now.addingTimeInterval(Double(-index * 600)))
        } + [.init(id: 6, name: "Earlier Reviewer", username: "earlier", status: .previouslyApproved, changedAt: .now.addingTimeInterval(-7200)),
             .init(id: 7, name: "Comment Author", username: "commenter", status: .commented),
             .init(id: 8, name: "Assigned Reviewer", username: "assigned", status: .assigned)]
        let location = "Sources/Payments/Checkout/Confirmation/PaymentConfirmationCoordinator.swift:142"
        let sourceBranch = "feature/payment-confirmation-with-long-branch-name"
        let url = card.url
        var details = RemoteMRDetails(checkedAt: .now, metadata: [
            .init(label: String(localized: .RemoteDetail.remoteDetailSourceBranch), value: sourceBranch),
            .init(label: String(localized: .RemoteDetail.remoteDetailTargetBranch), value: "main"),
            .init(label: String(localized: .RemoteSecurity.remoteSecurityCommit), value: card.head ?? ""),
            .init(label: String(localized: .RemoteDetail.remoteDetailPipeline), value: "success"),
        ], description: "Keep payment confirmation readable after a retry, including duplicate and interrupted responses.\n\nThe confirmation remains visible while the next request runs, so people can check the original payment and retry safely.\n\nThe test plan covers a successful retry, a duplicate response, offline recovery and long translated messages.",
        approvals: .init(progress: .init(completed: 2, required: 2, received: 5, requirementsSatisfied: false), people: people,
            rules: [.init(id: "owners", name: "Code owners", required: 1, approved: true, approvedBy: ["@reviewer1"]),
                    .init(id: "security", name: "Security team review of payment recovery", required: 1, approved: false)],
            requirementsSatisfied: false, historyAvailable: true),
        threads: [
            .init(id: "open", state: .open, location: location, notes: [
                .init(id: "1", author: "Alexandra Example With A Long Display Name", username: "reviewer1",
                    body: "Please preserve the previous confirmation when the retry fails. A duplicate server response should not replace it with an empty state.",
                    location: location, createdAt: .now.addingTimeInterval(-3600), url: url, origin: .ai, authorID: 1),
                .init(id: "2", author: "Alex Example", username: "alex", body: "The previous confirmation stays visible. The duplicate-response path now has a regression test.",
                    createdAt: .now.addingTimeInterval(-1800), url: url, origin: .ai, authorID: 9, originManual: true)
            ], reply: .published, draftCount: card.drafts.count, feedback: .addressed, draftIDs: card.drafts.map(\.id)),
            .init(id: "resolved", state: .resolved, notes: [
                .init(id: "3", author: "Earlier Reviewer", username: "earlier", body: "The longer translated button title now wraps correctly.",
                    createdAt: .now.addingTimeInterval(-2400), url: url, origin: .human, authorID: 6),
                .init(id: "5", author: "Alex Example", username: "alex", body: "Confirmed the long-title example on the compact layout.",
                    createdAt: .now.addingTimeInterval(-1200), url: url, origin: .human, authorID: 9),
                .init(id: "6", author: "Earlier Reviewer", username: "earlier", body: "Thanks. This is informational; no further code change is needed.",
                    createdAt: .now, url: url, origin: .human, authorID: 6)
            ], reply: .earlier, feedback: .informational),
            .init(id: "general", state: .general, notes: [
                .init(id: "4", author: "Comment Author", username: "commenter", body: "Please check the offline recovery example before publishing the final review.",
                    createdAt: .now, url: url, origin: .uncertain, authorID: 7)
            ], reply: .none, feedback: .needsVerification),
        ], reasons: ["One approval rule is still pending."], policy: ["Comment publication waits for review. Merge readiness is checked independently."],
        feedback: [.init(label: "Alexandra Example With A Long Display Name", value: "The reply is prepared. Check the discussion and pending draft before publishing.",
                         person: .init(name: "Alexandra Example With A Long Display Name", username: "reviewer1"))],
        activity: [.init(id: "run1", title: "Handle payment confirmation feedback", status: "Completed", summary: "Preserved the cached confirmation and added duplicate-response coverage.", createdAt: .now.addingTimeInterval(-900), head: card.head)],
        usage: [.init(label: "Reviewer / work agent", value: "$0.1420 · 2 agent requests"), .init(label: "Verifier", value: "$0.0081 · 4 agent requests")],
        branches: .init(source: sourceBranch, target: "main"))
        if let people = card.presentation?.approvalPeople {
            details.approvals = .init(progress: card.approvals, people: people, historyAvailable: true,
                viewerApprovalID: card.presentation?.viewerApprovalID)
        }
        if CommandLine.arguments.contains("--remote-preview-manual-decision") {
            details.feedback = [
                .init(label: String(localized: .AuthorFeedback.authorFeedbackManualDecision), value: "Confirm the required absent-transaction response."),
                .init(label: String(localized: .AuthorFeedback.authorFeedbackDecisionContext), value: "The application retrieves transaction details from a provider using a transaction identifier. The review asks how an absent transaction is represented and whether callers can distinguish it from a service failure."),
                .init(label: String(localized: .AuthorFeedback.authorFeedbackDecisionVerified), value: "The adapter preserves an explicit provider not-found response. A stub test verifies that mapping and that other failures remain server errors. This does not establish the real provider response."),
                .init(label: String(localized: .AuthorFeedback.authorFeedbackDecisionMissing), value: "The available provider contract omits the absent-transaction response. No integration environment was available to check it."),
                .init(label: String(localized: .AuthorFeedback.authorFeedbackDecisionQuestion), value: "Which response does the required provider contract guarantee for an absent transaction?"),
                .init(label: String(localized: .AuthorFeedback.authorFeedbackDecisionImpact), value: "This concern remains open pending evidence. Independent corrections can continue; automatic merge remains on hold for this essential requirement.")
            ]
        }
        details.automation = .init(active: true, summary: "Automation enabled · Decided by: Repository")
        if CommandLine.arguments.contains("--remote-preview-origin-resume") {
            details.originResume = .init(changeID: UUID().uuidString, resumesAt: .now.addingTimeInterval(600), drafts: 1)
        }
        return details
    }
}
@MainActor private final class PreviewTransport: RemotePhoneTransport {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)?
    var onStatus: (@MainActor (Bool, Bool) -> Void)?
    var board: RemoteBoard?
    let delay: Bool
    let failed: Bool
    let slowResponses: Bool
    private var staleDetails: Bool
    private var regeneration: DraftRegenerationBatch?
    private var regenerationReadyAt = Date.distantFuture
    init(board: RemoteBoard?, delay: Bool, failed: Bool, staleDetails: Bool = false, slowResponses: Bool = false) {
        self.board = board; self.delay = delay; self.failed = failed; self.staleDetails = staleDetails
        self.slowResponses = slowResponses
    }
    func start() { onStatus?(!failed, failed) }
    func stop() { onStatus?(false, false) }
    func send(_ message: RemoteMessage) async throws {
        if var batch = regeneration, batch.phase == .generating, Date() >= regenerationReadyAt {
            batch.phase = .ready
            batch.completed = batch.total
            regeneration = batch
            updateRegenerationControl()
        }
        if message.type == .hello, var board {
            if delay { try await Task.sleep(for: .seconds(8)) }
            if message.refresh == true { try await Task.sleep(for: .milliseconds(300)); board.updatedAt = .now; self.board = board }
            var capabilities = [RemoteMessage.detailsCapability, RemoteMessage.detailContextCapability]
            if board.draftRegeneration != nil { capabilities.append(RemoteMessage.draftRegenerationCapability) }
            await onMessage?(.init(type: .snapshot, challenge: message.challenge, board: board,
                capabilities: capabilities + (slowResponses ? [RemoteMessage.detailPreviewCapability] : [])))
        } else if let request = message.draftRegenerationRequest {
            let data = regenerationData
            let fullSize = data?.count ?? 0
            let page = data.flatMap { contents -> Data? in
                guard request.previewToken == RemoteDraftRegenerationPage.token(contents),
                      request.batchID == regeneration?.id, (0..<fullSize).contains(request.offset) else { return nil }
                return contents.subdata(in: request.offset..<min(request.offset + RemoteDraftRegenerationPage.pageBytes, fullSize))
            }
            await onMessage?(.init(type: .draftRegenerationPage, challenge: message.challenge,
                draftRegenerationPage: .init(request: request, data: page, totalBytes: fullSize)))
        } else if message.type == .detailRequest, let request = message.detailRequest, let board,
                  request.matches(board), let card = board.cards.first(where: { $0.id == request.cardID }) {
            if staleDetails {
                staleDetails = false
                await onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .changed)))
                return
            }
            if slowResponses { try await Task.sleep(for: .seconds(15)) }
            await onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current,
                details: RemoteDemo.details(for: card))))
        } else if let command = message.command {
            if slowResponses { try await Task.sleep(for: .seconds(15)) }
            if command.cardID == RemoteDraftRegenerationControl.cardID {
                await onMessage?(.init(type: .accepted, result: .init(id: command.id, status: .running)))
                let status = performRegeneration(RemoteDraftRegenerationOperation(argument: command.argument))
                await onMessage?(.init(type: .result, result: .init(id: command.id, status: status)))
                return
            }
            if command.isCompletionAcknowledgement, var board {
                for lane in board.lanes.indices {
                    board.lanes[lane].cards.removeAll { $0.id == command.cardID }
                }
                self.board = board
            } else if command.actionID == "markReady", var board {
                for lane in board.lanes.indices {
                    for index in board.lanes[lane].cards.indices where board.lanes[lane].cards[index].id == command.cardID {
                        board.lanes[lane].cards[index].title = board.lanes[lane].cards[index].title.replacingOccurrences(of: "Draft: ", with: "")
                        board.lanes[lane].cards[index].presentation?.draftBadge = nil
                        board.lanes[lane].cards[index].actions = []
                        board.lanes[lane].cards[index].primaryCTA = nil
                        board.lanes[lane].cards[index].contextRevision = "ready"
                    }
                }
                self.board = board
            }
            await onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
    }

    static func regenerationControl(batch: DraftRegenerationBatch?, data: Data?) -> RemoteDraftRegenerationControl {
        var actions: [RemoteAction] = []
        if batch == nil {
            actions.append(.init(id: RemoteDraftRegenerationControl.startID, kind: .startDraftRegeneration, token: "preview-start"))
        } else if let batch, batch.phase != .saving {
            actions.append(.init(id: RemoteDraftRegenerationControl.discardID, kind: .discardDraftRegeneration, token: batch.id.uuidString))
            if batch.phase == .ready {
                actions.append(.init(id: RemoteDraftRegenerationControl.applyID, kind: .applyDraftRegeneration, token: batch.id.uuidString))
            }
        }
        var summary = batch
        summary?.proposals = []
        return .init(card: .init(id: RemoteDraftRegenerationControl.cardID, title: "", project: "", url: nil, actions: actions),
            count: 3, batch: summary, previewToken: data.map(RemoteDraftRegenerationPage.token),
            proposalCount: data == nil ? 0 : batch?.proposals.count ?? 0, mergeRequestCount: 2)
    }

    private var regenerationData: Data? {
        guard let regeneration, regeneration.phase == .ready || regeneration.phase == .finished else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(regeneration.proposals)
    }

    private func updateRegenerationControl() {
        board?.draftRegeneration = Self.regenerationControl(batch: regeneration, data: regenerationData)
    }

    private func performRegeneration(_ operation: RemoteDraftRegenerationOperation?) -> RemoteCommandResult.Status {
        switch operation {
        case .start(let scope, _, _)?:
            let proposals = [
                DraftRegenerationProposal(projectID: 1, iid: 42, draftID: 1, mergeRequestTitle: "Add a clearer payment confirmation",
                    original: "Handled the retry case and added coverage for the duplicate response.",
                    replacement: "A failed retry keeps the last confirmation visible. A regression test covers duplicate responses.",
                    selectedByDefault: true),
                .init(projectID: 1, iid: 42, draftID: 2, mergeRequestTitle: "Add a clearer payment confirmation",
                    original: "Can we explain the retry behavior in the release notes?",
                    replacement: "Could the release notes say that a failed retry now keeps the last payment confirmation visible?"),
                .init(projectID: 2, iid: 17, draftID: 3, mergeRequestTitle: "Handle interrupted checkout requests",
                    original: "Please show an error after a failed checkout.", issue: .outdated,
                    explanation: "The checkout already shows this error.")
            ].filter { proposal in
                switch scope {
                case .all: true
                case .mergeRequest(let project, let iid): proposal.projectID == project && proposal.iid == iid
                case .draft(let project, let iid, let id): proposal.projectID == project && proposal.iid == iid && proposal.draftID == id
                }
            }
            regeneration = .init(id: UUID(), scope: scope, total: proposals.count, proposals: proposals)
            regenerationReadyAt = Date().addingTimeInterval(2)
        case .apply(let id, let ids)?:
            guard var batch = regeneration, batch.id == id, batch.phase == .ready else { return .changed }
            let selected = Set(ids)
            for index in batch.proposals.indices where selected.contains(batch.proposals[index].id) {
                let proposal = batch.proposals[index]
                if proposal.draftID == 2 {
                    batch.proposals[index].issue = .changed
                } else if let body = proposal.replacement {
                    batch.proposals[index].issue = .saved
                    let cardID = "mr:\(proposal.projectID):\(proposal.iid)"
                    if let lane = board?.lanes.firstIndex(where: { $0.cards.contains { $0.id == cardID } }),
                       let card = board?.lanes[lane].cards.firstIndex(where: { $0.id == cardID }),
                       let draft = board?.lanes[lane].cards[card].drafts.firstIndex(where: { $0.id == proposal.draftID }) {
                        board?.lanes[lane].cards[card].drafts[draft].body = body
                    }
                }
            }
            batch.phase = .finished
            regeneration = batch
            updateRegenerationControl()
            return batch.proposals.contains { $0.issue == .changed } ? .partial : .completed
        case .discard(let id)?:
            guard regeneration?.id == id else { return .changed }
            regeneration = nil
        case nil: return .failed
        }
        updateRegenerationControl()
        return .completed
    }
}
#endif

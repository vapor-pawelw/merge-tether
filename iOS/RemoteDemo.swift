#if DEBUG
import Foundation
import MergeTetherRemote

@MainActor enum RemoteDemo {
    static func makeModel() -> RemotePhoneModel? {
        let arguments = CommandLine.arguments
        let boardPreview = arguments.contains("--remote-preview")
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
            return PreviewTransport(board: boardPreview ? board : nil, delay: connections > 1, failed: failed)
        }, now: { Date().addingTimeInterval(offline ? -46 : 0) })
        if boardPreview { model.state.receive(.init(type: .snapshot, challenge: model.state.challenge(), board: board)) }
        return model
    }

    static let board = RemoteBoard(hostSession: UUID(), account: "Demo", updatedAt: .now, lanes: [
        .init(id: .own, cards: [
            .init(id: "mr:1:42", title: "Add a clearer payment confirmation", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/42")!,
                head: "a9f36b246dde", detail: String(localized: .MRHumanAction.mrHumanActionPublicationSingle),
                drafts: [.init(id: 1, body: "Handled the retry case and added coverage for the duplicate response.", context: "Sources/Checkout.swift:42")],
                actions: [.init(id: "publish", kind: .publish, token: "preview"), .init(id: "deleteDraft:1", kind: .deleteDraft, token: "preview")],
                needsAttention: true, mergeRequestIID: 42,
                primaryCTA: .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewDrafts), destination: .drafts),
                presentation: .init(author: "Alex Example", repository: "payments-api"), approvals: .init(completed: 2, required: 2, received: 5, requirementsSatisfied: false)),
            .init(id: "mr:1:43", title: "Keep cached account details available", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/43"),
                head: "b1c2d3e4", needsAttention: false, mergeRequestIID: 43,
                presentation: .init(author: "Alex Example", repository: "payments-api", status: String(localized: .AuthorFeedback.authorFeedbackWaitingChip))),
        ]),
        .init(id: .reviewed, cards: [
            .init(id: "mr:1:17", title: "Handle interrupted checkout requests", project: "example/mobile-app",
                url: URL(string: "https://gitlab.example.org/example/mobile-app/-/merge_requests/17")!,
                head: "b72de9918a3f", detail: String(localized: .MRHumanAction.mrHumanActionApproval),
                actions: [.init(id: "approve", kind: .approve, token: "preview")],
                needsAttention: true, mergeRequestIID: 17,
                primaryCTA: .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewApproval), destination: .actions),
                presentation: .init(author: "Sam Example", repository: "mobile-app"), approvals: .init(completed: 2, required: 2)),
        ]),
        .init(id: .other, cards: []),
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
        return .init(checkedAt: .now, metadata: [
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
                    createdAt: .now.addingTimeInterval(-1800), url: url, origin: .ai, authorID: 9)
            ], reply: .published, draftCount: card.drafts.count, feedback: .addressed),
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
        feedback: [.init(label: "@reviewer1", value: "The reply is prepared. Check the discussion and pending draft before publishing.")],
        activity: [.init(id: "run1", title: "Handle payment confirmation feedback", status: "Completed", summary: "Preserved the cached confirmation and added duplicate-response coverage.", createdAt: .now.addingTimeInterval(-900), head: card.head)],
        usage: [.init(label: "Reviewer / work agent", value: "$0.1420 · 2 agent requests"), .init(label: "Verifier", value: "$0.0081 · 4 agent requests")],
        branches: .init(source: sourceBranch, target: "main"))
    }
}
@MainActor private final class PreviewTransport: RemotePhoneTransport {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)?
    var onStatus: (@MainActor (Bool, Bool) -> Void)?
    let board: RemoteBoard?
    let delay: Bool
    let failed: Bool
    init(board: RemoteBoard?, delay: Bool, failed: Bool) { self.board = board; self.delay = delay; self.failed = failed }
    func start() { onStatus?(!failed, failed) }
    func stop() { onStatus?(false, false) }
    func send(_ message: RemoteMessage) async throws {
        if message.type == .hello, let board {
            if delay { try await Task.sleep(for: .seconds(8)) }
            await onMessage?(.init(type: .snapshot, challenge: message.challenge, board: board,
                capabilities: [RemoteMessage.detailsCapability]))
        } else if message.type == .detailRequest, let request = message.detailRequest, let board,
                  request.matches(board), let card = board.cards.first(where: { $0.id == request.cardID }) {
            await onMessage?(.init(type: .details, detailResponse: .init(request: request, status: .current,
                details: RemoteDemo.details(for: card))))
        } else if let command = message.command {
            await onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
    }
}
#endif

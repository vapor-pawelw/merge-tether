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
        let model = RemotePhoneModel(loadPairing: { pairing }, savePairing: { _ in },
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
                actions: [.init(id: "publish", kind: .publish, token: "preview")],
                needsAttention: true, mergeRequestIID: 42,
                primaryCTA: .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewDrafts), destination: .drafts),
                presentation: .init(author: "Alex Example", repository: "payments-api"), approvals: .init(completed: 1, required: 2)),
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
            await onMessage?(.init(type: .snapshot, challenge: message.challenge, board: board))
        } else if let command = message.command {
            await onMessage?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        }
    }
}
#endif

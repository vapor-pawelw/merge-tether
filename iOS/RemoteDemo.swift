#if DEBUG
import Foundation
import MergeTetherRemote

@MainActor enum RemoteDemo {
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
#endif

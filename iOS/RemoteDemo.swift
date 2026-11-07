#if DEBUG
import Foundation
import MergeTetherRemote

@MainActor enum RemoteDemo {
    static let board = RemoteBoard(hostSession: UUID(), account: "Demo", updatedAt: .now, lanes: [
        .init(id: .own, cards: [
            .init(id: "mr:1:42", title: "Add a clearer payment confirmation", project: "example/payments-api",
                url: URL(string: "https://gitlab.example.org/example/payments-api/-/merge_requests/42")!,
                head: "a9f36b246dde", detail: "One comment needs your review before publication.",
                drafts: [.init(id: 1, body: "Handled the retry case and added coverage for the duplicate response.", context: "Sources/Checkout.swift:42")],
                actions: [.init(id: "publish", kind: .publish, token: "preview")]),
        ]),
        .init(id: .reviewed, cards: [
            .init(id: "mr:1:17", title: "Handle interrupted checkout requests", project: "example/mobile-app",
                url: URL(string: "https://gitlab.example.org/example/mobile-app/-/merge_requests/17")!,
                head: "b72de9918a3f", detail: "Review completed. Ready for your approval.",
                actions: [.init(id: "approve", kind: .approve, token: "preview")]),
        ]),
        .init(id: .other, cards: []),
    ])
}
#endif

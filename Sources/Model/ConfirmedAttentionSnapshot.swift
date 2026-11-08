import Foundation

/// Last confirmed presentation only. This cache never grants an action or supplies GitLab proof.
@MainActor
struct ConfirmedAttentionSnapshot {
    struct Input {
        var account: String?
        var candidates: [UserAttentionSnapshot.Candidate] = []
        var checkingIDs: Set<String> = []
        var humanActions: [String: MRHumanAction] = [:]
    }
    private var account: String?
    private var confirmed: [String: [UserAttentionSnapshot.Candidate]] = [:]
    private(set) var humanActions: [String: MRHumanAction] = [:]
    var snapshot: UserAttentionSnapshot { .init(candidates: confirmed.values.flatMap { $0 }) }

    func matches(account: String?) -> Bool { account != nil && self.account == account }

    mutating func update(_ input: Input) {
        if account != input.account || input.account == nil {
            confirmed.removeAll()
            humanActions.removeAll()
        }
        account = input.account
        guard input.account != nil else { return }
        let groups = Dictionary(grouping: input.candidates, by: \.id)
        for id in Set(confirmed.keys).subtracting(groups.keys) {
            confirmed.removeValue(forKey: id)
            humanActions.removeValue(forKey: id)
        }
        for (id, candidates) in groups where !input.checkingIDs.contains(id) {
            confirmed[id] = candidates
            humanActions[id] = input.humanActions[id]
        }
    }
}

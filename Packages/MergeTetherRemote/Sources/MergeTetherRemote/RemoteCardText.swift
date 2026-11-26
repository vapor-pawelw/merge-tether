import Foundation

public extension RemoteCardText {
    var showsDraftStyle: Bool {
        // Older Macs only sent the translated badge. These were the two supported locales.
        isDraft ?? (draftBadge == "DRAFT" || draftBadge == "SZKIC")
    }
}

public struct RemoteCardSelection: Identifiable, Equatable, Sendable {
    public let card: RemoteCard
    public let cta: RemoteCardCTA?
    public var id: String { card.id }
    public var destination: RemoteCardCTA.Destination { cta?.destination ?? .overview }
    public var needsDetails: Bool { [.feedback, .assistantRuns, .discussions].contains(destination) }
    public var reviewSeenAction: RemoteAction? { cta?.duplicatesCardTap == false ? card.reviewSeenAction : nil }

    public init(card: RemoteCard, cta: RemoteCardCTA? = nil) {
        self.card = card; self.cta = cta
    }

    public func action(in current: RemoteCard) -> RemoteAction? {
        guard current.hasSameActionContext(as: card), let id = cta?.actionID,
              let advertised = card.actions.first(where: { $0.id == id }) else { return nil }
        return current.actions.first { $0 == advertised }
    }
}

/// The phone shows each sentence once, like the Mac card: a status or next step that repeats
/// the card's explanation adds nothing, and older hosts may still send such repeats.
public extension RemoteCard {
    var commandActions: [RemoteAction] {
        actions + drafts.flatMap { ($0.aiReplyDecisions ?? []).flatMap { [$0.reply, $0.human] } }
    }


    var reviewSeenAction: RemoteAction? {
        guard boardTraits?.isNew == true else { return nil }
        return actions.first { $0.id == RemoteAction.reviewSeenID && $0.kind == .markDone }
    }

    func hasSameActionContext(as other: RemoteCard) -> Bool {
        guard id == other.id, title == other.title, project == other.project, url == other.url else { return false }
        return head == other.head && contextRevision == other.contextRevision && drafts == other.drafts
    }

    var detailContextDigest: String? {
        var content = withoutDependencySources
        content.detail = ""
        content.presentation = nil
        content.needsAttention = nil
        content.primaryCTA = nil
        content.orderGroup = nil
        content.pinned = nil
        content.automation = nil
        content.canRemoveFromBoard = nil
        content.canLeaveReview = nil
        content.canAcknowledgeFinished = nil
        content.boardTraits = nil
        content.actions.removeAll { $0.kind == .editCard || $0.id == RemoteAction.reviewSeenID }
        content.issues = nil
        return try? RemoteDigest.token(content)
    }

    var visibleStatus: String? {
        guard let status = presentation?.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty,
              !Self.repeats(status, in: [detail]) else { return nil }
        return presentation?.status
    }

    var visibleNextStep: String? {
        guard let next = presentation?.nextStep?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty,
              !Self.repeats(next, in: [detail, presentation?.status ?? ""]) else { return nil }
        return presentation?.nextStep
    }

    var boardStatus: String? { presentation?.reviewCompletionInDetailsOnly == true ? nil : visibleStatus }
    var boardNextStep: String? { presentation?.reviewCompletionInDetailsOnly == true ? nil : visibleNextStep }

    /// Policy lines already stated by the card itself, mirroring the Mac summary's exclusions.
    func visiblePolicy(_ policy: [String]) -> [String] {
        let cardText = [detail, presentation?.status ?? "", presentation?.nextStep ?? ""]
        var shown: [String] = []
        for line in policy where !Self.repeats(line, in: cardText + shown) {
            shown.append(line)
        }
        return shown
    }

    private static func repeats(_ text: String, in others: [String]) -> Bool {
        let key = normalized(text)
        guard !key.isEmpty else { return true }
        return others.contains { other in
            let candidate = normalized(other)
            return !candidate.isEmpty && (candidate == key
                || candidate.components(separatedBy: "\n\n").map(normalized).contains(key))
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }
}

extension RemoteCard {
    var withoutDependencySources: Self {
        guard var dependencies, dependencies.predecessors.contains(where: { $0.sources != nil }) else { return self }
        for index in dependencies.predecessors.indices { dependencies.predecessors[index].sources = nil }
        var card = self
        card.dependencies = dependencies
        return card
    }
}

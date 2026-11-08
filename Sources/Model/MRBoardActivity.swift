import Foundation

enum MRBoardGrouping: String, Codable, CaseIterable {
    case withoutAutomation, drafts

    func effective(for automation: AutomationSettings) -> Self {
        automation.hasEnabledAutomation ? self : .drafts
    }
}

/// Visual grouping only; action admission still requires current GitLab evidence.
struct MRBoardActivity: Equatable {
    enum Group: Int { case finished, regular, inactive, drafts }
    let group: Group
    var isMuted: Bool { group == .inactive || group == .drafts }

    init(automation: AutomationSettings, target: MRAutomationScope.Target?, isDraft: Bool, isFinished: Bool = false,
         grouping: MRBoardGrouping = .withoutAutomation) {
        if isFinished { group = .finished }
        else if grouping.effective(for: automation) == .drafts { group = isDraft ? .drafts : .regular }
        else if let target, !automation.scope.resolve(target, isDraft: isDraft).active { group = .inactive }
        else { group = .regular }
    }
}

import Foundation

enum AutomationPackageDecision: String, Codable, Equatable, Sendable {
    case undecided, enabled, disabled
}

enum MergeWorkflowMode: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case off, preview, notify, assistant
}

struct MergeWorkflowRule: Codable, Equatable, Sendable {
    var mode: MergeWorkflowMode = .off
    var projects = ""
    var targetBranches = ""
    var requiredLabel = ""
    var retryInfrastructureFailure = false
    var waitHours = 48

    func effectiveMode(for trigger: MergeWorkflowTrigger) -> MergeWorkflowMode {
        trigger == .reviewWaiting && mode != .off ? .notify : mode
    }

    func includes(project: String) -> Bool {
        let paths = Self.projectPaths(projects)
        return paths.isEmpty || paths.contains(project)
    }

    func includes(_ request: GitLabMergeRequest) -> Bool {
        let branches = Self.projectPaths(targetBranches)
        let label = requiredLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return includes(project: request.webURL.gitLabProjectPath)
            && (branches.isEmpty || branches.contains(request.targetBranch))
            && (label.isEmpty || request.labels.contains(label))
    }

    static func projectPaths(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }
}

struct MergeWorkflowRules: Codable, Equatable, Sendable {
    private var rules: [String: MergeWorkflowRule] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([String: MergeWorkflowRule].self, forKey: .rules) ?? [:]
        if var waiting = rules[MergeWorkflowTrigger.reviewWaiting.rawValue] {
            waiting.mode = waiting.effectiveMode(for: .reviewWaiting)
            rules[MergeWorkflowTrigger.reviewWaiting.rawValue] = waiting
        }
    }

    private enum CodingKeys: String, CodingKey { case rules }

    subscript(trigger: MergeWorkflowTrigger) -> MergeWorkflowRule {
        get {
            var rule = rules[trigger.rawValue] ?? MergeWorkflowRule()
            rule.mode = rule.effectiveMode(for: trigger)
            return rule
        }
        set {
            var rule = newValue
            rule.mode = rule.effectiveMode(for: trigger)
            rules[trigger.rawValue] = rule
        }
    }

    var enabled: Set<MergeWorkflowTrigger> {
        Set(MergeWorkflowTrigger.allCases.filter { self[$0].mode != .off })
    }

    func hasSetting(for trigger: MergeWorkflowTrigger) -> Bool {
        rules[trigger.rawValue] != nil
    }
}


extension MergeWorkflowTrigger {
    var allowedModes: [MergeWorkflowMode] { self == .reviewWaiting ? [.off, .notify] : MergeWorkflowMode.allCases }
}

extension AutomationSettings {
    var canConfigureInfrastructureRetry: Bool {
        hasAutomaticPublicActionConsent && workflowRules[.pipelineFailure].mode == .assistant
            && !MergeWorkflowRule.projectPaths(workflowRules[.pipelineFailure].projects).isEmpty
    }
}

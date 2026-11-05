import Foundation

enum AutomationPackageDecision: String, Codable, Equatable, Sendable {
    case undecided, enabled, disabled
}

enum MergeWorkflowMode: String, Codable, Equatable, Sendable {
    case off, preview, notify, assistant
}

struct MergeWorkflowRule: Codable, Equatable, Sendable {
    var mode: MergeWorkflowMode = .off
    var projects = ""
    var targetBranches = ""
    var requiredLabel = ""
    var retryInfrastructureFailure = false
    var waitHours = 48

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

    subscript(trigger: MergeWorkflowTrigger) -> MergeWorkflowRule {
        get { rules[trigger.rawValue] ?? MergeWorkflowRule() }
        set { rules[trigger.rawValue] = newValue }
    }

    var enabled: Set<MergeWorkflowTrigger> {
        Set(MergeWorkflowTrigger.allCases.filter { self[$0].mode != .off })
    }

    func hasSetting(for trigger: MergeWorkflowTrigger) -> Bool {
        rules[trigger.rawValue] != nil
    }
}

import Foundation

struct GitLabMRDependencySnapshot: Sendable {
    let requests: [GitLabMergeRequest]
    let hasHiddenDependency: Bool
    var lastKnownRequests: [GitLabMergeRequest] = []

    /// A hidden dependency cannot prove that a previously readable link disappeared.
    func retainingHiddenReferences(from previous: Self?) -> Self {
        guard hasHiddenDependency, let previous else { return self }
        let visible = Set(requests.map { "\($0.projectID):\($0.iid)" })
        var retained: [String: GitLabMergeRequest] = [:]
        for request in previous.requests + previous.lastKnownRequests where request.state == "opened" {
            let key = "\(request.projectID):\(request.iid)"
            if !visible.contains(key), retained[key] == nil { retained[key] = request }
        }
        var snapshot = self
        snapshot.lastKnownRequests = retained.values.sorted { ($0.projectID, $0.iid) < ($1.projectID, $1.iid) }
        return snapshot
    }
}

/// Read-only dependency evidence. It does not grant or restrict automation actions.
struct MergeRequestDependencySummary: Equatable, Sendable {
    enum Source: String, Codable, Hashable, Sendable { case gitLab, stack }
    enum Issue: String, Codable, Hashable, Sendable {
        case dependenciesUnavailable, hiddenDependency, stackUnavailable, stackIncomplete, stackAmbiguous
    }
    struct Predecessor: Equatable, Sendable, Identifiable {
        let projectID: Int
        let iid: Int
        let title: String
        let url: URL
        let sources: Set<Source>
        var isCurrent = true
        var id: String { "\(projectID):\(iid)" }
        func reference(relativeTo project: Int) -> String {
            projectID == project ? "!\(iid)" : "\(url.gitLabProjectPath.split(separator: "/").last ?? "") !\(iid)"
        }
    }
    let stackPosition: String?
    let predecessors: [Predecessor]
    let issues: Set<Issue>

    init(request: GitLabMergeRequest, stack: MergeRequestStackSnapshot?, dependencies: GitLabMRDependencySnapshot?,
         unavailableSources: Set<Source> = []) {
        var issues: Set<Issue> = []
        var references: [String: Predecessor] = [:]
        func add(_ parent: GitLabMergeRequest, source: Source, isCurrent: Bool? = nil) {
            let key = "\(parent.projectID):\(parent.iid)"
            let current = isCurrent ?? !unavailableSources.contains(source)
            if let previous = references[key] {
                references[key] = Predecessor(projectID: parent.projectID, iid: parent.iid,
                    title: parent.title, url: parent.webURL, sources: previous.sources.union([source]),
                    isCurrent: previous.isCurrent || current)
            } else {
                references[key] = Predecessor(projectID: parent.projectID, iid: parent.iid,
                    title: parent.title, url: parent.webURL, sources: [source], isCurrent: current)
            }
        }
        if dependencies == nil || unavailableSources.contains(.gitLab) { issues.insert(.dependenciesUnavailable) }
        if dependencies?.hasHiddenDependency == true { issues.insert(.hiddenDependency) }
        for parent in dependencies?.lastKnownRequests ?? [] where parent.state == "opened" {
            guard Self.valid(parent, relativeTo: request), parent.projectID != request.projectID || parent.iid != request.iid else { continue }
            add(parent, source: .gitLab, isCurrent: false)
        }
        for parent in dependencies?.requests ?? [] where parent.state == "opened" {
            guard Self.valid(parent, relativeTo: request), parent.projectID != request.projectID || parent.iid != request.iid else {
                issues.insert(.dependenciesUnavailable)
                continue
            }
            add(parent, source: .gitLab)
        }

        var position: String?
        if let stack {
            let graph = DependencyStack(request: request, snapshot: stack)
            issues.formUnion(graph.issues)
            if let parent = graph.parent { add(parent, source: .stack) }
            position = graph.position
            // A direct GitLab blocker later in this chain contradicts its merge order.
            if references.values.contains(where: { $0.sources.contains(.gitLab)
                && $0.projectID == request.projectID && graph.successors.contains($0.iid) }) {
                issues.insert(.stackAmbiguous)
                position = nil
            }
        } else { issues.insert(.stackUnavailable) }
        if unavailableSources.contains(.stack) {
            issues.insert(.stackUnavailable)
            position = nil
        }
        stackPosition = position
        predecessors = references.values.sorted { ($0.projectID, $0.iid) < ($1.projectID, $1.iid) }
        self.issues = issues
    }

    static func valid(_ parent: GitLabMergeRequest, relativeTo child: GitLabMergeRequest) -> Bool {
        guard let host = child.webURL.host else { return false }
        let authority = child.webURL.port.map { "\(host):\($0)" } ?? host
        return parent.projectID > 0 && parent.iid > 0 && parent.webURL.scheme == child.webURL.scheme
            && parent.webURL.host == child.webURL.host && parent.webURL.port == child.webURL.port
            && parent.webURL.isGitLabMergeRequest(host: authority, iid: parent.iid)
    }

    /// A cached graph or a late task must describe the exact displayed branch context.
    struct Context: Hashable, Sendable {
        let projectID: Int
        let iid: Int
        let url: URL
        let head: String?
        let sourceProjectID: Int?
        let source: String
        let targetProjectID: Int?
        let target: String
        let state: String
        init(_ request: GitLabMergeRequest) {
            projectID = request.projectID; iid = request.iid; url = request.webURL; head = request.sha
            sourceProjectID = request.sourceProjectID; source = request.sourceBranch
            targetProjectID = request.targetProjectID; target = request.targetBranch; state = request.state
        }
    }

}


/// Presentation requires a complete linear chain; legacy automation numbering stays independent.
private struct DependencyStack {
    var parent: GitLabMergeRequest?
    var position: String?
    var issues: Set<MergeRequestDependencySummary.Issue> = []
    var successors: Set<Int> = []

    init(request: GitLabMergeRequest, snapshot: MergeRequestStackSnapshot) {
        typealias Summary = MergeRequestDependencySummary
        let requests = snapshot.requests.filter { $0.state == "opened" && $0.projectID == request.projectID
            && Summary.valid($0, relativeTo: request) }
        guard request.state == "opened", !snapshot.defaultBranch.isEmpty,
              requests.contains(where: { Summary.Context($0) == Summary.Context(request) }) else {
            issues.insert(.stackUnavailable)
            return
        }
        let byID = Dictionary(requests.map { ($0.iid, $0) }, uniquingKeysWith: { first, _ in first })
        let byBranch = Dictionary(grouping: requests, by: \.sourceBranch)
        var parents: [Int: [Int]] = [:]
        var children: [Int: [Int]] = [:]
        for child in requests where child.targetBranch != snapshot.defaultBranch {
            guard let target = child.targetProjectID, target > 0, !child.targetBranch.isEmpty else { continue }
            let matches = (byBranch[child.targetBranch] ?? []).filter {
                $0.iid != child.iid && $0.sourceProjectID == target && $0.targetProjectID == target
                    && $0.sourceBranch != $0.targetBranch && !$0.sourceBranch.isEmpty
            }
            parents[child.iid] = matches.map(\.iid)
            for match in matches { children[match.iid, default: []].append(child.iid) }
        }
        if let candidates = parents[request.iid], candidates.count == 1 { parent = byID[candidates[0]] }
        var component: Set<Int> = []
        var pending = [request.iid]
        while let node = pending.popLast() {
            guard component.insert(node).inserted else { continue }
            pending.append(contentsOf: (parents[node] ?? []) + (children[node] ?? []))
        }
        var remaining = children[request.iid] ?? []
        while let node = remaining.popLast() {
            if successors.insert(node).inserted { remaining.append(contentsOf: children[node] ?? []) }
        }
        guard component.count > 1 else { return }
        let roots = component.filter { parents[$0, default: []].isEmpty }
        guard roots.count == 1, let root = roots.first,
              component.allSatisfy({ parents[$0, default: []].count <= 1 }) else {
            issues.insert(.stackAmbiguous)
            return
        }
        guard byID[root]?.targetBranch == snapshot.defaultBranch,
              component.allSatisfy({ byID[$0]?.sourceProjectID == request.projectID
                  && byID[$0]?.targetProjectID == request.projectID }) else {
            issues.insert(.stackIncomplete)
            return
        }
        // A valid branch split has clear predecessors but no single n/N position.
        guard component.allSatisfy({ children[$0, default: []].count <= 1 }) else { return }
        var ordered: [Int] = []
        var next: Int? = root
        while let node = next, !ordered.contains(node) {
            ordered.append(node)
            next = children[node]?.first
        }
        guard next == nil, ordered.count == component.count, let index = ordered.firstIndex(of: request.iid) else {
            issues.insert(.stackAmbiguous)
            return
        }
        position = "\(index + 1)/\(ordered.count)"
    }
}

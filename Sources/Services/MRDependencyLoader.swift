import Foundation

/// Bounded, account-scoped reads for presentation only. Failures retain last-known evidence.
@MainActor
final class MRDependencyLoader {
    private typealias Context = MergeRequestDependencySummary.Context
    private typealias ID = MergeRequestAttentionMonitor.Item.ID
    private struct Account: Equatable {
        let host: String
        let username: String
        let revision: UInt64
    }
    private struct Entry<Value: Sendable> {
        let value: Value?
        let checkedAt: Date
        let succeeded: Bool
        func isCurrent(at now: Date) -> Bool {
            succeeded && now >= checkedAt
        }
    }
    private var account: Account?
    private var generation = 0
    private var projects: [Int: Entry<MergeRequestStackSnapshot>] = [:]
    private var dependencies: [Context: Entry<GitLabMRDependencySnapshot>] = [:]

    func refresh(requests: [GitLabMergeRequest], glab: GlabService, host: String,
                 now: Date = Date()) async -> [MergeRequestAttentionMonitor.Item.ID: MergeRequestDependencySummary] {
        guard glab.resolvedHost == host, let username = glab.currentUsername else { return [:] }
        let current = Account(host: host, username: username, revision: glab.accountRevision)
        if account != current {
            account = current
            projects = [:]
            dependencies = [:]
        }
        generation += 1
        let token = generation
        func stillCurrent() -> Bool {
            !Task.isCancelled && generation == token && account == current
                && glab.resolvedHost == host && glab.currentUsername == username && glab.accountRevision == current.revision
        }
        let rows = Dictionary(requests.filter { $0.state == "opened" && $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid) }
            .map { (ID(projectID: $0.projectID, iid: $0.iid), $0) }, uniquingKeysWith: { first, _ in first }).values
        let contexts = Set(rows.map(Context.init))
        dependencies = dependencies.filter { contexts.contains($0.key) }
        let projectIDs = Set(rows.map(\.projectID))
        projects = projects.filter { projectIDs.contains($0.key) }
        let dueProjects = projectIDs.filter { due(projects[$0]?.checkedAt, at: now) }
            .sorted { (projects[$0]?.checkedAt ?? .distantPast, $0) < (projects[$1]?.checkedAt ?? .distantPast, $1) }.prefix(3)
        let projectResults = await withTaskGroup(of: (Int, MergeRequestStackSnapshot?).self) { group in
            for project in dueProjects {
                group.addTask { [glab] in
                    let snapshot = try? await glab.fetchMergeRequestStackSnapshot(projectID: project, host: host)
                    return (project, snapshot)
                }
            }
            var results: [(Int, MergeRequestStackSnapshot?)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard stillCurrent() else { return [:] }
        for (project, value) in projectResults {
            projects[project] = .init(value: value ?? projects[project]?.value, checkedAt: now, succeeded: value != nil)
        }
        let dueRequests = rows.filter { due(dependencies[Context($0)]?.checkedAt, at: now) }.sorted {
            (dependencies[Context($0)]?.checkedAt ?? .distantPast, $0.projectID, $0.iid)
                < (dependencies[Context($1)]?.checkedAt ?? .distantPast, $1.projectID, $1.iid)
        }.prefix(12)
        let selected = Array(dueRequests)
        for start in stride(from: 0, to: selected.count, by: 4) {
            let batch = selected[start..<min(start + 4, selected.count)]
            let results = await withTaskGroup(of: (Context, GitLabMRDependencySnapshot?).self) { group in
                for request in batch {
                    group.addTask { [glab] in
                        let snapshot = try? await glab.fetchMergeRequestDependencySnapshot(
                            projectID: request.projectID, iid: request.iid, host: host)
                        return (Context(request), snapshot)
                    }
                }
                var results: [(Context, GitLabMRDependencySnapshot?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard stillCurrent() else { return [:] }
            for (context, value) in results {
                let previous = dependencies[context]?.value
                let observed = value?.retainingHiddenReferences(from: previous)
                dependencies[context] = .init(value: observed ?? previous,
                    checkedAt: now, succeeded: value != nil)
            }
        }
        guard stillCurrent() else { return [:] }
        return Dictionary(uniqueKeysWithValues: rows.map { request in
            let stack = projects[request.projectID]
            let explicit = dependencies[Context(request)]
            var unavailable: Set<MergeRequestDependencySummary.Source> = []
            if stack?.isCurrent(at: now) != true { unavailable.insert(.stack) }
            if explicit?.isCurrent(at: now) != true { unavailable.insert(.gitLab) }
            return (ID(projectID: request.projectID, iid: request.iid), MergeRequestDependencySummary(
                request: request, stack: stack?.value, dependencies: explicit?.value, unavailableSources: unavailable))
        })
    }

    private func due(_ checkedAt: Date?, at now: Date) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= 60 || now < checkedAt
    }
}

import Foundation

@MainActor
struct ReviewReadService {
    enum Error: LocalizedError {
        case changed, outsideScope, unavailable, dataLimit

        var errorDescription: String? {
            switch self {
            case .changed: "The account or merge request changed during review. Start a new review."
            case .outsideScope: "The requested project is outside this review's repository scope."
            case .unavailable: "The requested data is unavailable on the current host."
            case .dataLimit: "The requested data exceeds the review tool's size limit."
            }
        }
    }

    struct Context: Encodable {
        let repository: String
        let number: Int
        let head: String
        let title: String
        let description: String?
        let capabilities: [String]
    }

    let glab: GlabService
    let target: GitLabMergeRequest
    let host: String
    let user: GitLabAuthenticatedUser
    let relatedProjects: [String: Int]
    let isCurrent: @MainActor @Sendable () -> Bool

    func currentRequest() async throws -> GitLabMergeRequest {
        guard isCurrent() else { throw Error.changed }
        async let identity = glab.fetchAuthenticatedUser(host: host, expectedUsername: user.username)
        async let request = glab.fetchMergeRequest(projectID: target.projectID, iid: target.iid, host: host)
        let (authenticated, live) = try await (identity, request)
        guard isCurrent(), authenticated == user, live.isOpen, live.webURL == target.webURL,
              live.sha == target.sha, live.semanticContextFingerprint == target.semanticContextFingerprint,
              live.sourceProjectID == target.sourceProjectID, live.sourceBranch == target.sourceBranch else { throw Error.changed }
        return live
    }

    func read(_ command: ReviewCommand) async throws -> String {
        if command == .help { return ReviewCommand.helpText }
        let live = try await currentRequest()
        guard let head = live.sha, GlabService.isFullGitSHA(head) else { throw Error.changed }
        let value: String
        switch command {
        case .help: return ReviewCommand.helpText
        case .context:
            value = try Self.json(Context(repository: live.webURL.gitLabProjectPath, number: live.iid,
                head: head, title: live.title, description: live.description,
                capabilities: ["context", "diff", "discussions", "file show", "work-item show", "change show"]))
        case .diff:
            let bytes: Data = try await glab.mergeRequestAPI("/projects/\(live.projectID)/merge_requests/\(live.iid)/raw_diffs",
                host: host, decode: { $0 })
            value = try Self.text(bytes)
            _ = try await currentRequest()
        case .discussions:
            let threads = try await glab.fetchMergeRequestDiscussions(projectID: live.projectID, iid: live.iid, host: host)
            value = try Self.json(threads)
        case .file(let path):
            guard let project = live.sourceProjectID, project > 0 else { throw Error.unavailable }
            value = try Self.text(await glab.fetchReviewSourceFile(projectID: project, path: path, head: head, host: host))
        case .workItem(let project, let number):
            let projectID = try resolveProject(project, for: live)
            struct WorkItem: Codable {
                let title: String
                let description: String?
                let state: String?
            }
            let item: WorkItem = try await glab.mergeRequestAPI("/projects/\(projectID)/issues/\(number)", host: host)
            value = try Self.json(item)
        case .change(let project, let number):
            let projectID = try resolveProject(project, for: live)
            let change = try await glab.fetchMergeRequest(projectID: projectID, iid: number, host: host)
            value = try Self.json(Context(repository: change.webURL.gitLabProjectPath, number: change.iid,
                head: change.sha ?? "", title: change.title, description: change.description, capabilities: []))
        }
        guard isCurrent() else { throw Error.changed }
        return value
    }

    private func resolveProject(_ path: String?, for request: GitLabMergeRequest) throws -> Int {
        guard let path, path != request.webURL.gitLabProjectPath else { return request.projectID }
        guard let projectID = relatedProjects[path], projectID > 0 else { throw Error.outsideScope }
        return projectID
    }

    private static func text(_ bytes: Data) throws -> String {
        guard bytes.count <= 524_288 else { throw Error.dataLimit }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Error.unavailable }
        return text
    }

    private static func json(_ value: some Encodable) throws -> String {
        try text(JSONEncoder().encode(value))
    }
}

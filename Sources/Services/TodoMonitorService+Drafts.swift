import Foundation

extension TodoMonitorService {
    func canMarkMergeRequestReady(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard item.isAuthored, let request = item.mergeRequest,
              request.projectID == item.id.projectID, request.iid == item.id.iid,
              request.state == "opened", request.draft == true,
              request.author.username == glab.currentUsername,
              let host = glab.resolvedHost, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              let sha = request.sha, GlabService.isFullGitSHA(sha) else { return false }
        return true
    }

    func markMergeRequestReady(for item: MergeRequestAttentionMonitor.Item) async throws {
        guard canMarkMergeRequestReady(item), let request = item.mergeRequest, let sha = request.sha,
              let host = glab.resolvedHost, let username = glab.currentUsername,
              let executable = glab.glabPath else { throw CancellationError() }
        let revision = glab.accountRevision
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username)
        let sameAccount: @MainActor @Sendable () -> Bool = {
            self.glab.accountRevision == revision && self.glab.glabPath == executable
                && self.glab.resolvedHost == host && self.glab.currentUsername == username
        }
        guard sameAccount() else { throw GlabError.notAuthenticated }
        _ = try await glab.markMergeRequestReady(projectID: request.projectID, iid: request.iid, headSHA: sha,
            host: host, expectedUser: user, shouldProceed: sameAccount)
        guard sameAccount() else { throw GlabError.notAuthenticated }
        await refreshFromGitLab(for: item.id)
    }
}

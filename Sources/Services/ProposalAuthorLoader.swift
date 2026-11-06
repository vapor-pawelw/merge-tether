import Foundation
import Observation

@MainActor @Observable
final class ProposalAuthorLoader {
    typealias Account = GlabService.AuthedHost
    private var cachedRequest: GitLabMergeRequest?
    private var cachedTarget: MRAutomationScope.Target?
    private var loadingTarget: MRAutomationScope.Target?
    @ObservationIgnored private var generation = UUID()
    private let fetch: @MainActor (MRAutomationScope.Target) async throws -> GitLabMergeRequest
    private let currentAccount: @MainActor () -> Account?

    init(fetch: @escaping @MainActor (MRAutomationScope.Target) async throws -> GitLabMergeRequest,
         currentAccount: @escaping @MainActor () -> Account?) {
        self.fetch = fetch
        self.currentAccount = currentAccount
    }

    convenience init(glab: GlabService) {
        self.init(fetch: { target in
            try await glab.fetchMergeRequest(projectID: target.projectID, iid: target.iid ?? 0, host: target.host)
        }, currentAccount: {
            guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
            return .init(host: host, username: username)
        })
    }

    func load(_ proposal: MergeRequestBoardSnapshot.Proposal) async {
        let token = UUID()
        generation = token
        loadingTarget = nil
        guard accountMatches(proposal.target), let iid = proposal.target.iid, iid > 0,
              proposal.target.projectID > 0, proposal.url.isGitLabMergeRequest(host: proposal.target.host, iid: iid) else {
            cachedRequest = nil
            cachedTarget = nil
            return
        }
        guard ProposalMRContext(proposal: proposal).author == nil else { return }
        guard request(for: proposal) == nil else { return }
        cachedRequest = nil
        cachedTarget = nil
        loadingTarget = proposal.target
        defer { if generation == token { loadingTarget = nil } }
        do {
            let request = try await fetch(proposal.target)
            guard generation == token, !Task.isCancelled, accountMatches(proposal.target),
                  ProposalMRContext.matches(request, proposal: proposal) else { return }
            cachedTarget = proposal.target
            cachedRequest = request
        } catch {
            // Metadata is optional. Keep the proposal actionable and its author honestly unknown.
        }
    }

    func request(for proposal: MergeRequestBoardSnapshot.Proposal) -> GitLabMergeRequest? {
        guard accountMatches(proposal.target), cachedTarget == proposal.target,
              let cachedRequest, ProposalMRContext.matches(cachedRequest, proposal: proposal) else { return nil }
        return cachedRequest
    }

    func isLoading(_ proposal: MergeRequestBoardSnapshot.Proposal) -> Bool {
        accountMatches(proposal.target) && loadingTarget == proposal.target
    }

    private func accountMatches(_ target: MRAutomationScope.Target) -> Bool {
        currentAccount() == .init(host: target.host, username: target.username)
    }
}

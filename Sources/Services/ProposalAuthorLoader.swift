import Foundation
import Observation

@MainActor @Observable
final class ProposalAuthorLoader {
    typealias Account = GlabService.AuthedHost
    private var cachedRequest: GitLabMergeRequest?
    private var cachedTarget: MRAutomationScope.Target?
    private var cachedRevision: UInt64?
    private var loadingTarget: MRAutomationScope.Target?
    @ObservationIgnored private var generation = UUID()
    private let fetch: @MainActor (MRAutomationScope.Target) async throws -> GitLabMergeRequest
    private let currentAccount: @MainActor () -> Account?
    private let accountRevision: @MainActor () -> UInt64
    private let onLoaded: @MainActor (GitLabMergeRequest, MRAutomationScope.Target, URL, UInt64, Date) -> Void

    init(fetch: @escaping @MainActor (MRAutomationScope.Target) async throws -> GitLabMergeRequest,
         currentAccount: @escaping @MainActor () -> Account?,
         accountRevision: @escaping @MainActor () -> UInt64 = { 0 },
         onLoaded: @escaping @MainActor (GitLabMergeRequest, MRAutomationScope.Target, URL, UInt64, Date) -> Void = { _, _, _, _, _ in }) {
        self.fetch = fetch
        self.currentAccount = currentAccount
        self.accountRevision = accountRevision
        self.onLoaded = onLoaded
    }

    convenience init(glab: GlabService,
                     onLoaded: @escaping @MainActor (GitLabMergeRequest, MRAutomationScope.Target, URL, UInt64, Date) -> Void = { _, _, _, _, _ in }) {
        self.init(fetch: { target in
            try await glab.fetchMergeRequest(projectID: target.projectID, iid: target.iid ?? 0, host: target.host)
        }, currentAccount: {
            guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
            return .init(host: host, username: username)
        }, accountRevision: { glab.accountRevision }, onLoaded: onLoaded)
    }

    func load(_ proposal: MergeRequestBoardSnapshot.Proposal, force: Bool = false, displayMetadata: Bool = false) async {
        let token = UUID()
        let revision = accountRevision()
        let readStartedAt = Date()
        generation = token
        loadingTarget = nil
        guard accountMatches(proposal.target), let iid = proposal.target.iid, iid > 0,
              proposal.target.projectID > 0, proposal.url.isGitLabMergeRequest(host: proposal.target.host, iid: iid) else {
            cachedRequest = nil
            cachedTarget = nil
            return
        }
        guard force || displayMetadata || ProposalMRContext(proposal: proposal).author == nil else { return }
        guard force || request(for: proposal) == nil else { return }
        cachedRequest = nil
        cachedTarget = nil
        loadingTarget = proposal.target
        defer { if generation == token { loadingTarget = nil } }
        do {
            let request = try await fetch(proposal.target)
            guard generation == token, !Task.isCancelled, accountRevision() == revision, accountMatches(proposal.target),
                  ProposalMRContext.matches(request, proposal: proposal) else { return }
            cachedTarget = proposal.target
            cachedRequest = request
            cachedRevision = revision
            onLoaded(request, proposal.target, proposal.url, revision, readStartedAt)
        } catch {
            // Metadata is optional. Keep the proposal actionable and its author honestly unknown.
        }
    }

    func request(for proposal: MergeRequestBoardSnapshot.Proposal) -> GitLabMergeRequest? {
        guard accountMatches(proposal.target), cachedTarget == proposal.target, cachedRevision == accountRevision(),
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

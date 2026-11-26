import Foundation

/// Factual display metadata never grants management membership or action permissions.
struct MRDisplayMetadataCache {
    struct Account: Equatable {
        let host: String
        let username: String
        let revision: UInt64
    }
    private struct Entry {
        let request: GitLabMergeRequest
        let approvalProgress: MergeRequestApprovalProgress?
        let readStartedAt: Date
    }
    private var account: Account?
    private var entries: [MRAutomationScope.Target: Entry] = [:]

    mutating func record(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target, url: URL,
                         readStartedAt: Date, account: Account, currentAccount: Account,
                         approvalProgress: MergeRequestApprovalProgress? = nil) -> Bool {
        guard account == currentAccount, target.host == account.host, target.username == account.username,
              let iid = target.iid, iid > 0, target.projectID > 0,
              request.projectID == target.projectID, request.iid == iid, request.webURL == url,
              url.isGitLabMergeRequest(host: target.host, iid: iid),
              request.author.id > 0, !request.author.username.isEmpty,
              [.opened, .merged, .closed].contains(request.state) else { return false }
        if self.account != account {
            entries = [:]
            self.account = account
        }
        guard entries[target].map({ readStartedAt >= $0.readStartedAt }) ?? true else { return false }
        entries[target] = Entry(request: request, approvalProgress: approvalProgress, readStartedAt: readStartedAt)
        return true
    }

    func request(for target: MRAutomationScope.Target, url: URL, account: Account) -> GitLabMergeRequest? {
        guard self.account == account, target.host == account.host, target.username == account.username,
              let request = entries[target]?.request, request.webURL == url else { return nil }
        return request
    }

    func approvalProgress(for target: MRAutomationScope.Target, request: GitLabMergeRequest,
                          account: Account) -> MergeRequestApprovalProgress? {
        guard self.account == account, let entry = entries[target],
              entry.request.webURL == request.webURL, entry.request.sha == request.sha,
              entry.request.targetBranch == request.targetBranch, entry.request.state == request.state else { return nil }
        return entry.approvalProgress
    }

    func requests(account: Account) -> [GitLabMergeRequest] {
        guard self.account == account else { return [] }
        return entries.values.map(\.request).sorted { ($0.projectID, $0.iid) < ($1.projectID, $1.iid) }
    }
}

import Foundation

struct ManualReviewTarget: Sendable {
    let host: String
    let username: String
    let projectID: Int
    let iid: Int
    let url: URL

    func matchesAccount(host: String?, username: String?) -> Bool {
        self.host == host && self.username == username
    }

    func accepts(_ request: GitLabMergeRequest, treatAssignedMergeRequestsAsOwn: Bool = true) -> Bool {
        request.isOpen && request.projectID == projectID && request.iid == iid
            && request.webURL == url && url.isGitLabMergeRequest(host: host, iid: iid)
            && request.author.username != username
            && !request.isOwned(by: username, includingAssignee: treatAssignedMergeRequestsAsOwn) && request.sha?.isEmpty == false
    }
}

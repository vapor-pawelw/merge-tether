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

    func accepts(_ request: GitLabMergeRequest, treatSoleAssigneeAsOwn: Bool = true) -> Bool {
        request.isOpen && request.projectID == projectID && request.iid == iid
            && request.webURL == url && url.isGitLabMergeRequest(host: host, iid: iid)
            && !request.isOwned(by: username, includingSoleAssignee: treatSoleAssigneeAsOwn) && request.sha?.isEmpty == false
    }
}

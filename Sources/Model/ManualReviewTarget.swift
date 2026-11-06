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

    func accepts(_ request: GitLabMergeRequest) -> Bool {
        request.state == "opened" && request.projectID == projectID && request.iid == iid
            && request.webURL == url && url.isGitLabMergeRequest(host: host, iid: iid)
            && request.author.username != username && request.sha?.isEmpty == false
    }
}

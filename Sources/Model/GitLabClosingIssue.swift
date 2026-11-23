import Foundation
import MergeTetherRemote

struct MRIssueCandidate: Encodable, Equatable, Sendable {
    enum Relation: String, Encodable, Sendable { case closing, related, mentioned }
    let issue: RemoteMRIssue
    let relation: Relation
    let description: String?

    init(issue: RemoteMRIssue, relation: Relation, description: String? = nil) {
        self.issue = issue
        self.relation = relation
        self.description = description
    }
}

struct GitLabClosingIssue: Decodable {
    let id: String?
    let iid: Int?
    let title: String?
    let url: URL?
    let projectID: Int?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id, iid, title, description
        case url = "web_url", projectID = "project_id"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        // GitLab returns an integer ID for its own issues and a string key for external issues.
        id = try? fields.decode(String.self, forKey: .id)
        iid = try fields.decodeIfPresent(Int.self, forKey: .iid)
        title = try fields.decodeIfPresent(String.self, forKey: .title)
        url = (try? fields.decode(String.self, forKey: .url)).flatMap { URL(string: $0) }
        projectID = try fields.decodeIfPresent(Int.self, forKey: .projectID)
        description = try fields.decodeIfPresent(String.self, forKey: .description)
    }

    func candidate(in request: GitLabMergeRequest, relation: MRIssueCandidate.Relation) -> MRIssueCandidate? {
        guard let issue = displayIssue else { return nil }
        var resolved = issue
        if issue.linkURL == nil, projectID == request.projectID, let iid, iid > 0,
           var parts = URLComponents(url: request.webURL, resolvingAgainstBaseURL: false),
           let separator = parts.path.range(of: "/-/merge_requests/", options: .backwards) {
            parts.path = String(parts.path[..<separator.lowerBound]) + "/-/issues/\(iid)"
            parts.query = nil
            parts.fragment = nil
            resolved = .init(reference: issue.reference, title: issue.title, url: parts.url)
        }
        return .init(issue: resolved, relation: relation, description: description)
    }

    var displayIssue: RemoteMRIssue? {
        let name = Self.singleLine(title, limit: 160)
        let key = iid.flatMap { $0 > 0 ? "#\($0)" : nil } ?? Self.singleLine(id, limit: 100)
        guard let reference = key ?? Self.singleLine(name, limit: 100) else { return nil }
        let issue = RemoteMRIssue(reference: reference, title: key == nil ? nil : name, url: url)
        return .init(reference: issue.reference, title: issue.title, url: issue.linkURL)
    }

    static func singleLine(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(limit))
    }
}

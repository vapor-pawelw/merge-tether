import Foundation
import MergeTetherRemote

struct GitLabClosingIssue: Decodable {
    let id: String?
    let iid: Int?
    let title: String?
    let url: URL?

    private enum CodingKeys: String, CodingKey { case id, iid, title; case url = "web_url" }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        // GitLab returns an integer ID for its own issues and a string key for external issues.
        id = try? fields.decode(String.self, forKey: .id)
        iid = try fields.decodeIfPresent(Int.self, forKey: .iid)
        title = try fields.decodeIfPresent(String.self, forKey: .title)
        url = (try? fields.decode(String.self, forKey: .url)).flatMap { URL(string: $0) }
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

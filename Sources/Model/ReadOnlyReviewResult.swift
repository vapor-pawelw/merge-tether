import Foundation

struct ReadOnlyReviewResult: Decodable, Sendable {
    struct Draft: Decodable, Equatable, Sendable {
        let body: String
        let path: String?
        let line: Int?
        let discussionID: String?

        var isValid: Bool {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  body.utf8.count <= 6000, !DraftPublicationRisk.hasQuickAction(in: body) else { return false }
            if let discussionID { return !discussionID.isEmpty && path == nil && line == nil }
            if let path, let line { return ReviewCommand.validPath(path) && line > 0 }
            return path == nil && line == nil
        }
    }

    let status: AssistantJobResult.Status
    let summary: String
    let blocker: String?
    let drafts: [Draft]

    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["succeeded","blocked"]},"summary":{"type":"string"},"blocker":{"type":["string","null"]},"drafts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"body":{"type":"string"},"path":{"type":["string","null"]},"line":{"type":["integer","null"]},"discussionID":{"type":["string","null"]}},"required":["body","path","line","discussionID"]}}},"required":["status","summary","blocker","drafts"]}"#

    static func decode(_ data: Data, assistant: AutomationAssistant) throws -> Self {
        if assistant == .claude {
            struct Envelope: Decodable {
                struct Denial: Decodable {}
                let is_error: Bool
                let subtype: String?
                let permission_denials: [Denial]?
                let structured_output: ReadOnlyReviewResult?
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard !envelope.is_error, envelope.subtype == nil || envelope.subtype == "success",
                  envelope.permission_denials?.isEmpty != false, let result = envelope.structured_output else {
                throw AssistantJobResult.Error.assistantFailed
            }
            return result
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

struct GitLabReviewDiff: Decodable, Sendable {
    let oldPath: String
    let newPath: String
    let diff: String

    enum CodingKeys: String, CodingKey { case oldPath = "old_path", newPath = "new_path", diff }

    func containsNewLine(_ line: Int) -> Bool {
        var cursor: Int?
        for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if row.hasPrefix("@@ ") {
                cursor = row.split(separator: " ").dropFirst(2).first.flatMap { range in
                    range.hasPrefix("+") ? Int(range.dropFirst().prefix { $0.isNumber }) : nil
                }
            } else if let current = cursor, row.hasPrefix("+") || row.hasPrefix(" ") {
                if current == line { return true }
                if current == Int.max { return false }
                cursor = current + 1
            }
        }
        return false
    }
}

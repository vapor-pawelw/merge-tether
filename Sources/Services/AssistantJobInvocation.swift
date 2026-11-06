import Foundation

/// Executable MR tasks have full CLI tool access. GitLab action authorization
/// remains in their task instructions and the app's live policy/evidence checks.
struct AssistantJobInvocation {
    let workspace: URL
    let evidenceRoot: URL

    var helperEvidenceDirectories: [URL] {
        ["verdicts", "ai-assessments", "follow-up-preflight", "follow-up-verifications", "follow-up-locks"]
            .map { evidenceRoot.appending(path: $0, directoryHint: .isDirectory) }
    }

    var schemaURL: URL { workspace.appending(path: "schema.json") }
    var resultURL: URL { workspace.appending(path: "result.json") }
    var claudeTools: String { "default" }
    var claudeSettings: String { #"{"sandbox":{"enabled":false}}"# }

    func codexArguments(model: CodexReviewModel?, thinking: CodexReviewThinking?) -> [String] {
        var arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
                         "--dangerously-bypass-approvals-and-sandbox",
                         "--disable", "apps", "--disable", "plugins", "--disable", "memories",
                         "--output-schema", schemaURL.path, "--output-last-message", resultURL.path, "--json"]
        if let model { arguments += ["--model", model.rawValue] }
        if let thinking { arguments += ["-c", "model_reasoning_effort=\"\(thinking.rawValue)\""] }
        return arguments + ["-"]
    }

    var claudeArguments: [String] {
        ["-p", "--dangerously-skip-permissions", "--permission-prompts", "none",
         "--tools", claudeTools, "--settings", claudeSettings,
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
         "--no-session-persistence", "--output-format", "json", "--json-schema", AssistantJobResult.schema]
    }

    func prepareEvidenceDirectories() throws {
        for directory in helperEvidenceDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }
}

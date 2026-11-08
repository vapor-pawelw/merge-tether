import Foundation

/// Presentation copy is separate from evidence and never changes a verification verdict.
enum AgentExplanation {
    static let maximumLength = 200

    static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty || normalized.count > maximumLength ? nil : normalized
    }

    static func instructions(for field: String) -> String {
        """
        The \(field) field is a human-facing explanation in an attention card, not a verification log.
        Write plain English, ideally about 20 words and at most 200 characters, in one or two short sentences.
        Lead with the specific unresolved issue or missing evidence, then the supported next step and who owns it.
        Distinguish work the configured assistant can research, explain or fix from an external decision only a person can supply.
        Do not assign routine research, code corrections or verification to the user, or invent a human decision from uncertainty alone.
        Name the actual subject: for example, 'The reply claims an empty-response test, but no supporting test was found. Evidence is needed before publication.'
        Never start with successful checks, account/MR/branch matches, supplied-snapshot boilerplate or a recap of your process.
        Omit commit hashes, internal IDs, fingerprints, full paths, field names such as headSHA, tool logs and Markdown.
        Explain the consequence for this MR instead of implementation details. Distinguish an unconfirmed claim from a proven error.
        Do not invent a cause, evidence, permission or user action, and do not imply publication or verification has succeeded when it has not.
        When nothing is blocked, briefly say what was confirmed; do not invent a manual task.
        """
    }
}

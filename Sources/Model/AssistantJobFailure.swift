import Foundation

/// A failed or invalid CLI result can still describe partial remote effects.
/// Keep its bounded diagnostics so the user can inspect before retrying.
struct AssistantJobFailure: Error, CustomStringConvertible, Sendable {
    let description: String
    let transcript: String

    init(error: Error, output: ProcessRunner.Output) {
        description = GlabService.redactWorkflowEvidence(String(describing: error))
        transcript = String(GlabService.redactWorkflowEvidence(
            String(decoding: output.stdout, as: UTF8.self) + "\n" + output.stderr).prefix(262_144))
    }
}

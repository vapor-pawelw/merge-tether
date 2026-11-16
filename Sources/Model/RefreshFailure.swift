import Foundation

/// One read that could not confirm an MR row. The card names it instead of a generic refresh failure.
struct RefreshFailure: Equatable, Sendable {
    enum Check: Equatable, Sendable {
        case reviewerFeedback, replyDrafts, workflow, commentOrigin, mergeRequests

        var title: LocalizedStringResource {
            switch self {
            case .reviewerFeedback: .AutomationProgress.progressRefreshFailedFeedback
            case .replyDrafts: .AutomationProgress.progressRefreshFailedDraftReplies
            case .workflow: .AutomationProgress.progressRefreshFailedWorkflow
            case .commentOrigin: .AutomationProgress.progressRefreshFailedCommentOrigin
            case .mergeRequests: .AutomationProgress.progressRefreshFailedMergeRequests
            }
        }
    }

    /// A coarse, display-safe classification. Raw error text stays out of the inline label.
    enum Cause: Equatable, Sendable {
        case gitLabUnreachable, gitLabSignIn, assistantUnavailable, assistantFailed

        init?(_ error: any Error) {
            switch error {
            case GlabError.network, GlabError.timedOut: self = .gitLabUnreachable
            case GlabError.notAuthenticated: self = .gitLabSignIn
            case ReReviewVerifier.VerificationError.unavailable: self = .assistantUnavailable
            case ReReviewVerifier.VerificationError.failed, ReReviewVerifier.VerificationError.incompleteEvidence:
                self = .assistantFailed
            default: return nil
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .gitLabUnreachable: .AutomationProgress.progressFailureCauseGitLabUnreachable
            case .gitLabSignIn: .AutomationProgress.progressFailureCauseGitLabSignIn
            case .assistantUnavailable: .AutomationProgress.progressFailureCauseAssistantUnavailable
            case .assistantFailed: .AutomationProgress.progressFailureCauseAssistantFailed
            }
        }
    }

    let check: Check
    var cause: Cause? = nil
    /// Redacted technical detail for the hover explanation only.
    var detail: String? = nil

    var summary: String {
        let title = String(localized: check.title)
        guard let cause else { return title }
        return String(localized: .AutomationProgress.progressRefreshFailedWithCause(title, String(localized: cause.title)))
    }

    /// Inline text: the exact check when only one failed, otherwise a count with details on hover.
    static func label(_ failures: [RefreshFailure]) -> String? {
        guard let first = failures.first else { return nil }
        return failures.count == 1 ? first.summary
            : String(localized: .AutomationProgress.progressRefreshFailedCount(failures.count))
    }

    static func help(_ failures: [RefreshFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.map { failure in
            [failure.summary, failure.detail?.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n  ")
        }
        return (lines + [String(localized: .AutomationProgress.progressRefreshFailedRetry)]).joined(separator: "\n")
    }
}

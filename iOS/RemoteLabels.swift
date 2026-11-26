import SwiftUI
import MergeTetherRemote

extension RemoteCard {
    var gitLabActionURL: URL? {
        guard id.hasPrefix("mr:") || mergeRequestIID != nil,
              let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        return url
    }

    var repositoryName: String {
        project.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? project
    }
}

extension RemoteLaneID {
    func countedTitle(_ count: Int) -> Text {
        switch self {
        case .own: Text(.Board.boardLaneOwn(count))
        case .reviewed: Text(.Board.boardLaneReviewing(count))
        default: Text(verbatim: "\(String(localized: title)) (\(count.formatted()))")
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .ready: .Remote.remoteReady
        case .attention: .Remote.remoteAttention
        case .todos: .Remote.remoteTodos
        case .drafts: .Remote.remoteDrafts
        case .other: .Remote.remoteOther
        case .own: .Remote.remoteOwn
        case .reviewed: .Remote.remoteReviewed
        }
    }
}
extension RemoteActionKind {
    var title: LocalizedStringResource {
        switch self {
        case .checkThreads: .MergeActions.mergeActionsCheckThreads
        case .markReady: .Remote.remoteMarkReady
        case .merge: .MergeActions.mergeActionsMergeNow
        case .enqueueMerge: .MergeActions.mergeActionsEnqueue
        case .resolveThreads: .MergeActions.mergeActionsResolveConfirm
        case .retryJob: .Remote.remoteRetryJob
        case .publish: .Remote.remotePublish
        case .deleteDraft: .CommentReview.commentReviewDelete
        case .finishCommentReview: .CommentReview.commentReviewFinish
        case .approve: .Remote.remoteApprove
        case .personalApprove: .Board.boardApprovalsApprove
        case .removeApproval: .Board.boardApprovalsRemove
        case .editReviewers: .Board.boardReviewersEdit
        case .editCard: .CommandCenter.commandCenterActions
        case .markDone: .Remote.remoteMarkDone
        case .prepare: .Remote.remotePrepare
        case .handoff: .Remote.remoteHandoff
        case .reReview: .Remote.remoteReReview
        case .verify: .Remote.remoteVerify
        case .publishDraft: .Remote.remotePublishDraft
        case .runReview: .Remote.remoteRunReview
        case .stopJob: .Remote.remoteStopJob
        case .ignoreSuggestion: .FeedbackSuggestions.feedbackSuggestionsIgnore
        case .restoreSuggestion: .FeedbackSuggestions.feedbackSuggestionsRestore
        case .setCommentOrigin: .RemoteDetail.remoteDetailOriginMenuTitle
        case .confirmAIReply: .CommentReview.commentReviewReplyAI
        case .markReplyHuman: .CommentReview.commentReviewMarkHuman
        case .startDraftRegeneration: .DraftRegeneration.draftRegenerationGenerate
        case .applyDraftRegeneration: .DraftRegeneration.draftRegenerationSaveDraft
        case .discardDraftRegeneration: .DraftRegeneration.draftRegenerationDiscard
        }
    }
}

private extension RemoteAction {
    var usesCodingProvider: Bool {
        switch kind {
        case .prepare: !id.hasPrefix("intent:") || codingProvider != nil
        case .handoff, .verify, .retryJob, .runReview, .checkThreads, .startDraftRegeneration: true
        default: false
        }
    }
}

struct RemoteActionLabel: View {
    let action: RemoteAction?
    let title: Text

    var body: some View {
        if let action, action.usesCodingProvider {
            Label { title } icon: {
                CodingProviderIcon(provider: action.codingProvider.flatMap(CodingProviderGlyph.init(rawValue:)))
            }
        } else {
            title
        }
    }
}
extension RemoteCommandResult.Status {
    var title: LocalizedStringResource {
        switch self {
        case .checked: .MergeActions.mergeActionsChecked
        case .queued: .MergeActions.mergeActionsQueued
        case .inTrain: .MergeActions.mergeActionsInTrain
        case .partial: .Remote.remotePartiallyCompleted
        case .running: .Remote.remoteRunning
        case .completed: .Remote.remoteCompleted
        case .changed: .Remote.remoteChanged
        case .failed: .Remote.remoteFailed
        case .uncertain: .Remote.remoteUncertain
        case .limit: .Remote.remoteLimit
        }
    }
}

extension RemotePhoneModel {
    var resultTitle: LocalizedStringResource {
        if isInboxReadResult {
            switch state.result?.status {
            case .partial: return .Board.boardInboxReadPartial
            case .changed: return .Board.boardInboxReadChanged
            case .uncertain: return .Board.boardInboxReadUncertain
            default: break
            }
        }
        return switch completedPersonalApproval {
        case .removeApproval: .Board.boardApprovalsRemoved
        case .personalApprove: .Board.boardApprovalsApproved
        default: state.result?.status.title ?? .Remote.remoteCompleted
        }
    }
}

extension RemotePhoneConnectionStatus {
    var title: LocalizedStringResource {
        switch self {
        case .unpaired: .Remote.remotePair
        case .connecting: .Remote.remoteConnecting
        case .connected: .Remote.remoteConnected
        case .offline: .Remote.remoteUnavailable
        case .failed: .Remote.remoteConnectionFailed
        }
    }
    var help: LocalizedStringResource {
        switch self {
        case .unpaired: .Remote.remotePairHelp
        case .connecting: .Remote.remoteConnectingHelp
        case .connected, .offline: .Remote.remoteUnavailableHelp
        case .failed: .Remote.remoteConnectionFailedHelp
        }
    }
    var symbol: String {
        switch self {
        case .unpaired: "laptopcomputer.and.iphone"
        case .connecting: "laptopcomputer"
        case .connected: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .failed: "exclamationmark.triangle"
        }
    }
}

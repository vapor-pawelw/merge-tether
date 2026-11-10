import SwiftUI
import MergeTetherRemote

extension RemoteLaneID {
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
        case .retryJob: .Remote.remoteRetryJob
        case .publish: .Remote.remotePublish
        case .deleteDraft: .CommentReview.commentReviewDelete
        case .finishCommentReview: .CommentReview.commentReviewFinish
        case .approve: .Remote.remoteApprove
        case .markDone: .Remote.remoteMarkDone
        case .prepare: .Remote.remotePrepare
        case .handoff: .Remote.remoteHandoff
        case .reReview: .Remote.remoteReReview
        case .verify: .Remote.remoteVerify
        }
    }
}
extension RemoteCommandResult.Status {
    var title: LocalizedStringResource {
        switch self {
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

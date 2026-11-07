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

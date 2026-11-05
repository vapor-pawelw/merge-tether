import SwiftUI

struct AuthoredMergeRequestsView: View {
    let requests: [AuthoredMergeRequestStatus]
    let isLoading: Bool
    let hasError: Bool
    let scopeMenu: (GitLabMergeRequest) -> MRAutomationScopeMenu?

    var body: some View {
        if requests.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if hasError {
                    Label {
                        Text(.Menu.menuAuthoredStale)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.12))
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(AuthoredMergeRequestStatus.orderedForMerge(requests)) { status in
                            AuthoredMergeRequestRow(status: status)
                            if let menu = scopeMenu(status.request) {
                                menu.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 8)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if isLoading {
                ProgressView {
                    Text(.Menu.menuAuthoredLoading)
                }
            } else if hasError {
                ContentUnavailableView {
                    Label {
                        Text(.Menu.menuAuthoredError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text(.Menu.menuAuthoredEmptyTitle)
                    } icon: {
                        Image(systemName: "arrow.triangle.merge")
                    }
                } description: {
                    Text(.Menu.menuAuthoredEmptyDescription)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AuthoredMergeRequestRow: View {
    let status: AuthoredMergeRequestStatus

    var body: some View {
        Link(destination: status.request.webURL) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("!\(status.request.iid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(status.request.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    RepositoryPathText(projectPath)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(.Menu.menuAuthoredTargetBranch(status.request.targetBranch))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let pipeline = status.request.headPipeline {
                        Label {
                            Text(pipeline.statusLabel)
                        } icon: {
                            Image(systemName: pipeline.statusSymbol)
                                .foregroundStyle(pipeline.statusTint)
                        }
                    }

                    if status.blockers.isEmpty {
                        Label {
                            Text(.Menu.menuAuthoredReady)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(.green)
                    } else {
                        ForEach(status.blockers, id: \.self) { blocker in
                            Label {
                                if blocker == .other, let mergeStatus = status.request.detailedMergeStatus {
                                    Text(.Menu.menuAuthoredMergeCheck(mergeStatus.replacingOccurrences(of: "_", with: " ")))
                                } else {
                                    Text(blocker.displayLabel)
                                }
                            } icon: {
                                Image(systemName: blocker == .checking ? "clock" : "exclamationmark.circle")
                            }
                            .foregroundStyle(blocker == .checking ? Color.secondary : Color.orange)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(.Menu.menuActionOpenInBrowser))
    }

    private var projectPath: String {
        let parts = status.request.webURL.path.split(separator: "/")
        if let separator = parts.lastIndex(of: "-"), separator >= 2,
           parts.dropFirst(separator + 1).first == "merge_requests" {
            return parts[..<separator].joined(separator: "/")
        }
        return String(localized: .Menu.menuAuthoredProject(status.request.projectID))
    }
}

private extension GitLabMergeRequest.Pipeline {
    var statusLabel: LocalizedStringResource {
        switch status {
        case "success": .Menu.menuAuthoredPipelineSuccess
        case "failed": .Menu.menuAuthoredPipelineFailed
        case "running": .Menu.menuAuthoredPipelineRunning
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled", "waiting_for_callback":
            .Menu.menuAuthoredPipelinePending
        case "canceled", "canceling": .Menu.menuAuthoredPipelineCanceled
        case "skipped": .Menu.menuAuthoredPipelineSkipped
        case "manual": .Menu.menuAuthoredPipelineManual
        default: .Menu.menuAuthoredPipeline(status.replacingOccurrences(of: "_", with: " "))
        }
    }

    var statusSymbol: String {
        switch status {
        case "success": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "running": "arrow.triangle.2.circlepath.circle.fill"
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled", "waiting_for_callback":
            "clock.fill"
        case "canceled", "canceling": "slash.circle.fill"
        case "skipped": "forward.circle.fill"
        case "manual": "hand.raised.circle.fill"
        default: "questionmark.circle"
        }
    }

    var statusTint: Color {
        switch status {
        case "success": .green
        case "failed": .red
        case "running": .blue
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled", "waiting_for_callback", "manual":
            .orange
        default: .secondary
        }
    }
}

private extension MergeRequestBlocker {
    var displayLabel: LocalizedStringResource {
        switch self {
        case .draft: .Menu.menuAuthoredBlockerDraft
        case .approvals: .Menu.menuAuthoredBlockerApprovals
        case .changesRequested: .Menu.menuAuthoredBlockerChangesRequested
        case .discussions: .Menu.menuAuthoredBlockerDiscussions
        case .discussionPolicy: .Menu.menuAuthoredBlockerDiscussionPolicy
        case .approvalPolicy: .Menu.menuAuthoredBlockerApprovalPolicy
        case .conflictTaskFailed: .Menu.menuAuthoredBlockerConflictTaskFailed
        case .conflicts: .Menu.menuAuthoredBlockerConflicts
        case .pipeline: .Menu.menuAuthoredBlockerPipeline
        case .permissions: .Menu.menuAuthoredBlockerPermissions
        case .checking: .Menu.menuAuthoredBlockerChecking
        case .other: .Menu.menuAuthoredBlockerOther
        case .unknown: .Menu.menuAuthoredBlockerUnknown
        }
    }
}

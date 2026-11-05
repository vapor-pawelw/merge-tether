import SwiftUI

struct MergeWorkflowActivityView: View {
    let entries: [MergeWorkflowActivityEntry]
    var onHandoff: ((String) -> Void)? = nil

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(.Menu.menuWorkflowActivityEmptyTitle)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            } description: {
                Text(.Menu.menuWorkflowActivityEmptyDescription)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        MergeWorkflowActivityRow(entry: entry, onHandoff: onHandoff)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct MergeWorkflowActivityRow: View {
    let entry: MergeWorkflowActivityEntry
    var onHandoff: ((String) -> Void)? = nil
    @State private var confirmHandoff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.event.kind.displayLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(entry.createdAt, style: .relative)
                    .foregroundStyle(.secondary)
            }

            Link(destination: entry.event.mergeRequest.webURL) {
                Text("!\(entry.event.mergeRequest.iid) \(entry.event.mergeRequest.title)")
                    .lineLimit(2)
            }
            .help(Text(.Menu.menuActionOpenInBrowser))

            Text(entry.state.displayLabel)
                .foregroundStyle(.secondary)
            Text(entry.event.context)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let summary = entry.summary, !summary.isEmpty {
                DisclosureGroup {
                    Text(verbatim: summary)
                        .textSelection(.enabled)
                } label: {
                    Text(.Menu.menuWorkflowActivityResult)
                }
            }

            if let chatURL = entry.chatURL {
                Link(destination: chatURL) {
                    Text(.Menu.menuWorkflowActivityOpenChat)
                }
            }

            if entry.state == .awaitingPipelineHandoff, let onHandoff {
                Button {
                    confirmHandoff = true
                } label: {
                    Text(.Menu.menuWorkflowHandoffButton)
                }
                .confirmationDialog(
                    Text(.Menu.menuWorkflowHandoffTitle),
                    isPresented: $confirmHandoff,
                    titleVisibility: .visible
                ) {
                    Button {
                        onHandoff(entry.id)
                    } label: {
                        Text(.Menu.menuWorkflowHandoffConfirm)
                    }
                } message: {
                    Text(.Menu.menuWorkflowHandoffExplanation)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension MergeWorkflowActivityState {
    var displayLabel: LocalizedStringResource {
        switch self {
        case .preview: .Menu.menuWorkflowStatePreview
        case .notified: .Menu.menuWorkflowStateNotified
        case .awaitingPipelineHandoff: .Menu.menuWorkflowStateAwaitingPipelineHandoff
        case .alreadyRegistered: .Menu.menuWorkflowStateAlreadyRegistered
        case .queued: .Menu.menuWorkflowStateQueued
        case .running: .Menu.menuWorkflowStateRunning
        case .waitingForAssistant: .Menu.menuWorkflowStateWaitingForAssistant
        case .completed: .Menu.menuWorkflowStateCompleted
        case .failed: .Menu.menuWorkflowStateFailed
        case .skipped: .Menu.menuWorkflowStateSkipped
        }
    }
}

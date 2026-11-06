import AppKit
import SwiftUI

struct TodoRowView: View {
    let todo: Todo
    let currentUsername: String?
    let automationState: TodoAutomationService.ActionState?
    let scopeMenu: MRAutomationScopeMenu?
    let onAutomation: () -> Void
    let onMarkDone: () -> Void
    let onOpen: () -> Void

    @State private var isHovered = false
    @State private var isAutomationHovered = false
    @State private var isMarkDoneHovered = false
    @State private var isScopeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onOpen) {
                    HStack(alignment: .center, spacing: 10) {
                        AvatarView(url: todo.author.avatarURL, size: 32)
                        heading
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                markDoneButton
            }

            Button(action: onOpen) {
                metadata
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if automationState != nil || scopeMenu != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if let automationState { automationControl(automationState) }
                        scopeControl
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let automationState { automationControl(automationState) }
                        scopeControl
                    }
                }
            }
        }
        .mrRowContentPadding()
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && !isAutomationHovered && !isMarkDoneHovered && !isScopeHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Text(.Menu.menuActionOpenInBrowser)
            }
            Button(action: onMarkDone) {
                Text(.Menu.menuActionMarkAsDone)
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(todo.targetURL.absoluteString, forType: .string)
            } label: {
                Text(.Menu.menuActionCopyURL)
            }
        }
    }

    private var markDoneButton: some View {
        Button(action: onMarkDone) {
            Image(systemName: isMarkDoneHovered ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isMarkDoneHovered ? Color.accentColor : .secondary)
                .mrRowAccessoryFrame()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(.Menu.menuActionMarkAsDone))
        .accessibilityLabel(Text(.Menu.menuActionMarkAsDone))
        .onHover { isMarkDoneHovered = $0 }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            TodoBadgeView(todo: todo)
            MergeRequestTitle(title: todo.displayTitle,
                              isDraft: todo.targetType == .mergeRequest && todo.isDraft,
                              font: .body.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            RepositoryPathText(todo.project.pathWithNamespace)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ActionDescriptionText(todo: todo, currentUsername: currentUsername)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(verbatim: "·")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(RelativeTime.string(from: todo.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var scopeControl: some View {
        if let scopeMenu {
            scopeMenu.onHover { isScopeHovered = $0 }
        }
    }

    @ViewBuilder
    private func automationControl(_ state: TodoAutomationService.ActionState) -> some View {
        switch state {
        case .ready(let runner):
            Button(action: onAutomation) {
                Text(actionTitle(runner))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .overlay {
                if isAutomationHovered {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.18))
                        .allowsHitTesting(false)
                }
            }
            .onHover { isAutomationHovered = $0 }
            .onDisappear { isAutomationHovered = false }
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(.Menu.menuTodoAutomationRunning)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .queuedForAssistant:
            Text(.Menu.menuTodoAutomationQueued)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .finished:
            Text(.Menu.menuTodoAutomationFinished)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text(.Menu.menuTodoAutomationFailed)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func actionTitle(_ runner: AutomationRunner) -> LocalizedStringResource {
        if runner == .shell { return .Menu.menuTodoAutomationRunScript }
        return todo.actionName == .reviewRequested
            ? .Menu.menuTodoAutomationPrepareReview
            : .Menu.menuTodoAutomationPrepareFollowUp
    }

}

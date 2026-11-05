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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onMarkDone) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text(.Menu.menuActionMarkAsDone))
            .accessibilityLabel(Text(.Menu.menuActionMarkAsDone))

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(url: todo.author.avatarURL, size: 32)
                        details
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if automationState != nil || scopeMenu != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if let automationState { automationControl(automationState) }
                            scopeMenu
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if let automationState { automationControl(automationState) }
                            scopeMenu
                        }
                    }
                    .padding(.leading, 42)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && !isAutomationHovered ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 6)
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

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            TodoBadgeView(todo: todo)
            Text(todo.displayTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)

            RepositoryPathText(todo.project.pathWithNamespace)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .top, spacing: 6) {
                ActionDescriptionText(todo: todo, currentUsername: currentUsername)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(RelativeTime.string(from: todo.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

import Accessibility
import MergeTetherRemote
import SwiftUI
import UIKit

struct RemoteCardCornerActions: View {
    let card: RemoteCard
    let model: RemotePhoneModel?
    let onOpenAction: ((RemoteCardCTA) -> Void)?

    @State private var panel: Panel?
    @State private var confirmRemoval = false
    @State private var copyFeedback: UUID?

    private enum Panel: String, Identifiable {
        case automation, assistant
        var id: Self { self }
    }

    private var url: URL? {
        guard card.id.hasPrefix("mr:") || card.mergeRequestIID != nil,
              let url = card.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        return url
    }
    private var pinned: Bool { card.pinned ?? card.orderGroup?.pinned ?? false }
    private var canEdit: Bool {
        model?.state.canAct() == true && card.actions.contains { $0.kind == .editCard }
    }
    private var hasRemoteCardActions: Bool { model?.state.board?.cardAssistants != nil && card.pinned != nil }

    var body: some View {
        HStack(spacing: 0) {
            if pinned {
                Button { submit(.pin(false)) } label: {
                    icon("pin.fill").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(Text(.Board.boardUnpin))
                .accessibilityValue(Text(.Remote.remoteBoardPinned))
                .accessibilityIdentifier("remote.card.unpin.\(card.id)")
            }
            if let automation = card.automation {
                Button { panel = .automation } label: {
                    icon(automation.active && !automation.globallySuspended ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(automation.customized ? Color.orange : automation.active ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.RemoteCardActions.remoteCardActionsAutomation))
                .accessibilityValue(Text(automation.stateLabel))
                .accessibilityIdentifier("remote.card.automation.\(card.id)")
            }
            if let url {
                menu(url)
            }
        }
        .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { submit(.remove) } label: { Text(.Board.boardRemove) }
        } message: { Text(.Board.boardRemoveExplanation) }
        .sheet(item: $panel) { panel in
            if let model {
                switch panel {
                case .automation: RemoteCardAutomationPanel(model: model, original: card)
                case .assistant:
                    if let url { RemoteCardAssistantPanel(model: model, card: card, url: url) }
                }
            }
        }
        .onChange(of: model?.state.board?.hostSession) { panel = nil; confirmRemoval = false }
    }

    private func menu(_ url: URL) -> some View {
        Menu {
            Button { copy(url) } label: { Label(.CommandCenter.commandCenterCopyLink, systemImage: "link") }
            Link(destination: url) {
                Label(.CommandCenter.commandCenterOpenGitLab, systemImage: "arrow.up.right.square")
            }
            if hasRemoteCardActions {
                Button { submit(.pin(!pinned)) } label: {
                    Label(pinned ? .Board.boardUnpin : .Board.boardPin, systemImage: pinned ? "pin.slash" : "pin")
                }
                .disabled(!canEdit)
                Button { submit(.refresh) } label: { Label(.MRFreshness.mrFreshnessRefresh, systemImage: "arrow.clockwise") }
                    .disabled(!canEdit)
            }
            Section {
                if let ready = card.actions.first(where: { $0.kind == .markReady }), onOpenAction != nil {
                    actionButton(ready, symbol: "checkmark.circle")
                }
                if let review = card.actions.first(where: { $0.kind == .runReview }), onOpenAction != nil {
                    actionButton(review, symbol: "sparkle.magnifyingglass")
                }
                if model != nil {
                    Button { panel = .assistant } label: {
                        Label(.AssistantContext.assistantContextOpen, systemImage: "bubble.left.and.bubble.right")
                    }
                }
                if card.canAcknowledgeFinished == true {
                    Button { submit(.acknowledge) } label: { Label(.Remote.remoteSeen, systemImage: "checkmark") }
                        .disabled(!canEdit)
                }
            }
            if card.canRemoveFromBoard == true {
                Section {
                    Button(role: .destructive) { confirmRemoval = true } label: {
                        Label(.Board.boardRemove, systemImage: "minus.circle")
                    }
                    .disabled(!canEdit)
                }
            }
        } label: {
            icon(copyFeedback == nil ? "ellipsis" : "checkmark")
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
        .accessibilityIdentifier("remote.card.menu.\(card.id)")
        .overlay(alignment: .bottomTrailing) {
            if let copyFeedback {
                Text(.CommandCenter.commandCenterLinkCopied)
                    .font(.caption.weight(.medium)).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .fixedSize().offset(y: 24).allowsHitTesting(false).accessibilityHidden(true)
                    .task(id: copyFeedback) {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if self.copyFeedback == copyFeedback { self.copyFeedback = nil }
                    }
            }
        }
    }

    private func actionButton(_ action: RemoteAction, symbol: String) -> some View {
        Button {
            onOpenAction?(.init(title: action.label ?? String(localized: action.kind.title),
                destination: .actions, actionID: action.id))
        } label: {
            Label { Text(action.kind.title) } icon: { Image(systemName: symbol) }
        }
        .disabled(model?.state.canAct() != true)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func copy(_ url: URL) {
        UIPasteboard.general.url = url
        copyFeedback = UUID()
        AccessibilityNotification.Announcement(String(localized: .CommandCenter.commandCenterLinkCopied)).post()
    }

    private func submit(_ change: RemoteCardChange) {
        guard canEdit, let model else { return }
        Task { await model.changeCard(change, card: card) }
    }
}

private struct RemoteCardAutomationPanel: View {
    let model: RemotePhoneModel
    let original: RemoteCard
    @Environment(\.dismiss) private var dismiss
    @State private var proposed: ProposedChange?
    @State private var changing = false
    @State private var failure: RemoteCommandResult.Status?

    private struct ProposedChange {
        let card: RemoteCard
        let change: RemoteCardChange

        var changesRepository: Bool {
            if case .repository = change { return true }
            return false
        }
    }

    private enum PreferenceField {
        case mergeRequest, rule(RemoteCardAutomation.Rule.Kind), repository
    }

    private var current: RemoteCard? { model.state.board?.cards.first { $0.id == original.id } }
    private var canEdit: Bool {
        !changing && model.state.canAct() && current?.actions.contains { $0.kind == .editCard } == true
    }
    private var policy: [String] {
        guard let board = model.state.board, let current,
              let details = model.detailState.details(for: current, board: board) else { return [] }
        return details.policy
    }

    var body: some View {
        NavigationStack {
            Form {
                if let automation = current?.automation ?? original.automation {
                    Section {
                        LabeledContent {
                            Text(automation.stateLabel)
                        } label: { Text(.RemoteCardActions.remoteCardActionsAutomation) }
                        Text(verbatim: automation.source).foregroundStyle(.secondary)
                    } header: { Text(verbatim: original.title) }

                    Section {
                        preference(.RemoteCardActions.remoteCardActionsAutomation,
                            selection: automation.preference, field: .mergeRequest)
                        ForEach(automation.rules) { rule in
                            preference(rule.id.title, selection: rule.preference, field: .rule(rule.id))
                                .disabled(!rule.editable)
                        }
                    } header: {
                        Text(.RemoteCardActions.remoteCardActionsThisMR)
                    }
                    .disabled(!canEdit)

                    if !policy.isEmpty {
                        Section {
                            ForEach(Array(policy.enumerated()), id: \.offset) { _, explanation in
                                Text(verbatim: explanation)
                            }
                        } header: {
                            Text(.RemoteCardActions.remoteCardActionsPolicy)
                        }
                    }

                    Section {
                        preference(.RemoteCardActions.remoteCardActionsAutomation,
                            selection: automation.repositoryInherits ? .default : automation.repositoryEnabled ? .on : .off,
                            field: .repository)
                    } header: {
                        Text(.RemoteCardActions.remoteCardActionsRepository)
                    } footer: {
                        Text(automation.repositoryEnabled ? .RemoteCardActions.remoteCardActionsRepositoryOn
                            : .RemoteCardActions.remoteCardActionsRepositoryOff)
                    }
                    .disabled(!canEdit)
                }
                if changing { ProgressView() }
                if let failure { Text(failure.title).foregroundStyle(.orange) }
            }
            .navigationTitle(Text(.RemoteCardActions.remoteCardActionsAutomation))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(.Remote.remoteClose) { dismiss() } } }
            .task(id: model.supportsDetails ? current?.detailContextDigest : nil) {
                if let current, model.supportsDetails {
                    await model.requestDetails(card: current, force: true, fromGitLab: false)
                }
            }
            .onDisappear { model.cancelDetails() }
            .confirmationDialog(Text(.RemoteCardActions.remoteCardActionsConfirmPolicy),
                isPresented: Binding(get: { proposed != nil }, set: { if !$0 { proposed = nil } }),
                titleVisibility: .visible, presenting: proposed) { proposal in
                Button(.Remote.remoteConfirm) { apply(proposal) }
            } message: { proposal in
                Text(proposal.changesRepository ? .RemoteCardActions.remoteCardActionsConfirmRepository : .RemoteCardActions.remoteCardActionsConfirmMR)
            }
        }
    }

    private func preference(_ title: LocalizedStringResource, selection: RemoteCardAutomation.Preference,
                            field: PreferenceField) -> some View {
        Picker(selection: Binding(get: { selection }, set: { choice in
            switch field {
            case .mergeRequest: stage(.automation(choice))
            case .rule(let kind): stage(.rule(kind, choice))
            case .repository: stage(.repository(choice))
            }
        })) {
            ForEach(RemoteCardAutomation.Preference.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        } label: { Text(title) }
    }

    private func stage(_ change: RemoteCardChange) {
        guard canEdit, let current else { return }
        proposed = .init(card: current, change: change)
    }

    private func apply(_ proposal: ProposedChange) {
        proposed = nil
        changing = true
        failure = nil
        Task {
            let status = await model.changeCard(proposal.change, card: proposal.card, inSheet: true)
            if status != .completed { failure = status }
            changing = false
        }
    }
}

private struct RemoteCardAssistantPanel: View {
    let model: RemotePhoneModel
    let card: RemoteCard
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var destination: RemoteCardAssistant?
    @State private var message = ""
    @State private var copied = false

    private var destinations: [RemoteCardAssistant] { model.state.board?.cardAssistants ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        UIPasteboard.general.string = AssistantLaunchContext(url: url, title: card.title).prompt
                        copied = true
                    } label: {
                        Label(copied ? .RemoteCardActions.remoteCardActionsContextCopied : .AssistantContext.assistantContextCopy,
                            systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                if !destinations.isEmpty {
                    Section {
                        Picker(selection: $destination) {
                            ForEach(destinations) { option in Text(option.title).tag(Optional(option)) }
                        } label: { Text(.RemoteCardActions.remoteCardActionsAssistantOnMac) }
                        if destination?.requiresMessage == true {
                            TextField(text: $message, axis: .vertical) {
                                Text(.RemoteCardActions.remoteCardActionsAssistantMessage)
                            }
                        }
                        Button(.RemoteCardActions.remoteCardActionsAssistantOnMac, action: launch)
                            .disabled(!model.state.canAct() || change?.argument == nil
                                || !card.actions.contains { $0.kind == .editCard })
                    }
                }
            }
            .onAppear { destination = destinations.first }
            .navigationTitle(Text(.AssistantContext.assistantContextOpen))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(.Remote.remoteClose) { dismiss() } } }
        }
    }

    private var change: RemoteCardChange? {
        guard let destination, destinations.contains(destination) else { return nil }
        return .openAssistant(destination, message: destination.requiresMessage ? message : nil)
    }

    private func launch() {
        guard let change else { return }
        dismiss()
        Task { await model.changeCard(change, card: card) }
    }
}

private extension RemoteCardAutomation {
    var stateLabel: LocalizedStringResource {
        if globallySuspended { return .RemoteCardActions.remoteCardActionsSuspendedOnMac }
        return active ? .RemoteCardActions.remoteCardActionsOn : .RemoteCardActions.remoteCardActionsOff
    }
}

private extension RemoteCardAutomation.Preference {
    var title: LocalizedStringResource {
        switch self {
        case .default: .RemoteCardActions.remoteCardActionsDefault
        case .on: .RemoteCardActions.remoteCardActionsOn
        case .off: .RemoteCardActions.remoteCardActionsOff
        }
    }
}

private extension RemoteCardAutomation.Rule.Kind {
    var title: LocalizedStringResource {
        switch self {
        case .commentPublication: .RemoteCardActions.remoteCardActionsPublication
        case .merge: .RemoteCardActions.remoteCardActionsMerge
        case .approval: .RemoteCardActions.remoteCardActionsApproval
        }
    }
}

private extension RemoteCardAssistant {
    var title: LocalizedStringResource {
        switch self {
        case .codexApp: .AssistantContext.assistantContextCodexApp
        case .claudeDesktop: .AssistantContext.assistantContextClaudeDesktop
        case .t3Code: .AssistantContext.assistantContextT3Code
        case .codexCLI: .AssistantContext.assistantContextCodexCLI
        case .claudeCLI: .AssistantContext.assistantContextClaudeCLI
        }
    }
}

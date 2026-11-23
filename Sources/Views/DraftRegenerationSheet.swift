import MergeTetherRemote
import SwiftUI

struct DraftRegenerationPresentation: Identifiable {
    let id = UUID()
    /// A nil scope opens the work that is already in progress or ready to review.
    let scope: DraftRegenerationScope?
}

struct DraftRegenerationSheet: View {
    let presentation: DraftRegenerationPresentation
    let isAvailable: () -> Bool
    let batch: () -> DraftRegenerationBatch?
    let count: (DraftRegenerationScope) -> Int
    let mergeRequestCount: () -> Int
    var isLoading: () -> Bool = { false }
    var loadFailed: () -> Bool = { false }
    var reload: (() async -> Void)? = nil
    let start: (DraftRegenerationScope, String?) async -> Bool
    let apply: (Set<String>, UUID) async -> RemoteCommandResult.Status
    let discard: (UUID) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var addInstructions = false
    @State private var instructions = ""
    @State private var pending = false
    @State private var error: LocalizedStringResource?
    @State private var confirmDiscard: DraftRegenerationBatch?

    private var additionalInstructions: String { instructions.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var instructionsTooLong: Bool {
        additionalInstructions.utf8.count > DraftRegenerationScope.maximumInstructionsBytes
    }

    var body: some View {
        let current = batch()
        VStack(spacing: 0) {
            header(current)
            Divider()
            if let current {
                DraftRegenerationResults(batch: current, canWrite: isAvailable() && !pending,
                    isSubmitting: pending, isLoading: isLoading(), loadFailed: loadFailed(), error: error, reload: reload) { ids in
                    save(ids, batch: current)
                } onDiscard: { requiresConfirmation in
                    if requiresConfirmation { confirmDiscard = current }
                    else { discardBatch(current) }
                }
                .id(current.id)
            } else if let scope = presentation.scope {
                compose(scope)
            } else {
                ContentUnavailableView {
                    Label(.DraftRegeneration.draftRegenerationNoBatch, systemImage: "wand.and.stars")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 710, minHeight: 380, idealHeight: current == nil ? 445 : 620)
        #else
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(pending)
        #endif
        .alert(Text(.DraftRegeneration.draftRegenerationDiscardTitle), isPresented: Binding(
            get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
            presenting: confirmDiscard) { batch in
                Button(.DraftRegeneration.draftRegenerationKeep, role: .cancel) { confirmDiscard = nil }
                Button(.DraftRegeneration.draftRegenerationDiscard, role: .destructive) { discardBatch(batch) }
            } message: { _ in
                Text(.DraftRegeneration.draftRegenerationDiscardHelp)
            }
        .onChange(of: current?.id) { _, _ in error = nil }
    }

    private func header(_ current: DraftRegenerationBatch?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(current?.phase.regenerationTitle ?? composeTitle)
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let scope = current?.scope ?? presentation.scope {
                    let total = current?.total ?? count(scope)
                    HStack(spacing: 5) {
                        Text(.DraftRegeneration.draftRegenerationDraftCount(total))
                        if scope == .all, current == nil {
                            Text(verbatim: "·").accessibilityHidden(true)
                            Text(.DraftRegeneration.draftRegenerationMrCount(mergeRequestCount()))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
                    .padding(6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationClose))
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composeTitle: LocalizedStringResource {
        switch presentation.scope {
        case .all?: .DraftRegeneration.draftRegenerationAllTitle
        case .mergeRequest?: .DraftRegeneration.draftRegenerationMrTitle
        case .draft?: .DraftRegeneration.draftRegenerationOneTitle
        case nil: .DraftRegeneration.draftRegenerationTitle
        }
    }

    private func compose(_ scope: DraftRegenerationScope) -> some View {
        let total = count(scope)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(.DraftRegeneration.draftRegenerationComposeHelp).foregroundStyle(.secondary)
                    instructionOption(.DraftRegeneration.draftRegenerationUseCurrent, addsInstructions: false)
                    instructionOption(.DraftRegeneration.draftRegenerationAddExtra, addsInstructions: true)
                    if addInstructions {
                        TextField(text: $instructions, axis: .vertical) {
                            Text(.DraftRegeneration.draftRegenerationInstructions)
                        }
                        .textFieldStyle(.roundedBorder).lineLimit(3...7)
                        .accessibilityIdentifier("draft-regeneration.instructions")
                        if instructionsTooLong {
                            Text(.DraftRegeneration.draftRegenerationInstructionsTooLong)
                                .font(.callout).foregroundStyle(.red)
                        } else if total > 1 {
                            Text(.DraftRegeneration.draftRegenerationBatchInstructions)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let error { regenerationNotice(error) }
                    else if total == 0 { regenerationNotice(.DraftRegeneration.draftRegenerationNoDrafts) }
                    else if !isAvailable() && !pending {
                        regenerationNotice(.DraftRegeneration.draftRegenerationActionUnavailable)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                if pending { ProgressView().controlSize(.small) }
                Button(.DraftRegeneration.draftRegenerationGenerate) { generate(scope) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pending || !isAvailable() || total == 0
                              || (addInstructions && (additionalInstructions.isEmpty || instructionsTooLong)))
                    .accessibilityIdentifier("draft-regeneration.generate")
            }
            .padding(20)
        }
        .disabled(pending)
    }

    private func instructionOption(_ title: LocalizedStringResource, addsInstructions: Bool) -> some View {
        let selected = addInstructions == addsInstructions
        return Button {
            addInstructions = addsInstructions
        } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func generate(_ scope: DraftRegenerationScope) {
        pending = true
        error = nil
        let prompt = addInstructions ? additionalInstructions : nil
        Task {
            defer { pending = false }
            if await start(scope, prompt) {
                instructions = ""
            } else {
                error = .DraftRegeneration.draftRegenerationStartFailed
            }
        }
    }

    private func save(_ ids: Set<String>, batch: DraftRegenerationBatch) {
        pending = true
        error = nil
        Task {
            defer { pending = false }
            switch await apply(ids, batch.id) {
            case .completed, .partial: break
            case .changed: error = .DraftRegeneration.draftRegenerationSaveChanged
            case .uncertain: error = .DraftRegeneration.draftRegenerationSaveUncertain
            default: error = .DraftRegeneration.draftRegenerationSaveFailed
            }
        }
    }

    private func discardBatch(_ batch: DraftRegenerationBatch) {
        confirmDiscard = nil
        pending = true
        Task {
            defer { pending = false }
            if await discard(batch.id) { dismiss() }
            else { error = .DraftRegeneration.draftRegenerationActionUnavailable }
        }
    }
}

private struct DraftRegenerationResults: View {
    let batch: DraftRegenerationBatch
    let canWrite: Bool
    let isSubmitting: Bool
    let isLoading: Bool
    let loadFailed: Bool
    let error: LocalizedStringResource?
    let reload: (() async -> Void)?
    let onSave: (Set<String>) -> Void
    let onDiscard: (Bool) -> Void

    @State private var selected: Set<String> = []
    @State private var seen: Set<String> = []

    private struct MergeRequestGroup: Identifiable {
        let proposals: [DraftRegenerationProposal]
        var id: String { "\(proposals[0].projectID):\(proposals[0].iid)" }
        var heading: String { "!\(proposals[0].iid) · \(proposals[0].mergeRequestTitle)" }
        var hasReplacement: Bool { proposals.contains { $0.replacement != nil } }
    }

    private var groups: [MergeRequestGroup] {
        Dictionary(grouping: batch.proposals) { "\($0.projectID):\($0.iid)" }.values
            .map { MergeRequestGroup(proposals: $0) }
            .sorted {
                if $0.hasReplacement != $1.hasReplacement { return $0.hasReplacement }
                return ($0.heading, $0.id) < ($1.heading, $1.id)
            }
    }
    private var selectable: Set<String> {
        let validProposals = batch.proposals.filter { $0.issue == nil && $0.replacement != nil }
        return Set(validProposals.map(\.id))
    }
    private var saving: Bool { batch.phase == .saving }
    private var ready: Bool { batch.phase == .ready && !isLoading && !loadFailed }
    private var canClear: Bool { batch.phase == .finished || (ready && selectable.isEmpty) }
    private var singleDraft: Bool {
        if case .draft = batch.scope { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error { regenerationNotice(error) }
                    else if !canWrite && !isSubmitting && !saving {
                        regenerationNotice(.DraftRegeneration.draftRegenerationActionUnavailable)
                    }
                    if saving {
                        if let total = batch.savingTotal, total > 0, let processed = batch.savingCompleted {
                            ProgressView(value: Double(processed), total: Double(total)) {
                                Text(.DraftRegeneration.draftRegenerationSaveProgress(processed, total))
                            }
                        } else {
                            ProgressView { Text(.DraftRegeneration.draftRegenerationSaving) }
                        }
                        Text(.DraftRegeneration.draftRegenerationResumeHelp).foregroundStyle(.secondary)
                    } else if batch.phase == .generating {
                        ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1))) {
                            Text(.DraftRegeneration.draftRegenerationProgress(batch.completed, batch.total))
                        }
                        Text(.DraftRegeneration.draftRegenerationResumeHelp).foregroundStyle(.secondary)
                    } else if isLoading {
                        ProgressView { Text(.DraftRegeneration.draftRegenerationLoading) }
                    } else if loadFailed {
                        regenerationNotice(.DraftRegeneration.draftRegenerationLoadFailed)
                        if let reload {
                            Button(.DraftRegeneration.draftRegenerationRetry) { Task { await reload() } }
                        }
                    } else {
                        if ready && selectable.isEmpty {
                            Text(.DraftRegeneration.draftRegenerationNothingToSave).foregroundStyle(.secondary)
                        } else if ready {
                            Text(.DraftRegeneration.draftRegenerationReviewHelp).foregroundStyle(.secondary)
                            if !singleDraft && batch.proposals.contains(where: {
                                !$0.selectedByDefault && selectable.contains($0.id)
                            }) {
                                Text(.DraftRegeneration.draftRegenerationManualUnselected)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } else if batch.phase == .finished {
                            let saved = batch.proposals.filter { $0.issue == .saved }.count
                            Text(saved == 0 ? .DraftRegeneration.draftRegenerationNoneSaved
                                 : .DraftRegeneration.draftRegenerationSavedCount(saved))
                                .foregroundStyle(.secondary)
                        }
                        if groups.isEmpty {
                            regenerationNotice(.DraftRegeneration.draftRegenerationNoProposals)
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: group.heading).font(.headline).accessibilityAddTraits(.isHeader)
                                ForEach(group.proposals) { proposal in
                                    DraftRegenerationComparison(proposal: proposal, initiallyExpanded: batch.total == 1,
                                        showsUnsavedStatus: batch.phase == .finished,
                                        selection: ready && !singleDraft && selectable.contains(proposal.id)
                                            ? selection(for: proposal.id) : nil)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .onChange(of: selectable, initial: true) {
            let defaults = batch.proposals.filter { (singleDraft || $0.selectedByDefault) && selectable.contains($0.id) }.map(\.id)
            selected.formIntersection(selectable)
            selected.formUnion(Set(defaults).subtracting(seen))
            seen.formUnion(selectable)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { footerActions; Spacer(minLength: 0); saveButton() }
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { footerActions }
                    VStack(alignment: .leading, spacing: 8) { footerActions }
                }
                saveButton(fillWidth: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    @ViewBuilder private var footerActions: some View {
        if !saving {
            Button(canClear ? .DraftRegeneration.draftRegenerationClear : .DraftRegeneration.draftRegenerationDiscard) {
                onDiscard(!canClear)
            }
            .disabled(!canWrite)
        }
        if ready && !singleDraft && !selected.isEmpty {
            Button(.DraftRegeneration.draftRegenerationClearSelection) { selected.removeAll() }
        }
    }

    @ViewBuilder private func saveButton(fillWidth: Bool = false) -> some View {
        if ready && !selectable.isEmpty {
            Button { onSave(selected) } label: {
                Text(singleDraft ? .DraftRegeneration.draftRegenerationSaveDraft
                     : .DraftRegeneration.draftRegenerationSaveSelected(selected.count))
                    .frame(maxWidth: fillWidth ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent).disabled(!canWrite || selected.isEmpty)
            .accessibilityIdentifier("draft-regeneration.save")
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        .init(get: { selected.contains(id) }, set: { value in
            if value { selected.insert(id) } else { selected.remove(id) }
        })
    }
}

private struct DraftRegenerationComparison: View {
    let proposal: DraftRegenerationProposal
    let initiallyExpanded: Bool
    let showsUnsavedStatus: Bool
    let selection: Binding<Bool>?
    @Environment(\.dynamicTypeSize) private var dynamicType
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    #endif
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selection {
                Toggle(isOn: selection) {
                    Text(.DraftRegeneration.draftRegenerationSelect)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationSelectNamed(summary)))
            }
            if let issue = proposal.issue {
                Label(issue.regenerationTitle, systemImage: issue == .saved ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if showsUnsavedStatus && proposal.replacement != nil {
                Label(.DraftRegeneration.draftRegenerationUnsaved, systemImage: "circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let explanation = proposal.explanation {
                Text(verbatim: explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if initiallyExpanded {
                versions
            } else {
                DisclosureGroup(isExpanded: $expanded) { versions.padding(.top, 8) } label: {
                    Text(verbatim: summary)
                        .font(.callout).lineLimit(2)
                        .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationCompareNamed(summary)))
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("draft-regeneration.result.\(proposal.id)")
    }

    private var summary: String {
        let line = (proposal.replacement ?? proposal.original).split(whereSeparator: \.isNewline).first
        return line.map(String.init) ?? String(localized: .DraftRegeneration.draftRegenerationCompare)
    }

    @ViewBuilder private var versions: some View {
        if let replacement = proposal.replacement {
            let layout = comparesSideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                version(.DraftRegeneration.draftRegenerationOriginal, body: proposal.original, accent: false)
                version(.DraftRegeneration.draftRegenerationProposal, body: replacement, accent: true)
            }
        } else if !proposal.original.isEmpty {
            version(.DraftRegeneration.draftRegenerationOriginal, body: proposal.original, accent: false)
        }
    }

    private var comparesSideBySide: Bool {
        #if os(iOS)
        width == .regular && !dynamicType.isAccessibilitySize
        #else
        !dynamicType.isAccessibilitySize
        #endif
    }

    private func version(_ title: LocalizedStringResource, body: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ExtraContextMarkdown(source: body).font(.callout)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background((accent ? Color.accentColor : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func regenerationNotice(_ message: LocalizedStringResource) -> some View {
    Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
        Image(systemName: "exclamationmark.circle")
    }
    .font(.callout).foregroundStyle(.secondary)
}

extension DraftRegenerationBatch.Phase {
    var regenerationTitle: LocalizedStringResource {
        switch self {
        case .generating: .DraftRegeneration.draftRegenerationGenerating
        case .ready: .DraftRegeneration.draftRegenerationReview
        case .saving: .DraftRegeneration.draftRegenerationSaving
        case .finished: .DraftRegeneration.draftRegenerationFinished
        }
    }
}

private extension DraftRegenerationProposal.Issue {
    var regenerationTitle: LocalizedStringResource {
        switch self {
        case .unchanged: .DraftRegeneration.draftRegenerationUnchanged
        case .outdated: .DraftRegeneration.draftRegenerationOutdated
        case .changed: .DraftRegeneration.draftRegenerationChanged
        case .unavailable: .DraftRegeneration.draftRegenerationUnavailable
        case .failed: .DraftRegeneration.draftRegenerationFailed
        case .saved: .DraftRegeneration.draftRegenerationSaved
        }
    }
}

#Preview("Regeneration instructions") {
    DraftRegenerationSheet(presentation: .init(scope: .all), isAvailable: { true }, batch: { nil },
        count: { _ in 3 }, mergeRequestCount: { 2 }, start: { _, _ in true }, apply: { _, _ in .completed },
        discard: { _ in true })
}

#Preview("Regeneration proposals") {
    let batch = DraftRegenerationBatch(id: UUID(), scope: .all, total: 3, completed: 3, phase: .ready, proposals: [
        .init(projectID: 1, iid: 6, draftID: 10, mergeRequestTitle: "Handle expired subscriptions",
            original: "This will crash at startup for users with no subscription.",
            replacement: "Could we handle a missing subscription here? The app opens this screen before the first subscription is loaded.",
            selectedByDefault: true),
        .init(projectID: 1, iid: 6, draftID: 11, mergeRequestTitle: "Handle expired subscriptions",
            original: "Can we mention this in the docs?", replacement: "Could the release notes explain what changes for expired subscriptions?"),
        .init(projectID: 2, iid: 17, draftID: 20, mergeRequestTitle: "Refresh the account screen",
            original: "The refresh indicator stays visible after a failed request.", issue: .outdated)
    ])
    DraftRegenerationSheet(presentation: .init(scope: nil), isAvailable: { true }, batch: { batch },
        count: { _ in 3 }, mergeRequestCount: { 2 }, start: { _, _ in true }, apply: { _, _ in .completed },
        discard: { _ in true })
}

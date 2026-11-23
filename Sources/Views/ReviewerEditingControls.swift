import MergeTetherRemote
import SwiftUI

struct ReviewerEditing {
    var supportsBatch = true
    let search: (String) async throws -> [ReviewerCandidate]
    let change: ([ReviewerChange]) async -> RemoteCommandResult.Status
}

@MainActor @Observable final class ReviewerEditorState {
    var isEditing = false
    private(set) var isAdding = false
    private(set) var isSaving = false
    private(set) var pendingAdditions: [ReviewerCandidate] = []
    var pendingRemoval: ReviewerCandidate?
    var error: LocalizedStringResource?
    @ObservationIgnored private var additionEditing: ReviewerEditing?

    func startAdding(using editing: ReviewerEditing) {
        guard !isAdding, !isSaving else { return }
        error = nil
        isAdding = true
        additionEditing = editing
    }

    func add(_ person: ReviewerCandidate) {
        guard !isSaving, let editing = additionEditing else { return }
        if editing.supportsBatch {
            guard pendingAdditions.count < ReviewerChange.Batch.maximumCount,
                  !pendingAdditions.contains(where: { $0.id == person.id }) else { return }
            pendingAdditions.append(person)
        } else {
            save([.init(.add, reviewerID: person.id, username: person.username)], using: editing)
        }
    }

    func unselect(_ person: ReviewerCandidate) {
        pendingAdditions.removeAll { $0.id == person.id }
    }

    @discardableResult func finishAdding() -> Task<Void, Never>? {
        isAdding = false
        let editing = additionEditing
        additionEditing = nil
        let changes = pendingAdditions.map { ReviewerChange(.add, reviewerID: $0.id, username: $0.username) }
        pendingAdditions.removeAll()
        guard let editing, !changes.isEmpty else { return nil }
        return save(changes, using: editing)
    }

    @discardableResult func save(_ changes: [ReviewerChange], using editing: ReviewerEditing) -> Task<Void, Never>? {
        guard !isSaving else { return nil }
        isSaving = true
        error = nil
        return Task {
            defer { isSaving = false }
            switch await editing.change(changes) {
            case .completed:
                if !editing.supportsBatch, changes.first?.operation == .add { finishAdding() }
            case .changed:
                error = .Board.boardReviewersChanged
            case .uncertain:
                error = .Board.boardReviewersUncertain
            default:
                error = .Board.boardReviewersSaveFailed
            }
        }
    }
}

struct ReviewerRemovalButton: View {
    let person: ReviewerCandidate
    let revealed: Bool
    let state: ReviewerEditorState
    var onSelect: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Button(role: .destructive) {
            onSelect()
            state.pendingRemoval = person
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                #if os(iOS)
                .frame(width: 44, height: 44)
                #else
                .frame(width: 28, height: 28)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .opacity(revealed || focused ? 1 : 0)
        .allowsHitTesting(revealed || focused)
        .disabled(state.isSaving || state.isAdding)
        .help(Text(.Board.boardReviewersRemovePerson(person.username)))
        .accessibilityLabel(Text(.Board.boardReviewersRemovePerson(person.username)))
    }
}

struct ReviewerRemovalConfirmation: ViewModifier {
    let state: ReviewerEditorState
    var editing: ReviewerEditing?

    func body(content: Content) -> some View {
        content
            .alert(Text(.Board.boardReviewersRemove), isPresented: Binding(
                get: { state.pendingRemoval != nil }, set: { if !$0 { state.pendingRemoval = nil } }
            ), presenting: state.pendingRemoval) { person in
                Button(.Board.boardReviewersRemove, role: .destructive) {
                    guard let editing else { return }
                    state.save([.init(.remove, reviewerID: person.id, username: person.username)], using: editing)
                }
                Button(.Remote.remoteCancel, role: .cancel) {}
            } message: { person in
                Text(.Board.boardReviewersRemovePerson(person.username))
            }
    }
}

struct ReviewerSaveErrorAlert: ViewModifier {
    let state: ReviewerEditorState
    let editorClosed: Bool

    func body(content: Content) -> some View {
        content.alert(Text(state.error ?? .Board.boardReviewersSaveFailed), isPresented: Binding(
            get: { editorClosed && state.error != nil }, set: { if !$0 { state.error = nil } }
        )) {
            Button(.Remote.remoteClose) { state.error = nil }
        }
    }
}

struct ReviewerPicker: View {
    let editing: ReviewerEditing
    let assigned: [ReviewerCandidate]
    let state: ReviewerEditorState
    let onDone: () -> Void
    @State private var input = ""
    @State private var selection = 0
    @State private var loadedQuery: String?
    @State private var matches: [ReviewerCandidate] = []
    @State private var loadFailed = false
    @FocusState private var focused: Bool

    private var query: String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }
    private var alreadyAssigned: Bool {
        assigned.contains { $0.username.lowercased() == query.lowercased() }
    }
    private var choices: [ReviewerCandidate] {
        guard loadedQuery == query, !alreadyAssigned, !selectionLimitReached else { return [] }
        let assignedIDs = Set(assigned.map(\.id) + state.pendingAdditions.map(\.id))
        return matches.filter { !assignedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: .Board.boardReviewersSearch), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused)
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onSubmit {
                        if choices.indices.contains(selection) { add(choices[selection]) }
                    }
                if editing.supportsBatch {
                    Button(.Board.boardReviewersDone, action: onDone)
                } else {
                    Button(.Remote.remoteCancel) { state.finishAdding() }
                }
            }
            if !state.pendingAdditions.isEmpty { pendingAdditions }
            if selectionLimitReached {
                Text(.Board.boardReviewersSelectionLimit(ReviewerChange.Batch.maximumCount)).foregroundStyle(.secondary)
            } else if alreadyAssigned {
                Text(.Board.boardReviewersAlreadyAssigned).foregroundStyle(.secondary)
            } else if loadedQuery != query {
                ProgressView().controlSize(.small)
            } else if loadFailed {
                Text(.Board.boardReviewersSearchFailed).foregroundStyle(.secondary)
            } else if !query.isEmpty && choices.isEmpty {
                Text(.Board.boardReviewersNoMatches).foregroundStyle(.secondary)
            } else if !choices.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, person in
                                Button { add(person) } label: {
                                    HStack(spacing: 8) {
                                        let identity = PersonIdentity(name: person.name, username: person.username)
                                        PersonAvatar(url: person.avatarURL, size: 28, initials: identity.initials)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: person.name).font(.callout)
                                            Text(verbatim: "@\(person.username)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 5)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background {
                                        if index == selection { RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.12)) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(person.id)
                            }
                        }
                    }
                    .onChange(of: selection) { _, index in
                        if choices.indices.contains(index) { scroll.scrollTo(choices[index].id) }
                    }
                }
                .frame(height: min(CGFloat(choices.count) * 48 - 4, 145))
            }
        }
        .font(.callout)
        .disabled(state.isSaving)
        .task(id: query) { await load(query) }
        .defaultFocus($focused, true)
        .onAppear { focused = true }
    }

    private var pendingAdditions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(state.pendingAdditions) { person in
                    Button { state.unselect(person) } label: {
                        Label { Text(verbatim: "@\(person.username)") } icon: { Image(systemName: "xmark.circle.fill") }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            #if os(iOS)
                            .frame(minHeight: 44)
                            #else
                            .frame(minHeight: 24)
                            #endif
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(.Board.boardReviewersRemovePerson(person.username)))
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = min(max(selection + offset, 0), choices.count - 1)
        return .handled
    }

    private func load(_ query: String) async {
        loadedQuery = nil
        selection = 0
        loadFailed = false
        guard query.utf8.count <= 128 else {
            matches = []
            loadedQuery = query
            return
        }
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            var result = try await editing.search(query)
            try Task.checkCancellation()
            if let exact = result.firstIndex(where: { $0.username.caseInsensitiveCompare(query) == .orderedSame }) {
                let match = result.remove(at: exact)
                result.insert(match, at: 0)
            }
            matches = result
            loadedQuery = query
        } catch {
            guard !Task.isCancelled else { return }
            matches = []
            loadFailed = true
            loadedQuery = query
        }
    }

    private func add(_ person: ReviewerCandidate) {
        state.add(person)
        selection = 0
        if editing.supportsBatch {
            if person.username.caseInsensitiveCompare(query) == .orderedSame { input = "" }
            focused = true
        }
    }

    private var selectionLimitReached: Bool {
        state.pendingAdditions.count == ReviewerChange.Batch.maximumCount
    }
}

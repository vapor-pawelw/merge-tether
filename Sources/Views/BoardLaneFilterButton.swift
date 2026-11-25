import SwiftUI
import MergeTetherRemote

typealias MRBoardLaneFilter = RemoteBoardLaneFilter

extension RemoteBoardLaneFilter.Card {
    var title: LocalizedStringResource {
        switch self {
        case .needsAttention: .CommandCenter.commandCenterStatusAttention
        case .new: .Board.boardReviewAssignmentNew
        case .pinned: .Board.boardFiltersPinned
        }
    }
}

extension RemoteBoardLaneFilter.Section {
    var title: LocalizedStringResource {
        switch self {
        case .regular: .Board.boardFiltersRegular
        case .inactive: .Board.boardFiltersInactive
        }
    }
}

extension RemoteBoardLaneFilter {
    func matches(_ row: MergeRequestBoardSnapshot.Row, activity: @autoclosure () -> MRBoardActivity.Group,
                 isPinned: @autoclosure () -> Bool, isNew: Bool? = nil) -> Bool {
        matches(needsAttention: row.needsAttention, isNew: isNew ?? (row.newReviewAssignedAt != nil),
            isPinned: isPinned(), isInactive: activity() == .inactive)
    }
}

struct BoardLaneFilterButton: View {
    @Binding var selection: MRBoardLaneFilter
    let cardChoices: [MRBoardLaneFilter.Card]
    @State private var showingFilters = false

    var body: some View {
        Button {
            showingFilters.toggle()
        } label: {
            BoardCardActionIcon(systemName: selection.isActive
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(selection.isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(Text(.Board.boardFiltersTitle))
        .accessibilityLabel(Text(.Board.boardFiltersTitle))
        .accessibilityValue(Text(selection.isActive ? .Board.boardFiltersActive : .Board.boardFiltersAll))
        .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
            choices
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { !selection.isActive }, set: { _ in selection = .init() })) {
                Text(.Board.boardFiltersAll)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(.Board.boardFiltersCards).font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(cardChoices, id: \.self) { card in
                    Toggle(isOn: membership(of: card, in: $selection.cards)) { Text(card.title) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(.Board.boardFiltersSections).font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(MRBoardLaneFilter.Section.allCases, id: \.self) { section in
                    Toggle(isOn: membership(of: section, in: $selection.sections)) { Text(section.title) }
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(width: 172, alignment: .leading)
        .padding(12)
    }

    private func membership<Value: Hashable>(of value: Value, in values: Binding<Set<Value>>) -> Binding<Bool> {
        Binding {
            values.wrappedValue.contains(value)
        } set: { enabled in
            if enabled { values.wrappedValue.insert(value) }
            else { values.wrappedValue.remove(value) }
        }
    }
}

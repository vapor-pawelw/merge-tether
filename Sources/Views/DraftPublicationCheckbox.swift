import SwiftUI

struct DraftPublicationCheckbox: View {
    let draft: GitLabDraftNote
    @Binding var selection: DraftPublicationSelection
    var disabled = false

    var body: some View {
        Toggle(isOn: Binding(get: { selection.isSelected(draft) }, set: {
            selection.setSelected($0, draft: draft)
        })) {
            Text(.DraftPublication.draftPublicationSelect)
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .controlSize(.small)
        .disabled(disabled || !DraftPublicationSelection.canSelect(draft))
        .help(Text(.DraftPublication.draftPublicationSelect))
        .accessibilityLabel(Text(.DraftPublication.draftPublicationSelect))
        .accessibilityIdentifier("select-draft-\(draft.id ?? 0)")
    }
}

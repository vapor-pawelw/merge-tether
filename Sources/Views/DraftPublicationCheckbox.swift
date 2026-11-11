import SwiftUI

struct DraftPublicationWarnings: View {
    let drafts: [GitLabDraftNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(drafts.compactMap(DraftPublicationRisk.init)) { risk in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(risk.messages.enumerated()), id: \.offset) { _, message in
                        Label { Text(message).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    }
                }
                .accessibilityIdentifier("draft-publication-warning-\(risk.id)")
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
}

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

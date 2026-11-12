import SwiftUI

/// Evidence stays available without competing with the next step the user needs to understand.
struct AgentDiagnosticDetails: View {
    let reason: String

    var body: some View {
        DisclosureGroup {
            Text(verbatim: reason).font(.callout).foregroundStyle(.primary).lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: { Text(.AgentExplanation.agentExplanationDiagnostics).foregroundStyle(.secondary) }
        .font(.subheadline)
    }
}

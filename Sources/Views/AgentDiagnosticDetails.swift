import SwiftUI

/// Evidence stays available without competing with the next step the user needs to understand.
struct AgentDiagnosticDetails: View {
    let reason: String

    var body: some View {
        DisclosureGroup {
            Text(verbatim: reason).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } label: { Text(.AgentExplanation.agentExplanationDiagnostics) }
        .font(.caption).foregroundStyle(.secondary)
    }
}

import SwiftUI

/// App-only agent explanation for a draft or published comment. It never reaches GitLab.
struct RemoteExtraContextButton: View {
    let markdown: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label(.RemoteDetail.remoteDetailExtraContext, systemImage: "lightbulb")
                .font(.callout).frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text(.RemoteDetail.remoteDetailExtraContextHelp))
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label { Text(.RemoteDetail.remoteDetailExtraContextHelp) } icon: { Image(systemName: "lock") }
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ExtraContextMarkdown(source: markdown).font(.callout)
                    }
                    .padding(20)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(Text(.RemoteDetail.remoteDetailExtraContext))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(.Remote.remoteClose) { isPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

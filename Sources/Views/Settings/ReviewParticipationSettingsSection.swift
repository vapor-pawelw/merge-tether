import SwiftUI

struct ReviewParticipationSettingsSection: View {
    let monitor: TodoMonitorService
    @State private var username = ""
    @State private var isAdding = false
    @State private var failed = false
    @State private var persistenceFailed = false

    var body: some View {
        Section {
            HStack {
                TextField(text: $username) { Text(.ReviewParticipation.reviewParticipationUsername) }
                    .autocorrectionDisabled()
                Button {
                    isAdding = true
                    failed = false
                    persistenceFailed = false
                    Task {
                        defer { isAdding = false }
                        do {
                            try await monitor.excludeReviewParticipant(username: username)
                            username = ""
                        } catch ReviewParticipationError.persistence { persistenceFailed = true }
                        catch { failed = true }
                    }
                } label: { Text(.ReviewParticipation.reviewParticipationExclude) }
                    .disabled(isAdding || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || monitor.glab.currentUsername == nil || monitor.glab.resolvedHost == nil)
            }
            ForEach(monitor.settings.reviewParticipationPreferences.entries.filter {
                $0.host == monitor.glab.resolvedHost && $0.username == monitor.glab.currentUsername
            }) { entry in
                HStack {
                    Text(verbatim: entry.label)
                    Spacer()
                    Button {
                        persistenceFailed = false
                        do { try monitor.allowReviewParticipant(entry.id) }
                        catch { persistenceFailed = true }
                    } label: {
                        Text(.ReviewParticipation.reviewParticipationAllow)
                    }
                }
            }
            if failed { Text(.ReviewParticipation.reviewParticipationFailed).foregroundStyle(.red) }
            if persistenceFailed { Text(.ReviewParticipation.reviewParticipationSaveFailed).foregroundStyle(.red) }
        } header: { Text(.ReviewParticipation.reviewParticipationTitle) }
        footer: { Text(.ReviewParticipation.reviewParticipationHelp) }
    }
}

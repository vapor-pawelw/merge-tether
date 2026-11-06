import SwiftUI

/// Draft settings only. Applying the enclosing Settings form persists the change.
struct PublicationRestrictionsSettingsView: View {
    @Binding var restrictions: AutomaticPublicationRestrictions
    let glab: GlabService

    var body: some View {
        Section {
            DisclosureGroup {
                PublicationIdentityFilterEditor(identities: $restrictions.repositories,
                    title: .PublicationPolicy.publicationRepositories, kind: .repository, glab: glab)
                PublicationIdentityFilterEditor(identities: $restrictions.mergeRequestAuthors,
                    title: .PublicationPolicy.publicationMrAuthors, kind: .user, glab: glab)
                PublicationIdentityFilterEditor(identities: $restrictions.sourceCommentAuthors,
                    title: .PublicationPolicy.publicationCommentAuthors, kind: .user, glab: glab)
                HStack {
                    Toggle(isOn: $restrictions.requireAI) { Text(.PublicationPolicy.publicationRequireAI) }
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button { restrictions.requireAI = false } label: { Text(.PublicationPolicy.publicationReset) }
                        .disabled(!restrictions.requireAI)
                        .help(Text(.PublicationPolicy.publicationResetFilterHelp))
                }
                Text(.PublicationPolicy.publicationSourceHelp).font(.caption).foregroundStyle(.secondary)
                Button { restrictions = .init() } label: { Text(.PublicationPolicy.publicationResetFilters) }
                    .disabled(restrictions == .init())
                Text(.PublicationPolicy.publicationAdvancedHelp).font(.caption).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Text(.PublicationPolicy.publicationAdvanced)
                    Spacer()
                    Text(verbatim: summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !restrictions.repositories.isEmpty { parts.append(String(localized: .PublicationPolicy.publicationRepositories)) }
        if !restrictions.mergeRequestAuthors.isEmpty { parts.append(String(localized: .PublicationPolicy.publicationMrAuthors)) }
        if !restrictions.sourceCommentAuthors.isEmpty { parts.append(String(localized: .PublicationPolicy.publicationCommentAuthors)) }
        if restrictions.requireAI { parts.append(String(localized: .PublicationPolicy.publicationAiOnly)) }
        return parts.isEmpty ? String(localized: .PublicationPolicy.publicationUnrestrictedShort) : parts.joined(separator: " · ")
    }
}

struct AutomationDefaultsResetButton: View {
    let preset: AutomationPreset?
    let reset: (AutomationPreset) -> Void

    var body: some View {
        if let preset {
            Button { reset(preset) } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(.PublicationPolicy.publicationResetTo(String(localized: preset.title))))
            .help(Text(.PublicationPolicy.publicationResetTo(String(localized: preset.title))))
        } else {
            Menu {
                ForEach(AutomationPreset.allCases, id: \.self) { option in
                    Button { reset(option) } label: { Text(option.title) }
                }
            } label: { Image(systemName: "arrow.counterclockwise") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text(.PublicationPolicy.publicationChooseResetDefaults))
            .help(Text(.PublicationPolicy.publicationChooseResetDefaultsHelp))
        }
    }
}

private struct PublicationIdentityFilterEditor: View {
    enum Kind { case repository, user }
    @Binding var identities: [PublicationIdentity]
    let title: LocalizedStringResource
    let kind: Kind
    let glab: GlabService
    @State private var input = ""
    @State private var isResolving = false
    @State private var hasError = false
    @State private var resolutionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button { identities = [] } label: { Text(.PublicationPolicy.publicationReset) }
                    .disabled(identities.isEmpty)
                    .help(Text(.PublicationPolicy.publicationResetFilterHelp))
            }
            if identities.isEmpty {
                Text(.PublicationPolicy.publicationUnrestricted).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(identities) { identity in
                HStack(spacing: 6) {
                    Text(verbatim: identity.label).lineLimit(1)
                    Text(verbatim: identity.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { identities.removeAll { $0.id == identity.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(.PublicationPolicy.publicationRemove(identity.label)))
                }
            }
            HStack {
                TextField(text: $input) {
                    Text(kind == .repository ? .PublicationPolicy.publicationRepositoryPlaceholder : .PublicationPolicy.publicationUserPlaceholder)
                }
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .onSubmit { resolve() }
                Button(action: resolve) { Text(.PublicationPolicy.publicationAdd) }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving
                              || glab.resolvedHost == nil || glab.currentUsername == nil)
                if isResolving { ProgressView().controlSize(.small) }
            }
            if hasError { Text(.PublicationPolicy.publicationLookupFailed).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
        .onChange(of: glab.resolvedHost) { _, _ in clearLookup() }
        .onChange(of: glab.currentUsername) { _, _ in clearLookup() }
        .onDisappear { clearLookup() }
    }

    private func clearLookup() { resolutionID = nil; isResolving = false; hasError = false }

    private func resolve() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isResolving, let host = glab.resolvedHost,
              let username = glab.currentUsername else { return }
        let current = UUID()
        resolutionID = current; isResolving = true; hasError = false
        Task {
            defer { if resolutionID == current { isResolving = false } }
            do {
                _ = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username)
                let identity: PublicationIdentity
                if kind == .repository {
                    let id = try await glab.resolveAutomationProject(path: value, host: host)
                    identity = .init(host: host, entityID: id, label: value)
                } else {
                    identity = try await glab.resolvePublicationUser(username: value, host: host)
                }
                guard !Task.isCancelled, resolutionID == current,
                      glab.resolvedHost == host, glab.currentUsername == username else { return }
                if !identities.contains(where: { $0.id == identity.id }) { identities.append(identity) }
                if input.trimmingCharacters(in: .whitespacesAndNewlines) == value { input = "" }
            } catch {
                guard resolutionID == current, glab.resolvedHost == host, glab.currentUsername == username else { return }
                hasError = true
            }
        }
    }
}

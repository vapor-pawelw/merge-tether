import AppKit
import SwiftUI

struct GlabAuthStep: View {
    let monitor: TodoMonitorService

    @State private var isRechecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            bodyContent

            HStack {
                Button {
                    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    NSWorkspace.shared.open(terminal)
                } label: {
                    Text(.Onboarding.onboardingAuthOpenTerminal)
                }

                Button {
                    isRechecking = true
                    Task {
                        await monitor.recheckIntegration()
                        isRechecking = false
                    }
                } label: {
                    Text(.Onboarding.onboardingRecheck)
                }
                .disabled(isRechecking)
            }
        }
    }

    private var title: LocalizedStringResource {
        switch monitor.glab.authStatus {
        case .wrongDefaultHost:
            .Onboarding.onboardingAuthWrongHostTitle
        default:
            .Onboarding.onboardingAuthTitle
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch monitor.glab.authStatus {
        case .authenticated:
            authenticatedBody
        case .wrongDefaultHost(let hosts):
            wrongHostBody(hosts: hosts)
        case .notAuthenticated:
            notAuthenticatedBody
        case .unknown:
            Text(.Onboarding.onboardingAuthUnverified).foregroundStyle(.secondary)
        }
    }

    private var authenticatedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.Onboarding.onboardingAuthBody)
                .foregroundStyle(.secondary)

            CommandBox(command: "glab auth login")

            Label {
                Text(.Onboarding.onboardingAuthSignedIn(monitor.glab.currentUsername ?? ""))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var notAuthenticatedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.Onboarding.onboardingAuthBody)
                .foregroundStyle(.secondary)

            CommandBox(command: "glab auth login")

            Label {
                Text(.Onboarding.onboardingAuthNotAuthenticated)
            } icon: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func wrongHostBody(hosts: [GlabService.AuthedHost]) -> some View {
        let primary = hosts.first
        let defaultHost = monitor.glab.resolvedHost ?? ""
        let authedSummary = hosts.map(\.host).joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 12) {
            Text(.Onboarding.onboardingAuthWrongHostBody(authedSummary))
                .foregroundStyle(.secondary)

            if !defaultHost.isEmpty {
                Label {
                    Text(.Onboarding.onboardingAuthWrongHostCurrentDefault(defaultHost))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Text(.Onboarding.onboardingAuthWrongHostInstruction)
                .foregroundStyle(.secondary)

            if let primary {
                CommandBox(command: "glab config set host \(primary.host) --global")
            }
        }
    }
}

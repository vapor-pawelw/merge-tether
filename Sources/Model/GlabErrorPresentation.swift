import Foundation

struct GlabErrorPresentation {
    enum Kind { case connection, timedOut, signIn, hostConfiguration, missingCLI, permissions, invalidResponse, other }
    enum Action { case retry, signIn, setup, integrationSettings }
    let kind: Kind
    let action: Action
    let detail: String?

    init(error: GlabError, authStatus: GlabService.AuthStatus = .unknown) {
        let diagnostic: String?
        switch error {
        case .glabNotInstalled: kind = .missingCLI; action = .setup; diagnostic = nil
        case .notAuthenticated:
            if case .wrongDefaultHost = authStatus { kind = .hostConfiguration; action = .integrationSettings }
            else { kind = .signIn; action = .signIn }
            diagnostic = nil
        case .network(let value): kind = .connection; action = .retry; diagnostic = value
        case .timedOut: kind = .timedOut; action = .retry; diagnostic = nil
        case .decoding(let value): kind = .invalidResponse; action = .retry; diagnostic = value
        case .nonZeroExit(_, let value):
            let forbidden = GlabError.hasHTTPStatus(403, in: value) || value.localizedCaseInsensitiveContains("forbidden")
            kind = forbidden ? .permissions : .other
            action = forbidden ? .integrationSettings : .retry
            diagnostic = value
        case .unknown(let value): kind = .other; action = .retry; diagnostic = value
        }
        let sanitized = diagnostic.map { GlabService.redactWorkflowEvidence($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        detail = sanitized.flatMap { $0.isEmpty ? nil : String($0.prefix(8_000)) }
    }

    var title: LocalizedStringResource {
        switch kind {
        case .connection: .GitLabConnection.connectionTitle
        case .timedOut: .GitLabConnection.timeoutTitle
        case .signIn: .GitLabConnection.signInTitle
        case .hostConfiguration: .GitLabConnection.hostTitle
        case .missingCLI: .GitLabConnection.missingTitle
        case .permissions: .GitLabConnection.permissionsTitle
        case .invalidResponse: .GitLabConnection.responseTitle
        case .other: .GitLabConnection.otherTitle
        }
    }

    var message: LocalizedStringResource {
        switch kind {
        case .connection: .GitLabConnection.connectionHelp
        case .timedOut: .GitLabConnection.timeoutHelp
        case .signIn: .GitLabConnection.signInHelp
        case .hostConfiguration: .GitLabConnection.hostHelp
        case .missingCLI: .GitLabConnection.missingHelp
        case .permissions: .GitLabConnection.permissionsHelp
        case .invalidResponse, .other: .GitLabConnection.retryHelp
        }
    }

    var actionTitle: LocalizedStringResource {
        switch action {
        case .retry: .GitLabConnection.retry
        case .signIn: .GitLabConnection.signIn
        case .setup: .GitLabConnection.setup
        case .integrationSettings: .GitLabConnection.integrationSettings
        }
    }

    func perform(onRetry: () -> Void, onOpenSetup: () -> Void, onOpenIntegration: () -> Void) {
        switch action {
        case .retry: onRetry()
        case .signIn, .setup: onOpenSetup()
        case .integrationSettings: onOpenIntegration()
        }
    }
}

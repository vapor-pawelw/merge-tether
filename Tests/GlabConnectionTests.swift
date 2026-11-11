import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GitLabTodos

@MainActor
struct GlabConnectionTests {
    private let host = "gitlab.example.test"

    @Test(arguments: ["dial tcp lookup gitlab.example.test: i/o timeout", "no such host", "connection refused",
                      "network is unreachable", "TLS handshake timeout", "context deadline exceeded"])
    func transportFailuresOfferRetryWithoutSetupOrLogin(_ diagnostic: String) {
        let error = GlabError.classify(exitCode: 1, stderr: diagnostic)
        let presentation = GlabErrorPresentation(error: error)
        #expect(presentation.kind == .connection)
        #expect(presentation.action == .retry)
        #expect(presentation.detail == diagnostic)
    }

    @Test func requestNumbersAndURLsCannotBeMistakenForAnAuthenticationFailure() {
        let diagnostic = #"Get https://gitlab.example.test/api/v4/projects/401: dial tcp lookup gitlab.example.test: i/o timeout"#
        #expect(GlabError.classify(exitCode: 1, stderr: diagnostic) == .network(diagnostic))
        #expect(GlabError.classify(exitCode: 1, stderr: "GET /projects/401 returned HTTP 500") != .notAuthenticated)
        #expect(GlabError.classify(exitCode: 1, stderr: "HTTP 401 Unauthorized") == .notAuthenticated)
    }

    @Test func setupAuthenticationPermissionsAndBadResponsesHaveDifferentRecoveryActions() {
        #expect(GlabErrorPresentation(error: .glabNotInstalled).action == .setup)
        #expect(GlabErrorPresentation(error: .notAuthenticated).action == .signIn)
        #expect(GlabErrorPresentation(error: .notAuthenticated,
            authStatus: .wrongDefaultHost(authedHosts: [])).kind == .hostConfiguration)
        #expect(GlabErrorPresentation(error: .notAuthenticated,
            authStatus: .wrongDefaultHost(authedHosts: [])).action == .integrationSettings)
        let denied = GlabErrorPresentation(error: .nonZeroExit(code: 1, stderr: "HTTP 403 Forbidden"))
        #expect(denied.kind == .permissions && denied.action == .integrationSettings)
        #expect(GlabErrorPresentation(error: .timedOut).action == .retry)
        #expect(GlabErrorPresentation(error: .decoding("Invalid response")).action == .retry)
    }

    @Test func technicalDetailsAreSanitizedAndStayOutOfTheCompactSummary() {
        let diagnostic = "dial tcp lookup \(host): i/o timeout\nAuthorization: Bearer private-value\naccess_token=private-token"
        let presentation = GlabErrorPresentation(error: .network(diagnostic))
        #expect(presentation.detail?.contains("private-value") == false)
        #expect(presentation.detail?.contains("private-token") == false)
        #expect(presentation.detail?.contains("i/o timeout") == true)
        #expect(!String(localized: presentation.message).contains(host))
    }

    @Test func recoveryActionsUseRetrySetupOrIntegrationWithoutChangingSettings() {
        var actions: [String] = []
        for error in [GlabError.network("dial tcp timeout"), .notAuthenticated, .glabNotInstalled,
                      .nonZeroExit(code: 1, stderr: "403 Forbidden")] {
            GlabErrorPresentation(error: error).perform(onRetry: { actions.append("retry") },
                onOpenSetup: { actions.append("setup") }, onOpenIntegration: { actions.append("integration") })
        }
        #expect(actions == ["retry", "setup", "setup", "integration"])
        #expect(OnboardingView.startingStep(hasCompletedSetup: true, cliAvailable: true) == .glabAuth)
        #expect(OnboardingView.startingStep(hasCompletedSetup: true, cliAvailable: false) == .glabInstall)
        #expect(OnboardingView.startingStep(hasCompletedSetup: false, cliAvailable: true) == .glabInstall)
        let navigation = SettingsNavigation()
        var opened: SettingsNavigation.Tab?
        navigation.showIntegration { opened = navigation.selection }
        #expect(opened == .integration)
    }

    @Test func aLongDiagnosticDoesNotExpandTheCollapsedBannerOrPerformAnAction() {
        var actions = 0
        let long = Array(repeating: "dial tcp lookup \(host): i/o timeout", count: 80).joined(separator: "\n")
        let view = NSHostingView(rootView: ErrorBannerView(error: .network(long),
            onRetry: { actions += 1 }, onOpenSetup: { actions += 1 }, onOpenIntegration: { actions += 1 }).frame(width: 720))
        #expect(view.fittingSize.height > 0 && view.fittingSize.height < 140)
        #expect(actions == 0)
    }

    @Test(arguments: [false, true])
    func obsoleteSignInChecksCannotRestoreAnAccountAfterASwitch(_ returnsToOriginal: Bool) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "alice")
        glab.authStatus = .authenticated
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            gitlab.write("auth-started")
            try await gitlab.waitFor("release-auth")
            return InMemoryGitLab.output(error: "Logged in to \(host) as alice")
        }
        let pending = Task { await glab.recheck() }
        try await gitlab.waitFor("auth-started")
        glab.currentUsername = "bob"
        if returnsToOriginal { glab.currentUsername = "alice" }
        let revision = glab.accountRevision
        gitlab.write("release-auth")
        _ = await pending.value
        #expect(glab.currentUsername == (returnsToOriginal ? "alice" : "bob"))
        #expect(glab.accountRevision == revision && glab.authedHosts.isEmpty)
    }

    @Test func replacingTheExecutableDiscardsItsInFlightAuthenticationResult() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "alice")
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            gitlab.write("auth-started")
            try await gitlab.waitFor("release-auth")
            return InMemoryGitLab.output(error: "Logged in to \(host) as obsolete")
        }
        let pending = Task { await glab.recheck() }
        try await gitlab.waitFor("auth-started")
        glab.glabPath = URL(fileURLWithPath: "/different/glab")
        gitlab.write("release-auth")
        _ = await pending.value
        #expect(glab.currentUsername == "alice" && glab.authedHosts.isEmpty)
    }

    @Test func cancellingOneWaiterDoesNotCancelTheSharedAuthenticationProbe() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "alice")
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            gitlab.write("auth-started")
            try await gitlab.waitFor("release-auth")
            return InMemoryGitLab.output(error: "Logged in to \(host) as alice")
        }
        let first = Task { await glab.recheck() }
        try await gitlab.waitFor("auth-started")
        let second = Task {
            gitlab.write("second-waiter")
            return await glab.recheck()
        }
        try await gitlab.waitFor("second-waiter")
        first.cancel()
        gitlab.write("release-auth")
        #expect(await second.value == nil)
        _ = await first.value
        #expect(glab.authStatus == .authenticated)
        #expect(gitlab.requests.filter { $0.arguments.first == "auth" }.count == 1)
    }
}

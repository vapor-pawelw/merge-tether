import Foundation
import Observation
import OSLog
import Sparkle

@MainActor @Observable
final class AppUpdater {
    let presentation = AppUpdatePresentation()
    let isConfigured: Bool
    private(set) var isEnabled = false
    private(set) var automaticallyChecks = false
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private var controller: SPUUpdater?
    @ObservationIgnored private var restartWait: Task<Void, Never>?
    @ObservationIgnored private var isBusy: () -> Bool = { false }

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = URL(string: feed)?.scheme == "https" && Data(base64Encoded: publicKey)?.count == 32
    }

    func start(isBusy: @escaping () -> Bool) {
        guard isConfigured, controller == nil else { return }
        self.isBusy = isBusy
        let driver = AppUpdateDriver(presentation: presentation)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        do {
            try updater.start()
            automaticallyChecks = updater.automaticallyChecksForUpdates
            controller = updater
            isEnabled = true
        } catch {
            Log.update.error("Cannot start updater: \(error.localizedDescription, privacy: .private)")
            presentation.fail()
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard let controller else { return }
        controller.automaticallyChecksForUpdates = enabled
        automaticallyChecks = controller.automaticallyChecksForUpdates
    }

    func check() {
        guard let controller, controller.canCheckForUpdates else { return }
        controller.checkForUpdates()
    }

    func restart() {
        presentation.restart(isBusy: isBusy())
        guard case .waitingToRestart = presentation.phase, restartWait == nil else { return }
        restartWait = Task { [weak self] in
            defer { self?.restartWait = nil }
            while !Task.isCancelled {
                guard let self, case .waitingToRestart = self.presentation.phase else { return }
                self.presentation.continueRestartIfIdle(isBusy: self.isBusy())
                guard case .waitingToRestart = self.presentation.phase else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func cancelWaitingForRestart() {
        presentation.cancelWaitingForRestart()
    }
}

@MainActor
private final class AppUpdateDriver: NSObject, SPUUserDriver {
    private let presentation: AppUpdatePresentation

    init(presentation: AppUpdatePresentation) { self.presentation = presentation }

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        // The bundle sets the default and exposes the user's choice in General settings.
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { presentation.checking() }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !item.isInformationOnlyUpdate else {
            presentation.noUpdate(isCurrent: false)
            reply(.dismiss)
            return
        }
        presentation.offer(version: item.displayVersionString) { reply(.install) }
        if state.stage == .installing { presentation.ready { reply(.install) } }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error) async {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let current = reason?.int32Value == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            || reason?.int32Value == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue
        presentation.noUpdate(isCurrent: current)
    }

    func showUpdaterError(_ error: any Error) async {
        Log.update.error("Update session failed: \(error.localizedDescription, privacy: .private)")
        presentation.fail()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { presentation.downloading() }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { presentation.expect(bytes: length) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { presentation.received(bytes: length) }
    func showDownloadDidStartExtractingUpdate() { presentation.prepare() }
    func showExtractionReceivedProgress(_ progress: Double) { presentation.prepare(progress: progress) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        presentation.ready { reply(.install) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}
    func dismissUpdateInstallation() { presentation.endSession() }
}

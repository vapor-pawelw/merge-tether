import Observation

@MainActor @Observable
final class AppUpdatePresentation {
    enum Phase: Equatable {
        case idle, checking, current, unavailable, failed
        case available(String), downloading(Double?), preparing(Double?)
        case ready(String), waitingToRestart(String), restarting
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var version: String?
    @ObservationIgnored private var bytesReceived: UInt64 = 0
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var downloadAction: (() -> Void)?
    @ObservationIgnored private var restartAction: (() -> Void)?

    func checking() { phase = .checking }
    func noUpdate(isCurrent: Bool) { phase = isCurrent ? .current : .unavailable }

    func clearResult() {
        switch phase {
        case .current, .unavailable, .failed: phase = .idle
        default: break
        }
    }

    func offer(version: String, download: @escaping () -> Void) {
        self.version = version
        downloadAction = download
        phase = .available(version)
    }

    func download() {
        guard let action = downloadAction else { return }
        downloadAction = nil
        downloading()
        action()
    }

    func downloading() {
        bytesReceived = 0
        expectedBytes = 0
        phase = .downloading(nil)
    }

    func expect(bytes: UInt64) {
        expectedBytes = bytes
        updateDownloadProgress()
    }

    func received(bytes: UInt64) {
        bytesReceived += min(bytes, UInt64.max - bytesReceived)
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        guard case .downloading = phase else { return }
        phase = .downloading(expectedBytes == 0 ? nil : min(1, Double(bytesReceived) / Double(expectedBytes)))
    }

    func prepare(progress: Double? = nil) {
        phase = .preparing(progress.map { min(1, max(0, $0)) })
    }

    func ready(restart: @escaping () -> Void) {
        guard let version else { return }
        downloadAction = nil
        restartAction = restart
        phase = .ready(version)
    }

    func restart(isBusy: Bool = false) {
        guard case .ready(let version) = phase else { return }
        phase = .waitingToRestart(version)
        continueRestartIfIdle(isBusy: isBusy)
    }

    func continueRestartIfIdle(isBusy: Bool) {
        guard case .waitingToRestart = phase, !isBusy, let action = restartAction else { return }
        restartAction = nil
        phase = .restarting
        action()
    }

    func cancelWaitingForRestart() {
        guard case .waitingToRestart(let version) = phase else { return }
        phase = .ready(version)
    }

    func fail() {
        endSession()
        phase = .failed
    }

    func endSession() {
        downloadAction = nil
        restartAction = nil
        version = nil
        switch phase {
        case .idle, .current, .unavailable, .failed: break
        case .checking, .available, .downloading, .preparing, .ready, .waitingToRestart, .restarting:
            phase = .idle
        }
    }
}

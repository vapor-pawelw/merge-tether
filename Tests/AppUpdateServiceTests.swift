import Testing

@testable import MergeTether

@MainActor
struct AppUpdateServiceTests {
    @Test func installWaitsForPreparationAndExplicitRestart() {
        let updates = AppUpdatePresentation()
        var downloads = 0
        var restarts = 0

        updates.offer(version: "2.0.1") { downloads += 1 }
        #expect(updates.phase == .available("2.0.1"))
        updates.restart()
        #expect(restarts == 0)

        updates.download()
        updates.download()
        #expect(downloads == 1)
        #expect(updates.phase == .downloading(nil))
        updates.received(bytes: 10)
        updates.expect(bytes: 40)
        updates.received(bytes: 10)
        #expect(updates.phase == .downloading(0.5))
        updates.prepare(progress: 0.75)
        #expect(updates.phase == .preparing(0.75))

        updates.ready { restarts += 1 }
        #expect(updates.phase == .ready("2.0.1"))
        #expect(restarts == 0)
        updates.restart()
        updates.restart()
        #expect(restarts == 1)
        #expect(updates.phase == .restarting)
    }

    @Test func failedPreparationDiscardsTheOldRestartAction() {
        let updates = AppUpdatePresentation()
        var restarts = 0
        updates.offer(version: "2.0.1") {}
        updates.download()
        updates.ready { restarts += 1 }

        updates.fail()
        updates.restart()

        #expect(updates.phase == .failed)
        #expect(restarts == 0)
    }

    @Test func deferredRestartCanBeCancelledAndRetried() {
        let updates = AppUpdatePresentation()
        var restarts = 0
        updates.offer(version: "2.0.1") {}
        updates.download()
        updates.ready { restarts += 1 }

        updates.restart(isBusy: true)
        #expect(updates.phase == .waitingToRestart("2.0.1"))
        #expect(restarts == 0)
        updates.cancelWaitingForRestart()
        #expect(updates.phase == .ready("2.0.1"))
        updates.continueRestartIfIdle(isBusy: false)
        #expect(restarts == 0)
        updates.restart(isBusy: true)
        updates.continueRestartIfIdle(isBusy: false)
        #expect(restarts == 1)
    }
}

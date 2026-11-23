import Foundation
import IOKit.ps

/// One process-wide idle-sleep assertion while local agent processes are using AC power.
@MainActor
final class AssistantPowerActivity {
    private static let shared: AssistantPowerActivity = {
        let activity = AssistantPowerActivity(isOnExternalPower: {
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
            return IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSACPowerValue
        }, acquire: {
            let process = ProcessInfo.processInfo
            let assertion = process.beginActivity(options: .idleSystemSleepDisabled, reason: "MergeTether agent tasks")
            return { process.endActivity(assertion) }
        })
        // The shared observer and its context are retained for the life of the app.
        let context = Unmanaged.passUnretained(activity).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let activity = Unmanaged<AssistantPowerActivity>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated { activity.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        return activity
    }()

    private let isOnExternalPower: () -> Bool
    private let acquire: () -> () -> Void
    private var enabled = true
    private var running = 0
    private var release: (() -> Void)?

    init(isOnExternalPower: @escaping () -> Bool, acquire: @escaping () -> () -> Void) {
        self.isOnExternalPower = isOnExternalPower
        self.acquire = acquire
    }

    static func configure(enabled: Bool) {
        guard ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application else { return }
        shared.setEnabled(enabled)
    }

    static func whileRunning<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async rethrows -> Result {
        guard ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application else {
            return try await operation()
        }
        return try await shared.track(operation)
    }

    func track<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async rethrows -> Result {
        beginRun()
        defer { endRun() }
        return try await operation()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        powerSourceChanged()
    }

    func beginRun() {
        running += 1
        powerSourceChanged()
    }

    func endRun() {
        running -= 1
        powerSourceChanged()
    }

    func powerSourceChanged() {
        if enabled && running > 0 && isOnExternalPower() {
            if release == nil { release = acquire() }
        } else if let release {
            self.release = nil
            release()
        }
    }
}

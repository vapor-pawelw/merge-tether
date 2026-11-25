import Foundation

enum AssistantUsageRunner {
    enum AccessError: Error { case temporarilyUnavailable(AssistantCLIHealthIssue.Kind) }
    struct Context: Sendable {
        var id = UUID()
        let role: AssistantUsageRole
        let assistant: AutomationAssistant
        var model: String?
        var mergeRequest: AssistantUsageMergeRequest?
        var purpose: AssistantUsagePurpose?
        var correlationID: UUID?
    }

    static func run(_ executable: URL, arguments: [String] = [], environment: [String: String],
                    currentDirectory: URL? = nil, timeout: TimeInterval = 30, input: Data? = nil,
                    outputDirectory: URL? = nil,
                    usage: Context, store: AssistantUsageStore = .shared,
                    healthStore: AssistantCLIHealthStore? = nil,
                    beforeLaunch: (@Sendable () async throws -> Void)? = nil,
                    authorizeLaunch: (@MainActor @Sendable () -> Bool)? = nil,
                    codexProbe: @Sendable (URL, [String: String]) async -> AssistantCLIHealthIssue? = {
                        await CodexAccountProbe.probe(executable: $0, environment: $1)
                    }) async throws -> ProcessRunner.Output {
        let health = await MainActor.run { healthStore ?? AssistantCLIHealthStore.shared }
        if let hold = await health.hold(for: usage.assistant) { throw AccessError.temporarilyUnavailable(hold.issue.kind) }
        let startedAt = Date()
        do {
            try await store.begin(id: usage.id, role: usage.role, assistant: usage.assistant, date: Date(),
                mergeRequest: usage.mergeRequest, purpose: usage.purpose, correlationID: usage.correlationID)
        } catch {
            Log.monitor.error("Could not start agent usage receipt: \(String(describing: error), privacy: .private)")
        }
        do { try await beforeLaunch?() }
        catch {
            // This request never reached a subprocess and is not a CLI attempt.
            do { try await store.discard(id: usage.id) }
            catch { Log.monitor.error("Could not discard an unstarted agent usage receipt") }
            throw error
        }
        let capture = MeasurementCapture()
        let healthCapture = HealthCapture()
        let launchCapture = LaunchCapture()
        do {
            let output = try await AssistantPowerActivity.whileRunning {
                try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                    currentDirectory: currentDirectory, timeout: timeout, input: input, outputDirectory: outputDirectory, onOutput: {
                        capture.set(AssistantUsageParser.parse($0.stdout, assistant: usage.assistant, model: usage.model))
                        if let issue = AssistantCLIHealthIssue.parse($0, assistant: usage.assistant), healthCapture.recordFirst() {
                            let observedAt = Date()
                            Task { @MainActor in health.record(issue, assistant: usage.assistant, executable: executable,
                                startedAt: startedAt, observedAt: observedAt) }
                        }
                    }, authorizeLaunch: authorizeLaunch, onStarted: { launchCapture.markStarted() })
            }
            var issue = AssistantCLIHealthIssue.parse(output, assistant: usage.assistant)
            // `codex exec` reports failures as prose only; confirm an unrecognized one through Codex's account endpoints.
            if issue == nil, usage.assistant == .codex, output.exitCode != 0 {
                issue = await codexProbe(executable, environment)
            }
            if let issue {
                await health.record(issue, assistant: usage.assistant, executable: executable, startedAt: startedAt,
                    observedAt: Date())
            } else if AssistantCLIHealthIssue.confirmsSuccess(output, assistant: usage.assistant) {
                await health.recordSuccess(assistant: usage.assistant, startedAt: startedAt)
            }
            let complete = usage.assistant == .claude || (output.exitCode == 0 && capture.value?.terminalComplete == true)
            await finish(usage.id, capture: capture, complete: complete, store: store)
            return output
        } catch {
            if !launchCapture.started {
                do { try await store.discard(id: usage.id) }
                catch { Log.monitor.error("Could not discard an unstarted agent usage receipt") }
            } else {
                await finish(usage.id, capture: capture, complete: false, store: store)
            }
            throw error
        }
    }

    private static func finish(_ id: UUID, capture: MeasurementCapture, complete: Bool, store: AssistantUsageStore) async {
        do {
            try await store.finish(id: id, measurement: capture.value ?? .init(tokens: nil, estimatedUSD: nil,
                pricingVersion: nil), complete: complete)
        } catch {
            Log.monitor.error("Could not finish agent usage receipt: \(String(describing: error), privacy: .private)")
        }
    }

    private final class LaunchCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart = false
        var started: Bool { lock.withLock { didStart } }
        func markStarted() { lock.withLock { didStart = true } }
    }

    private final class MeasurementCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var measurement: AssistantUsageMeasurement?
        var value: AssistantUsageMeasurement? { lock.withLock { measurement } }
        func set(_ value: AssistantUsageMeasurement) { lock.withLock { measurement = value } }
    }

    private final class HealthCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded = false
        func recordFirst() -> Bool {
            lock.withLock {
                guard !recorded else { return false }
                recorded = true
                return true
            }
        }
    }
}

import Foundation

enum AssistantUsageRunner {
    struct Context: Sendable {
        var id = UUID()
        let role: AssistantUsageRole
        let assistant: AutomationAssistant
        var model: String?
    }

    static func run(_ executable: URL, arguments: [String] = [], environment: [String: String],
                    currentDirectory: URL? = nil, timeout: TimeInterval = 30, input: Data? = nil,
                    usage: Context, store: AssistantUsageStore = .shared) async throws -> ProcessRunner.Output {
        do {
            try await store.begin(id: usage.id, role: usage.role, assistant: usage.assistant, date: Date())
        } catch {
            Log.monitor.error("Could not start agent usage receipt: \(String(describing: error), privacy: .private)")
        }
        let capture = MeasurementCapture()
        do {
            let output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                currentDirectory: currentDirectory, timeout: timeout, input: input, onOutput: {
                    capture.set(AssistantUsageParser.parse($0.stdout, assistant: usage.assistant, model: usage.model))
                })
            let complete = usage.assistant == .claude || (output.exitCode == 0 && capture.value?.terminalComplete == true)
            await finish(usage.id, capture: capture, complete: complete, store: store)
            return output
        } catch {
            if let processError = error as? ProcessRunner.RunError, case .launchFailed = processError {
                do { try await store.discard(id: usage.id) }
                catch { Log.monitor.error("Could not discard unstarted agent usage: \(String(describing: error), privacy: .private)") }
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

    private final class MeasurementCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var measurement: AssistantUsageMeasurement?
        var value: AssistantUsageMeasurement? { lock.withLock { measurement } }
        func set(_ value: AssistantUsageMeasurement) { lock.withLock { measurement = value } }
    }
}

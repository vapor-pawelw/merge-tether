import CryptoKit
import Foundation

struct CrashReport: Sendable {
    struct Envelope: Sendable {
        let id: String
        let body: Data
    }

    struct StackFrame: Sendable {
        let binaryID: UUID
        let address: UInt64
        let base: UInt64
        var imageSize: UInt64? = nil
    }

    let timestamp: Date
    private let applicationVersion: String
    private let build: String
    private let systemVersion: String?
    private let type: String
    private let executable: String
    private let frames: [StackFrame]

    init?(timestamp: Date, applicationVersion: String, build: String, systemVersion: String,
          signal: Int?, exception: Int?, callStack: Data, executable: String) {
        self.init(timestamp: timestamp, applicationVersion: applicationVersion, build: build, systemVersion: systemVersion,
            signal: signal.flatMap { Self.signalNames[$0] }, exception: exception,
            executable: executable, frames: Self.appFrames(in: callStack, executable: executable))
    }

    init?(timestamp: Date, applicationVersion: String, build: String, systemVersion: String, signal: String?,
          exception: Int? = nil, executable: String, frames: [StackFrame]) {
        guard applicationVersion.wholeMatch(of: /[0-9]{1,8}(\.[0-9]{1,8}){0,3}/) != nil,
              build.wholeMatch(of: /[0-9]{1,8}(\.[0-9]{1,8}){0,3}/) != nil else { return nil }
        self.timestamp = timestamp
        self.applicationVersion = applicationVersion
        self.build = build
        self.systemVersion = systemVersion.split(separator: " ").first {
            $0.wholeMatch(of: /[0-9]{1,4}(\.[0-9]{1,4}){1,3}/) != nil
        }.map(String.init)
        if let signal, Self.signalNames.values.contains(signal) {
            type = signal
        } else if let exception, (1...15).contains(exception) {
            type = "Mach exception \(exception)"
        } else {
            type = "Application crash"
        }
        self.executable = executable
        self.frames = frames
    }

    func envelope(installationID: UUID) throws -> Envelope {
        #if os(macOS)
        let platform = "macOS"
        let identifier = "com.vaporpw.MergeTether"
        let mechanism = "macos_crash_report"
        #else
        let platform = "iOS"
        let identifier = "com.vaporpw.MergeTether.iOS"
        let mechanism = "metrickit"
        #endif
        var exception: [String: Any] = ["type": type, "mechanism": ["type": mechanism, "handled": false]]
        if !frames.isEmpty {
            exception["stacktrace"] = ["frames": frames.reversed().map {
                ["instruction_addr": Self.hex($0.address), "image_addr": Self.hex($0.base), "in_app": true]
            }]
        }
        var event: [String: Any] = [
            "timestamp": timestamp.timeIntervalSince1970,
            "platform": "cocoa", "level": "fatal",
            "release": "\(identifier)@\(applicationVersion)+\(build)", "dist": build,
            "user": ["id": installationID.uuidString.lowercased()],
            "exception": ["values": [exception]],
        ]
        if let systemVersion { event["contexts"] = ["os": ["name": platform, "version": systemVersion]] }
        var imageAddresses = Set<UInt64>()
        let images = frames.filter { imageAddresses.insert($0.base).inserted }.map { frame in
            var image: [String: Any] = ["type": "macho", "debug_id": frame.binaryID.uuidString.lowercased(),
                "image_addr": Self.hex(frame.base), "code_file": executable]
            if let size = frame.imageSize { image["image_size"] = size }
            return image
        }
        if !images.isEmpty { event["debug_meta"] = ["images": images] }
        let canonical = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        // Keep the same Sentry event ID when the OS delivers the same report again.
        var idBytes = Array(SHA256.hash(data: canonical).prefix(16))
        idBytes[6] = (idBytes[6] & 0x0f) | 0x40
        idBytes[8] = (idBytes[8] & 0x3f) | 0x80
        let id = idBytes.map { String(format: "%02x", $0) }.joined()
        event["event_id"] = id
        let payload = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let header = try JSONSerialization.data(withJSONObject: ["event_id": id])
        let item = try JSONSerialization.data(withJSONObject: ["type": "event", "length": payload.count])
        let newline = Data([10])
        return Envelope(id: id, body: header + newline + item + newline + payload)
    }

    private static func hex(_ address: UInt64) -> String { "0x" + String(address, radix: 16) }

    private static let signalNames = [
        Int(SIGABRT): "SIGABRT", Int(SIGBUS): "SIGBUS", Int(SIGFPE): "SIGFPE",
        Int(SIGILL): "SIGILL", Int(SIGKILL): "SIGKILL", Int(SIGSEGV): "SIGSEGV", Int(SIGTRAP): "SIGTRAP",
    ]

    private struct CallStackTree: Decodable {
        let callStacks: [Stack]
    }

    private struct Stack: Decodable {
        let threadAttributed: Bool?
        let callStackRootFrames: [Frame]
    }

    private struct Frame: Decodable {
        let binaryName: String?
        let binaryUUID: UUID?
        let address: UInt64?
        let offsetIntoBinaryTextSegment: UInt64?
        let subFrames: [Frame]?
    }

    private static func appFrames(in data: Data, executable: String) -> [StackFrame] {
        guard data.count <= 2_000_000, let tree = try? JSONDecoder().decode(CallStackTree.self, from: data),
              let crashingThread = tree.callStacks.first(where: { $0.threadAttributed == true }) else { return [] }
        var stack = crashingThread.callStackRootFrames
        var frames: [StackFrame] = []
        while let frame = stack.first, frames.count < 100 {
            if frame.binaryName?.split(separator: "/").last == Substring(executable),
               let binaryID = frame.binaryUUID, let address = frame.address,
               let offset = frame.offsetIntoBinaryTextSegment, offset < address {
                frames.append(.init(binaryID: binaryID, address: address, base: address - offset))
            }
            if let children = frame.subFrames, !children.isEmpty {
                stack = children
            } else {
                stack.removeFirst()
            }
        }
        return frames
    }
}

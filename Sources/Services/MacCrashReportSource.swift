import Foundation

struct MacCrashReportSource: Sendable {
    let executable: String
    let bundleIdentifier: String

    private static let reportSizeLimit = 2_000_000

    func recentReports(in directory: URL, startingAt start: Date) -> [CrashReport] {
        guard !executable.isEmpty, !bundleIdentifier.isEmpty else { return [] }
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(properties), options: [.skipsHiddenFiles]) else { return [] }

        let candidates: [(url: URL, modified: Date)] = urls.compactMap { url in
            guard url.pathExtension == "ips", url.lastPathComponent.hasPrefix(executable + "-"),
                  let values = try? url.resourceValues(forKeys: properties), values.isRegularFile == true,
                  values.isSymbolicLink == false, let modified = values.contentModificationDate,
                  modified >= start else { return nil }
            return (url, modified)
        }
        var reports: [CrashReport] = []
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }).prefix(30) {
            guard !Task.isCancelled else { break }
            if let data = read(candidate.url), let report = report(in: data, startingAt: start) {
                reports.append(report)
            }
        }
        return reports
    }

    func report(in data: Data, startingAt start: Date) -> CrashReport? {
        guard data.count <= Self.reportSizeLimit, let lineEnd = data.firstIndex(of: 10) else { return nil }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data[..<lineEnd]),
              header.bugType == "309", header.bundleID == bundleIdentifier,
              let details = try? decoder.decode(Details.self, from: data[data.index(after: lineEnd)...]),
              details.procName == executable, details.bundleInfo["CFBundleIdentifier"] == bundleIdentifier,
              let timestamp = Self.date(details.captureTime), timestamp >= start else { return nil }
        let thread = details.faultingThread.flatMap { index in
            details.threads.indices.contains(index) ? details.threads[index] : nil
        } ?? details.threads.first { $0.triggered == true }
        let frames: [CrashReport.StackFrame] = (thread?.frames ?? []).prefix(200).compactMap { frame in
            guard let index = frame.imageIndex, let offset = frame.imageOffset,
                  details.usedImages.indices.contains(index) else { return nil }
            let image = details.usedImages[index]
            guard image.name == executable, let binaryID = image.uuid,
                  header.sliceUUID.map({ $0 == binaryID }) ?? (image.path == details.procPath),
                  let base = image.base, let size = image.size,
                  offset < size else { return nil }
            let (address, overflow) = base.addingReportingOverflow(offset)
            guard !overflow else { return nil }
            return .init(binaryID: binaryID, address: address, base: base, imageSize: size)
        }
        return CrashReport(timestamp: timestamp, applicationVersion: header.appVersion, build: header.buildVersion,
            systemVersion: header.osVersion, signal: details.exception?.signal, executable: executable, frames: frames)
    }

    private func read(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.reportSizeLimit else { return nil }
        return try? handle.read(upToCount: Self.reportSizeLimit + 1)
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return formatter.date(from: raw)
    }

    private struct Header: Decodable {
        let bugType: String
        let bundleID: String
        let appVersion: String
        let buildVersion: String
        let osVersion: String
        let sliceUUID: UUID?

        enum CodingKeys: String, CodingKey {
            case bugType = "bug_type"
            case bundleID
            case appVersion = "app_version"
            case buildVersion = "build_version"
            case osVersion = "os_version"
            case sliceUUID = "slice_uuid"
        }
    }

    private struct Details: Decodable {
        let captureTime: String
        let procName: String
        let procPath: String
        let bundleInfo: [String: String]
        let faultingThread: Int?
        let exception: Exception?
        let threads: [Thread]
        let usedImages: [Image]

        struct Exception: Decodable { let signal: String? }
        struct Thread: Decodable {
            let triggered: Bool?
            let frames: [Frame]
        }
        struct Frame: Decodable {
            let imageIndex: Int?
            let imageOffset: UInt64?
        }
        struct Image: Decodable {
            let name: String?
            let path: String?
            let uuid: UUID?
            let base: UInt64?
            let size: UInt64?
        }
    }
}

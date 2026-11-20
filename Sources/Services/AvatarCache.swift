import AppKit
import CryptoKit
import Foundation
import ImageIO
import MergeTetherRemote
import UniformTypeIdentifiers

actor AvatarCache {
    private var memoryCache: [URL: NSImage] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let diskDirectory: URL
    private let session: URLSession

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskDirectory = caches.appendingPathComponent("com.vaporpw.MergeTether/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    func image(for url: URL) async -> NSImage? {
        if let memory = memoryCache[url] { return memory }

        let diskPath = diskPath(for: url)
        if let data = try? Data(contentsOf: diskPath), let image = NSImage(data: data) {
            memoryCache[url] = image
            return image
        }

        if let existing = inflight[url] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [session, diskPath] in
            do {
                let (data, _) = try await session.data(from: url)
                try? data.write(to: diskPath, options: .atomic)
                return NSImage(data: data)
            } catch {
                Log.avatars.debug("Avatar fetch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            memoryCache[url] = image
        }
        return image
    }

    private func diskPath(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent("\(hex).img")
    }
}

/// Reads only anonymous image responses. The host selects URLs from its own GitLab board.
final class RemoteAvatarLoader: NSObject, URLSessionTaskDelegate {
    static let shared = RemoteAvatarLoader()
    private let session: URLSession

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
        super.init()
    }

    func thumbnail(for url: URL) async -> Data? {
        guard let (file, response) = try? await session.download(from: url, delegate: self) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 72
              ] as CFDictionary) else { return nil }
        for quality in [0.8, 0.5, 0.3] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), bytes.length <= RemoteAvatarThumbnail.maximumBytes {
                return bytes as Data
            }
        }
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // Never turn a GitLab avatar into a request to another endpoint on the Mac's network.
        nil
    }
}

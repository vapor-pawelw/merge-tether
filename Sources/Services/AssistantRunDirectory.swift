import Darwin
import Foundation

/// Destructive operations are relative to opened directories and never follow links.
final class AssistantRunDirectory {
    struct Entry {
        fileprivate let stat: Darwin.stat
        var isDirectory: Bool { stat.st_mode & S_IFMT == S_IFDIR }
        var isFile: Bool { stat.st_mode & S_IFMT == S_IFREG }
        var isLink: Bool { stat.st_mode & S_IFMT == S_IFLNK }
        var isOwned: Bool { stat.st_uid == geteuid() }
        var bytes: Int64 { stat.st_size }
        var modified: Date { Date(timeIntervalSince1970: Double(stat.st_mtimespec.tv_sec)) }

        func matches(_ other: Entry) -> Bool {
            stat.st_dev == other.stat.st_dev && stat.st_ino == other.stat.st_ino
        }
    }

    let path: String
    private let descriptor: Int32
    private let identity: Entry
    private let parent: AssistantRunDirectory?
    private let name: String

    private init?(descriptor: Int32, path: String, parent: AssistantRunDirectory? = nil, name: String = "") {
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { close(descriptor); return nil }
        self.descriptor = descriptor
        self.path = path
        self.parent = parent
        self.name = name
        identity = Entry(stat: info)
    }

    deinit { close(descriptor) }

    static func open(_ path: String) -> AssistantRunDirectory? {
        guard path.first == "/", var directory = AssistantRunDirectory(
            descriptor: Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), path: "") else { return nil }
        for part in path.split(separator: "/") {
            guard let child = directory.child(String(part), requireOwnership: false) else { return nil }
            directory = child
        }
        return directory.identity.isOwned ? directory : nil
    }

    func entry(_ name: String) -> Entry? {
        guard Self.isComponent(name) else { return nil }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Entry(stat: info)
    }

    func child(_ name: String, requireOwnership: Bool = true) -> AssistantRunDirectory? {
        guard Self.isComponent(name), let child = AssistantRunDirectory(
            descriptor: openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
            path: path + "/" + name, parent: self, name: name) else { return nil }
        guard !requireOwnership || (child.identity.isOwned && child.identity.stat.st_dev == identity.stat.st_dev) else { return nil }
        return child
    }

    var isCurrent: Bool {
        guard let parent else { return true }
        return parent.isCurrent && parent.entry(name).map(identity.matches) == true
    }

    func names() -> [String]? {
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? result : nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard let name else { return nil }
            if name != "." && name != ".." { result.append(name) }
        }
    }

    func openFile(_ name: String, matching expected: Entry, writable: Bool = false) -> FileHandle? {
        guard expected.isFile, expected.isOwned, (!writable || expected.stat.st_nlink == 1), isCurrent else { return nil }
        let file = openat(descriptor, name, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        var info = stat()
        guard fstat(file, &info) == 0, expected.matches(Entry(stat: info)),
              !writable || info.st_nlink == 1 else { close(file); return nil }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }

    func read(_ name: String, limit: Int = 16_384) -> Data? {
        guard let entry = entry(name), entry.bytes <= limit, let handle = openFile(name, matching: entry) else { return nil }
        let content = (try? handle.read(upToCount: limit + 1)) ?? Data()
        return content.count <= limit ? content : nil
    }

    @discardableResult
    func unlink(_ name: String, matching expected: Entry) -> Bool {
        guard expected.isOwned, expected.stat.st_dev == identity.stat.st_dev, isCurrent,
              entry(name).map(expected.matches) == true else { return false }
        return unlinkat(descriptor, name, expected.isDirectory ? AT_REMOVEDIR : 0) == 0
    }

    func removeIfEmpty() {
        parent?.unlink(name, matching: identity)
    }

    /// A failed unlink leaves the remaining tree available for a later inspection.
    func removeContents() -> Bool {
        guard isCurrent, let names = names() else { return false }
        for name in names {
            guard let entry = entry(name) else { return false }
            if entry.isDirectory {
                guard let child = child(name), child.removeContents() else { return false }
            } else if !entry.isFile && !entry.isLink {
                return false
            }
            guard unlink(name, matching: entry) else { return false }
        }
        return true
    }

    private static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

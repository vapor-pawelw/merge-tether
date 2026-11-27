import Foundation

/// Locally inspects Git repositories inside a single run. Git never contacts a remote.
struct AssistantRunRepository {
    let directory: AssistantRunDirectory
    let metadata: AssistantRunDirectory
    let worktrees: [AssistantRunDirectory]

    private var checkouts: [AssistantRunDirectory] {
        directory === metadata ? worktrees : [directory] + worktrees
    }

    static func isBareWithWorktrees(_ directory: AssistantRunDirectory) -> Bool {
        directory.entry("HEAD")?.isFile == true && directory.entry("config")?.isFile == true
            && directory.entry("objects")?.isDirectory == true && directory.entry("worktrees")?.isDirectory == true
    }

    static func inspect(_ directory: AssistantRunDirectory, in run: AssistantRunDirectory) async -> Self? {
        let bare = directory.entry(".git") == nil && isBareWithWorktrees(directory)
        guard let metadata = bare ? directory : directory.child(".git"), metadata.isCurrent,
              metadataTreeIsLocal(metadata, depth: 0),
              metadata.child("info")?.entry("grafts") == nil,
              metadata.child("objects")?.child("info")?.entry("alternates") == nil,
              metadata.child("objects")?.child("info")?.entry("http-alternates") == nil,
              let config = metadata.read("config"),
              let configuration = await git(["config", "--file", "-", "--no-includes", "--null", "--list"], in: directory, input: config),
              configuration.exitCode == 0, supportedConfig(configuration.stdout, bare: bare),
              let worktrees = registeredWorktrees(metadata: metadata, in: run),
              !bare || !worktrees.isEmpty,
              let known = await git(["worktree", "list", "--porcelain", "-z"], in: directory), known.exitCode == 0 else { return nil }
        let paths = records(known.stdout).compactMap { record in
            record.hasPrefix("worktree ") ? String(record.dropFirst("worktree ".count)) : nil
        }
        let expected = [directory.path] + worktrees.map(\.path)
        guard paths.count == expected.count, Set(paths) == Set(expected) else { return nil }
        return Self(directory: directory, metadata: metadata, worktrees: worktrees)
    }

    func reclaimGeneratedFiles(authorize: @MainActor @Sendable () -> Bool) async {
        for checkout in checkouts {
            guard let tracked = await Self.git(["ls-files", "-z"], in: checkout), tracked.exitCode == 0 else { continue }
            for path in Set(Self.records(tracked.stdout)) where path == "pom.xml" || path.hasSuffix("/pom.xml") {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard let project = parts.dropLast().reduce(checkout as AssistantRunDirectory?, { $0?.child($1) }),
                      project.entry("pom.xml")?.isFile == true, let target = project.child("target"),
                      target.entry(".git") == nil else { continue }
                let relative = (parts.dropLast() + ["target"]).joined(separator: "/")
                let ignorePath = "./" + relative
                guard let ignored = await Self.git(["check-ignore", "-z", "--stdin"], in: checkout, input: Data((ignorePath + "\0").utf8)),
                      ignored.exitCode == 0, Self.records(ignored.stdout) == [ignorePath],
                      let paths = await Self.git(["ls-files", "-z", "--", relative], in: checkout), paths.exitCode == 0, paths.stdout.isEmpty,
                      await authorize() else { continue }
                for name in ["classes", "test-classes"] {
                    if let classes = target.child(name) { Self.reclaimClassFiles(classes, depth: 0) }
                }
                target.removeIfEmpty()
            }
        }
    }

    func reclaimIfReproducible(anchors: [String], authorize: @MainActor @Sendable () -> Bool) async {
        guard metadata.isCurrent, Self.hasOnlyRepositoryMetadata(metadata) else { return }
        var known: [String] = []
        for sha in Set(anchors) {
            guard let type = await Self.git(["cat-file", "-t", sha], in: directory), type.exitCode == 0,
                  type.stdout == Data("commit\n".utf8) else { continue }
            known.append(sha)
        }
        guard !known.isEmpty else { return }
        for checkout in checkouts {
            guard await Self.isClean(checkout) else { return }
        }
        // Explicit roots exclude remote-tracking refs and reflogs as proof of delivery.
        // Even dangling objects can be the only remaining copy of a reset edit or commit.
        guard let objects = await Self.git(["fsck", "--full", "--unreachable", "--no-reflogs", "--no-progress"] + known, in: directory),
              objects.exitCode == 0, objects.stdout.isEmpty, objects.stderr.isEmpty, await authorize() else { return }
        for worktree in worktrees {
            guard worktree.isCurrent, await authorize(),
                  let result = await Self.git(["worktree", "remove", "--", worktree.path], in: directory), result.exitCode == 0 else { return }
        }
        guard await authorize(), metadata.isCurrent, directory.removeContents() else { return }
        directory.removeIfEmpty()
    }

    private static func isClean(_ checkout: AssistantRunDirectory) async -> Bool {
        guard let index = await git(["ls-files", "--stage", "-v", "-z"], in: checkout), index.exitCode == 0,
              records(index.stdout).allSatisfy({ $0.hasPrefix("H ") && !$0.hasPrefix("H 160000 ") }),
              let result = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--no-renames"], in: checkout)
        else { return false }
        return result.exitCode == 0 && result.stdout.isEmpty && result.stderr.isEmpty
    }

    private static func registeredWorktrees(metadata: AssistantRunDirectory, in run: AssistantRunDirectory) -> [AssistantRunDirectory]? {
        guard metadata.entry("worktrees") != nil else { return [] }
        guard let registrations = metadata.child("worktrees"), let names = registrations.names() else { return nil }
        var worktrees: [AssistantRunDirectory] = []
        for name in names {
            guard let registration = registrations.child(name), registration.entry("locked") == nil,
                  registration.read("commondir") == Data("../..\n".utf8),
                  let gitPath = registration.read("gitdir").flatMap({ String(data: $0, encoding: .utf8) }),
                  gitPath.hasPrefix(run.path + "/"), gitPath.hasSuffix("/.git\n") else { return nil }
            let path = gitPath.dropFirst(run.path.count + 1).dropLast("/.git\n".count)
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ AssistantRunReclamation.isWorkspaceDirectoryName(String($0)) }),
                  let worktree = parts.reduce(run as AssistantRunDirectory?, { $0?.child(String($1)) }),
                  worktree.read(".git") == Data("gitdir: \(registration.path)\n".utf8) else { return nil }
            worktrees.append(worktree)
        }
        return worktrees
    }

    private static func hasOnlyRepositoryMetadata(_ metadata: AssistantRunDirectory) -> Bool {
        let checkoutMetadata: Set<String> = ["HEAD", "index", "logs", "ORIG_HEAD", "FETCH_HEAD", "COMMIT_EDITMSG"]
        let cloneMetadata = checkoutMetadata.union(["branches", "config", "description", "hooks", "info", "objects", "packed-refs", "refs", "shallow", "worktrees"])
        guard let names = metadata.names(), Set(names).isSubset(of: cloneMetadata) else { return false }
        if let hooks = metadata.child("hooks"), hooks.names()?.allSatisfy({ $0.hasSuffix(".sample") }) != true { return false }
        guard let registrations = metadata.child("worktrees") else { return true }
        let worktreeMetadata = checkoutMetadata.union(["commondir", "gitdir", "refs"])
        guard let linked = registrations.names() else { return false }
        return linked.allSatisfy {
            guard let registration = registrations.child($0), let entries = registration.names() else { return false }
            if let refs = registration.child("refs"), refs.names()?.isEmpty != true { return false }
            return Set(entries).isSubset(of: worktreeMetadata)
        }
    }

    private static func metadataTreeIsLocal(_ directory: AssistantRunDirectory, depth: Int) -> Bool {
        guard depth < 16, let names = directory.names() else { return false }
        for name in names {
            guard let entry = directory.entry(name), entry.isOwned,
                  !name.hasSuffix(".lock"), !name.hasSuffix(".promisor") else { return false }
            if entry.isDirectory {
                guard let child = directory.child(name), metadataTreeIsLocal(child, depth: depth + 1) else { return false }
            } else if !entry.isFile { return false }
        }
        return true
    }

    private static func supportedConfig(_ bytes: Data, bare: Bool) -> Bool {
        let coreKeys: Set<String> = ["core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates",
            "core.ignorecase", "core.precomposeunicode", "core.symlinks", "core.autocrlf", "core.eol"]
        let entries = records(bytes)
        if bare, entries.filter({ $0 == "core.bare" || $0.hasPrefix("core.bare\n") }) != ["core.bare\ntrue"] { return false }
        return entries.allSatisfy { record in
            let key = record.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return coreKeys.contains(key) || key.hasPrefix("user.") || key.hasPrefix("branch.")
                || (key.hasPrefix("remote.") && (key.hasSuffix(".url") || key.hasSuffix(".fetch") || key.hasSuffix(".tagopt")))
        }
    }

    private static func reclaimClassFiles(_ directory: AssistantRunDirectory, depth: Int) {
        guard depth < 32, directory.entry(".git") == nil, let names = directory.names() else { return }
        for name in names where !name.hasPrefix(".") {
            if let child = directory.child(name) {
                reclaimClassFiles(child, depth: depth + 1)
            } else if name.hasSuffix(".class"), let entry = directory.entry(name),
                      let handle = directory.openFile(name, matching: entry),
                      let header = try? handle.read(upToCount: 8), isJavaClassHeader(header) {
                directory.unlink(name, matching: entry)
            }
        }
        directory.removeIfEmpty()
    }

    private static func isJavaClassHeader(_ bytes: Data) -> Bool {
        guard bytes.count == 8, bytes.prefix(4) == Data([0xca, 0xfe, 0xba, 0xbe]) else { return false }
        let version = Int(bytes[6]) * 256 + Int(bytes[7])
        return (45...100).contains(version)
    }

    private static func records(_ bytes: Data) -> [String] {
        String(decoding: bytes, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private static func git(_ arguments: [String], in directory: AssistantRunDirectory,
                            input: Data? = nil) async -> ProcessRunner.Output? {
        guard directory.isCurrent, !Task.isCancelled else { return nil }
        let pathspec = arguments.first == "ls-files" ? ["--literal-pathspecs"] : []
        return try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"),
            arguments: pathspec + ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                        "-c", "core.attributesFile=/dev/null", "-c", "core.commitGraph=false"] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                          "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
                          "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0"],
            currentDirectory: URL(fileURLWithPath: directory.path, isDirectory: true), timeout: 12, input: input)
    }
}

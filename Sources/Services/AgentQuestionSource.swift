import Foundation

/// The app retrieves public source. The agent receives selected excerpts as data.
struct AgentQuestionSource: Sendable {
    static let repository = "vapor-pawelw/merge-tether"

    struct Evidence: Encodable, Sendable {
        struct File: Encodable, Sendable {
            let path: String
            let url: URL
            let excerpt: String
        }

        let installedVersion: String
        let ref: String?
        let mainFallback: Bool
        let files: [File]

        var notice: Notice? {
            if files.isEmpty { return .unavailable }
            return mainFallback ? .mainFallback : nil
        }
    }

    enum Notice: String, Codable, Sendable { case mainFallback, unavailable }

    struct Build: Sendable {
        let version: String
        let released: Bool

        static var installed: Self {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            #if DEBUG
            return .init(version: version, released: false)
            #else
            return .init(version: version, released: true)
            #endif
        }

        var refs: [String] {
            guard released, version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?$"#,
                                         options: .regularExpression) != nil else { return ["main"] }
            return ["v" + version, version, "main"]
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Data
    let fetch: Fetch

    init(fetch: @escaping Fetch = Self.publicData) { self.fetch = fetch }

    func evidence(for terms: [String], build: Build) async throws -> Evidence {
        guard let revision = try await resolve(build) else {
            return .init(installedVersion: build.version, ref: nil, mainFallback: false, files: [])
        }
        let files = try await excerpts(commit: revision.sha, terms: terms)
        return .init(installedVersion: build.version, ref: revision.ref, mainFallback: revision.ref == "main", files: files)
    }

    enum HelpMatch { case controlNames, topics }

    static func installedHelp(for terms: [String], matching: HelpMatch = .controlNames, bundle: Bundle = .main) -> [String] {
        guard !terms.isEmpty, let url = bundle.url(forResource: "automation", withExtension: "md"),
              let documentation = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return installedHelp(for: terms, matching: matching, documentation: documentation)
    }

    static func installedHelp(for terms: [String], matching: HelpMatch = .controlNames,
                              documentation: String) -> [String] {
        let boundedTerms = terms.prefix(5).map { String($0.prefix(AgentQuestionInput.maximumLength)) }
        let queries = boundedTerms.map { " " + helpSearchKey($0) + " " }
        let topics = words(boundedTerms.joined(separator: " "))
            .subtracting(["merge", "request", "button", "gitlab", "what", "does", "with", "when", "this"])
        let keywords = matching == .topics ? Set(topics.map { String($0.prefix(6)) }) : []
        let paragraphs = documentation.components(separatedBy: "\n\n")
        let matches = paragraphs.enumerated().compactMap { index, paragraph -> (index: Int, score: Int)? in
            let labels = paragraph.matches(of: /\*\*([^*\n]+)\*\*/).map { helpSearchKey(String($0.1)) }
            let labelScore = labels.filter { label in
                label.contains(" ") && queries.contains { $0.contains(" " + label + " ") }
            }.map(\.count).max()
            if let labelScore { return (index, 100 + labelScore) }
            guard !keywords.isEmpty else { return nil }
            let terms = Set(words(paragraph).map { String($0.prefix(6)) })
            let score = terms.intersection(keywords).count
            guard score >= min(2, keywords.count) else { return nil }
            let labelTerms = Set(words(labels.joined(separator: " ")).map { String($0.prefix(6)) })
            return (index, score + 4 * labelTerms.intersection(keywords).count)
        }
        return matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }.prefix(3).map { String(paragraphs[$0.index].prefix(1_600)) }
    }

    private static func helpSearchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private struct GitObject: Decodable {
        let sha: String
        let type: String?
    }

    private struct GitReference: Decodable { let object: GitObject }

    private func resolve(_ build: Build) async throws -> (ref: String, sha: String)? {
        for ref in build.refs {
            try Task.checkCancellation()
            do {
                if ref == "main" {
                    let commit: GitObject = try await api("commits/main")
                    if Self.isCommitHash(commit.sha) { return (ref, commit.sha) }
                } else if let sha = try await taggedCommit(ref) {
                    return (ref, sha)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        try Task.checkCancellation()
        return nil
    }

    private func taggedCommit(_ ref: String) async throws -> String? {
        let reference: GitReference = try await api("git/ref/tags/" + ref)
        var object = reference.object
        for _ in 0..<3 where Self.isCommitHash(object.sha) {
            if object.type == "commit" { return object.sha }
            guard object.type == "tag" else { return nil }
            let annotated: GitReference = try await api("git/tags/" + object.sha)
            object = annotated.object
        }
        return nil
    }

    private func api<Value: Decodable>(_ path: String) async throws -> Value {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!
        return try JSONDecoder().decode(Value.self, from: await fetch(url))
    }

    private static func isCommitHash(_ sha: String) -> Bool {
        sha.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }

    private func excerpts(commit: String, terms: [String]) async throws -> [Evidence.File] {
        struct Tree: Decodable {
            struct Entry: Decodable { let path: String; let type: String; let size: Int? }
            let tree: [Entry]
        }
        let treeURL = URL(string: "https://api.github.com/repos/\(Self.repository)/git/trees/\(commit)?recursive=1")!
        let candidates: [String]
        do {
            let tree = try JSONDecoder().decode(Tree.self, from: await fetch(treeURL))
            candidates = tree.tree.filter { $0.type == "blob" && ($0.size ?? Int.max) <= 320_000 }
                .map(\.path).filter(Self.isSourcePath)
        } catch is CancellationError { throw CancellationError() }
        catch { return [] }
        let ranked = Self.rank(candidates, terms: terms)
        let selected = Array(ranked.prefix(5))
        return try await withThrowingTaskGroup(of: (Int, Evidence.File?).self) { group in
            for (index, path) in selected.enumerated() {
                group.addTask {
                    let raw = URL(string: "https://raw.githubusercontent.com/\(Self.repository)/\(commit)/\(path)")!
                    let link = URL(string: "https://github.com/\(Self.repository)/blob/\(commit)/\(path)")!
                    do {
                        let data = try await fetch(raw)
                        try Task.checkCancellation()
                        guard data.count <= 320_000, let text = String(data: data, encoding: .utf8) else { return (index, nil) }
                        return (index, .init(path: path, url: link, excerpt: Self.excerpt(text, terms: terms)))
                    } catch is CancellationError { throw CancellationError() }
                    catch { return (index, nil) }
                }
            }
            var received: [(Int, Evidence.File)] = []
            for try await (index, file) in group { if let file { received.append((index, file)) } }
            return received.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func isEvidenceLink(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 5, parts.prefix(3).joined(separator: "/") == repository + "/blob",
              isCommitHash(String(parts[3])) else { return false }
        return isSourcePath(parts.dropFirst(4).joined(separator: "/"))
    }

    static func isSourcePath(_ path: String) -> Bool {
        guard path.count <= 240, path.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains($0) }) else { return false }
        return path == "README.md" || (path.hasPrefix("docs/") && path.hasSuffix(".md"))
            || (path.hasPrefix("Helpers/Automation/") && path.hasSuffix(".py"))
            || (["Sources/", "iOS/", "Tests/"].contains { path.hasPrefix($0) } && path.hasSuffix(".swift"))
    }

    static func rank(_ paths: [String], terms: [String]) -> [String] {
        let keywords = words(terms.prefix(5).map { String($0.prefix(80)) }.joined(separator: " "))
        let ranked = paths.compactMap { path -> (String, Int)? in
            let name = String(path.split(separator: "/").last ?? "").lowercased()
            let score = keywords.reduce(0) { $0 + (name.contains($1) ? $1.count : 0) }
            let general = path == "docs/automation.md" || path == "README.md"
            let weight = score * (path.hasPrefix("Tests/") ? 1 : 2)
            return general || score > 0 ? (path, weight + (general ? 1 : 0)) : nil
        }
        let ordered = ranked.sorted { left, right in left.1 == right.1 ? left.0 < right.0 : left.1 > right.1 }
        // Reserve a place for the product rules even when Swift file names match better.
        let rules = "docs/automation.md"
        return Array(ordered.map(\.0).filter { $0 != rules }.prefix(4)) + (paths.contains(rules) ? [rules] : [])
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 4 && !["docs", "swift", "sources", "mergetether"].contains($0) }.map(String.init))
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        if text.count <= 14_000 { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let keywords = words(terms.prefix(5).map { String($0.prefix(80)) }.joined(separator: " "))
        let matches = lines.enumerated().compactMap { index, content -> (index: Int, score: Int)? in
            let line = content.lowercased()
            let score = keywords.filter { line.contains($0) }.reduce(0) { $0 + $1.count }
            return score > 0 ? (index, score) : nil
        }
        let scored = matches.sorted {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }
        var selected = Set(lines.indices.prefix(35))
        for (index, _) in scored.prefix(18) {
            selected.formUnion(max(0, index - 4)...min(index + 9, lines.count - 1))
        }
        return String(selected.sorted().map { "\($0 + 1): \(lines[$0])" }.joined(separator: "\n").prefix(14_000))
    }

    static func publicData(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("MergeTether Agent Question", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == url.host, data.count <= 4_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
}

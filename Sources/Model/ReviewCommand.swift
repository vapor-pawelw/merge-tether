import Foundation

/// The worker-facing vocabulary. It contains neither provider credentials nor write operations.
enum ReviewCommand: Equatable, Sendable {
    case help, context, diff, discussions
    case file(String)
    case workItem(project: String?, number: Int)
    case change(project: String?, number: Int)

    enum Error: Swift.Error, Equatable { case invalidArguments }

    static let helpText = """
        mergetether context
        mergetether diff
        mergetether discussions
        mergetether file show <repository-relative path>
        mergetether work-item show <number or project/path#number>
        mergetether change show <number or project/path#number>
        mergetether --help
        """

    init(arguments: [String]) throws {
        switch arguments {
        case ["--help"], ["help"]: self = .help
        case ["context"]: self = .context
        case ["diff"]: self = .diff
        case ["discussions"]: self = .discussions
        default:
            guard arguments.count == 3, arguments[1] == "show" else { throw Error.invalidArguments }
            let reference = arguments[2]
            switch arguments[0] {
            case "file":
                guard Self.validPath(reference) else { throw Error.invalidArguments }
                self = .file(reference)
            case "work-item", "change":
                let parts = reference.split(separator: "#", omittingEmptySubsequences: false)
                guard parts.count == 1 || parts.count == 2,
                      let suffix = parts.last, let number = Int(suffix), number > 0,
                      String(number) == suffix else { throw Error.invalidArguments }
                let project = parts.count == 2 ? String(parts[0]) : nil
                if let project, !Self.validPath(project) || !project.contains("/") ||
                    !project.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._/".unicodeScalars.contains($0)) }) {
                    throw Error.invalidArguments
                }
                self = arguments[0] == "work-item" ? .workItem(project: project, number: number)
                    : .change(project: project, number: number)
            default: throw Error.invalidArguments
            }
        }
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

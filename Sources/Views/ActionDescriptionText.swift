import SwiftUI

struct ActionDescriptionText: View {
    let todo: Todo
    let currentUsername: String?
    var repositoryPath: String? = nil

    var body: some View {
        let description = viewerText.map { Text(verbatim: $0) } ?? composedText
        if let repositoryPath, let repositoryName = repositoryPath.split(separator: "/").last {
            let repository = Text(verbatim: String(repositoryName)).font(.caption).foregroundStyle(Color.accentColor)
            description + Text(verbatim: "  ") + repository
        } else {
            description
        }
    }

    private var isSelf: Bool {
        guard let currentUsername else { return false }
        return todo.author.username == currentUsername
    }

    private var viewerText: String? {
        if isSelf {
            return Self.localized(todo.actionName.selfLocalizationKey)
        }
        if !todo.actionName.takesAuthorSlot {
            return Self.localized(todo.actionName.localizationKey)
        }
        return nil
    }

    /// Author name in bold followed by the action verb. Splits the localized
    /// format string around "%@" so translations can keep the slot anywhere.
    private var composedText: Text {
        let format = Self.localized(todo.actionName.localizationKey)
        let parts = format.components(separatedBy: "%@")
        guard parts.count >= 2 else {
            return Text(todo.author.name).bold() + Text(" ") + Text(format)
        }
        let prefix = Text(parts[0])
        let author = Text(todo.author.name).bold()
        let suffix = Text(parts.dropFirst().joined(separator: "%@"))
        return prefix + author + suffix
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Actions", bundle: .main, value: key, comment: "")
    }
}

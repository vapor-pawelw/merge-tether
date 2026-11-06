import Foundation

enum CommandCenterSearch {
    static func matches(_ query: String, title: String, repository: String, iid: Int) -> Bool {
        let text = "\(title) \(repository) !\(iid)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

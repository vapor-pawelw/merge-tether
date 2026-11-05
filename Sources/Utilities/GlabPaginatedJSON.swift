import Foundation

enum GlabPaginatedJSON {
    static func decode<Item: Decodable>(
        _ type: Item.Type,
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [Item] {
        if let singlePage = try? decoder.decode([Item].self, from: data) {
            return singlePage
        }

        // glab can print one JSON array per response page. Scan array
        // boundaries outside strings, then decode each complete page normally.
        var items: [Item] = []
        var pageStart: Data.Index?
        var foundPage = false
        var depth = 0
        var inString = false
        var escaped = false

        for index in data.indices {
            let byte = data[index]
            guard let start = pageStart else {
                switch byte {
                case UInt8(ascii: "["):
                    pageStart = index
                    depth = 1
                case 0x20, 0x09, 0x0A, 0x0D:
                    continue
                default:
                    throw invalidPageStream
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    items.append(contentsOf: try decoder.decode([Item].self, from: data[start...index]))
                    pageStart = nil
                    foundPage = true
                }
            default:
                break
            }
        }

        guard foundPage, pageStart == nil else { throw invalidPageStream }
        return items
    }

    private static var invalidPageStream: DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Expected complete JSON array pages from glab"))
    }
}

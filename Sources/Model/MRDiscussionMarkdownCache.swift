import Foundation
import MergeTetherRemote

@MainActor
final class MRDiscussionMarkdownCache {
    private struct Entry { let rendered: AttributedString? }
    private let capacity: Int
    private let maximumSourceBytes: Int
    private let renderSource: (String) -> AttributedString?
    private var entries: [Data: Entry] = [:]
    private var accessOrder: [Data] = []
    private var retainedSourceBytes = 0

    init(capacity: Int = 128, maximumSourceBytes: Int = 2_097_152,
         render: @escaping (String) -> AttributedString? = SafeInlineMarkdown.render) {
        self.capacity = max(0, capacity)
        self.maximumSourceBytes = max(0, maximumSourceBytes)
        renderSource = render
    }

    func render(_ source: String) -> AttributedString? {
        // Swift String equality normalizes Unicode; comments must retain their exact source text.
        let key = Data(source.utf8)
        if let entry = entries[key] {
            accessOrder.removeAll { $0 == key }
            accessOrder.append(key)
            return entry.rendered
        }
        let rendered = renderSource(source)
        guard capacity > 0, maximumSourceBytes > 0, key.count <= maximumSourceBytes else { return rendered }
        while entries.count >= capacity || retainedSourceBytes + key.count > maximumSourceBytes {
            let oldest = accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
            retainedSourceBytes -= oldest.count
        }
        entries[key] = Entry(rendered: rendered)
        accessOrder.append(key)
        retainedSourceBytes += key.count
        return rendered
    }
}

import Foundation

struct MergeRequestStackSnapshot: Sendable {
    let requests: [GitLabMergeRequest]
    let defaultBranch: String
    let openIIDs: Set<Int>
    let positions: [Int: String]

    init(requests: [GitLabMergeRequest], defaultBranch: String) {
        self.requests = requests
        self.defaultBranch = defaultBranch
        let open = requests.filter { $0.state == "opened" }
        openIIDs = Set(open.map(\.iid))
        let byBranch = Dictionary(grouping: open, by: \.sourceBranch)
        var parents: [Int: [Int]] = [:]
        var children: [Int: [Int]] = [:]

        for child in open where child.targetBranch != defaultBranch {
            guard let project = child.targetProjectID else { continue }
            let matches = (byBranch[child.targetBranch] ?? []).filter { parent in
                parent.iid != child.iid && parent.author.id == child.author.id
                    && parent.sourceProjectID == project && parent.targetProjectID == project
                    && parent.sourceBranch != parent.targetBranch
            }
            parents[child.iid] = matches.map(\.iid)
            for parent in matches {
                children[parent.iid, default: []].append(child.iid)
            }
        }

        var positions: [Int: String] = [:]
        for root in openIIDs where parents[root, default: []].isEmpty {
            var nodes = [(iid: root, depth: 1)]
            var index = 0
            while index < nodes.count {
                let node = nodes[index]
                let next = children[node.iid, default: []]
                guard next.allSatisfy({ parents[$0]?.count == 1 }) else { break }
                nodes.append(contentsOf: next.map { (iid: $0, depth: node.depth + 1) })
                index += 1
            }
            guard index == nodes.count, nodes.count > 1 else { continue }
            // Siblings are at the same depth. Count the longest path through each MR.
            var pathEnds: [Int: Int] = [:]
            for node in nodes.reversed() {
                let end = children[node.iid, default: []].compactMap { pathEnds[$0] }.max() ?? node.depth
                pathEnds[node.iid] = end
                positions[node.iid] = "\(node.depth)/\(end)"
            }
        }
        self.positions = positions
    }

    static func title(_ title: String, iid: Int, position: String?) -> String {
        guard let position,
              let number = title.range(of: "(?<!\\S)!\(iid)(?!\\S)", options: .regularExpression) else { return title }
        var title = title
        title.insert(contentsOf: " \(position)", at: number.upperBound)
        return title
    }
}

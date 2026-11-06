import Foundation

extension URL {
    /// Event URLs may point at the MR's pipeline tab; live request/proof URLs remain strict.
    func gitLabTodoMergeRequestURL(host: String, iid: Int) -> URL? {
        guard iid > 0, var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        let suffix = "/-/merge_requests/\(iid)"
        if components.path.hasSuffix(suffix + "/pipelines") {
            components.path = String(components.path.dropLast("/pipelines".count))
        } else if !components.path.hasSuffix(suffix) {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let canonical = components.url, canonical.isGitLabMergeRequest(host: host, iid: iid) else { return nil }
        return canonical
    }
}

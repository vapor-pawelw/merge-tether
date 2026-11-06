import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct PublicationIdentityLookupTests {
    @Test(arguments: ["valid", "mismatch", "missing", "invalid", "ambiguous"])
    func userConditionsResolveToServerIDsAndRejectUncertainIdentity(kind: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload: String = switch kind {
        case "valid": #"[{"id":7,"username":"alice","name":"Alice"}]"#
        case "mismatch": #"[{"id":7,"username":"other","name":"Alice"}]"#
        case "invalid": #"[{"id":0,"username":"alice","name":"Alice"}]"#
        case "ambiguous": #"[{"id":7,"username":"alice"},{"id":8,"username":"alice"}]"#
        default: "[]"
        }
        let executable = folder.appending(path: "glab")
        try Data(payload.utf8).write(to: folder.appending(path: "users.json"))
        try Data("""
        #!/bin/sh
        set -eu
        test "$1" = api
        test "$2" = '/users?username=alice'
        test "$3" = --hostname
        test "$4" = gitlab.example.test
        cat "$(dirname "$0")/users.json"
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService(); glab.glabPath = executable
        do {
            let identity = try await glab.resolvePublicationUser(username: "@alice", host: "gitlab.example.test")
            #expect(kind == "valid")
            #expect(identity.entityID == 7 && identity.host == "gitlab.example.test" && identity.label == "@alice")
        } catch {
            #expect(kind != "valid")
        }
    }
}

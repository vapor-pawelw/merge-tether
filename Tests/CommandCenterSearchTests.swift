import Testing
@testable import GitLabTodos

struct CommandCenterSearchTests {
    @Test func searchesAcrossTitleRepositoryAndMergeRequestNumber() {
        #expect(CommandCenterSearch.matches("logging payments !42", title: "Improve Logging", repository: "team/payments", iid: 42))
        #expect(CommandCenterSearch.matches("", title: "Improve logging", repository: "team/payments", iid: 42))
        #expect(!CommandCenterSearch.matches("payments 43", title: "Improve logging", repository: "team/payments", iid: 42))
        #expect(!CommandCenterSearch.matches("unknown", title: "Improve logging", repository: "team/payments", iid: 42))
    }

    @Test func trimsWhitespaceAndIgnoresCaseAndDiacritics() {
        #expect(CommandCenterSearch.matches("  ODSWIEZ  \n TEAM ", title: "Odśwież", repository: "team/app", iid: 2))
    }
}

import Foundation
import Testing
@testable import MergeTether

struct StableRowKeyTests {
    private func keys(_ ids: [Int?]) -> [StableRowKey] {
        StableRowKey.rows(ids, id: { $0 }).map(\.key)
    }

    @Test func realIDsNilIDsAndDuplicatesProduceUniqueKeys() {
        let result = keys([1, nil, 2, nil, 1, 2, 1, nil])
        #expect(Set(result).count == result.count)
        #expect(result == [.id(1), .position(0), .id(2), .position(1), .position(2), .position(3), .position(4), .position(5)])
    }

    @Test func positionFallbackNeverCollidesWithRealIDs() {
        let result = keys([0, nil, 1, nil])
        #expect(Set(result).count == 4)
    }

    @Test func rowsKeepIndexAndElement() {
        let rows = StableRowKey.rows(["a", "b"], id: { $0 == "a" ? 5 : nil })
        #expect(rows.map(\.index) == [0, 1])
        #expect(rows.map(\.element) == ["a", "b"])
    }

    @Test func draftKeepsItsKeyWhenAnEarlierDraftIsRemoved() {
        let before = StableRowKey.rows([10, 20, 30] as [Int?], id: { $0 })
        let after = StableRowKey.rows([20, 30] as [Int?], id: { $0 })
        #expect(before[1].key == after[0].key)
        #expect(before[2].key == after[1].key)
        #expect(after[0].index == 0)
    }
}

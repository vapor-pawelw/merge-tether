import Foundation
import Testing
@testable import MergeTether

@Suite("RefreshInterval")
struct RefreshIntervalTests {
    @Test("raw values are in seconds")
    func rawValuesInSeconds() {
        #expect(RefreshInterval.oneMinute.rawValue == 60)
        #expect(RefreshInterval.fiveMinutes.rawValue == 300)
        #expect(RefreshInterval.fifteenMinutes.rawValue == 900)
        #expect(RefreshInterval.thirtyMinutes.rawValue == 1800)
        #expect(RefreshInterval.oneHour.rawValue == 3600)
    }

    @Test("allCases preserves ascending order")
    func orderedAscending() {
        let raws = RefreshInterval.allCases.map(\.rawValue)
        #expect(raws == raws.sorted())
    }

    @Test("seconds property matches raw value as TimeInterval")
    func secondsMatchRaw() {
        for interval in RefreshInterval.allCases {
            #expect(interval.seconds == TimeInterval(interval.rawValue))
        }
    }
}

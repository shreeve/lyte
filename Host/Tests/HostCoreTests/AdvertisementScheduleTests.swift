import HostCore
import XCTest

final class AdvertisementScheduleTests: XCTestCase {
    private let s: UInt64 = 1_000_000_000

    func testTheFirstFilingIsDueAtOnceAndAStandingRecordIsNeverDue() {
        var schedule = AdvertisementSchedule()
        XCTAssertTrue(schedule.isDue(nowNS: 0))
        schedule.filed()
        XCTAssertFalse(schedule.isDue(nowNS: 1_000 * s))
    }

    func testLossesBackOffUntilARecordIsEstablishedAgain() {
        var schedule = AdvertisementSchedule()
        schedule.filed()
        schedule.retry(nowNS: 10 * s)          // daemon restarted
        XCTAssertFalse(schedule.isDue(nowNS: 10 * s))
        XCTAssertTrue(schedule.isDue(nowNS: 11 * s))
        schedule.retry(nowNS: 11 * s)          // not back yet
        XCTAssertFalse(schedule.isDue(nowNS: 12 * s))
        XCTAssertTrue(schedule.isDue(nowNS: 13 * s))
        schedule.filed()
        schedule.retry(nowNS: 13 * s)          // failed right after filing
        XCTAssertTrue(schedule.isDue(nowNS: 17 * s), "still backing off")
        XCTAssertFalse(schedule.isDue(nowNS: 16 * s))
        for _ in 0..<10 { schedule.retry(nowNS: 100 * s) }
        XCTAssertTrue(schedule.isDue(nowNS: 160 * s), "capped at a minute")

        schedule.filed()
        schedule.established()
        schedule.retry(nowNS: 500 * s)
        XCTAssertTrue(schedule.isDue(nowNS: 501 * s), "established resets the back-off")
    }

    func testEntryGroupStatesMapToReactions() {
        XCTAssertEqual(AvahiEntryGroupState.registering.reaction, .keep)
        XCTAssertEqual(AvahiEntryGroupState.established.reaction, .keep)
        XCTAssertEqual(AvahiEntryGroupState.uncommitted.reaction, .refile)
        XCTAssertEqual(AvahiEntryGroupState.failure.reaction, .refile)
        XCTAssertEqual(AvahiEntryGroupState.collision.reaction, .refileRenamed)
        XCTAssertNil(AvahiEntryGroupState(rawValue: 9))
    }
}

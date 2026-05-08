// LLMessengerTests/AppStateTests.swift
import XCTest
@testable import LLMessenger

final class BriefListGrouperTests: XCTestCase {

    private func makeDate(daysOffset: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: daysOffset, to: today)!
            .addingTimeInterval(3600)  // 1am of that day
    }

    private func makeBrief(id: Int64, date: Date) -> Brief {
        Brief(id: id,
              createdAt: date,
              status: "ready", services: "[]",
              openingSummary: nil, notificationText: "x",
              episodicSummary: nil)
    }

    func testTodayBriefGoesToTodayGroup() {
        let brief = makeBrief(id: 1, date: makeDate(daysOffset: 0))
        let groups = BriefListGrouper.group([brief])
        XCTAssertEqual(groups.first?.label, "Today")
        XCTAssertEqual(groups.first?.briefs.count, 1)
    }

    func testYesterdayBriefGoesToYesterdayGroup() {
        let brief = makeBrief(id: 2, date: makeDate(daysOffset: -1))
        let groups = BriefListGrouper.group([brief])
        XCTAssertEqual(groups.first?.label, "Yesterday")
    }

    func testOlderBriefGetsDateLabel() {
        let brief = makeBrief(id: 3, date: makeDate(daysOffset: -5))
        let groups = BriefListGrouper.group([brief])
        XCTAssertFalse(groups.first?.label == "Today")
        XCTAssertFalse(groups.first?.label == "Yesterday")
        XCTAssertFalse(groups.first?.label.isEmpty ?? true)
    }

    func testGroupsAreSortedNewestFirst() {
        let today = makeBrief(id: 1, date: makeDate(daysOffset: 0))
        let yesterday = makeBrief(id: 2, date: makeDate(daysOffset: -1))
        let groups = BriefListGrouper.group([yesterday, today])
        XCTAssertEqual(groups.first?.label, "Today")
        XCTAssertEqual(groups.last?.label, "Yesterday")
    }

    func testBriefsWithinGroupSortedNewestFirst() {
        let older = makeBrief(id: 1, date: makeDate(daysOffset: 0).addingTimeInterval(-3600))
        let newer = makeBrief(id: 2, date: makeDate(daysOffset: 0))
        let groups = BriefListGrouper.group([older, newer])
        XCTAssertEqual(groups.first?.briefs.first?.id, 2)
    }

    func testEmptyInputReturnsNoGroups() {
        let groups = BriefListGrouper.group([])
        XCTAssertTrue(groups.isEmpty)
    }
}

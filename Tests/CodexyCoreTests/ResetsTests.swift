import XCTest
@testable import CodexyCore

final class ResetsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    let week = 10080

    func snap(_ hours: Double, used: Double, endHours: Double) -> WindowSnapshot {
        WindowSnapshot(at: t0.addingTimeInterval(hours * 3600), minutes: week, used: used, end: t0.addingTimeInterval(endHours * 3600))
    }

    func testEarlyResetIsCounted() {
        var log = ResetLog()
        log.observe(snap(0, used: 40, endHours: 100))
        log.observe(snap(10, used: 100, endHours: 100.01))           // same window, its end moved a little
        XCTAssertTrue(log.observe(snap(20, used: 0, endHours: 20 + 168)))
        XCTAssertEqual(log.used, [t0.addingTimeInterval(20 * 3600)])
        XCTAssertEqual(log.since, t0)
    }

    func testWindowThatStartsAfterTheLastOneEndedIsNotAReset() {
        var log = ResetLog()
        log.observe(snap(0, used: 70, endHours: 100))
        XCTAssertFalse(log.observe(snap(130, used: 2, endHours: 130 + 168)))
        XCTAssertTrue(log.used.isEmpty)
    }

    func testOlderWindowSeenAgainIsIgnored() {
        // Two sources taking turns (a stale session, another account): A, B, A, B counts B once.
        var log = ResetLog()
        log.observe(snap(0, used: 30, endHours: 100))
        XCTAssertTrue(log.observe(snap(1, used: 0, endHours: 1 + 168)))
        XCTAssertFalse(log.observe(snap(1.01, used: 30, endHours: 100)))
        XCTAssertFalse(log.observe(snap(1.02, used: 0, endHours: 1 + 168)))
        XCTAssertEqual(log.used.count, 1)
    }

    func testMovedWindowWithoutLessUsedIsNotAReset() {
        var log = ResetLog()
        log.observe(snap(0, used: 0, endHours: 168))
        XCTAssertFalse(log.observe(snap(0.5, used: 0, endHours: 168.5)))
        XCTAssertTrue(log.used.isEmpty)
    }

    func testCountsSinceADate() {
        var log = ResetLog()
        log.observe(snap(0, used: 50, endHours: 100))
        log.observe(snap(20, used: 0, endHours: 20 + 168))
        log.observe(snap(30, used: 90, endHours: 20 + 168))
        log.observe(snap(40, used: 1, endHours: 40 + 168))
        XCTAssertEqual(log.used.count, 2)
        XCTAssertEqual(log.count(since: t0.addingTimeInterval(30 * 3600)), 1)
        XCTAssertEqual(log.last, t0.addingTimeInterval(40 * 3600))
    }

    func testRolloutLineGivesTheLongestCodexWindow() throws {
        let line = #"{"timestamp":"2026-10-21T17:00:42.939Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1793000000},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1793203849},"plan_type":"plus"}}}"#
        let s = try XCTUnwrap(ResetScan.snapshot(Data(line.utf8)))
        XCTAssertEqual(s.minutes, 10080)
        XCTAssertEqual(s.used, 3)
        XCTAssertEqual(s.end, Date(timeIntervalSince1970: 1_793_203_849))
        let other = #"{"timestamp":"2026-10-21T17:00:42.939Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1793203849}}}}"#
        XCTAssertNil(ResetScan.snapshot(Data(other.utf8)))
    }

    func testScanReadsRolloutFilesInTimeOrder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexy-resets-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let day = home + "/sessions/2026/10/21"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        func line(_ ts: String, _ used: Double, _ end: Int) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(end)}}}}"#
        }
        // The later file is listed first by name: order comes from the timestamps.
        try line("2026-10-21T17:00:00.000Z", 0, 1_793_203_849).write(toFile: day + "/rollout-a.jsonl", atomically: true, encoding: .utf8)
        try [line("2026-10-21T10:00:00.000Z", 80, 1_792_900_000), #"{"timestamp":"x","type":"event_msg","payload":{"type":"agent_message","message":"\"type\":\"token_count\""}}"#]
            .joined(separator: "\n").write(toFile: day + "/rollout-b.jsonl", atomically: true, encoding: .utf8)
        var log = ResetLog()
        log.scan(home: home)
        XCTAssertEqual(log.used.count, 1)
        XCTAssertNotNil(log.scannedUntil)
    }
}

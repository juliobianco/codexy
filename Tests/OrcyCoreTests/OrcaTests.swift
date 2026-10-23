import XCTest
import SQLite3
@testable import OrcyCore

// Fixtures follow the shapes seen from Orca 1.4.223 (`orca worktree ps --json`, orca-stats.json), anonymised.
final class OrcaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_700_000)

    func ms(_ secondsAgo: Double) -> Int { Int((now.timeIntervalSince1970 - secondsAgo) * 1000) }

    func testWorktreePsPhasesAndCounts() throws {
        let json = """
        {"id":"1","ok":true,"result":{"worktrees":[
          {"worktreeId":"a","displayName":"api","repo":"app","branch":"fix-login","liveTerminalCount":1,"lastOutputAt":\(ms(5)),"isArchived":false,"isMainWorktree":false,
           "agents":[{"agentType":"codex","state":"working","stateStartedAt":\(ms(60)),"lastAssistantMessage":"secret","toolInput":"secret"}]},
          {"worktreeId":"b","displayName":"ui","repo":"app","branch":"ui","liveTerminalCount":2,"lastOutputAt":\(ms(30)),"isArchived":false,
           "agents":[{"agentType":"claude","state":"blocked"},{"agentType":"codex","state":"monitoring"}]},
          {"worktreeId":"c","displayName":"build","repo":"app","branch":"b","liveTerminalCount":1,"lastOutputAt":\(ms(20)),"agents":[]},
          {"worktreeId":"d","displayName":"old","repo":"app","branch":"o","liveTerminalCount":1,"lastOutputAt":\(ms(72000)),"agents":[{"agentType":"codex","state":"done"}]},
          {"worktreeId":"e","displayName":"gone","repo":"app","branch":"g","liveTerminalCount":0,"agents":[]},
          {"worktreeId":"f","displayName":"archived","repo":"app","branch":"x","isArchived":true,"liveTerminalCount":1,"agents":[]}
        ]}}
        """
        let l = try XCTUnwrap(OrcaParser.worktreePs(Data(json.utf8), now: now))
        XCTAssertEqual(l.worktrees.map(\.id), ["a", "b", "c", "d", "e"])          // archived left out
        XCTAssertEqual(l.worktrees.map(\.phase), [.working, .waiting, .working, .agent, .closed])   // d: a codex that finished its turn, still open
        XCTAssertEqual(l.sorted.map(\.id), ["b", "a", "c", "d", "e"])            // waiting first, then by output
        XCTAssertEqual(l.working, 3)        // a (codex), b (monitoring), c (busy terminal, no status)
        XCTAssertEqual(l.waiting, 1)
        XCTAssertEqual(l.agentsOpen, 1)
        XCTAssertEqual(l.worktrees[0].agents[0].since, Date(timeIntervalSince1970: Double(ms(60)) / 1000))
    }

    func testTerminalsAddHiddenWorktreesAndAgentNames() throws {
        let ps = """
        {"ok":true,"result":{"worktrees":[
          {"worktreeId":"r1::/w/app/api","displayName":"api","repo":"app","branch":"refs/heads/me/api","path":"/w/app/api","liveTerminalCount":1,"lastOutputAt":\(ms(3000)),"agents":[]},
          {"worktreeId":"r1::/w/app","displayName":"main","repo":"app","branch":"main","path":"/w/app","isMainWorktree":true,"liveTerminalCount":1,"lastOutputAt":\(ms(4000)),"agents":[]},
          {"worktreeId":"r2::/w/other","displayName":"main","repo":"other","branch":"main","path":"/w/other","isMainWorktree":true,"liveTerminalCount":0,"agents":[]}
        ]}}
        """
        let term = """
        {"ok":true,"result":{"terminals":[
          {"worktreeId":"r1::/w/app/api","worktreePath":"/w/app/api","branch":"refs/heads/me/api","title":"T","lastOutputAt":\(ms(3000)),"agentIdentity":"codex","preview":"secret"},
          {"worktreeId":"r1::/w/app","worktreePath":"/w/app","branch":"refs/heads/main","title":"T","lastOutputAt":\(ms(4000)),"agentIdentity":"claude"},
          {"worktreeId":"r1::/w/app","worktreePath":"/w/app","branch":"refs/heads/main","title":"T2","lastOutputAt":\(ms(10)),"agentIdentity":null},
          {"worktreeId":"r2::/w/other/wt-x","worktreePath":"/w/other/wt-x","branch":"refs/heads/feat","title":"VEN","lastOutputAt":\(ms(700)),"agentIdentity":"opencode"},
          {"worktreeId":"r2::/w/gone","worktreePath":"/w/gone","orphaned":true,"agentIdentity":"codex"}
        ]}}
        """
        let live = try XCTUnwrap(OrcaParser.worktreePs(Data(ps.utf8), now: now))
        let ts = try XCTUnwrap(OrcaParser.terminals(Data(term.utf8)))
        XCTAssertEqual(ts.count, 4)                                       // the orphaned one is left out
        let m = OrcaParser.merge(live, terminals: ts, now: now)
        XCTAssertEqual(m.worktrees.count, 4)
        let by = Dictionary(uniqueKeysWithValues: m.worktrees.map { ($0.id, $0) })
        XCTAssertEqual(by["r1::/w/app/api"]?.agentNames, ["codex"]); XCTAssertEqual(by["r1::/w/app/api"]?.phase, .agent)
        XCTAssertEqual(by["r1::/w/app"]?.agentNames, ["claude"]); XCTAssertEqual(by["r1::/w/app"]?.liveTerminals, 2)
        XCTAssertEqual(by["r1::/w/app"]?.phase, .working)                  // claude is named and a terminal printed 10 s ago
        // The hidden worktree comes from its terminal: named by the folder, the repo by the id's prefix, marked external.
        let ext = try XCTUnwrap(by["r2::/w/other/wt-x"])
        XCTAssertEqual(ext.name, "wt-x"); XCTAssertEqual(ext.repo, "other"); XCTAssertEqual(ext.branch, "feat")
        XCTAssertTrue(ext.external); XCTAssertEqual(ext.agentNames, ["opencode"]); XCTAssertEqual(ext.phase, .agent)
        XCTAssertEqual(by["r2::/w/other"]?.phase, .closed)
        XCTAssertEqual(m.repos, ["app", "other"])
        XCTAssertEqual(m.agentsOpen, 2); XCTAssertEqual(m.terminals, 4); XCTAssertEqual(m.working, 1)
        // opencode working in that folder: the terminal looks quiet, the worktree works.
        let busy = OrcaParser.merge(live, terminals: ts, busyPaths: ["/w/other/wt-x"], now: now)
        XCTAssertEqual(busy.worktrees.first { $0.id == ext.id }?.phase, .working)
        XCTAssertEqual(busy.working, 2)
    }

    func testOpenCodeProbeFindsRunningFolders() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("orcy-oc-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        create table session_v2 (directory text, time_idle integer, time_updated integer, time_archived integer);
        insert into session_v2 values ('/w/running', null, \(ms(5)), null), ('/w/stale', null, \(ms(3000)), null),
          ('/w/idle', \(ms(5)), \(ms(5)), null), ('/w/archived', null, \(ms(5)), \(ms(1)));
        """, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(OpenCodeProbe.activeFolders(path: path, now: now), ["/w/running"])
        XCTAssertEqual(OpenCodeProbe.activeFolders(path: path + ".missing", now: now), [])
    }

    func testStatesFoldAsOrcaListsThem() {
        XCTAssertEqual(["working", "monitoring", "waiting", "blocked", "done", "idle", "unverifiable"].map { AgentPhase(orcaState: $0) },
                       [.working, .working, .waiting, .waiting, .idle, .idle, .idle])
    }

    func testFailedAnswerGivesItsMessage() {
        let d = Data(#"{"id":"1","ok":false,"error":{"code":"runtime_unreachable","message":"Orca is not running"}}"#.utf8)
        XCTAssertNil(OrcaParser.worktreePs(d))
        XCTAssertEqual(OrcaParser.error(d), "Orca is not running")
    }

    func testStatsPairStartsAndStops() {
        let t = now.timeIntervalSince1970 * 1000
        let json = """
        {"schemaVersion":1,"events":[
          {"type":"agent_start","at":\(t - 7_200_000),"worktreeId":"a","meta":{"sessionKey":"k1"}},
          {"type":"agent_stop","at":\(t - 3_600_000),"worktreeId":"a","meta":{"sessionKey":"k1","durationMs":3600000}},
          {"type":"agent_start","at":\(t - 5_400_000),"worktreeId":"b","meta":{"sessionKey":"k2"}},
          {"type":"agent_stop","at":\(t - 600_000),"worktreeId":"c","meta":{"sessionKey":"lost","durationMs":600000}},
          {"type":"agent_start","at":\(t - 1_800_000),"worktreeId":"d","meta":{"sessionKey":"k3"}}
        ]}
        """
        let runs = OrcaStatsFile.runs(Data(json.utf8))
        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(runs.filter { $0.end == nil }.map(\.worktreeId).sorted(), ["b", "d"])
        let a = Activity.of(runs, from: now.addingTimeInterval(-86400), to: now, now: now)
        XCTAssertEqual(a.started, 4)        // the stop without its start started inside the span too
        XCTAssertEqual(a.seconds, 3600 + 5400 + 600 + 1800, accuracy: 0.5)
        XCTAssertEqual(a.peak, 3)           // b and d running, then the lost one alongside
        // Clipped: only the last hour.
        let h = Activity.of(runs, from: now.addingTimeInterval(-3600), to: now, now: now)
        XCTAssertEqual(h.seconds, 3600 + 600 + 1800, accuracy: 0.5)
    }

    func testDaysEndWithToday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let runs = [AgentRun(start: now.addingTimeInterval(-86400 - 60), end: now.addingTimeInterval(-86400), worktreeId: "a"),
                    AgentRun(start: now.addingTimeInterval(-120), end: now.addingTimeInterval(-60), worktreeId: "b")]
        let d = Activity.days(runs, count: 7, now: now, calendar: cal)
        XCTAssertEqual(d.count, 7)
        XCTAssertEqual(d.last?.day, cal.startOfDay(for: now))
        XCTAssertEqual(d.last?.activity.started, 1)
        XCTAssertEqual(d[5].activity.started, 1)
    }

    func testDatabaseSummary() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("orcy-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let today = OrcaDB.parseDate("2026-10-21 12:00:00")!
        sqlite3_exec(db, """
        create table tasks (id text, status text, completed_at text);
        insert into tasks values ('1','completed','2026-10-21 13:00:00'),('2','completed','2026-10-20T10:00:00.000Z'),
          ('3','failed','2026-10-21T14:00:00.000Z'),('4','blocked',null),('5','pending',null);
        create table worker_dispatches (state text);
        insert into worker_dispatches values ('succeeded'),('succeeded'),('failed');
        create table question_threads (status text);
        insert into question_threads values ('answered'),('open');
        """, nil, nil, nil)
        sqlite3_close(db)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let s = try XCTUnwrap(OrcaDB.summary(path: path, now: today, calendar: cal))
        XCTAssertEqual(s.total, 5); XCTAssertEqual(s.completed, 2); XCTAssertEqual(s.failed, 1); XCTAssertEqual(s.blocked, 1)
        XCTAssertEqual(s.completedToday, 1); XCTAssertEqual(s.failedToday, 1)
        XCTAssertEqual(s.successRate!, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(s.dispatchesByState, ["succeeded": 2, "failed": 1])
        XCTAssertEqual(s.questions, 2); XCTAssertEqual(s.openQuestions, 1)
        XCTAssertNil(OrcaDB.summary(path: path + ".missing"))
    }
}

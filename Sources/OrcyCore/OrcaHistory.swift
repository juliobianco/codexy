import Foundation
import SQLite3

// History, from Orca's own files: orca-stats.json (every agent start and stop) and orchestration.db (tasks,
// dispatches, questions). Both are opened read-only; only kinds, states and times are read.

/// One agent from start to stop; `end` nil while it still runs.
public struct AgentRun: Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public var worktreeId: String
    public init(start: Date, end: Date?, worktreeId: String) { self.start = start; self.end = end; self.worktreeId = worktreeId }
}

public enum OrcaStatsFile {
    public static var url: URL { URL(fileURLWithPath: OrcaCLI.dataDir + "/orca-stats.json") }

    /// `{events: [{type: agent_start|agent_stop, at (ms), worktreeId, meta: {sessionKey, durationMs}}]}`, paired by sessionKey.
    /// A stop without its start (trimmed history) uses its duration.
    public static func runs(_ data: Data) -> [AgentRun] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = j["events"] as? [[String: Any]] else { return [] }
        var open: [String: AgentRun] = [:]
        var out: [AgentRun] = []
        for e in events.sorted(by: { ($0["at"] as? NSNumber)?.doubleValue ?? 0 < ($1["at"] as? NSNumber)?.doubleValue ?? 0 }) {
            guard let type = e["type"] as? String, let at = (e["at"] as? NSNumber)?.doubleValue else { continue }
            let meta = e["meta"] as? [String: Any] ?? [:]
            let key = meta["sessionKey"] as? String ?? UUID().uuidString
            let when = Date(timeIntervalSince1970: at / 1000), wt = e["worktreeId"] as? String ?? ""
            if type == "agent_start" {
                open[key] = AgentRun(start: when, end: nil, worktreeId: wt)
            } else if type == "agent_stop" {
                if var r = open.removeValue(forKey: key) { r.end = when; out.append(r) }
                else if let ms = (meta["durationMs"] as? NSNumber)?.doubleValue {
                    out.append(AgentRun(start: when.addingTimeInterval(-ms / 1000), end: when, worktreeId: wt))
                }
            }
        }
        return (out + open.values).sorted { $0.start < $1.start }
    }

    public static func load() -> [AgentRun] { (try? Data(contentsOf: url)).map(runs) ?? [] }
}

/// Agents over a span of time: how many started, how long they ran, how many at once.
public struct Activity: Equatable, Sendable {
    public var started = 0
    public var seconds: TimeInterval = 0
    public var peak = 0
    public var averageSeconds: TimeInterval { started > 0 ? seconds / Double(started) : 0 }
    public init() {}

    /// Runs clipped to [from, to); a run still going counts until `now`.
    public static func of(_ runs: [AgentRun], from: Date, to: Date, now: Date = Date()) -> Activity {
        var a = Activity()
        var edges: [(Date, Int)] = []
        for r in runs {
            let end = min(r.end ?? now, to), start = max(r.start, from)
            if r.start >= from && r.start < to { a.started += 1 }
            guard end > start else { continue }
            a.seconds += end.timeIntervalSince(start)
            edges += [(start, 1), (end, -1)]
        }
        var n = 0
        for e in edges.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { n += e.1; a.peak = max(a.peak, n) }
        return a
    }

    /// One `Activity` per local day, the oldest first, ending with today.
    public static func days(_ runs: [AgentRun], count: Int, now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, activity: Activity)] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { back in
            let d = calendar.date(byAdding: .day, value: -back, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: d)!
            return (d, of(runs, from: d, to: next, now: now))
        }
    }
}

/// Orchestration tasks and what came of them.
public struct TaskSummary: Equatable, Sendable {
    public var byStatus: [String: Int] = [:]
    public var completedToday = 0
    public var failedToday = 0
    public var dispatchesByState: [String: Int] = [:]
    public var openQuestions = 0
    public var questions = 0
    public init() {}

    public var completed: Int { byStatus["completed", default: 0] }
    public var failed: Int { byStatus["failed", default: 0] }
    public var blocked: Int { byStatus["blocked", default: 0] }
    public var total: Int { byStatus.values.reduce(0, +) }
    /// Completed among the tasks that ended (completed or failed); nil before the first one.
    public var successRate: Double? { completed + failed > 0 ? Double(completed) / Double(completed + failed) : nil }
}

public enum OrcaDB {
    public static var path: String { OrcaCLI.dataDir + "/orchestration.db" }

    /// nil when the file is missing or its tables have another shape (a newer Orca).
    public static func summary(path: String = path, now: Date = Date(), calendar: Calendar = .current) -> TaskSummary? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var s = TaskSummary()
        let today = calendar.startOfDay(for: now)
        guard query(db, "select status, completed_at from tasks", { row in
            let status = row.text(0) ?? "?"
            s.byStatus[status, default: 0] += 1
            if let done = row.text(1).flatMap(parseDate), done >= today {
                if status == "completed" { s.completedToday += 1 } else if status == "failed" { s.failedToday += 1 }
            }
        }) else { return nil }
        _ = query(db, "select state from worker_dispatches") { s.dispatchesByState[$0.text(0) ?? "?", default: 0] += 1 }
        _ = query(db, "select status from question_threads") { row in
            s.questions += 1
            if row.text(0) == "open" || row.text(0) == "pending" { s.openQuestions += 1 }
        }
        return s
    }

    struct Row {
        let stmt: OpaquePointer?
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    }

    @discardableResult
    static func query(_ db: OpaquePointer?, _ sql: String, _ each: (Row) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { sqlite3_finalize(stmt); return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(Row(stmt: stmt)) }
        return true
    }

    /// Orca writes UTC both ways: "2026-10-22 15:03:09" and "2026-10-22T16:30:47.249Z".
    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }
}

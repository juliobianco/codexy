import Foundation
import SQLite3

// Orca (the agent orchestrator, an Electron app) and what Orcy reads from it, all read-only:
// - live: `orca worktree ps --json` (worktrees and the agent state their hooks report) joined with
//   `orca terminal list --json` (every terminal, the agent running in it, its last output), through the CLI inside
//   the app bundle (~0.13 s of CPU a call each);
// - history: orca-stats.json (agent starts and stops) and orchestration.db (tasks, dispatches, questions).
// Orca hides the worktrees it did not create (a repo's "external worktree visibility", default hide): `worktree ps`
// leaves them out, but their terminals are listed, so they come from the terminals.
// The same answers carry prompts, agent messages, tool input and terminal previews: never read into the model, never kept.

/// Orca's agent states (its own list: working, monitoring, waiting, blocked, done, idle, unverifiable), folded into three.
public enum AgentPhase: String, Sendable, CaseIterable {
    case working, waiting, idle

    public init(orcaState s: String) {
        switch s {
        case "working", "monitoring", "running", "thinking": self = .working
        case "waiting", "blocked": self = .waiting
        default: self = .idle
        }
    }
}

public struct OrcaAgent: Equatable, Sendable {
    public var type: String          // "codex", "claude", …
    public var state: String         // Orca's own word
    public var since: Date?
    public var phase: AgentPhase { AgentPhase(orcaState: state) }
    public init(type: String, state: String, since: Date?) { self.type = type; self.state = state; self.since = since }
}

/// What a worktree is doing, most urgent first: an agent that needs you, one that works, an agent open but idle,
/// a terminal left open, nothing.
public enum WorktreePhase: Int, Sendable, Comparable, CaseIterable {
    case waiting, working, agent, open, closed
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One terminal of `orca terminal list`. Only its metadata: the preview is never read.
public struct OrcaTerminal: Equatable, Sendable {
    public var worktreeId: String
    public var path: String
    public var branch: String
    public var agent: String?        // `agentIdentity`: "codex", "claude", "opencode"…
    public var lastOutput: Date?
    public init(worktreeId: String, path: String, branch: String, agent: String?, lastOutput: Date?) {
        self.worktreeId = worktreeId; self.path = path; self.branch = branch; self.agent = agent; self.lastOutput = lastOutput
    }
}

public struct OrcaWorktree: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var repo: String
    public var branch: String
    public var path: String
    public var liveTerminals: Int
    public var lastOutput: Date?
    public var isMain: Bool
    /// What Orca's hooks report (codex, claude).
    public var agents: [OrcaAgent]
    /// Agents named by the terminals (`agentIdentity`) or found by another tool, without duplicates: who is running here.
    public var agentNames: [String] = []
    /// A worktree Orca did not create: it comes from its terminals, not from `worktree ps`.
    public var external = false
    /// Work Orca's agent status does not show: terminal output in the last 90 s, or an opencode session running here.
    public var outputActive = false

    public init(id: String, name: String, repo: String, branch: String, path: String = "", liveTerminals: Int, lastOutput: Date?,
                isMain: Bool, agents: [OrcaAgent], outputActive: Bool = false) {
        self.id = id; self.name = name; self.repo = repo; self.branch = branch; self.path = path; self.liveTerminals = liveTerminals
        self.lastOutput = lastOutput; self.isMain = isMain; self.agents = agents; self.outputActive = outputActive
        self.agentNames = Self.names(agents, [])
    }

    static func names(_ agents: [OrcaAgent], _ extra: [String]) -> [String] {
        var out: [String] = []
        for n in agents.map(\.type) + extra where !n.isEmpty && !out.contains(n) { out.append(n) }
        return out
    }

    public var phase: WorktreePhase {
        if agents.contains(where: { $0.phase == .waiting }) { return .waiting }
        if agents.contains(where: { $0.phase == .working }) || outputActive { return .working }
        if liveTerminals > 0 || !agentNames.isEmpty { return agentNames.isEmpty ? .open : .agent }
        return .closed
    }
}

public struct OrcaLive: Equatable, Sendable {
    public var worktrees: [OrcaWorktree]
    public var at: Date
    public init(worktrees: [OrcaWorktree], at: Date) { self.worktrees = worktrees; self.at = at }

    /// Most urgent first, then the most recent output.
    public var sorted: [OrcaWorktree] {
        worktrees.sorted { ($0.phase, -($0.lastOutput?.timeIntervalSince1970 ?? 0)) < ($1.phase, -($1.lastOutput?.timeIntervalSince1970 ?? 0)) }
    }
    public func count(_ p: WorktreePhase) -> Int { worktrees.filter { $0.phase == p }.count }
    /// Agents doing something now: those Orca says work, plus a worktree whose terminal or opencode session is busy without a status.
    public var working: Int {
        worktrees.reduce(0) { n, w in
            let a = w.agents.filter { $0.phase == .working }.count
            return n + (a > 0 ? a : (w.phase == .working ? 1 : 0))
        }
    }
    public var waiting: Int { worktrees.reduce(0) { $0 + $1.agents.filter { $0.phase == .waiting }.count } }
    /// Worktrees with an agent open and idle: "processes running" that wait for something to do.
    public var agentsOpen: Int { count(.agent) }
    public var terminals: Int { worktrees.reduce(0) { $0 + $1.liveTerminals } }
    /// More than one repo: rows need the repo's name to tell two "main" apart.
    public var repos: [String] { Array(Set(worktrees.map(\.repo))).sorted() }
}

public enum OrcaParser {
    /// Terminal output within this long, with no agent status, counts as work.
    public static let outputActiveSeconds: TimeInterval = 90

    static func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
    static func branchName(_ b: String) -> String { b.hasPrefix("refs/heads/") ? String(b.dropFirst(11)) : b }

    /// `{"ok":true,"result":{"worktrees":[…]}}`; archived worktrees are left out. nil when it is not that shape.
    public static func worktreePs(_ data: Data, now: Date = Date()) -> OrcaLive? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true,
              let rows = (j["result"] as? [String: Any])?["worktrees"] as? [[String: Any]] else { return nil }
        let list: [OrcaWorktree] = rows.compactMap { r in
            guard let id = r["worktreeId"] as? String, r["isArchived"] as? Bool != true else { return nil }
            let agents = (r["agents"] as? [[String: Any]] ?? []).map {
                OrcaAgent(type: $0["agentType"] as? String ?? "agent", state: $0["state"] as? String ?? "unverifiable",
                          since: date($0["stateStartedAt"]))
            }
            let last = date(r["lastOutputAt"])
            let terminals = (r["liveTerminalCount"] as? NSNumber)?.intValue ?? 0
            var w = OrcaWorktree(id: id, name: r["displayName"] as? String ?? r["branch"] as? String ?? id,
                                 repo: r["repo"] as? String ?? "", branch: branchName(r["branch"] as? String ?? ""),
                                 path: r["path"] as? String ?? "", liveTerminals: terminals, lastOutput: last,
                                 isMain: r["isMainWorktree"] as? Bool ?? false, agents: agents)
            w.outputActive = agents.isEmpty && terminals > 0 && last.map { now.timeIntervalSince($0) < outputActiveSeconds } == true
            return w
        }
        return OrcaLive(worktrees: list, at: now)
    }

    /// `{"ok":true,"result":{"terminals":[…]}}`: metadata only; `preview` is not looked at.
    public static func terminals(_ data: Data) -> [OrcaTerminal]? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true,
              let rows = (j["result"] as? [String: Any])?["terminals"] as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let id = r["worktreeId"] as? String, r["orphaned"] as? Bool != true else { return nil }
            let agent = (r["agentIdentity"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return OrcaTerminal(worktreeId: id, path: r["worktreePath"] as? String ?? "", branch: branchName(r["branch"] as? String ?? ""),
                                agent: agent, lastOutput: date(r["lastOutputAt"]))
        }
    }

    /// Joins the two answers. `busyPaths`: folders where another tool (opencode) has a session running now.
    public static func merge(_ live: OrcaLive, terminals: [OrcaTerminal], busyPaths: Set<String> = [], now: Date = Date()) -> OrcaLive {
        var list = live.worktrees
        var index = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
        // A worktree id is "<repo id>::<path>": the repos' names come from the rows `worktree ps` gave.
        var repoNames: [String: String] = [:]
        for w in list { if let r = w.id.range(of: "::") { repoNames[String(w.id[..<r.lowerBound])] = w.repo } }
        var byWorktree: [String: [OrcaTerminal]] = [:]
        for t in terminals { byWorktree[t.worktreeId, default: []].append(t) }
        for (id, ts) in byWorktree.sorted(by: { $0.key < $1.key }) {
            let last = ts.compactMap(\.lastOutput).max()
            let named = ts.compactMap(\.agent)
            if let i = index[id] {
                list[i].agentNames = OrcaWorktree.names(list[i].agents, list[i].agentNames + named)
                list[i].liveTerminals = max(list[i].liveTerminals, ts.count)
                list[i].lastOutput = [list[i].lastOutput, last].compactMap { $0 }.max()
                if list[i].path.isEmpty { list[i].path = ts[0].path }
            } else {
                let path = ts[0].path
                let repo = id.range(of: "::").flatMap { repoNames[String(id[..<$0.lowerBound])] }
                    ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                var w = OrcaWorktree(id: id, name: (path as NSString).lastPathComponent, repo: repo, branch: ts[0].branch, path: path,
                                     liveTerminals: ts.count, lastOutput: last, isMain: false, agents: [])
                w.agentNames = OrcaWorktree.names([], named)
                w.external = true
                index[id] = list.count
                list.append(w)
            }
        }
        for i in list.indices {
            let recent = list[i].lastOutput.map { now.timeIntervalSince($0) < outputActiveSeconds } == true
            let busyElsewhere = !list[i].path.isEmpty && busyPaths.contains(list[i].path)
            if busyElsewhere { list[i].agentNames = OrcaWorktree.names(list[i].agents, list[i].agentNames + ["opencode"]) }
            list[i].outputActive = busyElsewhere || (list[i].agents.isEmpty && list[i].liveTerminals > 0 && recent)
        }
        return OrcaLive(worktrees: list, at: live.at)
    }

    /// The `error.message` of a failed answer, cut short.
    public static func error(_ data: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == false else { return nil }
        return ((j["error"] as? [String: Any])?["message"] as? String).map { String($0.prefix(160)) }
    }
}

/// Folders where opencode has a session running now (no idle time, updated in the last 5 minutes): an opencode in an
/// Orca terminal prints little, so its terminal looks quiet while it works. Read-only, ~15 ms; empty without opencode.
public enum OpenCodeProbe {
    public static var path: String { NSHomeDirectory() + "/.local/share/opencode/opencode.db" }

    public static func activeFolders(path: String = path, now: Date = Date()) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        var stmt: OpaquePointer?
        let since = Int64((now.timeIntervalSince1970 - 300) * 1000)
        guard sqlite3_prepare_v2(db, "select distinct directory from session_v2 where time_idle is null and time_archived is null and time_updated > \(since)", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return []
        }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) } }
        return out
    }
}

/// The CLI that ships inside Orca.app (the /usr/local/bin link may be broken; the bundled one always matches the app).
public enum OrcaCLI {
    public static let bundleId = "com.stablyai.orca"
    public static let path: String? = ["/Applications/Orca.app", NSHomeDirectory() + "/Applications/Orca.app"]
        .map { $0 + "/Contents/Resources/bin/orca" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    public enum LiveResult: Sendable { case ok(OrcaLive), failed(String) }

    public static func live(now: Date = Date()) -> LiveResult {
        guard let exe = path else { return .failed("Orca.app not found") }
        guard let r = run(exe, ["worktree", "ps", "--json"]) else { return .failed("orca did not answer") }
        guard let ps = OrcaParser.worktreePs(r, now: now) else {
            let why = OrcaParser.error(r) ?? "unexpected answer"
            OrcyLog.write("worktree ps failed: \(why)")
            return .failed(why)
        }
        // The terminals add the hidden worktrees and the agent in each one; without them the worktrees still show.
        let terminals = run(exe, ["terminal", "list", "--json"]).flatMap(OrcaParser.terminals) ?? []
        return .ok(OrcaParser.merge(ps, terminals: terminals, busyPaths: OpenCodeProbe.activeFolders(now: now), now: now))
    }

    /// stdout of a short run, with an argument array (never a shell). A bare PATH is enough: the script finds its app.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 15) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return d.isEmpty ? nil : d
    }

    /// ~/Library/Application Support/orca: Orca's own data folder.
    public static var dataDir: String { NSHomeDirectory() + "/Library/Application Support/orca" }
}

/// ~/Library/Logs/Orcy.log, so failures can be read without a debugger.
public enum OrcyLog {
    public static func write(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Orcy.log")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss xx"
        let line = "\(f.string(from: Date())) \(s)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

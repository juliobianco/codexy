import Foundation

// Resets used: the weekly window started over before its end. Codex lists only the reset credits still
// available, so the used ones are read from the limits it reports: the live read, and the copy of the limits
// in every `token_count` line of the rollout files, which goes back to the first Codex session on this Mac.
// ponytail: an early reset OpenAI gives everyone looks the same as a credit you used; both are counted.

/// The longest window at one moment: how full it was and when it ends.
public struct WindowSnapshot: Equatable, Sendable {
    public var at: Date
    public var minutes: Int
    public var used: Double
    public var end: Date
    public init(at: Date, minutes: Int, used: Double, end: Date) {
        self.at = at; self.minutes = minutes; self.used = used; self.end = end
    }
}

extension CodexLimits {
    /// The longest window, for the reset log; nil when its end is unknown.
    public var snapshot: WindowSnapshot? {
        guard let l = limits.max(by: { $0.windowMinutes < $1.windowMinutes }), let end = l.resetsAt else { return nil }
        return WindowSnapshot(at: asOf ?? Date(), minutes: l.windowMinutes, used: l.usedPercent, end: end)
    }
}

public struct ResetLog: Codable, Equatable, Sendable {
    /// When each early window started, oldest first.
    public var used: [Date] = []
    /// The first snapshot ever read: the count is complete from there.
    public var since: Date?
    /// The newest window seen and how full it was last time.
    var latestEnd: Date?
    var latestUsed: Double?
    /// Rollout files last changed before this were read already.
    var scannedUntil: Date?

    public init() {}

    /// The same window's end moves by a minute or so between reads.
    static let slack: TimeInterval = 600

    /// Snapshots must come oldest first. A later end whose window starts before the newest one ended, with
    /// less used than before, is an early reset. An end no later than the newest is that window again, or an
    /// older copy (a stale session, another account): only the newest window moves the count.
    @discardableResult
    public mutating func observe(_ s: WindowSnapshot) -> Bool {
        since = since.map { min($0, s.at) } ?? s.at
        guard let last = latestEnd else { latestEnd = s.end; latestUsed = s.used; return false }
        if abs(s.end.timeIntervalSince(last)) <= Self.slack { latestUsed = s.used; return false }
        guard s.end > last else { return false }
        let before = latestUsed ?? 0
        latestEnd = s.end; latestUsed = s.used
        let start = s.end.addingTimeInterval(-Double(s.minutes) * 60)
        guard start < last.addingTimeInterval(-Self.slack), s.used < before else { return false }
        used.append(start)
        return true
    }

    public func count(since d: Date) -> Int { used.filter { $0 >= d }.count }
    public var last: Date? { used.last }

    /// The rollout files changed since the last scan, their snapshots fed in time order.
    public mutating func scan(home: String = CodexCLI.home, now: Date = Date()) {
        let after = scannedUntil.map { $0.addingTimeInterval(-60) }
        for s in ResetScan.snapshots(home: home, changedAfter: after) { observe(s) }
        scannedUntil = now
    }

    public static var fileURL: URL { UsageHistory.fileURL.deletingLastPathComponent().appendingPathComponent("resets.json") }
    public static func load() -> ResetLog {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(ResetLog.self, from: $0) } ?? ResetLog()
    }
    public func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.fileURL, options: .atomic) } }
}

/// The limits copied into the rollout files: only `token_count` lines are decoded, picked by their start.
public enum ResetScan {
    public static func snapshots(home: String, changedAfter: Date?) -> [WindowSnapshot] {
        let fm = FileManager.default
        var out: [WindowSnapshot] = []
        for path in RolloutScanner.files(home: home) {
            if let after = changedAfter {
                guard let mod = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, mod >= after else { continue }
            }
            let data: Data?
            if path.hasSuffix(".zst") { data = CodexCLI.zstd.flatMap { CodexCLI.run($0, ["-dc", path], timeout: 30) } }
            else { data = fm.contents(atPath: path) }
            guard let data else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true)
            where line.prefix(RolloutScanner.head).range(of: RolloutScanner.countMarker) != nil {
                if let s = snapshot(Data(line)) { out.append(s) }
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// One `token_count` line: the longest window of the main "codex" limits.
    static func snapshot(_ line: Data) -> WindowSnapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let at = (o["timestamp"] as? String).flatMap(CodexParser.iso),
              let rl = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
              (rl["limit_id"] as? String ?? "codex") == "codex" else { return nil }
        let windows: [WindowSnapshot] = ["primary", "secondary"].compactMap { k in
            guard let w = rl[k] as? [String: Any],
                  let m = (w["window_minutes"] as? NSNumber)?.intValue,
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let end = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return WindowSnapshot(at: at, minutes: m, used: used, end: Date(timeIntervalSince1970: end))
        }
        return windows.max { $0.minutes < $1.minutes }
    }
}

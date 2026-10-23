import SwiftUI
import AppKit
import CodexyCore
import OrcyCore

@MainActor @Observable
final class AppModel {
    /// What Orca is doing now (`orca worktree ps`), every 10 s while Orca runs. nil before the first answer.
    var live: OrcaLive?
    var liveAt: Date?
    var liveError = ""
    var orcaRunning = true
    /// Every agent start and stop (orca-stats.json) and the tasks (orchestration.db), every minute.
    var runs: [AgentRun] = []
    var tasks: TaskSummary?
    var now = Date()
    /// Snapshots (dev aid) fill the model with made-up data: they must never notify or write anything.
    @ObservationIgnored var persist = true
    // MARK: alerts: an agent waits for you, a task finished
    var alertTick = 0                              // moves twice a second while an alert is on: drives the pulse and the confetti
    var celebrateUntil: Date?
    var previewWaitingUntil: Date?
    @ObservationIgnored private var prevWaiting: Set<String> = []
    @ObservationIgnored private var prevWorking: Set<String> = []
    @ObservationIgnored private var prevCompleted: Int?
    let scene: SceneModel

    private var timers: [Timer] = []

    init(seed: UInt64? = nil) {
        scene = SceneModel(seed: seed)
        if DevFlags.demo { loadDemo(); return }
        every(10) { [self] in refreshLive() }
        every(60) { [self] in refreshHistory() }
        every(1) { [self] in now = Date() }
        every(0.5) { [self] in if alertWaiting || alertCelebrating { alertTick += 1 } }
        every(600) { [self] in scene.refreshWeather() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refreshLive(force: true) } }
        }
        // Orca opening or quitting shows at once, not at the next tick.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == OrcaCLI.bundleId else { return }
                MainActor.assumeIsolated { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshLive(force: true) } }
            }
        }
        if Prefs.shared.alertsNotifyWaiting || Prefs.shared.alertsNotifyDone { Notifier.authorize() }
        refreshLive(force: true); refreshHistory()
    }

    private func every(_ s: TimeInterval, _ f: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in MainActor.assumeIsolated { f() } }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    static var orcaIsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: OrcaCLI.bundleId).isEmpty }

    @ObservationIgnored private var probing = false
    /// Asks Orca only while it runs: the CLI must never be what starts it. Each read starts the CLI twice (~0.3 s of
    /// CPU), so it runs every 10 s while something works or waits or the panel is open, and every 30 s when all is quiet.
    func refreshLive(force: Bool = false) {
        let busy = working > 0 || waiting > 0 || scene.isShown
        if !force, let at = liveAt, Date().timeIntervalSince(at) < (busy ? 9 : 29) { return }
        let old = Self.orcaIsRunning && (liveAt.map { Date().timeIntervalSince($0) > 60 } ?? false)
        if old != stale { stale = old }
        guard Self.orcaIsRunning else {
            orcaRunning = false; live = nil; liveError = ""
            scene.observe(model: self)
            return
        }
        orcaRunning = true
        guard !probing else { return }
        probing = true
        Task.detached {
            let r = OrcaCLI.live()
            await MainActor.run {
                self.probing = false
                switch r {
                case .ok(let l):
                    self.noticeChanges(l)
                    if l != self.live { self.live = l }
                    self.liveAt = l.at; self.liveError = ""; self.stale = false
                case .failed(let why): self.liveError = why
                }
                self.scene.observe(model: self)
            }
        }
    }

    func refreshHistory() {
        Task.detached(priority: .utility) {
            let runs = OrcaStatsFile.load(), tasks = OrcaDB.summary()
            await MainActor.run {
                if let c = tasks?.completedToday, let p = self.prevCompleted, c > p { self.celebrate() }
                self.prevCompleted = tasks?.completedToday
                self.runs = runs; self.tasks = tasks
            }
        }
    }

    /// A worktree whose agent starts waiting, or one that stops working: a notification (if asked for), and the mascot reacts.
    private func noticeChanges(_ l: OrcaLive) {
        let waiting = Set(l.worktrees.filter { $0.phase == .waiting }.map(\.id))
        let working = Set(l.worktrees.filter { $0.phase == .working }.map(\.id))
        defer { prevWaiting = waiting; prevWorking = working }
        guard live != nil, persist else { return }          // the first answer only sets the baseline
        let names = Dictionary(uniqueKeysWithValues: l.worktrees.map { ($0.id, $0.name) })
        if Prefs.shared.alertsNotifyWaiting, let id = waiting.subtracting(prevWaiting).first {
            Notifier.post(L.t("notify.waiting"), names[id] ?? "")
        }
        let finished = prevWorking.subtracting(working).subtracting(waiting)
        if Prefs.shared.alertsNotifyDone, let id = finished.first { Notifier.post(L.t("notify.done"), names[id] ?? "") }
    }

    // MARK: alerts
    var alertWaiting: Bool {
        guard Prefs.shared.alertsAnimate else { return false }
        return (live?.waiting ?? 0) > 0 || (previewWaitingUntil.map { $0 > now } ?? false)
    }
    var alertCelebrating: Bool { Prefs.shared.alertsAnimate && (celebrateUntil.map { $0 > now } ?? false) }

    /// A task finished: the mascot celebrates, the bar sparkles for a few seconds.
    func celebrate() {
        celebrateUntil = Date().addingTimeInterval(8)
        scene.clawd.celebrate()
    }

    /// Settings → "Preview": shows an alert for a few seconds without touching the real numbers.
    func previewAlert(waiting: Bool) {
        if waiting { previewWaitingUntil = Date().addingTimeInterval(8) } else { celebrate() }
    }

    // MARK: texts shared by the panel and the bar
    var working: Int { live?.working ?? 0 }
    var waiting: Int { live?.waiting ?? 0 }
    /// No answer for over a minute while Orca runs: the numbers on screen are old. Set with each read, not each
    /// second, so the menu bar picture is redrawn only when something changed.
    var stale = false

    /// "1 working · 3 open agents · 12 stopped", or why there is nothing.
    var headline: String {
        guard orcaRunning else { return L.t("orca.closed") }
        guard let l = live else { return liveError.isEmpty ? L.t("loading") : L.t("orca.noAnswer", liveError) }
        var parts = ["\(l.working) " + L.t("working")]
        if l.waiting > 0 { parts.append(L.count("waitingForYou", l.waiting)) }
        if l.agentsOpen > 0 { parts.append(L.count("wt.agents", l.agentsOpen)) }
        let stopped = l.count(.open) + l.count(.closed)
        if stopped > 0 { parts.append(L.count("wt.stopped", stopped)) }
        if l.worktrees.isEmpty { return L.t("nothing") }
        return parts.joined(separator: " · ") + (stale ? " · " + L.t("stale") : "")
    }

    /// Today, from the history files.
    var today: Activity { Activity.of(runs, from: Calendar.current.startOfDay(for: now), to: now, now: now) }
    var week: [(day: Date, activity: Activity)] { Activity.days(runs, count: 7, now: now) }

    /// "12 min", "3h 05m": how long something has been going.
    func since(_ d: Date?) -> String? {
        guard let d else { return nil }
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return L.t("justNow") }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    static func hours(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int(seconds / 60)) min" : String(format: "%.1f h", seconds / 3600)
    }

    /// The sky's hover text, in the chosen language.
    var skyTip: String {
        let s = scene
        let sun = s.skySim.weather.flatMap { w in w.sunrise.flatMap { a in w.sunset.map { (a, $0) } } }
            ?? s.lon.map { Wx.sunCalc(lat: s.skySim.lat, lon: $0) } ?? (420, 1140)
        let tip = Wx.skyTip(weather: s.skySim.weather, sun: sun)
        var lines: [String] = []
        if let w = tip.weather {
            var l = "\(tip.temp > 0 ? "+" : "")\(tip.temp)°, \(L.t("wx." + Wx.kind(w.code).id))"
            if let city = s.city, !city.isEmpty { l = "\(city) · " + l }
            lines += [l, L.t("tip.wind", tip.windMS)]
        } else { lines.append(L.t("tip.noWeather")) }
        lines.append(L.t("tip.sun", tip.sunrise, tip.sunset))
        lines.append(L.t("tip.moon", L.t("moon.\(tip.moonPhase)"), tip.moonLit))
        return lines.joined(separator: "\n")
    }

    // MARK: demo data (screenshots, ORCY_DEMO=1)
    private func loadDemo() {
        persist = false
        let t = Date()
        func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(s) }
        func agent(_ state: String, _ ago: TimeInterval) -> OrcaAgent { OrcaAgent(type: "codex", state: state, since: at(-ago)) }
        var ext = OrcaWorktree(id: "6", name: "export-csv", repo: "web-app", branch: "export-csv", liveTerminals: 1, lastOutput: at(-700), isMain: false, agents: [])
        ext.external = true; ext.agentNames = ["opencode"]
        live = OrcaLive(worktrees: [
            OrcaWorktree(id: "1", name: "api-login", repo: "web-app", branch: "fix-login", liveTerminals: 1, lastOutput: at(-40), isMain: false, agents: [agent("blocked", 300)]),
            OrcaWorktree(id: "2", name: "checkout", repo: "web-app", branch: "checkout-v2", liveTerminals: 1, lastOutput: at(-3), isMain: false, agents: [agent("working", 720)]),
            OrcaWorktree(id: "3", name: "search", repo: "web-app", branch: "search-index", liveTerminals: 2, lastOutput: at(-1), isMain: false, agents: [agent("working", 1500)]),
            OrcaWorktree(id: "4", name: "main", repo: "docs", branch: "main", liveTerminals: 1, lastOutput: at(-5400), isMain: true, agents: [agent("done", 5400)]),
            ext,
            OrcaWorktree(id: "5", name: "billing", repo: "web-app", branch: "billing", liveTerminals: 0, lastOutput: at(-90000), isMain: false, agents: []),
        ], at: t)
        liveAt = t
        var r: [AgentRun] = []
        for d in 0..<7 {
            for i in 0..<(6 + (d * 5) % 9) {
                let s = at(-Double(d) * 86400 - Double(i) * 2400 - 3600)
                r.append(AgentRun(start: s, end: s.addingTimeInterval(600 + Double(i % 4) * 300), worktreeId: "\(i % 4)"))
            }
        }
        r.append(AgentRun(start: at(-720), end: nil, worktreeId: "2")); r.append(AgentRun(start: at(-1500), end: nil, worktreeId: "3"))
        runs = r
        var s = TaskSummary(); s.byStatus = ["completed": 86, "failed": 3, "blocked": 1]; s.completedToday = 9; s.failedToday = 1
        s.dispatchesByState = ["succeeded": 86, "failed": 3]; s.questions = 12
        tasks = s
        scene.skySim.weather = Weather(code: 2, temp: 22, wind: 14, sunrise: 6 * 60 + 5, sunset: 18 * 60 + 40, at: t)
        scene.skySim.lat = -23.5; scene.lon = -46.6
        scene.observe(model: self)
    }
}

import SwiftUI
import CodexyCore

@MainActor @Observable
final class AppModel {
    var usage: Usage?
    var usageAt: Date?
    var usageFailed = false
    var usageError = ""
    /// Running Codex sessions (CodexSessions: open rollout files), every 5 s.
    var sessions: [AgentSession] = []
    var status: ServiceStatus?
    var statusFailed = false
    var codexVersion: String?
    var codexLatest: String?
    var history = UsageHistory.load()
    /// Snapshots (dev aid) fill the model with made-up data: they must never write it to the real history file.
    @ObservationIgnored var persist = true
    /// Projects, models and turns of the last 7 days, from Codex's rollout files. nil until the first scan.
    var projects: ProjectUsage?
    @ObservationIgnored private let scanner = RolloutScanner()
    @ObservationIgnored private var scanningProjects = false
    @ObservationIgnored private var scannedAt = Date.distantPast
    /// Resets used, counted from the rollout files and the live read (see ResetLog).
    var resets = ResetLog.load()
    @ObservationIgnored private var scanningResets = false
    @ObservationIgnored private var resetsScanned = false
    var now = Date()
    private var failStreak = 0
    // MARK: alerts: a session waits for you, a limit started over
    var alertTick = 0                              // moves twice a second while an alert is on: drives the pulse and the confetti
    var celebrateUntil: Date?
    var alertEarly = false                         // the reset came before its time
    var previewWaitingUntil: Date?
    @ObservationIgnored private var prevWaiting = 0
    let scene: SceneModel

    private var timers: [Timer] = []

    init(seed: UInt64? = nil) {
        scene = SceneModel(seed: seed)
        // Made-up data for screenshots (CODEXY_DEMO): no polling, so nothing real ever reaches the screen.
        if DevFlags.demo { loadDemo(); return }
        // The popover only exists while open, so polling lives here, not in a view.
        // Once a minute, every 20 s near a limit (the last percent points are the ones worth watching).
        every(20) { [self] in
            let hot = max(usage?.session?.percent ?? 0, usage?.week?.percent ?? 0) >= 90
            if hot || Date().timeIntervalSince(usageAt ?? .distantPast) >= 55 { refreshUsage() }
        }
        every(1) { [self] in now = Date() }
        every(5) { [self] in refreshSessions() }
        every(0.5) { [self] in if alertWaiting || alertCelebrating { alertTick += 1 } }
        every(600) { [self] in scene.refreshWeather() }
        every(900) { [self] in refreshProjects() }
        every(120) { [self] in refreshStatus() }
        every(6 * 3600) { [self] in refreshVersion() }
        every(3600) { [self] in refreshResets() }
        // After the Mac wakes up a probe that was running got no answer: ask again instead of waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refreshUsage(); self?.refreshStatus() } }
        }
        if Prefs.shared.alertsNotifyPace { Notifier.authorize() }     // on by default: ask once, at the first start
        refreshUsage(); refreshSessions(); refreshStatus(); refreshVersion(); refreshResets()
        // The floating widget comes back where it was left.
        if Prefs.shared.floatOpen, ProcessInfo.processInfo.environment["CODEXY_NO_FLOAT"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in FloatingWidget.shared.show(model: self, animated: false) }
        }
    }

    private func every(_ s: TimeInterval, _ f: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in MainActor.assumeIsolated { f() } }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private var probing = false
    func refreshUsage() {
        guard !probing else { return }
        probing = true
        Task.detached {
            let r = CodexCLI.fetchUsage()
            await MainActor.run {
                self.probing = false
                switch r {
                case .ok(let u):
                    if self.failStreak > 0 { Log.write("usage probe is back after \(self.failStreak) failed attempt(s)"); self.failStreak = 0 }
                    for e in ResetDetector.events(old: self.usage, new: u) { self.celebrate(e) }
                    self.usage = u; self.usageAt = Date(); self.usageFailed = false; self.usageError = ""
                    self.scene.observe(model: self)
                    self.checkPace()
                    if self.history.add(session: u.session?.percent, week: u.week?.percent), self.persist { self.history.save() }
                    // Live, a used reset shows at once; before the first scan the files' older windows would be skipped.
                    if self.resetsScanned, let s = u.snapshot {
                        var r = self.resets
                        r.observe(s)
                        if r != self.resets { self.resets = r; if self.persist { r.save() } }
                    }
                case .failed(let why):   // keep the last numbers, marked stale, and try again soon
                    self.failStreak += 1
                    self.usageFailed = true; self.usageError = why
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.refreshUsage() }
                }
            }
        }
    }

    private var scanning = false
    func refreshSessions() {
        guard !scanning else { return }
        scanning = true
        Task.detached {
            let s = CodexSessions.list()
            await MainActor.run {
                self.scanning = false
                if s != self.sessions { self.sessions = s; self.scene.observe(model: self); self.sessionsChanged() }
            }
        }
    }

    /// Sessions changed: a newly waiting one is worth a notification (if asked for).
    private func sessionsChanged() {
        let waiting = sessions.filter(\.waiting)
        defer { prevWaiting = waiting.count }
        guard waiting.count > prevWaiting, Prefs.shared.alertsNotifyWaiting, persist, let s = waiting.first else { return }
        let where_ = [Redact.name(s.git?.repo ?? s.name, "project"), s.git.map { Redact.name($0.branch, "branch") }].compactMap { $0 }.joined(separator: " · ")
        Notifier.post(L.t("notify.waiting"), where_)
    }

    /// `codex --version` and the newest GitHub release, every 6 hours.
    func refreshVersion() {
        Task {
            codexVersion = await Task.detached { CodexVersion.installed() }.value
            codexLatest = await CodexVersion.latest()
        }
    }

    /// "Codex 0.163.0", plus "· 0.170.0 available" when GitHub has a newer release.
    var versionText: String? {
        guard let v = codexVersion else { return nil }
        if let n = codexLatest, CodexVersion.isNewer(n, than: v) { return L.t("version.update", v, n) }
        return "Codex \(v)"
    }

    /// status.openai.com, every 2 minutes.
    func refreshStatus() {
        Task {
            let s = await StatusFetcher.fetch()
            statusFailed = s == nil
            if let s { status = s }
        }
    }

    /// Reads the rollout files of the last 7 days in the background. Only when the details are open: it is the costly part.
    func refreshProjects(force: Bool = false) {
        guard !DevFlags.demo, !scanningProjects,
              force || (UserDefaults.standard.bool(forKey: "detailsOpen") && Date().timeIntervalSince(scannedAt) > 600) else { return }
        scanningProjects = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let r = scanner.scan(since: Date().addingTimeInterval(-7 * 86400))
            await MainActor.run { self.projects = r; self.scannedAt = Date(); self.scanningProjects = false }
        }
    }

    /// Early resets from the rollout files changed since the last scan: all of them the first time (half a minute), then a few.
    func refreshResets() {
        guard !DevFlags.demo, !scanningResets else { return }
        scanningResets = true
        let log = resets
        Task.detached(priority: .utility) {
            var r = log
            r.scan()
            await MainActor.run {
                self.resets = r; self.resetsScanned = true; self.scanningResets = false
                if self.persist { r.save() }
            }
        }
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

    // MARK: alerts
    var alertWaiting: Bool {
        guard Prefs.shared.alertsAnimate else { return false }
        return sessions.contains(where: \.waiting) || (previewWaitingUntil.map { $0 > now } ?? false)
    }
    var alertCelebrating: Bool { Prefs.shared.alertsAnimate && (celebrateUntil.map { $0 > now } ?? false) }

    /// The forecast says the 5 h limit comes within the hour and before the reset: one notification per window.
    private func checkPace() {
        guard Prefs.shared.alertsNotifyPace, persist, let reset = usage?.session?.reset else { return }
        let key = "paceAlertedReset", last = UserDefaults.standard.double(forKey: key)
        let p = Pace.session(history, now: Date(), reset: reset)
        guard Pace.alertDue(p, now: Date(), reset: reset, lastReset: last > 0 ? Date(timeIntervalSince1970: last) : nil),
              case .hits(let at) = p else { return }
        UserDefaults.standard.set(reset.timeIntervalSince1970, forKey: key)
        Notifier.post(L.t("notify.pace", L.date("HH:mm").string(from: at)), L.t("notify.paceBody", L.date("HH:mm").string(from: reset)))
    }

    /// A limit started over: Clawd celebrates, the bar and the widget sparkle for a few seconds.
    func celebrate(_ e: ResetEvent, notify: Bool = true) {
        celebrateUntil = Date().addingTimeInterval(8); alertEarly = e.early
        scene.clawd.celebrate()
        guard notify, Prefs.shared.alertsNotifyReset else { return }
        let name = L.t(e.window == .session ? "notify.session" : "notify.week")
        Notifier.post(L.t(e.early ? "alert.resetEarly" : "alert.reset"), name)
    }

    /// Settings → "Preview": shows an alert for a few seconds without touching the real numbers.
    func previewAlert(waiting: Bool) {
        if waiting { previewWaitingUntil = Date().addingTimeInterval(8) }
        else { celebrate(ResetEvent(window: .session, early: false), notify: false) }
    }

    // MARK: demo data (screenshots)
    private func loadDemo() {
        persist = false
        let t = Date()
        func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(s) }
        usage = CodexLimits(limits: [CodexLimit(windowMinutes: 300, usedPercent: 42, resetsAt: at(2 * 3600 + 51 * 60)),
                                     CodexLimit(windowMinutes: 10080, usedPercent: 31, resetsAt: at(3 * 86400 + 4 * 3600))],
                            plan: "plus", source: .appServer, asOf: t,
                            resetCredits: ResetCredits(available: 1, nextExpiry: at(9 * 86400)))
        status = ServiceStatus(level: .ok, text: "", detail: [])
        switch ProcessInfo.processInfo.environment["CODEXY_DEMO_STATUS"] {         // a bad day, for screenshots
        case "others": status = ServiceStatus(level: .ok, text: "", detail: [], affected: [.init(name: "ChatGPT Work", status: "degraded_performance", important: false)])
        case "codex": status = ServiceStatus(level: .minor, text: "Elevated errors in Codex", detail: ["Elevated errors in Codex"],
                                             affected: [.init(name: "CLI", status: "degraded_performance", important: true)])
        default: break
        }
        usageAt = t
        if ProcessInfo.processInfo.environment["CODEXY_DEMO_FAIL"] != nil {     // the warning of a failing read, for screenshots
            usageAt = t.addingTimeInterval(-14 * 60); usageFailed = true; usageError = "timed out after 45 s"; failStreak = 3
        }
        // A week of the quota cycle: 5-hour windows that fill up and reset, the weekly share creeping up.
        var h = UsageHistory()
        let cycleStart = at(3 * 86400 + 4 * 3600 - 7 * 86400)
        var m = Int(t.timeIntervalSince(cycleStart) / 60)
        while m >= 0 {
            let when = t.addingTimeInterval(-Double(m) * 60)
            let hours = Double(Int(t.timeIntervalSince(when) / 60) % 1) + Double(m) / 60
            let active = Int(hours / 24) % 7 != 5 || hours.truncatingRemainder(dividingBy: 24) < 9      // a quiet Saturday afternoon
            if active {
                let win = (hours.truncatingRemainder(dividingBy: 5.3)) / 5.3
                let session = Int(min(96, win * (70 + Double(Int(hours / 5.3) % 4) * 8)))
                let week = Int(Double(31) * (1 - hours / (92)))
                h.add(session: session, week: max(0, week), now: when)
            }
            m -= 7
        }
        history = h
        sessions = [
            AgentSession(pid: 1, name: "web-app", cwd: "/demo/web-app", busy: true, waiting: false,
                         git: GitInfo(repo: "web-app", branch: "main", worktree: nil), thread: "demo-1"),
            AgentSession(pid: 2, name: "api", cwd: "/demo/api", busy: false, waiting: true,
                         git: GitInfo(repo: "api", branch: "fix-login", worktree: "api-fix"), thread: "demo-2"),
            AgentSession(pid: 2, name: "docs", cwd: "/demo/docs", busy: false, waiting: false,
                         git: GitInfo(repo: "docs", branch: "main", worktree: nil), thread: "demo-3"),
        ]
        let hr = Int(t.timeIntervalSince1970 / 3600)
        projects = ProjectUsage(hourly: [hr - 2: ["web-app": ["gpt-5.1-codex": 40, "gpt-5.1-codex-mini": 3], "docs": ["gpt-5.1-codex": 11]],
                                         hr - 30: ["web-app": ["gpt-5.1-codex": 10], "api-server": ["gpt-5.1-codex-max": 18]],
                                         hr - 50: ["api-server": ["gpt-5.1-codex": 10]]],
                                paths: ["web-app": "~/code/web-app", "api-server": "~/code/api-server", "docs": "~/code/docs"],
                                turns: [hr - 2: 14, hr - 30: 9, hr - 50: 5],
                                threads: ["a": hr - 2, "b": hr - 2, "c": hr - 30, "d": hr - 50])
        scene.skySim.weather = Weather(code: 2, temp: 22, wind: 14, sunrise: 6 * 60 + 5, sunset: 18 * 60 + 40, at: t)
        scene.skySim.lat = 38.7; scene.lon = -9.1
        scene.clock = Calendar.current.date(bySettingHour: Int(ProcessInfo.processInfo.environment["CODEXY_DEMO_HOUR"] ?? "") ?? 14,
                                            minute: 0, second: 0, of: t)
        scene.observe(model: self)
    }

    // MARK: texts shared by the panel and the floating widget
    /// The big number on top: the 5h limit, or the week when Codex reports no 5h window (Plus, today).
    var top: UsageLine? { usage?.session ?? usage?.week }
    var topIsWeek: Bool { usage?.session == nil && usage?.week != nil }
    var topPaceText: String? { topIsWeek ? weekPaceText : sessionPaceText }
    /// What the big number is, at the start of the line under it: "Left this week", "Left", "Week"; nothing for the 5h use.
    var topLabel: String? {
        if Prefs.shared.showLeft { return L.t(topIsWeek ? "left.week" : "left") }
        return topIsWeek ? L.t("week.line") : nil
    }
    /// "Left this week · resets in 6d 23h".
    var topLine: String { topLabel.map { $0 + " · " + resetText } ?? resetText }

    var resetText: String {
        guard let u = usage else { return usageFailed ? L.t("noDataWhy", usageError) : L.t("loading") }
        guard let s = u.session ?? u.week else { return L.t("noData") }
        let base: String
        if let r = s.reset, let span = Format.span(to: r, now: now) { base = L.t("resetsIn", span) }
        else { base = s.percent == 0 ? L.t("windowClosed") : L.t("resetsSoon") }
        return stale ? base + " · " + L.t("stale") : base
    }

    /// The straight-line forecast under the bar; nothing while there is too little to say (see Pace).
    var sessionPaceText: String? {
        paceText(Pace.session(history, now: now, reset: usage?.session?.reset), "HH:mm", "pace.session")
    }
    var weekPaceText: String? {
        guard let w = usage?.week else { return nil }
        return paceText(Pace.week(percent: w.percent, now: now, reset: w.reset), "EEE HH:mm", "pace.week")
    }
    private func paceText(_ p: Pace, _ format: String, _ key: String) -> String? {
        switch p {
        case .hits(let d): L.t(key + ".hits", L.date(format).string(from: d))
        case .safe: L.t(key + ".safe")
        case .unknown: nil
        }
    }

    func limitText(_ l: UsageLine?) -> String {
        guard let l else { return "" }
        let span = l.reset.flatMap { Format.span(to: $0, now: now) }
        let p = Prefs.shared
        let pct = "\(p.shown(l.percent))%" + (p.showLeft ? " " + L.t("left.word") : "")
        return span.map { "\(pct) · \($0)" } ?? pct
    }

    var sessionsText: String {
        if sessions.isEmpty { return L.t("none") }
        var t = L.count("session", sessions.count)
        let busy = sessions.filter(\.busy).count, wait = sessions.filter(\.waiting).count
        if busy > 0 { t += " · \(busy) \(L.t("working"))" }
        if wait > 0 { t += " · \(wait) \(L.t("waiting"))" }
        return t
    }

    /// Hover text of the bubble: the reset and the week.
    var bubbleTip: String { [resetText, "\(L.t("hist.week")) \(limitText(usage?.week))"].joined(separator: "\n") }

    /// Forget the saved samples (settings > System).
    func clearHistory() { history = UsageHistory(); history.save() }

    /// A warning only when it is real: two failed reads in a row, or no good read for 10 minutes. Quiet otherwise.
    var usageUnhealthy: Bool { failStreak >= 2 || (usageAt.map { now.timeIntervalSince($0) > 600 } ?? false) }

    /// "stale for 14 min · codex not found": what to tell the user, and why.
    var healthText: String? {
        guard usageUnhealthy else { return nil }
        let why: String
        switch usageError {
        case "codex not found": why = L.t("health.noCodex")
        case "could not start codex": why = L.t("health.start")
        case let e where e.hasPrefix("app-server gave no answer"): why = L.t("health.timeout")
        case "": why = L.t("health.old")
        default: why = L.t("health.output")
        }
        guard let at = usageAt, let span = Format.span(to: now, now: at) else { return why }
        return L.t("health.since", span) + " · " + why
    }

    var stale: Bool { usageFailed && usage != nil }

    /// "Plus · from the last session file": the plan, and a note when the numbers are not live.
    var planText: String? {
        guard let u = usage else { return nil }
        var parts = [u.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }].compactMap { $0 }
        if u.source == .sessionFile {
            let ago = u.asOf.flatMap { Format.span(to: now, now: $0) }
            parts.append(ago.map { L.t("source.fileAgo", $0) } ?? L.t("source.file"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

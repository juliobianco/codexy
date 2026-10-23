import SwiftUI
import AppKit
import CodexyCore
import OrcyCore

// The dropdown card: the orca and how many agents work, then the worktrees by what they do, today, the last 7 days.
struct PanelView: View {
    let model: AppModel
    @AppStorage("idleOpen") private var idleOpen = false
    @State private var contentHeight: CGFloat = 0
    private var prefs: Prefs { Prefs.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            hero
            Text(model.headline).font(.system(size: 12)).foregroundStyle(T.text2).padding(.top, 8)
            worktrees
            TodayCard(model: model).padding(.top, 12)
            if prefs.showDetails { WeekChart(model: model).padding(.top, 12) }
            footer.padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 12)
        .frame(width: 300)
        .background(T.bg)
        .background(ThemePattern(name: prefs.palette.pattern))
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .background(FitWindow(height: contentHeight))
        .preferredColorScheme(.dark)
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 0) {
            if model.alertWaiting || model.alertCelebrating { AlertBadge(model: model) }
            else { Text(L.t("app.title")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.muted) }
            Spacer()
            MoreMenu(model: model)
        }
    }

    private var hero: some View {
        HeroView(scene: model.scene, model: model)
            .help(prefs.showSky ? model.skyTip : "")
            // The menu bar keeps this view alive while the panel is closed: animate only while it is on screen.
            .background { if !DevFlags.offscreen { WindowVisibility { if $0 { model.scene.start(); model.refreshLive(force: true) } else { model.scene.stop() } } } }
    }

    // MARK: worktrees by what they do
    @ViewBuilder private var worktrees: some View {
        if let l = model.live {
            let all = l.sorted
            let waiting = all.filter { $0.phase == .waiting }, working = all.filter { $0.phase == .working }
            let agents = all.filter { $0.phase == .agent }
            let idle = all.filter { $0.phase == .open || $0.phase == .closed }
            if !waiting.isEmpty { section(L.t("sec.waiting"), "\(waiting.count)", T.warn) { rows(waiting) } }
            if !working.isEmpty { section(L.t("sec.working"), "\(working.count)", T.ok) { rows(working) } }
            if !agents.isEmpty { section(L.t("sec.agents"), "\(agents.count)", T.accent) { rows(agents) } }
            if prefs.showIdle, !idle.isEmpty {
                section(L.t("sec.idle"), "\(idle.count)", T.dim, toggle: true) { if idleOpen { rows(idle) } }
            }
        }
    }

    private func rows(_ list: [OrcaWorktree]) -> some View {
        VStack(spacing: 6) { ForEach(list) { WorktreeRow(w: $0, model: model, showRepo: (model.live?.repos.count ?? 0) > 1) } }
    }

    private func section<C: View>(_ title: String, _ count: String, _ color: Color, toggle: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if toggle { idleOpen.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    Text(count).font(.system(size: 10, weight: .semibold)).foregroundStyle(T.dim)
                    Spacer()
                    if toggle { Text(idleOpen ? "▴" : "▾").font(.system(size: 10)).foregroundStyle(T.muted) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!toggle)
            content()
        }
        .padding(.top, 11)
    }

    // MARK: footer
    private var footer: some View {
        HStack {
            Button { Self.openOrca() } label: {
                Label(L.t("orca.open"), systemImage: "arrow.up.forward.app").font(.system(size: 10.5)).foregroundStyle(T.muted)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(model.liveAt.map { Self.clock.string(from: $0) } ?? "").font(.system(size: 10)).foregroundStyle(model.stale ? T.warn : T.faint)
        }
    }

    static func openOrca() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OrcaCLI.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

// MARK: one worktree: name, branch, what its agent does and for how long
struct WorktreeRow: View {
    let w: OrcaWorktree
    let model: AppModel
    var showRepo = false         // more than one repo: say which one

    var body: some View {
        Button { PanelView.openOrca() } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Redact.name(w.name, "worktree")).font(.system(size: 12, weight: .medium)).foregroundStyle(T.text2).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(state).font(.system(size: 10.5)).foregroundStyle(color)
                    if let t = model.since(when) { Text(t).font(.system(size: 10)).foregroundStyle(T.dim).monospacedDigit() }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([w.path.isEmpty ? nil : w.path, w.external ? L.t("wt.external") : nil, L.t("orca.open")].compactMap { $0 }.joined(separator: "\n"))
    }

    /// The agent that sets the phase, if any.
    private var agent: OrcaAgent? {
        switch w.phase {
        case .waiting: w.agents.first { $0.phase == .waiting }
        case .working: w.agents.first { $0.phase == .working }
        default: w.agents.first
        }
    }
    /// Since when the worktree is in this phase: the agent's state, else the last terminal output.
    private var when: Date? { (w.phase == .waiting || w.phase == .working) ? (agent?.since ?? w.lastOutput) : w.lastOutput }

    // "web-app · claude + codex": the repo when there are several, who runs there, then the branch when it says
    // more than the name (last, so a long branch is what gets cut).
    private var detail: String {
        var parts: [String] = []
        if showRepo, !w.repo.isEmpty { parts.append(Redact.name(w.repo, "repo")) }
        if !w.agentNames.isEmpty, w.phase != .closed { parts.append(w.agentNames.joined(separator: " + ")) }
        let name = (w.name as NSString).lastPathComponent
        if !w.branch.isEmpty, !w.branch.hasSuffix(name), !(w.isMain && showRepo && w.branch == "main") { parts.append(Redact.name(w.branch, "branch")) }
        if w.phase == .closed { parts.append(L.t("wt.noTerminal")) }
        return parts.isEmpty ? Redact.name(w.branch.isEmpty ? w.repo : w.branch, "branch") : parts.joined(separator: " · ")
    }
    private var color: Color {
        switch w.phase { case .waiting: T.warn; case .working: T.ok; case .agent: T.accent; case .open: T.muted; case .closed: T.off }
    }
    private var state: String {
        switch w.phase {
        case .waiting: L.t("waitingForYou")
        case .working: agent == nil && w.agentNames.isEmpty ? L.t("wt.output") : L.t("working")
        case .agent: L.t("wt.agentOpen")
        case .open: L.t("wt.quiet")
        case .closed: L.t("wt.closedOne")
        }
    }
}

// MARK: today: tasks done and failed, agents and their hours
struct TodayCard: View {
    let model: AppModel

    var body: some View {
        let a = model.today, t = model.tasks
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sun.max.fill").font(.system(size: 11))
                Text(L.t("today")).font(.system(size: 10, weight: .semibold))
                Spacer()
                if let r = t?.successRate { Text(L.t("today.success", Int((r * 100).rounded()))).font(.system(size: 10)).foregroundStyle(T.muted) }
            }
            .foregroundStyle(T.accent)
            HStack(spacing: 8) {
                tile(t.map { "\($0.completedToday)" } ?? "–", L.t("today.done"), T.ok)
                tile(t.map { "\($0.failedToday)" } ?? "–", L.t("today.failed"), (t?.failedToday ?? 0) > 0 ? T.crit : T.muted)
            }
            HStack(spacing: 8) {
                tile("\(a.started)", L.t("today.agents"), T.textHi)
                tile(AppModel.hours(a.seconds), L.t("today.hours"), T.textHi)
            }
            if let d = detail(a, t) { Text(d).font(.system(size: 10)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(T.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.accent.opacity(0.3), lineWidth: 1))
        .help(L.t("today.tip"))
    }

    /// "3 at once at most · 2 blocked · 4 questions": only what is there.
    private func detail(_ a: Activity, _ t: TaskSummary?) -> String? {
        var parts: [String] = []
        if a.peak > 1 { parts.append(L.t("today.peak", a.peak)) }
        if let b = t?.blocked, b > 0 { parts.append(L.count("blocked", b)) }
        if let q = t?.openQuestions, q > 0 { parts.append(L.count("question", q)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .light)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(T.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))
    }
}

// MARK: the last 7 days: agents started per day, the hours over each bar
struct WeekChart: View {
    let model: AppModel

    var body: some View {
        let days = model.week
        let peak = max(1, days.map(\.activity.started).max() ?? 1)
        let total = days.reduce(Activity()) { var s = $0; s.started += $1.activity.started; s.seconds += $1.activity.seconds; return s }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L.t("week.title")).font(.system(size: 10, weight: .semibold)).foregroundStyle(T.dim)
                Spacer()
                Text(L.t("week.total", total.started, AppModel.hours(total.seconds))).font(.system(size: 10)).foregroundStyle(T.muted)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let today = i == days.count - 1
                    VStack(spacing: 3) {
                        Text(d.activity.started > 0 ? "\(d.activity.started)" : "").font(.system(size: 9)).foregroundStyle(T.muted).monospacedDigit()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(today ? T.accent : T.accent.opacity(0.45))
                            .frame(height: max(2, 46 * CGFloat(d.activity.started) / CGFloat(peak)))
                        Text(L.date("EEE").string(from: d.day).replacingOccurrences(of: ".", with: "")).font(.system(size: 9, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? T.text2 : T.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .help(L.t("week.dayTip", L.date("EEE d").string(from: d.day), d.activity.started, AppModel.hours(d.activity.seconds)))
                }
            }
            .frame(height: 74, alignment: .bottom)
        }
    }
}

// MARK: the "⋯" menu
struct MoreMenu: View {
    let model: AppModel
    @State private var login = LoginItem.isOn
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if DevFlags.offscreen { Text("⋯").font(.system(size: 13, weight: .bold)).foregroundStyle(T.muted) } else { menu }
    }

    private var menu: some View {
        Menu {
            Button(L.t("menu.refresh")) { model.refreshLive(force: true); model.refreshHistory() }
            Button(L.t("orca.open")) { PanelView.openOrca() }
            Button(L.t("menu.settings")) { SettingsWindow.open(openWindow) }
            Toggle(L.t("menu.launch"), isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.isOn }))
            Divider()
            Button(L.t("menu.quit")) { NSApp.terminate(nil) }
        } label: {
            Text("⋯").font(.system(size: 13, weight: .bold)).foregroundStyle(T.muted)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onAppear { login = LoginItem.isOn }
    }
}

// MARK: is the panel on screen
/// Reports when the hosting window becomes visible or hidden (ordered out, covered), once per change.
struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { let v = Watcher(); v.changed = changed; return v }
    func updateNSView(_ v: Watcher, context: Context) { v.changed = changed }

    final class Watcher: NSView {
        var changed: ((Bool) -> Void)?
        private var token: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let t = token { NotificationCenter.default.removeObserver(t); token = nil }
            guard let w = window else { report(false); return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(w.occlusionState.contains(.visible)) }
            }
            report(w.occlusionState.contains(.visible))
        }

        private func report(_ on: Bool) {
            guard on != last else { return }
            last = on
            changed?(on)
        }
    }
}

// MARK: the menu bar window follows the content
// MenuBarExtra keeps the window at the largest size it has had: after collapsing a section the card
// floated in the middle of an empty frame. This sets the window to the content's height, top edge fixed.
struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FitWindow: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FitView { FitView() }
    func updateNSView(_ v: FitView, context: Context) { v.height = height; v.apply() }

    final class FitView: NSView {
        var height: CGFloat = 0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        func apply() {
            // After the layout pass: the window may not be attached yet on the first call.
            DispatchQueue.main.async { [self] in
                guard height > 0, let w = window else { return }
                var f = w.frame
                let chrome = f.height - w.contentRect(forFrameRect: f).height
                let newH = height + chrome
                guard abs(f.height - newH) > 0.5 else { return }
                f.origin.y += f.height - newH          // keep the top edge where it is
                f.size.height = newH
                w.setFrame(f, display: true, animate: false)
            }
        }
    }
}

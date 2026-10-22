import SwiftUI
import AppKit
import CodexyCore

// OpenAI's status (Codex only) and the credits Codex reports: the words for the model, and the two panel rows.

extension AppModel {
    var statusColor: Color {
        switch status?.level {
        case .ok: T.ok; case .minor: T.warn; case .major: T.crit; default: T.dim
        }
    }

    var statusText: String {
        guard let s = status else { return statusFailed ? L.t("status.offline") : L.t("status.loading") }
        if s.onlyOthersAffected { return L.t("status.others") }
        switch s.level {
        case .ok: return L.t("status.ok")
        case .unknown: return L.t("status.unknown")
        default: return s.text.isEmpty ? L.t(s.level == .major ? "status.major" : "status.minor") : s.text
        }
    }

    /// Lines under the status: the other open Codex incidents, then each Codex component that is off, in our words.
    var statusDetail: [String] {
        guard let s = status else { return [] }
        return s.detail.filter { $0 != s.text } + s.affected.filter(\.important).map { "\($0.name): \(Self.componentWord($0.status))" }
    }

    /// Hover text: every component that is off, Codex or not.
    var statusTip: String {
        let off = status?.affected.map { "\($0.name): \(Self.componentWord($0.status))" } ?? []
        return ([L.t("status.open")] + off).joined(separator: "\n")
    }

    static func componentWord(_ status: String) -> String {
        let k = "status.c." + status
        let w = L.t(k)
        return w == k ? status.replacingOccurrences(of: "_", with: " ") : w
    }

    /// "125.5 credits": paid credits only (reset credits have their own row), nil when there is nothing.
    var creditsText: String? {
        guard let c = usage?.credits, c.worthShowing else { return nil }
        return c.unlimited ? L.t("credits.unlimited") : L.t("credits.balance", c.balance ?? "?")
    }

    /// What Codex says is left (live read only) and the early resets counted so far; nil while unknown.
    var resetsAvailable: Int? { usage?.resetCredits?.available }
    var resetsUsed: Int? { resets.since == nil ? nil : resets.used.count }

    /// "5 in the last 7 days · last Oct 21, 13:10 · next expires in 3d 2h": nil when there is nothing to add.
    var resetsDetail: String? {
        var parts: [String] = []
        let week = resets.count(since: now.addingTimeInterval(-7 * 86400))
        if week > 0 { parts.append(L.t("resets.week", week)) }
        if let d = resets.last { parts.append(L.t("resets.last", L.date(L.t("resets.date")).string(from: d))) }
        if let e = usage?.resetCredits?.nextExpiry, let span = Format.span(to: e, now: now) { parts.append(L.t("resetCredit.expires", span)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var resetsTip: String { L.t("resets.tip", resets.since.map { L.date(L.t("resets.date")).string(from: $0) } ?? "–") }
}

/// Dot + headline + Codex details; a click opens status.openai.com.
struct StatusRow: View {
    let model: AppModel

    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: StatusFetcher.pageURL)!) } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 7, height: 7).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.statusText).font(.system(size: 12)).foregroundStyle(T.muted)
                    ForEach(model.statusDetail, id: \.self) {
                        Text($0).font(.system(size: 10.5)).foregroundStyle(T.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(model.statusTip)
    }
}

extension AppModel {
    /// The limit Codex says was reached, then one line per extra bucket: "gpt-5-codex-spark: 5h 12% · week 3%".
    var extraLimitLines: [String] {
        guard let u = usage else { return [] }
        var out: [String] = []
        if let r = u.reachedType { out.append(L.t("limit.reached", r.replacingOccurrences(of: "_", with: " "))) }
        for e in u.extras {
            let p = Prefs.shared
            let parts = [e.session.map { "5h \(p.shown($0.percent))%" }, e.week.map { "\(L.t("hist.week")) \(p.shown($0.percent))%" }].compactMap { $0 }
            out.append("\(e.name): " + parts.joined(separator: " · "))
        }
        return out
    }
}

/// Reached limit and extra buckets under the week row. Hidden when Codex reports none.
struct ExtraLimitsLine: View {
    let model: AppModel

    var body: some View {
        ForEach(model.extraLimitLines, id: \.self) {
            Text($0).font(.system(size: 11)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// Reset credits and paid credits, under the week row. Hidden when Codex reports none.
/// Reset credits, in a card of their own: how many Codex says are left, how many were used (see ResetLog).
/// Hidden until either is known.
struct ResetsLine: View {
    let model: AppModel

    var body: some View {
        if model.resetsAvailable != nil || model.resetsUsed != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 11))
                    Text(L.t("resets")).font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(T.purple)
                HStack(spacing: 8) {
                    // Available is green when there is one to use; used is the purple of the card.
                    tile(model.resetsAvailable, "resets.available", color: (model.resetsAvailable ?? 0) > 0 ? T.ok : T.muted)
                    tile(model.resetsUsed, "resets.used", color: T.purple)
                }
                if let d = model.resetsDetail {
                    Text(d).font(.system(size: 10)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(T.purple.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.purple.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
            .help(model.resetsTip)
        }
    }

    /// A big number over its word; "…" while it is still being counted.
    private func tile(_ n: Int?, _ key: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n.map(String.init) ?? "…").font(.system(size: 26, weight: .light)).monospacedDigit().foregroundStyle(color)
            Text(n.map { L.word(key, $0) } ?? L.t("resets.counting")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(T.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))
    }
}

struct CreditsLine: View {
    let model: AppModel

    var body: some View {
        if let t = model.creditsText {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 10))
                Text(t).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(T.muted)
            .help(L.t("credits.tip"))
        }
    }
}

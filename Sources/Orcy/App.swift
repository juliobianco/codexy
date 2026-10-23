import SwiftUI
import AppKit
import CodexyCore
import OrcyCore

@main
struct OrcyApp: App {
    @State private var model = AppModel()

    init() {
        // One copy only: a second launch of the same bundle quits at once.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { exit(0) }
        // `Orcy --snapshot DIR`: render the panel and the bar label to PNGs (for checking the look), then quit.
        let a = CommandLine.arguments
        if a.contains(where: { ["--snapshot", "--scenes", "--settings", "--readme", "--pets"].contains($0) }) { DevFlags.offscreen = true }
        if let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count {
            Snapshot.schedule(dir: a[i + 1])
        }
        if let i = a.firstIndex(of: "--readme"), i + 1 < a.count {
            let d = a[i + 1]
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.readme(dir: d) } }
        }
        if let i = a.firstIndex(of: "--settings"), i + 1 < a.count {
            let d = a[i + 1]
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.settings(dir: d) } }
        }
        if let i = a.firstIndex(of: "--icon"), i + 1 < a.count {
            let d = a[i + 1]
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.icon(dir: d) } }
        }
        if let i = a.firstIndex(of: "--pets"), i + 1 < a.count {
            let d = a[i + 1]
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.pets(dir: d) } }
        }
        if let i = a.firstIndex(of: "--scenes"), i + 1 < a.count {
            let d = a[i + 1]
            DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.scenes(dir: d) } }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window(L.t("set.title"), id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Closed state: the little orca, then ▶ agents working and ? agents waiting for you (blinking).
/// MenuBarExtra drops custom shapes, so the label is rendered to a bitmap.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // The bitmap is drawn by an ImageRenderer, outside this view's tracking: touch what it uses, so a change redraws the label.
        _ = (Prefs.shared.pet, model.working, model.waiting, model.alertTick, model.orcaRunning, model.stale)
        return Image(nsImage: render())
    }

    @MainActor private func render() -> NSImage {
        let r = ImageRenderer(content: BarLabel(model: model))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = false
        return img
    }
}

struct BarLabel: View {
    let model: AppModel

    var body: some View {
        let on = model.alertTick % 2 == 0
        HStack(spacing: 4) {
            PetGlyph(pet: Pets.current()).opacity(model.orcaRunning ? 1 : 0.4)
            if model.waiting > 0 {
                Text("?\(model.waiting)").font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.black.opacity(0.85))
                    .fixedSize().padding(.horizontal, 4).frame(height: 13)
                    .background(Capsule().fill(T.warn))
                    .opacity(model.alertWaiting && !on ? 0.35 : 1)
            }
            if model.working > 0 {
                Text("▶\(model.working)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(T.ok).fixedSize()
            }
        }
        .opacity(model.stale ? 0.55 : 1)
        .overlay { if model.alertCelebrating { Confetti(tick: model.alertTick) } }
        .padding(.horizontal, 1)
        .frame(height: 18)
    }
}

/// The mascot's normal face, one point a pixel: 18 x 12.
struct PetGlyph: View {
    let pet: Pet?

    var body: some View {
        Canvas { ctx, _ in
            guard let pet else { return }
            for (c, rects) in pet.pixels("normal", frame: ClawdFrame()) {
                var p = Path()
                for q in rects { p.addRect(CGRect(x: q.x, y: q.y, width: q.w, height: q.h)) }
                ctx.fill(p, with: .color(Color(hexString: c)))
            }
        }
        .frame(width: 18, height: 12)
    }
}

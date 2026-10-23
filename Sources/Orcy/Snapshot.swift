import SwiftUI
import AppKit
import CodexyCore
import OrcyCore

/// Dev aid: renders the views offscreen, so the look can be checked without screen-recording permission.
@MainActor
enum Snapshot {
    static func schedule(dir: String) {
        let model = AppModel()
        model.persist = false
        if let sk = skinFromEnv() { model.scene.skinOverride = sk }
        if let la = ProcessInfo.processInfo.environment["ORCY_LAT"].flatMap(Double.init),
           let lo = ProcessInfo.processInfo.environment["ORCY_LON"].flatMap(Double.init) {
            model.scene.skySim.lat = la; model.scene.lon = lo; model.scene.refreshWeather(force: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            model.scene.warmup(Int(ProcessInfo.processInfo.environment["ORCY_TICKS"] ?? "") ?? 60)
            write(PanelView(model: model).environment(\.colorScheme, .dark), "\(dir)/panel.png")
            write(BarLabel(model: model).padding(8).background(Color(white: 0.15)), "\(dir)/bar.png")
            exit(0)
        }
    }

    /// `--scenes DIR`: Clawd and the sky in a handful of situations, one PNG each.
    static func scenes(dir: String, thenExit: Bool = true) {
        func at(_ h: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())! }
        struct S { var name: String; var hour: Int; var wx: Int?; var busy = 0, waiting = 0, sessions = 1, pct = 20; var click = false; var ticks = 120 }
        let list = [
            S(name: "day-clear-work", hour: 13, wx: 0, busy: 1), S(name: "day-rain-idle", hour: 14, wx: 63),
            S(name: "dusk-wait", hour: 18, wx: 2, waiting: 1), S(name: "night-snow", hour: 22, wx: 73),
            S(name: "storm-crit", hour: 15, wx: 95, busy: 1, pct: 92), S(name: "sleep", hour: 23, sessions: 0, ticks: 80),
            S(name: "dead", hour: 12, wx: 0, pct: 100), S(name: "fog-dawn", hour: 6, wx: 45),
        ]
        var models: [(String, SceneModel)] = []
        for sc in list {
            let m = SceneModel()
            m.skySim.lat = -23.55; m.lon = -46.63
            m.skinOverride = skinFromEnv()
            m.clock = at(sc.hour)
            m.skySim.forceWeather = sc.wx
            var i = MascotInput(); i.sessions = sc.sessions; i.busy = sc.busy; i.waiting = sc.waiting; i.sessionPct = sc.pct
            m.clawd.observe(i)
            m.size = CGSize(width: 272, height: 56)
            m.warmup(sc.ticks)
            models.append((sc.name, m))
        }
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(models.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(models[i].0).font(.system(size: 9)).foregroundStyle(T.muted)
                    SceneCanvas(scene: models[i].1).frame(width: 272, height: 56)
                }
            }
        }.padding(10).background(T.bg)
        write(sheet, "\(dir)/sheet.png")
        if thenExit { exit(0) }
    }

    /// `--pets DIR`: pets.png, every mascot in each mood, big enough to judge the pixels.
    static func pets(dir: String) {
        let moods = ["normal", "slack", "crit", "sleep", "walk1", "walk2", "sit"]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Pets.all(), id: \.id) { p in
                HStack(spacing: 10) {
                    Text(p.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.text2).frame(width: 70, alignment: .leading)
                    ForEach(moods.filter { !["walk1", "walk2", "sit"].contains($0) || p.art[$0] != nil }, id: \.self) { m in
                        VStack(spacing: 2) {
                            PetPreview(pet: p, mood: m, pose: ["walk1", "walk2", "sit"].contains(m) ? m : nil).frame(width: 64, height: 40).scaleEffect(1.6).frame(width: 100, height: 64)
                            Text(m).font(.system(size: 9)).foregroundStyle(T.muted)
                        }
                    }
                }
            }
        }.padding(14).background(T.bg)
        write(sheet, "\(dir)/pets.png")
        exit(0)
    }

    /// `--settings DIR`: every tab of the settings window as a PNG.
    static func settings(dir: String) {
        let model = AppModel(); model.persist = false
        if let l = ProcessInfo.processInfo.environment["ORCY_LANG"] { Prefs.shared.language = l }
        for tab in ["look", "bar", "system"] {
            write(SettingsView(model: model, tab: tab, scrolls: false), "\(dir)/settings-\(tab).png")
        }
        exit(0)
    }

    /// `--readme DIR` (with ORCY_DEMO=1): the pictures of the README: the panel, the bar, every settings tab, the mascot in a few situations.
    static func readme(dir: String) {
        DevFlags.offscreen = true
        let model = AppModel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            model.scene.warmup(90)
            write(PanelView(model: model).environment(\.colorScheme, .dark), "\(dir)/panel.png")
            write(BarLabel(model: model).padding(8).background(Color(white: 0.15)), "\(dir)/bar.png")
            for tab in ["look", "bar", "system"] {
                write(SettingsView(model: model, tab: tab, scrolls: false), "\(dir)/settings-\(tab).png")
            }
            scenes(dir: dir, thenExit: false)
            exit(0)
        }
    }

    /// `--icon DIR`: AppIcon.iconset/*.png for `iconutil -c icns` (see scripts/make-icon.sh).
    static func icon(dir: String) {
        let set = "\(dir)/AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                           ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            let view = IconView().frame(width: 1024, height: 1024).scaleEffect(CGFloat(px) / 1024).frame(width: CGFloat(px), height: CGFloat(px))
            let r = ImageRenderer(content: view); r.scale = 1
            guard let img = r.cgImage else { continue }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
        }
        exit(0)
    }

    /// ORCY_SKIN=<id> previews a skin (built in or from the user folder) without touching the saved choice.
    private static func skinFromEnv() -> Skin? {
        guard let id = ProcessInfo.processInfo.environment["ORCY_SKIN"]?.lowercased() else { return nil }
        return Skins.all().first { $0.id == id }
    }

    private static func write<V: View>(_ v: V, _ path: String) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        guard let img = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}


/// The app icon: the orca over a night sea.
struct IconView: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let card = Path(roundedRect: CGRect(x: w * 0.06, y: w * 0.06, width: w * 0.88, height: w * 0.88), cornerRadius: w * 0.2)
            ctx.fill(card, with: .linearGradient(Gradient(colors: [Color(hex: 0x2B2B33), Color(hex: 0x141416)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: w)))
            for (x, y, r) in [(0.22, 0.24, 0.012), (0.78, 0.2, 0.016), (0.68, 0.34, 0.01), (0.3, 0.38, 0.01), (0.86, 0.46, 0.012)] {
                ctx.fill(Path(ellipseIn: CGRect(x: w * x, y: w * y, width: w * r * 2, height: w * r * 2)), with: .color(.white.opacity(0.7)))
            }
            guard let orca = Pets.all().first(where: { $0.id == "orca" }) else { return }
            let u = w * 0.66 / 18                       // one pixel
            let ox = (w - 18 * u) / 2, oy = w * 0.5 - 6 * u * 1.1
            for (c, rects) in orca.pixels("normal", frame: ClawdFrame()) {
                var p = Path()
                for q in rects { p.addRect(CGRect(x: ox + q.x * u, y: oy + q.y * u * 1.1, width: q.w * u, height: q.h * u * 1.1)) }
                ctx.fill(p, with: .color(Color(hexString: c)))
            }
            ctx.fill(Path(CGRect(x: w * 0.2, y: oy + 12 * u * 1.1 + u * 0.4, width: w * 0.6, height: u * 0.5)), with: .color(Color(hex: 0x38BDF8).opacity(0.45)))
        }
    }
}

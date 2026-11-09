import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Uses the shipping MiniView with an in-memory fixture; no duplicate symbol layout.
struct DemoMini: View {
    let model: ScreenshotModel
    let windowOpacity: Double
    init(remaining: Double, baseline: Double, time: Double, durationMinutes: Double, unit: DotUnit,
         selection: Int? = nil, windowOpacity: Double = 1, provider: String = "codex", scope: String? = nil, hud: Bool = false) {
        let model = ScreenshotModel()
        model.configureSymbol(provider: provider, scope: scope, remaining: remaining, baseline: baseline,
            durationMinutes: durationMinutes, unit: unit,
            index: selection ?? DotScale.defaultIndex(unit: unit, durationMinutes: durationMinutes),
            opacity: windowOpacity, time: time)
        model.miniHUD = hud
        self.model = model; self.windowOpacity = windowOpacity
    }
    var body: some View { MiniView(model: model).opacity(windowOpacity) }
}

struct DemoFrame: View {
    let time: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Usage Gauge").font(.system(size: 27, weight: .medium)).foregroundStyle(FlightDeck.ink)
            Text("Remaining quota relative to the next reset").font(.system(size: 12)).foregroundStyle(FlightDeck.muted).padding(.top, 5)
            HStack(spacing: 28) {
                example("Session", detail: "On pace", remaining: 50, baseline: 50 + 0.4 * cos(time), durationMinutes: 300, unit: .time)
                example("Weekly", detail: "Ahead of budget", remaining: 44, baseline: 50 - time / 20, durationMinutes: 10080, unit: .time, provider: "claude")
                example("Fable", detail: "Model-scoped quota", remaining: 53, baseline: 50 - time / 20, durationMinutes: 10080, unit: .percentagePoints, provider: "claude", scope: "Fable")
            }.padding(.top, 22).frame(maxWidth: .infinity)
            Text("SYNTHETIC DATA  ·  Minutes, hours, or pp  ·  Motion accelerated")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(FlightDeck.muted).padding(.top, 18)
        }.padding(26).frame(width: 600, height: 330, alignment: .topLeading)
            .background(FlightDeck.screen).environment(\.colorScheme, .dark)
    }
    private func example(_ title: String, detail: String, remaining: Double, baseline: Double, durationMinutes: Double, unit: DotUnit, provider: String = "codex", scope: String? = nil) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(FlightDeck.ink)
            DemoMini(remaining: remaining, baseline: baseline, time: time, durationMinutes: durationMinutes, unit: unit, provider: provider, scope: scope)
            Text(detail).font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
        }.frame(maxWidth: .infinity)
    }
}

enum DemoScene: String, CaseIterable {
    case overview = "demo", scales, warning, opacity, validity = "data-validity", reserve = "low-reserve"
    var title: String {
        switch self {
        case .overview: return "Usage Gauge"
        case .scales: return "Time or percentage points"
        case .warning: return "Budget warning"
        case .opacity: return "Dragging and opacity"
        case .validity: return "Data validity"
        case .reserve: return "Low reserve, in numbers"
        }
    }
}

struct FeatureFrame: View {
    let scene: DemoScene
    let time: Double
    private var step: Int { min(2, Int(time / 3.2)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(scene.title).font(.system(size: 27, weight: .medium)).foregroundStyle(FlightDeck.ink)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(FlightDeck.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            Group {
                switch scene {
                case .scales: scales
                case .warning: warning
                case .opacity: desktop
                case .validity: validity
                case .reserve: reserve
                case .overview: EmptyView()
                }
            }.frame(height: scene == .validity ? 270 : 206).padding(.top, 22)
        }.padding(26).frame(width: 600, height: scene == .validity ? 450 : 390, alignment: .topLeading)
            .background(FlightDeck.screen)
            .overlay(alignment: .bottomLeading) {
                Text("SYNTHETIC DATA  ·  Rendered feature demonstration")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(FlightDeck.muted).padding(26)
            }.environment(\.colorScheme, .dark)
    }
    private var subtitle: String {
        switch scene {
        case .scales: return "Scroll over the scale, or click to select an interval"
        case .warning: return "The reference rises as consumption gets ahead of the linear budget"
        case .opacity: return "Drag the instrument or its label · Adjust opacity beside the limit name"
        case .validity: return "N/A and static hatching distinguish missing data from a real zero"
        case .reserve: return "Below 10%, symbol modes show the percentage beneath the remaining bar"
        case .overview: return ""
        }
    }
    private var scales: some View {
        HStack(spacing: 28) {
            scaleExample("Session", duration: 300, unit: .time, choices: "5 → 10 → 15 minutes")
            scaleExample("Weekly", duration: 10080, unit: .time, choices: "2HR · 4HR · 8HR\n1DAY · 2DAY · 4DAY")
            scaleExample("pp mode", duration: 10080, unit: .percentagePoints, choices: "1 → 2 → 5 pp")
        }
    }
    private var validity: some View {
        let states: [DataCondition] = [.loading, .authentication, .noLimits, .unavailable, .stale, .resetPending, .invalid, .idle, .live]
        let condition = states[min(states.count - 1, Int(time / 1.6))]
        let numeric = ScreenshotModel.validityFixture(condition: condition, provider: "codex")
        let hud = ScreenshotModel.validityFixture(condition: condition, provider: "codex")
        numeric.stepIndex = 4; hud.stepIndex = 4; hud.miniHUD = true; hud.miniSymbols = true
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 36) {
                MiniView(model: numeric).frame(width: 320, height: 228)
                MiniView(model: hud).frame(width: 110, height: 148)
            }.frame(maxWidth: .infinity)
            Text(condition.token + " / " + condition.detail).font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                .lineLimit(2).frame(height: 26, alignment: .topLeading)
        }
    }
    private var reserve: some View {
        HStack(spacing: 28) {
            reserveExample("Normal", values: [10, 9.9, 8.7], duration: 300, selection: 0, hud: false, note: "REM → 9% → 8%")
            reserveExample("HUD · Below 1%", values: [1.1, 0.9, 0.4], duration: 10080, selection: 2, hud: true, note: "Positive reserve: <1%")
            reserveExample("HUD · Actual zero", values: [1, 0.4, 0], duration: 10080, selection: 5, hud: true, note: "Only a real zero: 0%")
        }
    }
    private func reserveExample(_ title: String, values: [Double], duration: Double, selection: Int, hud: Bool, note: String) -> some View {
        let remaining = values[step]
        return VStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(FlightDeck.ink)
            // Keep a current window even at zero; the label, rather than pace warning, is the subject.
            DemoMini(remaining: remaining, baseline: remaining + 0.1, time: time, durationMinutes: duration,
                     unit: .time, selection: selection, hud: hud)
            Text(note).font(.system(size: 9)).foregroundStyle(FlightDeck.muted)
        }.frame(maxWidth: .infinity)
    }
    private func scaleExample(_ name: String, duration: Double, unit: DotUnit, choices: String) -> some View {
        let weeklyTime = duration > 300 && unit == .time
        let selected = weeklyTime ? min(5, Int(time / 1.6)) : step
        return VStack(spacing: 8) {
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(FlightDeck.ink)
            DemoMini(remaining: 48, baseline: 50, time: time, durationMinutes: duration, unit: unit, selection: selected, provider: duration == 300 ? "codex" : "claude", scope: unit == .percentagePoints ? "Fable" : nil)
            Text(choices).font(.system(size: 10)).foregroundStyle(FlightDeck.muted).multilineTextAlignment(.center).frame(height: 26)
        }.frame(maxWidth: .infinity)
    }
    private var warning: some View {
        let remaining = 54 - 10 * min(1, time / 6.4)
        let baseline = 50 - time / 40
        let scale = DotScale(unit: .time, durationMinutes: 10080, index: 1)
        let deviation = UsageDeviation(remaining: remaining, baseline: baseline, pointsPerDot: scale.pointsPerDot)
        return HStack(spacing: 34) {
            DemoMini(remaining: remaining, baseline: baseline, time: time, durationMinutes: 10080, unit: .time, provider: "claude")
                .scaleEffect(1.2).frame(width: 170, height: 190)
            VStack(alignment: .leading, spacing: 12) {
                Text(deviation.warning ? "Upper limit" : (deviation.difference ?? 0) > 0 ? "Ahead of budget" : "Reserve")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(deviation.warning ? FlightDeck.alert : FlightDeck.ink)
                Text(deviation.warning ? "Red ↔ service color\n0.8 seconds per color\nNo fading" : "Fixed center diamond\nMoving reference bar\nAbsolute quota on the right")
                    .font(.system(size: 14)).foregroundStyle(FlightDeck.muted).lineSpacing(7)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var desktop: some View {
        let opacity = 0.65 + 0.35 * cos(time / 9.6 * 2 * Double.pi)
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.14, green: 0.17, blue: 0.20))
                VStack(alignment: .leading, spacing: 11) {
                    Text("Example desktop").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    ForEach(0..<6, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.10))
                            .frame(width: row % 2 == 0 ? 360 : 250, height: 8)
                    }
                }.padding(20)
                DemoMini(remaining: 52, baseline: 50, time: time, durationMinutes: 10080, unit: .time, windowOpacity: opacity, provider: "claude")
                    .position(x: 75 + (geometry.size.width - 150) * (0.5 - 0.5 * cos(time / 9.6 * 2 * Double.pi)), y: geometry.size.height / 2)
                Text("\(Int((opacity * 100).rounded()))% opacity").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlightDeck.ink).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }.clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

@main struct GenerateDemo {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/demo.gif").deletingLastPathComponent()
        for scene in DemoScene.allCases {
            try render(scene: scene, output: directory.appendingPathComponent(scene.rawValue + ".gif"))
        }
    }
    @MainActor private static func render(scene: DemoScene, output: URL) throws {
        let count = scene == .validity ? 72 : 48
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            fatalError("Unable to create GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<count {
            let time = Double(frame) * 0.2
            let content = scene == .overview ? AnyView(DemoFrame(time: time)) : AnyView(FeatureFrame(scene: scene, time: time))
            let size = NSSize(width: 600, height: scene == .overview ? 330 : scene == .validity ? 450 : 390)
            let image = DocumentationRenderer.image(content, size: size)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            if frame == 0 || frame == 32 {
                let previews = output.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/demo-previews")
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                let png = scene == .overview && frame == 0 ? output.deletingPathExtension().appendingPathExtension("png") : previews.appendingPathComponent("\(scene.rawValue)-\(frame).png")
                let still = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(still, image, nil)
                guard CGImageDestinationFinalize(still) else { fatalError("Unable to save demo PNG") }
            }
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save GIF") }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        print("Generated \(count) synthetic frames, \(attributes[.size] ?? 0) bytes: \(output.lastPathComponent)")
    }
}

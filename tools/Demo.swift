import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Offline documentation rendering. No UsageModel, collectors, preferences, or account files.
struct DemoMini: View {
    let remaining: Double
    let baseline: Double
    let time: Double
    let durationMinutes: Double
    let unit: DotUnit
    var selection: Int? = nil
    var windowOpacity: Double = 1
    var provider = "codex"
    private var accent: Color { provider == "claude" ? FlightDeck.amber : FlightDeck.cyan }
    private var scale: DotScale { DotScale(unit: unit, durationMinutes: durationMinutes, index: selection ?? DotScale.defaultIndex(unit: unit, durationMinutes: durationMinutes)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 8))
                Text(provider.capitalized).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").font(.system(size: 10))
            }.frame(height: 20)
            HStack(spacing: 2) {
                Text(durationMinutes == 300 ? "Session" : "Weekly").font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
                Spacer(minLength: 0)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.5)).frame(height: 2)
                        Circle().fill(FlightDeck.ink).frame(width: 7, height: 7)
                            .offset(x: (geometry.size.width - 7) * (windowOpacity - 0.3) / 0.7)
                    }.frame(height: geometry.size.height)
                }.frame(width: 36)
            }.frame(height: 14)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 3) {
                    VerticalComparison(remaining: remaining, baseline: baseline, scale: scale, color: accent, sampleTime: time).frame(height: 70)
                    Text(scale.caption).font(.system(size: 8, design: .monospaced)).foregroundStyle(FlightDeck.muted).frame(height: 10)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    RemainingBar(remaining: remaining, color: accent)
                    Image(systemName: "battery.0percent").font(.system(size: 9)).foregroundStyle(FlightDeck.muted).frame(height: 10)
                }.frame(width: 12)
                ResetBar(progress: baseline, expired: false, color: accent)
            }.frame(height: 84)
        }.padding(8).frame(width: 110, height: 148, alignment: .topLeading)
            .background(FlightDeck.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .foregroundStyle(FlightDeck.ink).preferredColorScheme(.dark).opacity(windowOpacity)
    }
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
                example("pp mode", detail: "Reserve", remaining: 53, baseline: 50 - time / 20, durationMinutes: 10080, unit: .percentagePoints)
            }.padding(.top, 22).frame(maxWidth: .infinity)
            Text("SYNTHETIC DATA  ·  Minutes, hours, or pp  ·  Motion accelerated")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(FlightDeck.muted).padding(.top, 18)
        }.padding(26).frame(width: 600, height: 330, alignment: .topLeading)
            .background(FlightDeck.screen).environment(\.colorScheme, .dark)
    }
    private func example(_ title: String, detail: String, remaining: Double, baseline: Double, durationMinutes: Double, unit: DotUnit, provider: String = "codex") -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(FlightDeck.ink)
            DemoMini(remaining: remaining, baseline: baseline, time: time, durationMinutes: durationMinutes, unit: unit, provider: provider)
            Text(detail).font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
        }.frame(maxWidth: .infinity)
    }
}

enum DemoScene: String, CaseIterable {
    case overview = "demo", scales, warning, opacity
    var title: String {
        switch self {
        case .overview: return "Usage Gauge"
        case .scales: return "Time or percentage points"
        case .warning: return "Budget warning"
        case .opacity: return "Dragging and opacity"
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
                case .overview: EmptyView()
                }
            }.frame(height: 206).padding(.top, 22)
        }.padding(26).frame(width: 600, height: 390, alignment: .topLeading)
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
        case .overview: return ""
        }
    }
    private var scales: some View {
        HStack(spacing: 28) {
            scaleExample("Session", duration: 300, unit: .time, choices: "5 → 10 → 15 minutes")
            scaleExample("Weekly", duration: 10080, unit: .time, choices: "2 → 4 → 8 hours")
            scaleExample("pp mode", duration: 10080, unit: .percentagePoints, choices: "1 → 2 → 5 pp")
        }
    }
    private func scaleExample(_ name: String, duration: Double, unit: DotUnit, choices: String) -> some View {
        VStack(spacing: 8) {
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(FlightDeck.ink)
            DemoMini(remaining: 48, baseline: 50, time: time, durationMinutes: duration, unit: unit, selection: step)
            Text(choices).font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
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
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/demo.gif").deletingLastPathComponent()
        for scene in DemoScene.allCases {
            try render(scene: scene, output: directory.appendingPathComponent(scene.rawValue + ".gif"))
        }
    }
    @MainActor private static func render(scene: DemoScene, output: URL) throws {
        let count = 48
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            fatalError("Unable to create GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<count {
            let time = Double(frame) * 0.2
            let content = scene == .overview ? AnyView(DemoFrame(time: time)) : AnyView(FeatureFrame(scene: scene, time: time))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Unable to render demo frame") }
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

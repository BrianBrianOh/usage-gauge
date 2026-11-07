import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Offline documentation rendering. No UsageModel, collectors, preferences, or account files.
struct DemoMini: View {
    let remaining: Double
    let baseline: Double
    let time: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 8))
                Text("Codex").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").font(.system(size: 10))
            }.frame(height: 20)
            Text("Weekly").font(.system(size: 10)).foregroundStyle(FlightDeck.muted).frame(height: 14)
            HStack(spacing: 6) {
                VerticalComparison(remaining: remaining, baseline: baseline, color: FlightDeck.cyan, sampleTime: time)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 4) {
                    RemainingBar(remaining: remaining, color: FlightDeck.cyan)
                    Image(systemName: "battery.0percent").font(.system(size: 9)).foregroundStyle(FlightDeck.muted).frame(height: 10)
                }.frame(width: 12)
                ResetBar(progress: baseline, expired: false, color: FlightDeck.cyan)
            }.frame(height: 80)
        }.padding(8).frame(width: 110, height: 148, alignment: .topLeading)
            .background(FlightDeck.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .foregroundStyle(FlightDeck.ink).preferredColorScheme(.dark)
    }
}

struct DemoFrame: View {
    let time: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Usage Gauge").font(.system(size: 27, weight: .medium)).foregroundStyle(FlightDeck.ink)
            Text("Remaining quota relative to the next reset").font(.system(size: 12)).foregroundStyle(FlightDeck.muted).padding(.top, 5)
            HStack(spacing: 28) {
                example("On pace", detail: "Bar near center", remaining: 50, baseline: 50 + 0.4 * cos(time))
                example("Below baseline", detail: "Reference above you", remaining: 44, baseline: 50 - time / 20)
                example("Reserve", detail: "Reference below you", remaining: 53, baseline: 50 - time / 20)
            }.padding(.top, 22).frame(maxWidth: .infinity)
            Text("SYNTHETIC DATA  ·  2 pp per dot  ·  Motion accelerated")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(FlightDeck.muted).padding(.top, 18)
        }.padding(26).frame(width: 600, height: 330, alignment: .topLeading)
            .background(FlightDeck.screen).environment(\.colorScheme, .dark)
    }
    private func example(_ title: String, detail: String, remaining: Double, baseline: Double) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(FlightDeck.ink)
            DemoMini(remaining: remaining, baseline: baseline, time: time)
            Text(detail).font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
        }.frame(maxWidth: .infinity)
    }
}

@main struct GenerateDemo {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/demo.gif")
        let count = 40
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            fatalError("Unable to create GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<count {
            let renderer = ImageRenderer(content: DemoFrame(time: Double(frame) * 0.2))
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Unable to render demo frame") }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            if frame == 0 {
                let png = output.deletingLastPathComponent().appendingPathComponent("demo.png")
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

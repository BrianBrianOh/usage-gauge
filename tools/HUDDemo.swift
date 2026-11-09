import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Synthetic desktop pixels are passed through the shipping ink atlas and contrast mask.
/// The HUD itself is rendered from MiniView; no accounts or screen capture are used.
private struct HUDDemoBackground: View {
    let time: Double
    static let size = NSSize(width: 548, height: 244)
    var body: some View {
        let paperX = -248 + 796 * (0.5 - 0.5 * cos(time / 16 * 2 * .pi))
        ZStack(alignment: .topLeading) {
            Color(red: 0.045, green: 0.075, blue: 0.09)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<10, id: \.self) { row in
                    Rectangle().fill(.white.opacity(0.06)).frame(width: row % 2 == 0 ? 480 : 356, height: 1)
                }
            }.padding(18)
            ZStack(alignment: .topLeading) {
                Color(red: 0.94, green: 0.95, blue: 0.93)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<10, id: \.self) { row in
                        Rectangle().fill(.black.opacity(0.11)).frame(width: row % 3 == 0 ? 178 : 210, height: 2)
                    }
                }.padding(18)
            }.frame(width: 248, height: Self.size.height).offset(x: paperX)
        }.frame(width: Self.size.width, height: Self.size.height).clipped()
    }
}

private struct HUDDemoFrame: View {
    let background: CGImage
    let numeric: CGImage
    let symbols: CGImage
    let time: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transparent HUD").font(.system(size: 27, weight: .medium)).foregroundStyle(FlightDeck.ink)
            Text("Green instruments that adapt to the screen beneath them")
                .font(.system(size: 12)).foregroundStyle(FlightDeck.muted).padding(.top, 5)
            ZStack(alignment: .topLeading) {
                Image(decorative: background, scale: 2).interpolation(.none)
                Image(decorative: numeric, scale: 2).interpolation(.none).offset(x: 4, y: 8)
                Image(decorative: symbols, scale: 2).interpolation(.none).offset(x: 414, y: 48)
            }.frame(width: 548, height: 244).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 22)
            HStack {
                Text(time >= 10 && time < 14.4 ? "WARNING: HOLLOW ↔ HIDDEN" : time >= 3.2 && time < 6.4 ? "CONTROLS ON HOVER" : "ONE GREEN TONE PER LETTER, SYMBOL OR BAR")
                Spacer()
                Text("SYNTHETIC DATA")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(FlightDeck.muted).padding(.top, 18)
        }.padding(26).frame(width: 600, height: 410, alignment: .topLeading)
            .background(FlightDeck.screen).environment(\.colorScheme, .dark)
    }
}

@main struct GenerateHUDDemo {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        HUDContrastMask.selfTest()
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/hud.gif")
        let previews = output.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/hud-previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let count = 80
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            fatalError("Unable to create HUD GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var numericMask = HUDContrastMask(), symbolMask = HUDContrastMask()
        var sawBright = false, sawDark = false, sawWarningOn = false, sawWarningOff = false
        for frame in 0..<count {
            let time = Double(frame) * 0.2
            let background = DocumentationRenderer.image(HUDDemoBackground(time: time), size: HUDDemoBackground.size)
            let numeric = instrument(symbols: false, time: time, background: background, origin: CGPoint(x: 4, y: 8), mask: &numericMask)
            let symbols = instrument(symbols: true, time: time, background: background, origin: CGPoint(x: 414, y: 48), mask: &symbolMask)
            sawBright = sawBright || numericMask.decisions.contains(0)
            sawDark = sawDark || numericMask.decisions.contains(1)
            if time >= 10 && time < 14.4 {
                sawWarningOff = sawWarningOff || WarningFlash.isRed(at: time)
                sawWarningOn = sawWarningOn || !WarningFlash.isRed(at: time)
            }
            let image = DocumentationRenderer.image(HUDDemoFrame(background: background, numeric: numeric, symbols: symbols, time: time), size: NSSize(width: 600, height: 410))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            if [0, 20, 40, 52, 56, 60, 72].contains(frame) {
                DocumentationRenderer.png(image, output: previews.appendingPathComponent("hud-\(frame).png"))
            }
            if frame % 20 == 0 { print("Rendered HUD frame \(frame + 1)/\(count)"); fflush(stdout) }
        }
        precondition(sawBright && sawDark && sawWarningOn && sawWarningOff, "HUD demo must show both green tones and both warning phases")
        guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save HUD GIF") }
        print("Generated \(count) synthetic HUD frames: \(output.lastPathComponent)")
    }

    @MainActor private static func instrument(symbols: Bool, time: Double, background: CGImage, origin: CGPoint, mask: inout HUDContrastMask) -> CGImage {
        let model = ScreenshotModel(), provider = symbols ? "claude" : "codex"
        let other = symbols ? model.snapshot : model.claudeSnapshot
        let warning = time >= 10 && time < 14.4
        model.configureSymbol(provider: provider, scope: nil, remaining: 50,
            baseline: warning ? (symbols ? 55.5 : 54.5) : 50 + 0.3 * sin(time),
            durationMinutes: symbols ? 10080 : 300, unit: .time, index: symbols ? 1 : 0, opacity: 1, time: time)
        if symbols { model.snapshot = other } else { model.claudeSnapshot = other }
        model.miniHUD = true; model.miniSymbols = symbols; model.renderHUDControls = time >= 3.2 && time < 6.4
        let size = MiniLayout.size(symbols: symbols)
        let original = DocumentationRenderer.image(MiniView(model: model), size: size)
        let atlas = HUDInkAtlas.make(bitmap: NSBitmapImageRep(cgImage: original), pointSize: size, units: model.hudContrastUnits)
        let bar = model.hudContrastUnits.first { $0.id == "usage-bar" }!.rect
        for fraction in [0.25, 0.5, 0.75] {
            let tick = model.hudContrastUnits.first { $0.id == "remaining-tick-\(fraction)" }!.rect
            precondition(abs(tick.midY - (bar.minY + bar.height * (1 - fraction))) < 0.001,
                         "Shared ticks must align with the bars' exact quarter positions")
        }
        let crop = background.cropping(to: CGRect(x: origin.x * 2, y: origin.y * 2, width: size.width * 2, height: size.height * 2))!
        var bgra = HUDContrastMask.rgba(crop)!
        for pixel in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(pixel, pixel + 2) }
        bgra.withUnsafeBufferPointer { pixels in
            _ = mask.updateInkBGRA(pixels.baseAddress!, width: crop.width, height: crop.height, bytesPerRow: crop.width * 4, atlas: atlas)
        }
        model.miniAutoContrast = true; model.hudContrastMap = mask.image(pointSize: size)
        return DocumentationRenderer.image(MiniView(model: model), size: size)
    }
}

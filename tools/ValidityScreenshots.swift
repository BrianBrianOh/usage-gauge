import AppKit
import SwiftUI

/// Review every validity state without touching account files or the installed app.
@main struct ValidityScreenshots {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DataAvailability.selfTest(); HUDContrastMask.selfTest()
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/validity-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var total = 0
        for provider in ["codex", "claude"] {
            for condition in DataCondition.allCases {
                for mode in ["full", "numeric", "symbols", "hud-numeric", "hud-symbols"] {
                    let model = ScreenshotModel.validityFixture(condition: condition, provider: provider)
                    model.miniHUD = mode.hasPrefix("hud-"); model.miniSymbols = mode.hasSuffix("symbols")
                    model.stepIndex = 4
                    let actual = model.availability(now: Date().timeIntervalSince1970).condition
                    precondition(actual == condition, "Fixture state mismatch: \(condition) became \(actual)")
                    let size = mode == "full" ? NSSize(width: 560, height: 780) : MiniLayout.size(symbols: model.miniSymbols)
                    let view = mode == "full" ? AnyView(GaugeView(model: model)) : AnyView(MiniView(model: model))
                    let image = DocumentationRenderer.image(view, size: size)
                    if mode != "full" {
                        let ids = Set(model.hudContrastUnits.map(\.id))
                        if !condition.permitsReference {
                            precondition(!ids.contains("pace-diamond") && !ids.contains("pace-reference"), "Inhibited data must not show a pace indication")
                            precondition(ids.contains("pace-na"), "Inhibited data needs an explicit N/A flag")
                        }
                        if !condition.permitsObservation {
                            precondition(ids.contains("data-flag"), "Missing measurements need a reason flag")
                            if !model.miniSymbols {
                                precondition(model.hudContrastUnits.first { $0.id == "metric-value-Remaining" }?.text?.value == "N/A", "Missing measurements must say N/A")
                            }
                        }
                        let bar = model.hudContrastUnits.first { $0.id == "usage-bar" }!.rect
                        for fraction in [0.25, 0.5, 0.75] {
                            let tick = model.hudContrastUnits.first { $0.id == "remaining-tick-\(fraction)" }!.rect
                            precondition(abs(tick.midY - (bar.minY + bar.height * (1 - fraction))) < 0.001)
                        }
                        if model.miniHUD {
                            let atlas = HUDInkAtlas.make(bitmap: NSBitmapImageRep(cgImage: image), pointSize: size, units: model.hudContrastUnits)
                            precondition(atlas.units.contains { $0.id == "usage-bar" })
                            // Every stroke of each hatch/bar receives one tone, including N/A states.
                            let bgra = [UInt8](repeating: 255, count: atlas.width * atlas.height * 4)
                            var mask = HUDContrastMask()
                            bgra.withUnsafeBufferPointer { _ = mask.updateInkBGRA($0.baseAddress!, width: atlas.width, height: atlas.height, bytesPerRow: atlas.width * 4, atlas: atlas) }
                            for unit in atlas.units {
                                precondition(unit.pixels.allSatisfy { mask.decisions[$0] == 1 }, "Light background must give every complete ink entity a dark green tone")
                            }
                        }
                    }
                    DocumentationRenderer.png(image, output: output.appendingPathComponent("\(provider)-\(condition.rawValue)-\(mode).png"))
                    total += 1
                }
                print("Verified \(provider) / \(condition.rawValue)"); fflush(stdout)
            }
        }
        // A real empty/full meter must retain its number rather than being treated as absent.
        for remaining in [0.0, 100.0] {
            let model = ScreenshotModel()
            model.configureSymbol(provider: "codex", scope: nil, remaining: remaining, baseline: 50,
                                  durationMinutes: 300, unit: .time, index: 0, opacity: 1, time: 0)
            model.miniHUD = true
            precondition(model.availability(now: Date().timeIntervalSince1970).condition == .live)
            let image = DocumentationRenderer.image(MiniView(model: model), size: MiniLayout.symbolSize)
            precondition(model.hudContrastUnits.contains { $0.id == "pace-diamond" })
            DocumentationRenderer.png(image, output: output.appendingPathComponent("codex-real-\(Int(remaining))-symbols.png"))
        }
        print("PASS: \(total) state/layout combinations, real zero/full, inhibited indications, quarter ticks and HUD contrast")
    }


}

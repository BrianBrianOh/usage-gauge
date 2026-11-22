import AppKit
import SwiftUI

/// Regression for native Menu padding leaving the last WEEK/SESS glyph partly bright.
/// Renders the shipping view off screen with synthetic data; no screen access is used.
@main struct CheckHUDLabels {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for provider in ["codex", "claude"] {
            for symbols in [true, false] {
                for weekly in [true, false] {
                    let model = ScreenshotModel()
                    model.provider = provider; model.miniHUD = true; model.miniSymbols = symbols
                    let suffix = provider == "codex" ? (weekly ? "secondary" : "primary") : (weekly ? "seven_day" : "five_hour")
                    model.selectedID = provider + ":" + suffix
                    let size = MiniLayout.size(symbols: symbols)
                    let image = DocumentationRenderer.image(MiniView(model: model), size: size)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let atlas = HUDInkAtlas.make(bitmap: bitmap, pointSize: size, units: model.hudContrastUnits)
                    let label = model.hudContrastUnits.first { $0.id == "limit" }!
                    let glyphs = atlas.units.filter { $0.id.hasPrefix("limit:") }
                    precondition(glyphs.count == 4, "All four title glyphs need contrast coverage")
                    let covered = Set(glyphs.flatMap(\.outputPixels))
                    let sampled = Set(glyphs.flatMap(\.pixels))
                    let sy = CGFloat(bitmap.pixelsHigh) / size.height
                    let top = max(0, Int(floor(label.rect.minY * sy)))
                    let bottom = min(bitmap.pixelsHigh, Int(ceil(label.rect.maxY * sy)))
                    var ink: [Int] = []
                    // Scan the entire title row, independently of the computed character cells.
                    // Checking only pixels inside those cells would miss the original regression.
                    for y in top..<bottom {
                        for x in 0..<bitmap.pixelsWide where bitmap.bitmapData![y * bitmap.bytesPerRow + x * 4 + 3] >= 48 {
                            let pixel = y * bitmap.pixelsWide + x
                            precondition(covered.contains(pixel), "Visible title ink is outside its color region")
                            precondition(sampled.contains(pixel), "Visible title ink is missing from background sampling")
                            ink.append(pixel)
                        }
                    }
                    precondition(!ink.isEmpty)
                    let name = "\(provider)-\(symbols ? "symbols" : "numeric")-\(label.text!.value)"
                    var mask = HUDContrastMask()
                    for (background, dark) in [(UInt8(255), true), (UInt8(0), false), (UInt8(255), true)] {
                        let pixels = [UInt8](repeating: background, count: atlas.width * atlas.height * 4)
                        pixels.withUnsafeBufferPointer {
                            precondition(mask.updateInkBGRA($0.baseAddress!, width: atlas.width, height: atlas.height,
                                bytesPerRow: atlas.width * 4, atlas: atlas))
                        }
                        precondition(ink.allSatisfy { mask.decisions[$0] == (dark ? 1 : 0) },
                            "Every title pixel must switch on the same frame, including the fourth glyph")
                        model.miniAutoContrast = true; model.hudContrastMap = mask.image(pointSize: size)
                        let preview = DocumentationRenderer.image(ZStack {
                            (dark ? Color.white : Color.black)
                            MiniView(model: model)
                        }, size: size)
                        DocumentationRenderer.png(preview, output: output.appendingPathComponent("\(name)-\(dark ? "white" : "black").png"))
                    }
                    print("PASS: \(name), \(ink.count) title pixels sampled and colored, white/black/white")
                }
            }
        }
    }
}

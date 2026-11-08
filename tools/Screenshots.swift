import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct GenerateScreenshots {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for provider in ["codex", "claude"] {
            let model = ScreenshotModel()
            model.miniHUD = CommandLine.arguments.contains("--hud")
            let prefix = model.miniHUD ? "hud-" : ""
            model.provider = provider
            model.selectedID = provider == "codex" ? "codex:primary" : "claude:seven_day"
            model.miniDotIndex = DotScale.defaultIndex(unit: .time, durationMinutes: model.quota!.durationMinutes)
            if !CommandLine.arguments.contains("--mini-only") && !model.miniHUD {
                try render(GaugeView(model: model), size: NSSize(width: 560, height: 780),
                           output: output.appendingPathComponent("full-\(provider).png"))
            }
            try render(MiniView(model: model), size: MiniLayout.size(symbols: false),
                       output: output.appendingPathComponent("\(prefix)mini-\(provider).png"))
            model.miniSymbols = true
            try render(MiniView(model: model), size: MiniLayout.size(symbols: true),
                       output: output.appendingPathComponent("\(prefix)symbols-\(provider).png"))
            if provider == "claude" {
                for (id, filename) in [("claude:five_hour", "symbols-claude-session.png"), ("claude:fable", "symbols-claude-fable.png")] {
                    model.selectedID = id
                    model.miniDotIndex = DotScale.defaultIndex(unit: .time, durationMinutes: model.quota!.durationMinutes)
                    try render(MiniView(model: model), size: MiniLayout.size(symbols: true),
                               output: output.appendingPathComponent(prefix + filename))
                }
            }
        }
    }

    @MainActor private static func render<Content: View>(_ content: Content, size: NSSize, output: URL) throws {
        let image = DocumentationRenderer.image(content, size: size)
        DocumentationRenderer.png(image, output: output)
        print("Rendered synthetic \(output.lastPathComponent): \(image.width) × \(image.height)")
    }
}

import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Compile-time replacement for UsageModel in documentation builds only.
/// Every value is synthetic. No file loading, UserDefaults, account calls, or timers.
@MainActor final class ScreenshotModel: ObservableObject {
    @Published var provider = "codex"
    @Published var snapshot = Snapshot()
    @Published var claudeSnapshot = Snapshot()
    @Published var selectedID = "codex:primary"
    @Published var selectedDate: Date?
    @Published var spanIndex = 4
    @Published var stepIndex = 0
    @Published var interval = 120
    @Published var alwaysOnTop = false
    @Published var miniMode = false
    @Published var miniOnTop = true
    @Published var miniSymbols = false
    @Published var miniOpacity = 1.0
    @Published var miniDotUnit = DotUnit.time
    @Published var miniDotIndex = 0
    var onChange: (() -> Void)?
    var onMoveMini: ((MiniCorner) -> Void)?
    var activeSnapshot: Snapshot { provider == "claude" ? claudeSnapshot : snapshot }
    var quota: Quota? { activeSnapshot.windows.first { $0.id == selectedID } ?? activeSnapshot.windows.first }
    var headline: Quota? { quota }
    var displayStep: Double { GaugeScale.steps[stepIndex] }
    var miniDotScale: DotScale { DotScale(unit: miniDotUnit, durationMinutes: quota?.durationMinutes ?? 300, index: miniDotIndex) }
    var accent: Color { provider == "claude" ? FlightDeck.amber : FlightDeck.cyan }
    var error: String? { nil }
    var isRefreshing: Bool { false }
    var sourceLabel: String { provider == "claude" ? "Claude Code" : "Account" }
    func start() { fatalError("Collectors are disabled in screenshot builds") }
    func refresh() { fatalError("Collectors are disabled in screenshot builds") }
    func refreshAll() { fatalError("Collectors are disabled in screenshot builds") }
    func connectClaude() { fatalError("Sign-in is disabled in screenshot builds") }
    func stop() {}

    init() {
        let now = Date().timeIntervalSince1970
        snapshot.windows = Self.windows(provider: "codex", now: now)
        claudeSnapshot.windows = Self.windows(provider: "claude", now: now)
        snapshot.fetchedAt = now
        claudeSnapshot.fetchedAt = now
        claudeSnapshot.source = "Claude Code"
        claudeSnapshot.extra = ExtraUsage(enabled: false)
        claudeSnapshot.breakdown = [UsageShare(name: "Sonnet", percent: 72), UsageShare(name: "Opus", percent: 28)]
    }

    private static func windows(provider: String, now: Double) -> [Quota] {
        [300.0, 10080.0].map { duration in
            let weekly = duration > 300
            let total = duration * 60
            let reset = now + total * (weekly ? 0.58 : 0.46)
            let start = reset - total
            let remaining = weekly ? 62.0 : 54.0
            let points = (0...96).map { index -> Sample in
                let fraction = Double(index) / 96
                // A deterministic, monotone staircase with quieter and busier stretches.
                let consumed = (100 - remaining) * (fraction + 0.035 * sin(fraction * 6 * .pi))
                let value = index == 96 ? remaining : 100 - floor(consumed * 2) / 2
                return Sample(t: start + (now - start) * fraction, remaining: value)
            }
            let suffix = provider == "codex" ? (weekly ? "secondary" : "primary") : (weekly ? "seven_day" : "five_hour")
            return Quota(id: provider + ":" + suffix, name: provider, durationMinutes: duration,
                         resetAt: reset, remaining: remaining, observedAt: now, points: points)
        }
    }
}

/// The real views, hosted off screen, including native rotary controls.
/// This renders owned view contents; it never captures the desktop or the installed app.
private final class ScreenshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

@main struct GenerateScreenshots {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for provider in ["codex", "claude"] {
            let model = ScreenshotModel()
            model.provider = provider
            model.selectedID = provider == "codex" ? "codex:primary" : "claude:seven_day"
            try render(GaugeView(model: model), size: NSSize(width: 560, height: 780),
                       output: output.appendingPathComponent("full-\(provider).png"))
            try render(MiniView(model: model), size: MiniLayout.size(symbols: false),
                       output: output.appendingPathComponent("mini-\(provider).png"))
        }
    }

    @MainActor private static func render<Content: View>(_ content: Content, size: NSSize, output: URL) throws {
        let host = NSHostingView(rootView: content.environment(\.displayScale, 2))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = ScreenshotWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        // SwiftUI/AppKit need a layout turn, but the window is never ordered on screen.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.layoutSubtreeIfNeeded()
        window.display()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Unable to allocate screenshot")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Unable to create screenshot")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save screenshot") }
        window.close()
        print("Rendered synthetic \(output.lastPathComponent): \(image.width) × \(image.height)")
    }
}

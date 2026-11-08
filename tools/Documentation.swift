import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Compile-time replacement for UsageModel in documentation builds only.
/// No account files, preferences, collectors, or polling timers are used.
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
    var renderTime: TimeInterval? = nil
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
    func start() { fatalError("Collectors are disabled in documentation builds") }
    func refresh() { fatalError("Collectors are disabled in documentation builds") }
    func refreshAll() { fatalError("Collectors are disabled in documentation builds") }
    func connectClaude() { fatalError("Sign-in is disabled in documentation builds") }
    func stop() {}

    init() {
        let now = Date().timeIntervalSince1970
        snapshot.windows = Self.windows(provider: "codex", now: now)
        claudeSnapshot.windows = Self.windows(provider: "claude", now: now)
        let weekly = claudeSnapshot.windows[1]
        claudeSnapshot.windows.append(Quota(id: "claude:fable", name: "Fable", durationMinutes: weekly.durationMinutes,
            resetAt: weekly.resetAt, remaining: weekly.remaining, observedAt: now, points: weekly.points, severity: "normal"))
        snapshot.fetchedAt = now; claudeSnapshot.fetchedAt = now
        claudeSnapshot.source = "Claude Code"
        claudeSnapshot.extra = ExtraUsage(enabled: false)
        claudeSnapshot.breakdown = [UsageShare(name: "Sonnet", percent: 72), UsageShare(name: "Opus", percent: 28)]
    }

    /// Prepare the actual symbol view for one synthetic animation frame.
    func configureSymbol(provider: String, scope: String?, remaining: Double, baseline: Double,
                         durationMinutes: Double, unit: DotUnit, index: Int, opacity: Double, time: Double) {
        self.provider = provider
        miniSymbols = true; miniDotUnit = unit; miniDotIndex = index; miniOpacity = opacity; renderTime = time
        let now = Date().timeIntervalSince1970
        selectedID = "demo:selection"
        let selected = Quota(id: selectedID, name: scope ?? provider, durationMinutes: durationMinutes,
            resetAt: now + durationMinutes * 60 * baseline / 100, remaining: remaining, observedAt: now,
            points: [], severity: "normal")
        var windows = Self.windows(provider: provider, now: now)
        if provider == "claude" {
            windows.append(Quota(id: "claude:fable", name: "Fable", durationMinutes: 10080,
                resetAt: now + 10080 * 60 * 0.58, remaining: 62, observedAt: now, points: [], severity: "normal"))
        }
        windows.removeAll { $0.name == selected.name && $0.durationMinutes == selected.durationMinutes }
        windows.insert(selected, at: 0)
        var value = Snapshot(); value.windows = windows; value.fetchedAt = now
        if provider == "claude" { claudeSnapshot = value; snapshot = Snapshot() }
        else { snapshot = value; claudeSnapshot = Snapshot() }
    }

    private static func windows(provider: String, now: Double) -> [Quota] {
        [300.0, 10080.0].map { duration in
            let weekly = duration > 300, total = duration * 60
            let reset = now + total * (weekly ? 0.58 : 0.46), start = reset - total
            let remaining = weekly ? 62.0 : 54.0
            let points = (0...96).map { index -> Sample in
                let fraction = Double(index) / 96
                let consumed = (100 - remaining) * (fraction + 0.035 * sin(fraction * 6 * .pi))
                let value = index == 96 ? remaining : 100 - floor(consumed * 2) / 2
                return Sample(t: start + (now - start) * fraction, remaining: value)
            }
            let suffix = provider == "codex" ? (weekly ? "secondary" : "primary") : (weekly ? "seven_day" : "five_hour")
            return Quota(id: provider + ":" + suffix, name: provider, durationMinutes: duration,
                         resetAt: reset, remaining: remaining, observedAt: now, points: points, severity: "normal")
        }
    }
}

private final class DocumentationWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

/// Render owned view contents off screen, including native menus and sliders.
/// Never captures the desktop or the installed app.
@MainActor enum DocumentationRenderer {
    static func image<Content: View>(_ content: Content, size: NSSize) -> CGImage {
        let host = NSHostingView(rootView: content.environment(\.displayScale, 2))
        host.frame = NSRect(origin: .zero, size: size); host.appearance = NSAppearance(named: .darkAqua)
        let window = DocumentationWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        host.layoutSubtreeIfNeeded(); window.display()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Unable to allocate documentation image")
        }
        bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { fatalError("Unable to render documentation image") }
        window.close(); return image
    }

    static func png(_ image: CGImage, output: URL) {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Unable to create documentation PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save documentation PNG") }
    }
}

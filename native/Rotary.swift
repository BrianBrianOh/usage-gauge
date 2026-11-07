import AppKit
import SwiftUI

enum GaugeScale {
    static let spans: [Double?] = [3600, 21600, 86400, 259200, nil]
    static let spanLabels = ["1H", "6H", "24H", "3D", "ALL"]
    static let spanNames = ["Past hour", "Past 6 hours", "Past 24 hours", "Past 3 days", "Full cycle"]
    static let steps: [Double] = [0.1, 0.2, 0.5, 1, 2]
    static let stepLabels = ["0.1", "0.2", "0.5", "1", "2"]
    static func precision(_ step: Double) -> Int {
        if step <= 0.1 { return 5 }
        if step <= 0.2 { return 4 }
        if step <= 0.5 { return 3 }
        if step <= 1 { return 2 }
        return 1
    }
    static func bounded(_ index: Int) -> Int { min(4, max(0, index)) }
    static func domain(_ quota: Quota, index: Int, now: Double) -> ClosedRange<Date> {
        guard let seconds = spans[bounded(index)] else { return quota.startDate...quota.resetDate }
        let end = min(quota.resetAt, max(quota.start + 1, now))
        return Date(timeIntervalSince1970: max(quota.start, end - seconds))...Date(timeIntervalSince1970: end)
    }
    static func vertical(_ quota: Quota, index: Int, domain: ClosedRange<Date>) -> (range: ClosedRange<Double>, ticks: [Double]) {
        guard index != 4 else { return (0...100, [0,25,50,75,100]) }
        let actual = quota.points.filter { domain.contains($0.date) }.map(\.remaining)
        let values = actual + [quota.baseline(domain.lowerBound.timeIntervalSince1970), quota.baseline(domain.upperBound.timeIntervalSince1970)]
        let low = values.min() ?? 0, high = values.max() ?? 100
        let padding = max(0.5, (high - low) * 0.15)
        let targetLow = max(0, low - padding), targetHigh = min(100, high + padding)
        let step = [0.5, 1.0, 2, 5, 10, 20, 25].first { $0 >= max(2, targetHigh - targetLow) / 4 } ?? 25
        let lower = max(0, floor(targetLow / step) * step)
        let upper = min(100, max(lower + step, ceil(targetHigh / step) * step))
        return (lower...upper, Array(stride(from: lower, through: upper + step / 10, by: step)).filter { $0 <= upper })
    }
}

struct RotaryDial: NSViewRepresentable {
    var title: String
    var labels: [String]
    @Binding var selection: Int
    var accent: Color
    func makeNSView(context: Context) -> DetentKnob {
        let view = DetentKnob(frame: .zero)
        view.labels = labels; view.title = title
        view.onSelect = { selection = $0 }
        view.setSelection(selection, animated: false)
        return view
    }
    func updateNSView(_ view: DetentKnob, context: Context) {
        view.labels = labels; view.title = title; view.accent = NSColor(accent)
        view.onSelect = { selection = $0 }
        view.setSelection(selection, animated: true)
    }
}

final class DetentKnob: NSControl {
    var labels: [String] = []
    var title = ""
    var accent = NSColor.systemTeal { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private(set) var selection = 0
    private var drawnPosition: Double = 0
    private var animation: Timer?
    private var scrollRemainder: CGFloat = 0
    private var lastScroll: TimeInterval = 0
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 108) }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: 52) }
    private func angle(_ value: Double) -> Double { (225 - value * 270 / Double(max(1, labels.count - 1))) * .pi / 180 }
    private func point(_ value: Double, radius: Double) -> NSPoint {
        let a = angle(value); return NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }
    func setSelection(_ value: Int, animated: Bool) {
        let next = min(max(0, labels.count - 1), max(0, value))
        guard next != selection || !animated else { return }
        selection = next; animation?.invalidate()
        guard animated else { drawnPosition = Double(next); needsDisplay = true; return }
        let start = drawnPosition, began = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (Date.timeIntervalSinceReferenceDate - began) / 0.18)
            self.drawnPosition = start + (Double(next) - start) * (1 - pow(1 - progress, 3))
            self.needsDisplay = true
            if progress == 1 { timer.invalidate(); self.animation = nil }
        }
        animation = timer; RunLoop.main.add(timer, forMode: .common)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    private func choose(_ index: Int) {
        let next = min(max(0, labels.count - 1), max(0, index))
        guard selection != next else { return }
        setSelection(next, animated: true); onSelect?(next)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        // Every printed detent and its radial sector is a direct click target.
        let distances = labels.indices.map { i -> CGFloat in
            let p = point(Double(i), radius: 51)
            return hypot(location.x - p.x, location.y - p.y)
        }
        if let index = distances.indices.min(by: { distances[$0] < distances[$1] }) { choose(index) }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase != [] { return }
        if event.timestamp - lastScroll > 0.25 { scrollRemainder = 0 }
        lastScroll = event.timestamp
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? -event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        if !event.hasPreciseScrollingDeltas { choose(selection + (delta > 0 ? 1 : -1)); return }
        scrollRemainder += delta
        if abs(scrollRemainder) >= 14 {
            choose(selection + (scrollRemainder > 0 ? 1 : -1)); scrollRemainder = 0
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: choose(selection - 1)
        case 124, 126: choose(selection + 1)
        case 115: choose(0)
        case 119: choose(labels.count - 1)
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let c = center
        let bezel = NSBezierPath(ovalIn: NSRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68))
        NSColor.black.withAlphaComponent(0.28).setFill(); bezel.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke(); bezel.lineWidth = 1; bezel.stroke()
        for i in 0..<25 {
            let position = Double(i) * Double(max(1, labels.count - 1)) / 24
            let path = NSBezierPath(); path.move(to: point(position, radius: 36)); path.line(to: point(position, radius: i % 6 == 0 ? 43 : 39))
            (i % 6 == 0 ? NSColor.white.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.22)).setStroke()
            path.lineWidth = i % 6 == 0 ? 1.6 : 0.8; path.stroke()
        }
        for i in labels.indices {
            let p = point(Double(i), radius: 50)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: i == selection ? .bold : .medium), .foregroundColor: i == selection ? accent : NSColor(white: 0.72, alpha: 1)]
            let text = labels[i] as NSString, size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attributes)
        }
        let knob = NSBezierPath(ovalIn: NSRect(x: c.x - 28, y: c.y - 28, width: 56, height: 56))
        NSGradient(starting: NSColor(white: 0.29, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?.draw(in: knob, angle: 90)
        NSColor(white: 0.4, alpha: 1).setStroke(); knob.lineWidth = 1; knob.stroke()
        // A broad grip and luminous index recreate a detented cockpit selector.
        let a = angle(drawnPosition), dx = cos(a), dy = sin(a)
        let grip = NSBezierPath(); grip.move(to: NSPoint(x: c.x - dx * 18, y: c.y - dy * 18)); grip.line(to: NSPoint(x: c.x + dx * 21, y: c.y + dy * 21))
        NSColor(white: 0.36, alpha: 1).setStroke(); grip.lineWidth = 10; grip.lineCapStyle = .round; grip.stroke()
        let needle = NSBezierPath(); needle.move(to: point(drawnPosition, radius: 9)); needle.line(to: point(drawnPosition, radius: 24))
        accent.setStroke(); needle.lineWidth = 3; needle.lineCapStyle = .round; needle.stroke()
        if window?.firstResponder === self {
            accent.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 32, y: c.y - 32, width: 64, height: 64)); ring.lineWidth = 1; ring.stroke()
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { labels.isEmpty ? "" : labels[selection] }
    override func accessibilityPerformIncrement() -> Bool { choose(selection + 1); return true }
    override func accessibilityPerformDecrement() -> Bool { choose(selection - 1); return true }
    override func accessibilityHelp() -> String? { "Scroll or click a detent to select. Arrow keys are also supported." }
}

struct InstrumentPanel: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        HStack(spacing: 0) {
            selector(title: "Time range", subtitle: GaugeScale.spanNames[model.spanIndex], labels: GaugeScale.spanLabels, selection: $model.spanIndex)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 100)
            selector(title: "Display interval", subtitle: "\(GaugeScale.stepLabels[model.stepIndex]) s", labels: GaugeScale.stepLabels, selection: $model.stepIndex)
        }.padding(.vertical, 10).modifier(Bezel(hardware: true))
        .help("Scroll one detent at a time, or click a label. Account refresh is set separately.")
    }
    private func selector(title: String, subtitle: String, labels: [String], selection: Binding<Int>) -> some View {
        VStack(spacing: 0) {
            Text(title).font(FlightDeck.label(9)).tracking(0.3).foregroundStyle(FlightDeck.ink)
            RotaryDial(title: title, labels: labels, selection: selection, accent: model.accent).frame(height: 108)
            Text(subtitle).font(FlightDeck.label(8)).tracking(0.5).foregroundStyle(model.accent)
        }.frame(maxWidth: .infinity)
    }
}

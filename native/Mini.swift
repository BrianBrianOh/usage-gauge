import AppKit
import SwiftUI

enum MiniCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum MiniLayout {
    static let valueSize = NSSize(width: 320, height: 184)
    static let symbolSize = NSSize(width: 110, height: 148)
    static func opacity(_ value: Double) -> Double { value.isFinite ? min(1, max(0.3, value)) : 1 }
    static func size(symbols: Bool) -> NSSize { symbols ? symbolSize : valueSize }
    static func origin(_ corner: MiniCorner, in visible: NSRect, size: NSSize = MiniLayout.valueSize) -> NSPoint {
        NSPoint(x: (corner == .topRight || corner == .bottomRight) ? visible.maxX - size.width - 12 : visible.minX + 12,
                y: (corner == .topLeft || corner == .topRight) ? visible.maxY - size.height - 12 : visible.minY + 12)
    }
    static func resized(_ frame: NSRect, to size: NSSize, in visible: NSRect) -> NSRect {
        let right = abs(visible.maxX - frame.maxX) <= 24
        let bottom = abs(frame.minY - visible.minY) <= 24
        let x = right ? frame.maxX - size.width : frame.minX
        let y = bottom ? frame.minY : frame.maxY - size.height
        return NSRect(x: min(max(visible.minX + 12, x), visible.maxX - size.width - 12),
                      y: min(max(visible.minY + 12, y), visible.maxY - size.height - 12), width: size.width, height: size.height)
    }
    static func countdown(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MiniHostingView: NSHostingView<MiniView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small blank header region provides a reliable drag target without capturing buttons.
struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> DragView {
        let view = DragView(); view.toolTip = "Drag to move"; return view
    }
    func updateNSView(_ view: DragView, context: Context) {}
}

struct MiniView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: model.miniSymbols ? 5 : 7) {
            header
            if let quota = model.quota {
                limitSelector(quota)
                TimelineView(.periodic(from: .now, by: model.displayStep)) { context in
                    if model.miniSymbols { symbols(quota, now: context.date) }
                    else { readings(quota, now: context.date) }
                }.id(model.stepIndex)
            } else {
                Spacer(minLength: 0)
                Text(model.isRefreshing ? "Loading usage…" : "No usage data").font(.system(size: 15)).foregroundStyle(FlightDeck.ink)
                if model.provider == "claude" && !model.isRefreshing {
                    Button("Connect Claude", action: model.connectClaude).buttonStyle(.plain).foregroundStyle(model.accent)
                }
                Text(model.error ?? "Open the full window for account details.").font(.system(size: 10)).foregroundStyle(FlightDeck.muted).lineLimit(2)
                Spacer(minLength: 0)
            }
        }.padding(model.miniSymbols ? 8 : 12)
            .frame(width: MiniLayout.size(symbols: model.miniSymbols).width, height: MiniLayout.size(symbols: model.miniSymbols).height, alignment: .topLeading)
            .background(FlightDeck.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(FlightDeck.ink)
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
    private var header: some View {
        HStack(spacing: model.miniSymbols ? 5 : 10) {
            if model.miniSymbols {
                Menu {
                    Picker("Service", selection: $model.provider) {
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                    }.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Text(model.provider.capitalized).font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 6))
                    }.foregroundStyle(model.accent)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Service")
            } else {
                ForEach(["codex", "claude"], id: \.self) { provider in
                    Button(provider.capitalized) { model.provider = provider }
                        .buttonStyle(.plain).font(.system(size: 11, weight: model.provider == provider ? .semibold : .regular))
                        .foregroundStyle(model.provider == provider ? model.accent : FlightDeck.muted)
                        .accessibilityAddTraits(model.provider == provider ? .isSelected : [])
                }
            }
            WindowDragRegion().frame(minWidth: model.miniSymbols ? 5 : 10, maxWidth: .infinity, minHeight: 20)
            if !model.miniSymbols {
                Button { model.miniSymbols = true } label: { Image(systemName: "chart.bar") }
                    .help("Symbols only").accessibilityLabel("Symbols only")
                Button { model.miniOnTop.toggle() } label: { Image(systemName: model.miniOnTop ? "pin.fill" : "pin") }
                    .foregroundStyle(model.miniOnTop ? model.accent : FlightDeck.muted)
                    .help(model.miniOnTop ? "Keep on top: on" : "Keep on top: off").accessibilityLabel("Keep mini window on top")
                    .accessibilityValue(model.miniOnTop ? "On" : "Off")
                Button { model.miniMode = false } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full window").accessibilityLabel("Full window")
            }
            Menu {
                Toggle("Symbols only", isOn: $model.miniSymbols)
                Toggle("Keep on top", isOn: $model.miniOnTop)
                Menu("Dot unit") {
                    Picker("Dot unit", selection: $model.miniDotUnit) {
                        Text("Time budget").tag(DotUnit.time)
                        Text("Percentage points").tag(DotUnit.percentagePoints)
                    }.pickerStyle(.inline)
                }
                Menu("Dot spacing") {
                    Picker("Dot spacing", selection: $model.miniDotIndex) {
                        ForEach(model.miniDotScale.optionNames.indices, id: \.self) { index in
                            Text(model.miniDotScale.optionNames[index]).tag(index)
                        }
                    }.pickerStyle(.inline)
                }
                Divider()
                Button("Refresh", action: model.refresh).disabled(model.isRefreshing)
                Menu("Move to corner") {
                    ForEach(MiniCorner.allCases, id: \.self) { corner in
                        Button(corner.title) { model.onMoveMini?(corner) }
                    }
                }
                Divider()
                Button("Full window") { model.miniMode = false }
                Button("Quit Usage Gauge") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Options").accessibilityLabel("Options")
        }.buttonStyle(.plain).font(.system(size: 11)).frame(height: 20)
    }
    @ViewBuilder private func limitSelector(_ quota: Quota) -> some View {
        HStack(spacing: 2) {
            if model.activeSnapshot.windows.count > 1 {
                Menu {
                    ForEach(model.activeSnapshot.windows) { item in
                        Button(model.miniSymbols ? symbolTitle(item) : item.title) { model.selectedID = item.id }
                    }
                } label: {
                    HStack(spacing: 3) { Text(model.miniSymbols ? symbolTitle(quota) : quota.title).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 7)) }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Limit")
            } else { Text(model.miniSymbols ? symbolTitle(quota) : quota.title) }
            Spacer(minLength: 0)
            if model.miniSymbols && model.error != nil {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundStyle(FlightDeck.amber)
                    .help("Refresh failed; showing the last observation")
            } else if model.miniSymbols && Date().timeIntervalSince1970 - quota.observedAt > Double(max(model.interval * 3, 600)) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)).foregroundStyle(FlightDeck.amber)
                    .help("The last observation is out of date")
            } else if model.isRefreshing {
                if model.miniSymbols { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).help("Updating…") }
                else { Text("Updating…") }
            }
            if model.miniSymbols {
                Slider(value: $model.miniOpacity, in: 0.3...1, step: 0.05)
                    .labelsHidden().controlSize(.mini).tint(model.accent).frame(width: 36)
                    .accessibilityLabel("Window opacity")
                    .accessibilityValue("\(Int((model.miniOpacity * 100).rounded())) percent")
                    .help("Window opacity: \(Int((model.miniOpacity * 100).rounded()))%")
            }
        }.font(.system(size: 10)).foregroundStyle(FlightDeck.muted).frame(height: 14)
    }
    private func symbolTitle(_ quota: Quota) -> String {
        let period = quota.durationMinutes == 300 ? "Session" : quota.durationMinutes == 10080 ? "Weekly" : "Current window"
        guard quota.name != "codex" && quota.name != "claude" else { return period }
        let name = quota.name.replacingOccurrences(of: #"\d+(?:\.\d+)*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return name + " · " + period
    }
    private func symbols(_ quota: Quota, now: Date) -> some View {
        let time = now.timeIntervalSince1970
        let baseline = quota.isIdle ? nil : quota.baseline(time)
        let expired = !quota.isIdle && time >= quota.resetAt
        let stale = time - quota.observedAt > Double(max(model.interval * 3, 600))
        return HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 3) {
                VerticalComparison(remaining: quota.remaining, baseline: expired ? nil : baseline,
                                   scale: model.miniDotScale, isCurrent: !stale && model.error == nil, color: model.accent)
                    .frame(height: 70)
                    .overlay(DotScaleWheel(selection: $model.miniDotIndex, labels: model.miniDotScale.optionNames))
                WindowDragRegion().frame(height: 10)
                    .overlay(Text(model.miniDotScale.caption).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(FlightDeck.muted).allowsHitTesting(false))
            }.frame(maxWidth: .infinity)
            VStack(spacing: 4) {
                RemainingBar(remaining: quota.remaining, color: model.accent)
                Image(systemName: "battery.0percent").font(.system(size: 9)).foregroundStyle(FlightDeck.muted).frame(height: 10)
                    .accessibilityHidden(true)
            }.frame(width: 12)
            ResetBar(progress: baseline, expired: expired, color: model.accent)
        }.frame(height: 84)
    }
    private func readings(_ quota: Quota, now: Date) -> some View {
        let time = now.timeIntervalSince1970
        let age = time - quota.observedAt
        let stale = age > Double(max(model.interval * 3, 600))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                metric("Remaining", value: Formats.percent(quota.remaining), size: 30, color: model.accent)
                metric("Linear baseline", value: quota.isIdle ? "—" : String(format: "%.*f%%", GaugeScale.precision(model.displayStep), quota.baseline(time)), size: 21, color: FlightDeck.ink)
            }.frame(height: 50)
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
            HStack {
                Text(quota.isIdle ? "Reset" : "Resets in").foregroundStyle(FlightDeck.muted)
                Spacer()
                Text(quota.isIdle ? "Starts on next use" : time >= quota.resetAt ? "Waiting for reset" : MiniLayout.countdown(quota.resetAt - time))
                    .monospacedDigit().foregroundStyle(FlightDeck.ink)
            }.font(.system(size: 12)).frame(height: 17)
            HStack(spacing: 3) {
                Text(quota.isIdle ? "Window not started" : "\(Formats.date(quota.resetAt)) \(Formats.zone)")
                Spacer(minLength: 2)
                if model.error != nil {
                    Text("Refresh failed").foregroundStyle(FlightDeck.amber).help(model.error ?? "")
                } else if stale {
                    Text("\(Formats.duration(age)) old").foregroundStyle(FlightDeck.amber)
                } else {
                    Text("Updated \(Formats.axisTime.string(from: quota.observedDate))")
                }
            }.font(.system(size: 9)).foregroundStyle(FlightDeck.muted).lineLimit(1)
        }
    }
    private func metric(_ label: String, value: String, size: CGFloat, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(FlightDeck.muted)
            Text(value).font(.system(size: size, weight: .medium, design: .monospaced)).tracking(-0.8).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum DotUnit: String {
    case time
    case percentagePoints
}

struct DotScale {
    static let values = [1.0, 2.0, 5.0]
    static func bounded(_ index: Int) -> Int { min(values.count - 1, max(0, index)) }
    static func points(_ index: Int) -> Double { values[bounded(index)] }
    static func label(_ index: Int) -> String { String(Int(points(index))) }
    static func isLongWindow(_ minutes: Double) -> Bool { minutes.isFinite && minutes >= 1440 }
    static func defaultIndex(unit: DotUnit, durationMinutes: Double) -> Int {
        unit == .percentagePoints || isLongWindow(durationMinutes) ? 1 : 0
    }
    let unit: DotUnit
    let durationMinutes: Double
    let index: Int
    init(unit: DotUnit, durationMinutes: Double, index: Int) {
        self.unit = unit
        self.durationMinutes = durationMinutes.isFinite && durationMinutes > 0 ? durationMinutes : 300
        self.index = Self.bounded(index)
    }
    /// Time values are equivalent budget minutes, not a depletion-time forecast.
    var options: [Double] {
        unit == .percentagePoints ? Self.values : Self.isLongWindow(durationMinutes) ? [120, 240, 480] : [5, 10, 15]
    }
    var pointsPerDot: Double { unit == .percentagePoints ? options[index] : options[index] * 100 / durationMinutes }
    var caption: String {
        if unit == .percentagePoints { return "\(Int(options[index])) pp/dot" }
        return Self.isLongWindow(durationMinutes) ? "\(Int(options[index] / 60))h/dot" : "\(Int(options[index]))m/dot"
    }
    private func quantity(_ value: Double) -> String {
        if unit == .percentagePoints { return "\(Int(value)) percentage point\(value == 1 ? "" : "s")" }
        if value >= 60 { return "\(Int(value / 60)) hour\(value == 60 ? "" : "s")" }
        return "\(Int(value)) minute\(value == 1 ? "" : "s")"
    }
    var optionNames: [String] { options.map { quantity($0) + " per dot" } }
    var limitText: String { quantity(options[index] * 2) }
    var warningText: String {
        unit == .time ? "at least \(limitText) of consumption ahead of the linear budget" : "at least \(limitText) below the linear budget"
    }
}

/// Transparent native wheel target; mouse and trackpad input both select discrete scales.
struct DotScaleWheel: NSViewRepresentable {
    @Binding var selection: Int
    let labels: [String]
    func makeNSView(context: Context) -> DotScaleControl { DotScaleControl() }
    func updateNSView(_ view: DotScaleControl, context: Context) {
        view.selection = DotScale.bounded(selection)
        view.labels = labels
        view.onSelect = { selection = $0 }
        view.toolTip = "\(labels[DotScale.bounded(selection)]). Scroll to change spacing, click to choose, or drag to move the window."
    }
}

final class DotScaleControl: NSControl {
    var selection = 1
    var labels = ["1 percentage point per dot", "2 percentage points per dot", "5 percentage points per dot"]
    var onSelect: ((Int) -> Void)?
    private var scrollRemainder: CGFloat = 0
    private var lastScroll: TimeInterval = 0
    private var mousePress: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func choose(_ index: Int) {
        let next = DotScale.bounded(index)
        guard selection != next else { return }
        selection = next
        onSelect?(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        if event.timestamp - lastScroll > 0.25 { scrollRemainder = 0 }
        lastScroll = event.timestamp
        let delta = -event.scrollingDeltaY
        guard delta != 0 else { return }
        if !event.hasPreciseScrollingDeltas { choose(selection + (delta > 0 ? 1 : -1)); return }
        if delta * scrollRemainder < 0 { scrollRemainder = 0 }
        scrollRemainder += delta
        if abs(scrollRemainder) >= 14 {
            choose(selection + (scrollRemainder > 0 ? 1 : -1))
            scrollRemainder = 0
        }
    }
    override func mouseDown(with event: NSEvent) {
        mousePress = event
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressed = mousePress else { return }
        let dx = event.locationInWindow.x - pressed.locationInWindow.x
        let dy = event.locationInWindow.y - pressed.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        mousePress = nil
        window?.performDrag(with: pressed)
    }
    override func mouseUp(with event: NSEvent) {
        guard mousePress != nil else { return }
        mousePress = nil
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        for index in labels.indices {
            let item = NSMenuItem(title: labels[index], action: #selector(selectOption(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = selection == index ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
    @objc private func selectOption(_ sender: NSMenuItem) { choose(sender.tag) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: choose(selection - 1)
        case 124, 125: choose(selection + 1)
        default: super.keyDown(with: event)
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Dot spacing" }
    override func accessibilityValue() -> Any? { labels[selection] }
    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityPerformIncrement() -> Bool { choose(selection + 1); return true }
    override func accessibilityPerformDecrement() -> Bool { choose(selection - 1); return true }
}

enum WarningFlash {
    static let halfPeriod = 0.8
    static func isRed(at time: TimeInterval) -> Bool {
        Int(floor(time / halfPeriod)) % 2 == 0
    }
}

/// Positive deviation means the reference requires more remaining capacity than we have.
/// The center is the current observation, not 50% remaining.
struct UsageDeviation {
    static let dotsPerSide = 2
    let remaining: Double
    let baseline: Double?
    var pointsPerDot = 2.0
    var isCurrent = true
    var limit: Double { pointsPerDot * Double(Self.dotsPerSide) }
    var difference: Double? {
        guard remaining.isFinite, let baseline, baseline.isFinite else { return nil }
        return baseline - remaining
    }
    var normalized: Double { min(1, max(-1, (difference ?? 0) / limit)) }
    var outsideScale: Bool { difference.map { abs($0) > limit + 1e-9 } ?? false }
    var warning: Bool { isCurrent && (difference.map { $0 >= limit - 1e-9 } ?? false) }
}

struct VerticalComparison: View {
    let remaining: Double
    let baseline: Double?
    var scale = DotScale(unit: .percentagePoints, durationMinutes: 300, index: 1)
    var isCurrent = true
    let color: Color
    var sampleTime: TimeInterval? = nil
    private var deviation: UsageDeviation { UsageDeviation(remaining: remaining, baseline: baseline, pointsPerDot: scale.pointsPerDot, isCurrent: isCurrent) }
    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width / 2
            let center = geometry.size.height / 2
            let travel = center - 8
            ZStack {
                ForEach(-2...2, id: \.self) { tick in
                    let y = center + Double(tick) / Double(UsageDeviation.dotsPerSide) * travel
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        if tick == 0 {
                            Path { path in
                                let dotX = x + side * 22
                                path.move(to: CGPoint(x: dotX - 2.5, y: y)); path.addLine(to: CGPoint(x: dotX + 2.5, y: y))
                                path.move(to: CGPoint(x: dotX, y: y - 2.5)); path.addLine(to: CGPoint(x: dotX, y: y + 2.5))
                            }.stroke(FlightDeck.muted.opacity(0.85), lineWidth: 0.75)
                        } else {
                            Circle().stroke(FlightDeck.muted.opacity(0.65), lineWidth: 0.75)
                                .frame(width: 3, height: 3).position(x: x + side * 22, y: y)
                        }
                    }
                }
                if deviation.difference != nil {
                    let y = center - deviation.normalized * travel
                    Rectangle().fill(FlightDeck.ink).frame(width: 32, height: 1.25).position(x: x, y: y)
                        .help("Linear baseline: \(Formats.percent(baseline!))").opacity(isCurrent ? 1 : 0.4)
                    if deviation.outsideScale {
                        Path { path in
                            let direction = deviation.normalized > 0 ? -1.0 : 1.0
                            path.move(to: CGPoint(x: x - 3, y: y + direction * 3))
                            path.addLine(to: CGPoint(x: x, y: y + direction * 6))
                            path.addLine(to: CGPoint(x: x + 3, y: y + direction * 3))
                        }.stroke(FlightDeck.ink.opacity(isCurrent ? 1 : 0.4), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }
                }
                FixedUsageDiamond(warning: deviation.warning, color: color, sampleTime: sampleTime)
                    .position(x: x, y: center).help("Current remaining usage: \(Formats.percent(remaining))")
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Remaining usage against linear baseline")
            .accessibilityValue(accessibilitySummary)
            .help("Diamond: current remaining usage, fixed at center. White bar: linear baseline. \(scale.optionNames[scale.index]); limits ±\(scale.limitText). Bar above center: below budget. Alternating red: \(scale.warningText).\(scale.unit == .time ? " Time measures the linear budget difference, not a depletion forecast." : "")\(isCurrent ? "" : " Last observation; alert paused.")")
    }
    private var accessibilitySummary: String {
        let reference = baseline.map(Formats.percent) ?? "unavailable"
        let alert = deviation.warning ? "; \(scale.warningText)" : ""
        return "Remaining \(Formats.percent(remaining)); baseline \(reference); \(scale.optionNames[scale.index])\(alert)\(isCurrent ? "" : "; last observation, alert paused")"
    }
}

struct FixedUsageDiamond: View {
    let warning: Bool
    let color: Color
    var sampleTime: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let sampleTime {
                diamond(red: warning && WarningFlash.isRed(at: sampleTime))
            } else if warning && !reduceMotion {
                // Independent of the number-update dial, so a 2-second step cannot alias the pulse.
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    diamond(red: WarningFlash.isRed(at: context.date.timeIntervalSince1970))
                }
            } else { diamond(red: warning) }
        }.frame(width: 12, height: 12).transaction { $0.animation = nil }
    }
    private func diamond(red: Bool) -> some View {
        Rectangle().fill(red ? FlightDeck.alert : color).frame(width: 9, height: 9)
            .overlay(Rectangle().stroke(FlightDeck.panel, lineWidth: 1))
            .rotationEffect(.degrees(45))
    }
}

struct RemainingBar: View {
    let remaining: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.08))
                Rectangle().fill(color).frame(height: geometry.size.height * min(1, max(0, remaining / 100)))
            }.clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(FlightDeck.muted.opacity(0.5), lineWidth: 0.75))
        }.frame(width: 7, height: 64)
            .help("Actual remaining usage: \(Formats.percent(remaining)). Full height is 100%.")
            .accessibilityElement(children: .ignore).accessibilityLabel("Actual remaining usage")
            .accessibilityValue(Formats.percent(remaining))
    }
}

struct ResetBar: View {
    let progress: Double?
    let expired: Bool
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            RemainingBar(remaining: progress ?? 0, color: FlightDeck.ink)
                .accessibilityHidden(true)
            Image(systemName: progress == nil ? "pause" : expired ? "arrow.clockwise" : "clock")
                .font(.system(size: 9)).foregroundStyle(FlightDeck.muted).frame(height: 10)
        }.frame(width: 12)
            .help(progress == nil ? "The reset window has not started" : expired ? "Waiting for a new reset window" : "Time left until reset")
            .accessibilityElement(children: .ignore).accessibilityLabel("Time left until reset")
            .accessibilityValue(progress.map(Formats.percent) ?? "Not started")
    }
}

import AppKit
import SwiftUI

struct MiniPalette {
    let hud: Bool
    static let hudGreen = Color(red: 0.25, green: 1, blue: 0.35)
    static let hudDarkGreen = Color(red: 0.03, green: 0.30, blue: 0.07)
    var ink: Color { hud ? Self.hudGreen : FlightDeck.ink }
    var muted: Color { hud ? Self.hudGreen.opacity(0.9) : FlightDeck.muted }
    var panel: Color { hud ? .clear : FlightDeck.panel }
    var border: Color { hud ? .clear : .white.opacity(0.14) }
    var separator: Color { hud ? Self.hudGreen.opacity(0.2) : .white.opacity(0.09) }
    func tint(_ color: Color) -> Color { hud ? Self.hudGreen : color }
}

private struct MiniPaletteKey: EnvironmentKey {
    static let defaultValue = MiniPalette(hud: false)
}

extension EnvironmentValues {
    var miniPalette: MiniPalette {
        get { self[MiniPaletteKey.self] }
        set { self[MiniPaletteKey.self] = newValue }
    }
}

private struct HUDUnitAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private struct HUDUnitRects: PreferenceKey {
    static let defaultValue: [HUDContrastUnit] = []
    static func reduce(value: inout [HUDContrastUnit], nextValue: () -> [HUDContrastUnit]) { value.append(contentsOf: nextValue()) }
}
private extension View {
    func hudUnit(_ id: String) -> some View {
        anchorPreference(key: HUDUnitAnchors.self, value: .bounds) { [id: $0] }
    }
    func hudHitArea(_ enabled: Bool) -> some View {
        background(Color.black.opacity(enabled ? 0.004 : 0)).contentShape(Rectangle())
    }
}

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
    static let valueSize = NSSize(width: 320, height: 228)
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
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { !rootView.model.miniHUD }
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
    private var palette: MiniPalette { MiniPalette(hud: model.miniHUD) }
    private var renderTime: TimeInterval? {
        #if SCREENSHOT_RENDER
        model.renderTime
        #else
        nil
        #endif
    }
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
                Text(model.isRefreshing ? "Loading usage…" : "No usage data").font(.system(size: 15)).foregroundStyle(palette.ink).hudUnit("empty-title")
                if model.provider == "claude" && !model.isRefreshing {
                    Button("Connect Claude", action: model.connectClaude).buttonStyle(.plain).foregroundStyle(palette.tint(model.accent)).hudUnit("connect")
                }
                Text(model.error ?? "Open the full window for account details.").font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(2).hudUnit("empty-detail")
                Spacer(minLength: 0)
            }
        }.padding(model.miniSymbols ? 8 : 12)
            .frame(width: MiniLayout.size(symbols: model.miniSymbols).width, height: MiniLayout.size(symbols: model.miniSymbols).height, alignment: .topLeading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(palette.ink)
            .environment(\.miniPalette, palette)
            .overlay {
                if model.miniHUD && model.miniAutoContrast, let map = model.hudContrastMap {
                    Image(nsImage: map).resizable().interpolation(.none)
                        .blendMode(.sourceAtop).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .compositingGroup()
            // One faint, centered edge avoids the doubled strokes of offset outlines.
            .shadow(color: palette.hud ? MiniPalette.hudDarkGreen.opacity(0.6) : .clear, radius: 0.35)
            .backgroundPreferenceValue(HUDUnitAnchors.self) { anchors in
                GeometryReader { geometry in
                    Color.clear.preference(key: HUDUnitRects.self, value: anchors.keys.sorted().map {
                        HUDContrastUnit(id: $0, rect: geometry[anchors[$0]!])
                    })
                }
            }
            .onPreferenceChange(HUDUnitRects.self) { units in
                if model.hudContrastUnits != units { model.hudContrastUnits = units }
            }
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
    private var header: some View {
        HStack(spacing: model.miniSymbols ? (model.miniHUD ? 2 : 5) : 10) {
            if model.miniSymbols {
                if model.miniHUD {
                    HUDServiceLabel(selection: $model.provider, color: palette.ink)
                        .frame(width: 42, height: 22).hudUnit("service")
                } else {
                Menu {
                    Picker("Service", selection: $model.provider) {
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                    }.pickerStyle(.inline)
                } label: {
                    Text(model.provider.capitalized).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.tint(model.accent))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Service").hudUnit("service")
                }
                // Menu labels draw only text and images, so the other service's mark sits beside it.
                let other = model.provider == "claude" ? "codex" : "claude"
                RiskDot(risk: risk(of: other), tint: model.miniHUD ? palette.ink : nil).help(risk(of: other).map { "\(other.capitalized): \($0.label)" } ?? "").hudUnit("service-risk")
            } else {
                ForEach(["codex", "claude"], id: \.self) { provider in
                    if model.miniHUD {
                        HStack(spacing: 3) {
                            HUDServiceLabel(selection: $model.provider, labelProvider: provider, showsMenu: false,
                                            color: model.provider == provider ? palette.ink : palette.muted)
                                .frame(width: 42, height: 22)
                            RiskDot(risk: risk(of: provider), tint: palette.ink)
                        }.hudUnit("service-\(provider)")
                    } else {
                    Button { model.provider = provider } label: {
                        HStack(spacing: 3) { Text(provider.capitalized); RiskDot(risk: risk(of: provider), tint: model.miniHUD ? palette.ink : nil) }
                    }
                        .buttonStyle(.plain).font(.system(size: 11, weight: model.provider == provider ? .semibold : .regular))
                        .foregroundStyle(model.provider == provider ? palette.tint(model.accent) : palette.muted)
                        .accessibilityAddTraits(model.provider == provider ? .isSelected : [])
                        .hudUnit("service-\(provider)")
                    }
                }
            }
            if model.miniHUD {
                Spacer(minLength: 0)
                Image(systemName: "cursorarrow").font(.system(size: 8))
                    .foregroundStyle(palette.ink)
                    .frame(width: 12, height: 16)
                    .background(Color.black.opacity(0.004))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(palette.ink, lineWidth: 0.7))
                    .overlay(WindowDragRegion())
                    .help("Drag to move HUD")
                    .accessibilityLabel("Move HUD")
                    .hudUnit("drag-handle")
            } else {
                WindowDragRegion().frame(minWidth: model.miniSymbols ? 5 : 10, maxWidth: .infinity, minHeight: 20)
            }
            if !model.miniSymbols {
                Button { model.miniSymbols = true } label: { Image(systemName: "chart.bar") }
                    .help("Symbols only").accessibilityLabel("Symbols only")
                    .hudUnit("symbols-button")
                Button { model.miniOnTop.toggle() } label: { Image(systemName: model.miniOnTop ? "pin.fill" : "pin") }
                    .foregroundStyle(model.miniOnTop ? palette.tint(model.accent) : palette.muted)
                    .help(model.miniOnTop ? "Keep on top: on" : "Keep on top: off").accessibilityLabel("Keep mini window on top")
                    .accessibilityValue(model.miniOnTop ? "On" : "Off")
                    .hudUnit("pin-button")
                Button { model.miniMode = false } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full window").accessibilityLabel("Full window")
                    .hudUnit("full-button")
            }
            Menu {
                Toggle("Symbols only", isOn: $model.miniSymbols)
                Toggle("HUD mode", isOn: $model.miniHUD)
                Toggle("Automatic contrast", isOn: $model.miniAutoContrast).disabled(!model.miniHUD)
                if model.miniHUD && model.miniAutoContrast {
                    Text(model.hudContrastStatus.label)
                    if model.hudContrastStatus == .permissionRequired {
                        Button("Allow background access…") { model.onRequestHUDContrastPermission?() }
                    }
                }
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
            } label: {
                if model.miniHUD {
                    Text("⋯").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.ink)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 24, height: 22).contentShape(Rectangle())
                .hudHitArea(model.miniHUD)
                .help("Options").accessibilityLabel("Options")
                .hudUnit("options")
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
                    HStack(spacing: 3) {
                        Text(model.miniSymbols ? symbolTitle(quota, compact: true) : quota.title)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1).fixedSize(horizontal: model.miniSymbols, vertical: false)
                        if !model.miniSymbols {
                            if model.miniHUD { Text("⌄").font(.system(size: 10)).foregroundStyle(palette.muted) }
                            else { Image(systemName: "chevron.down").font(.system(size: 7)) }
                        }
                    }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: model.miniSymbols ? 40 : nil, alignment: .leading).layoutPriority(1)
                    .accessibilityLabel("Limit").accessibilityValue(symbolTitle(quota))
                    .help("Select limit: \(symbolTitle(quota))")
                    .hudHitArea(model.miniHUD)
                    .hudUnit("limit")
            } else { Text(model.miniSymbols ? symbolTitle(quota, compact: true) : quota.title).hudUnit("limit") }
            if let constraint = model.activeSnapshot.sharedConstraints(for: quota, now: Date().timeIntervalSince1970).first {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).frame(width: model.miniSymbols ? 9 : nil).foregroundStyle(palette.tint(constraint.risk.color))
                    .help("\(constraint.quota.title): \(Formats.percent(constraint.quota.remaining)) left · \(constraint.risk.label). It counts all usage, so it can stop work before this limit does.")
                    .accessibilityLabel("Shared limit at risk")
                    .hudUnit("shared-risk")
            }
            Spacer(minLength: 0)
            if model.miniSymbols && model.error != nil {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).frame(width: 9).foregroundStyle(palette.tint(FlightDeck.amber))
                    .help("Refresh failed; showing the last observation")
                    .hudUnit("refresh-error")
            } else if model.miniSymbols && Date().timeIntervalSince1970 - quota.observedAt > Double(max(model.interval * 3, 600)) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)).frame(width: 9).foregroundStyle(palette.tint(FlightDeck.amber))
                    .help("The last observation is out of date")
                    .hudUnit("stale")
            } else if model.isRefreshing {
                if model.miniSymbols { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).frame(width: 9).help("Updating…").hudUnit("refreshing") }
                else { Text("Updating…").hudUnit("refreshing") }
            }
            Group {
                if model.miniHUD {
                    HUDOpacitySlider(value: $model.miniOpacity)
                } else {
                    Slider(value: $model.miniOpacity, in: 0.3...1, step: 0.05)
                        .labelsHidden().controlSize(.mini).tint(model.accent)
                }
            }
                .frame(minWidth: model.miniSymbols ? 28 : 60, idealWidth: model.miniSymbols ? 36 : 60, maxWidth: model.miniSymbols ? 36 : 60)
                .accessibilityLabel("Window opacity")
                .accessibilityValue("\(Int((model.miniOpacity * 100).rounded())) percent")
                .help("Window opacity: \(Int((model.miniOpacity * 100).rounded()))%")
                .hudHitArea(model.miniHUD)
                .hudUnit("opacity")
        }.font(.system(size: 10)).foregroundStyle(palette.muted).frame(height: 14)
    }
    private func risk(of provider: String) -> LimitRisk? {
        (provider == "claude" ? model.claudeSnapshot : model.snapshot).riskiest(now: Date().timeIntervalSince1970)?.risk
    }
    private func symbolTitle(_ quota: Quota, compact: Bool = false) -> String {
        let period = quota.durationMinutes == 300 ? "Session" : quota.durationMinutes == 10080 ? "Weekly" : "Current window"
        guard quota.name != "codex" && quota.name != "claude" else { return period }
        let name = quota.name.replacingOccurrences(of: #"\d+(?:\.\d+)*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return compact ? name : name + " · " + period
    }
    private func symbols(_ quota: Quota, now: Date) -> some View {
        let time = now.timeIntervalSince1970
        let baseline = quota.isIdle ? nil : quota.baseline(time)
        let expired = !quota.isIdle && time >= quota.resetAt
        let stale = time - quota.observedAt > Double(max(model.interval * 3, 600))
        return HStack(alignment: .top, spacing: 6) {
            // 70 - 2 aligns the caption with the bars' 64 + 4 icon row.
            VStack(spacing: -2) {
                VerticalComparison(remaining: quota.remaining, baseline: expired ? nil : baseline,
                                   scale: model.miniDotScale, isCurrent: !stale && model.error == nil, color: palette.tint(model.accent), sampleTime: renderTime)
                    .frame(height: 70)
                Group {
                    if model.miniHUD { Color.clear }
                    else { WindowDragRegion() }
                }.frame(height: 10)
                    .overlay(Text(model.miniDotScale.compactCaption).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(palette.muted).allowsHitTesting(false))
            }.frame(maxWidth: .infinity)
                .overlay {
                    if model.miniHUD {
                        GeometryReader { geometry in
                            let diameter = VerticalComparison.diamondDiameter(height: 70)
                            DotScaleWheel(selection: $model.miniDotIndex, labels: model.miniDotScale.optionNames)
                                .frame(width: diameter, height: diameter)
                                .position(x: geometry.size.width / 2, y: 35)
                        }
                    } else {
                        DotScaleWheel(selection: $model.miniDotIndex, labels: model.miniDotScale.optionNames)
                    }
                }
                .hudUnit("pace")
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 4) {
                // Capacity takes the limit-risk colour; the diamond keeps reporting pace.
                RemainingBar(remaining: quota.remaining, color: palette.tint(quota.limitRisk(now: time)?.color ?? model.accent))
                Image(systemName: "battery.0percent").font(.system(size: 9)).foregroundStyle(palette.muted).frame(height: 10)
                    .accessibilityHidden(true)
                }.frame(width: 12)
                ResetBar(progress: baseline, expired: expired, color: palette.tint(model.accent))
            }.hudUnit("remaining-bars")
        }.frame(height: 84)
            .overlay(alignment: .topTrailing) {
                SharedRemainingTicks().frame(width: 30, height: 64)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
    private func readings(_ quota: Quota, now: Date) -> some View {
        let time = now.timeIntervalSince1970
        let age = time - quota.observedAt
        let stale = age > Double(max(model.interval * 3, 600))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    metric("Remaining", value: Formats.percent(quota.remaining), size: 28, color: palette.tint(quota.limitRisk(now: time)?.color ?? model.accent))
                    metric("Linear baseline", value: quota.isIdle ? "—" : String(format: "%.*f%%", GaugeScale.precision(model.displayStep), quota.baseline(time)), size: 19, color: palette.ink)
                }
                Rectangle().fill(palette.separator).frame(width: 1, height: 84)
                // Both mini modes share the same scale, warning, drag, and wheel controls.
                symbols(quota, now: now).frame(width: 94)
            }.frame(height: 94)
            Rectangle().fill(palette.separator).frame(height: 1)
            HStack {
                Text(quota.isIdle ? "Reset" : "Resets in").foregroundStyle(palette.muted).hudUnit("reset-title")
                Spacer()
                Text(quota.isIdle ? "Starts on next use" : time >= quota.resetAt ? "Waiting for reset" : MiniLayout.countdown(quota.resetAt - time))
                    .monospacedDigit().foregroundStyle(palette.ink)
                    .hudUnit("reset-time")
            }.font(.system(size: 12)).frame(height: 17)
            HStack(spacing: 3) {
                Text(quota.isIdle ? "Window not started" : "\(Formats.date(quota.resetAt)) \(Formats.zone)")
                    .hudUnit("reset-date")
                Spacer(minLength: 2)
                if model.error != nil {
                    Text("Refresh failed").foregroundStyle(palette.tint(FlightDeck.amber)).help(model.error ?? "").hudUnit("update-status")
                } else if stale {
                    Text("\(Formats.duration(age)) old").foregroundStyle(palette.tint(FlightDeck.amber)).hudUnit("update-status")
                } else {
                    Text("Updated \(Formats.axisTime.string(from: quota.observedDate))").hudUnit("update-status")
                }
            }.font(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
        }
    }
    private func metric(_ label: String, value: String, size: CGFloat, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(palette.muted)
            Text(value).font(.system(size: size, weight: .medium, design: .monospaced)).tracking(-0.8).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).hudUnit("metric-\(label)")
    }
}

/// Service names only select a service; the separate cursor box owns HUD dragging.
struct HUDServiceLabel: NSViewRepresentable {
    @Binding var selection: String
    var labelProvider: String? = nil
    var showsMenu = true
    let color: Color
    func makeNSView(context: Context) -> HUDServiceControl { HUDServiceControl() }
    func updateNSView(_ view: HUDServiceControl, context: Context) {
        view.selectedProvider = selection; view.labelProvider = labelProvider ?? selection
        view.showsMenu = showsMenu; view.ink = NSColor(color)
        view.onSelect = { selection = $0 }; view.needsDisplay = true
        view.toolTip = showsMenu ? "Click to choose service" : "Click to select \(view.labelProvider.capitalized)"
    }
}

final class HUDServiceControl: NSControl {
    var selectedProvider = "codex"
    var labelProvider = "codex"
    var showsMenu = true
    var ink = NSColor(MiniPalette.hudGreen)
    var onSelect: ((String) -> Void)?
    private var mousePress: NSEvent?
    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 22) }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.004).setFill(); bounds.fill()
        let weight: NSFont.Weight = labelProvider == selectedProvider ? .semibold : .regular
        let text = NSAttributedString(string: labelProvider.capitalized, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight), .foregroundColor: ink])
        text.draw(at: NSPoint(x: 3, y: (bounds.height - text.size().height) / 2))
    }
    override func mouseDown(with event: NSEvent) { mousePress = event }
    override func mouseDragged(with event: NSEvent) {
        guard let pressed = mousePress,
              hypot(event.locationInWindow.x - pressed.locationInWindow.x, event.locationInWindow.y - pressed.locationInWindow.y) >= 3 else { return }
        // Cancel a dragged click without handing it to the window.
        mousePress = nil
    }
    override func mouseUp(with event: NSEvent) {
        guard mousePress != nil else { return }; mousePress = nil; activate()
    }
    private func activate() {
        window?.makeFirstResponder(self)
        guard showsMenu else { onSelect?(labelProvider); return }
        let menu = NSMenu()
        for (index, provider) in ["codex", "claude"].enumerated() {
            let item = NSMenuItem(title: provider.capitalized, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = provider == selectedProvider ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }
    @objc private func selectProvider(_ sender: NSMenuItem) { onSelect?(sender.tag == 0 ? "codex" : "claude") }
    override func keyDown(with event: NSEvent) {
        if [36,49,125].contains(event.keyCode) { activate() } else { super.keyDown(with: event) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { showsMenu ? .popUpButton : .button }
    override func accessibilityLabel() -> String? { showsMenu ? "Service" : labelProvider.capitalized }
    override func accessibilityValue() -> Any? { labelProvider.capitalized }
    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
}

/// A monochrome control whose thumb and track keep the HUD's green ink.
struct HUDOpacitySlider: View {
    @Binding var value: Double
    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 6)
            let position = (MiniLayout.opacity(value) - 0.3) / 0.7
            ZStack(alignment: .leading) {
                Rectangle().fill(MiniPalette.hudGreen.opacity(0.35)).frame(height: 1)
                    .padding(.horizontal, 3)
                Rectangle().fill(MiniPalette.hudGreen).frame(width: 4, height: 9)
                    .offset(x: 1 + travel * position)
            }.frame(height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = min(1, max(0, (drag.location.x - 3) / travel))
                    value = MiniLayout.opacity(((0.3 + fraction * 0.7) / 0.05).rounded() * 0.05)
                })
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Window opacity")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = MiniLayout.opacity(value + 0.05)
                case .decrement: value = MiniLayout.opacity(value - 0.05)
                @unknown default: break
                }
            }
    }
}

enum DotUnit: String {
    case time
    case percentagePoints
}

struct DotScale {
    static let values = [1.0, 2.0, 5.0]
    static let weeklyMinutes = [120.0, 240, 480, 1440, 2880, 5760]
    /// The diamond covers ±0.4 dot, or ±2 equivalent budget minutes at 5m/dot.
    static let diamondHalfSpanInDots = 0.4
    static func bounded(_ index: Int, count: Int = values.count) -> Int { min(max(0, count - 1), max(0, index)) }
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
        self.index = Self.bounded(index, count: unit == .time && Self.isLongWindow(self.durationMinutes) ? Self.weeklyMinutes.count : Self.values.count)
    }
    /// Time values are equivalent budget minutes, not a depletion-time forecast.
    var options: [Double] {
        unit == .percentagePoints ? Self.values : Self.isLongWindow(durationMinutes) ? Self.weeklyMinutes : [5, 10, 15]
    }
    var pointsPerDot: Double { unit == .percentagePoints ? options[index] : options[index] * 100 / durationMinutes }
    var caption: String {
        if unit == .percentagePoints { return "\(Int(options[index])) pp/dot" }
        if options[index] >= 1440 { return "\(Int(options[index] / 1440))d/dot" }
        return Self.isLongWindow(durationMinutes) ? "\(Int(options[index] / 60))h/dot" : "\(Int(options[index]))m/dot"
    }
    var compactCaption: String { caption.replacingOccurrences(of: "/dot", with: "").replacingOccurrences(of: " ", with: "") }
    private func quantity(_ value: Double) -> String {
        if unit == .percentagePoints {
            let amount = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return "\(amount) percentage point\(value == 1 ? "" : "s")"
        }
        let minutes = Int(value.rounded()), days = minutes / 1440, hours = (minutes % 1440) / 60, remainder = minutes % 60
        if days > 0 {
            return "\(days) day\(days == 1 ? "" : "s")"
                + (hours == 0 ? "" : " \(hours) hour\(hours == 1 ? "" : "s")")
                + (remainder == 0 ? "" : " \(remainder) minute\(remainder == 1 ? "" : "s")")
        }
        if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
                + (remainder == 0 ? "" : " \(remainder) minute\(remainder == 1 ? "" : "s")")
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
    var optionNames: [String] { options.map { quantity($0) + " per dot" } }
    var diamondHalfSpanText: String { quantity(options[index] * Self.diamondHalfSpanInDots) }
    var limitText: String { quantity(options[index] * 2) }
    var warningText: String {
        unit == .time ? "at least \(limitText) of consumption ahead of the linear budget" : "at least \(limitText) below the linear budget"
    }
}

/// Transparent native wheel target; mouse and trackpad input both select discrete scales.
struct DotScaleWheel: NSViewRepresentable {
    @Environment(\.miniPalette) private var palette
    @Binding var selection: Int
    let labels: [String]
    func makeNSView(context: Context) -> DotScaleControl { DotScaleControl() }
    func updateNSView(_ view: DotScaleControl, context: Context) {
        view.selection = DotScale.bounded(selection, count: labels.count)
        view.labels = labels
        if view.hudHitTesting != palette.hud { view.hudHitTesting = palette.hud; view.needsDisplay = true }
        view.onSelect = { selection = $0 }
        view.toolTip = "\(labels[DotScale.bounded(selection, count: labels.count)]). \(palette.hud ? "Scroll within the diamond's bounds, including its hollow center. Click to choose." : "Scroll anywhere in the instrument. Click to choose, or drag to move the window.")"
    }
}

final class DotScaleControl: NSControl {
    var hudHitTesting = false
    var selection = 1
    var labels = ["1 percentage point per dot", "2 percentage points per dot", "5 percentage points per dot"]
    var onSelect: ((Int) -> Void)?
    private var scrollRemainder: CGFloat = 0
    private var lastScroll: TimeInterval = 0
    private var mousePress: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        // WindowServer otherwise passes events through zero-alpha holes in a transparent window.
        if hudHitTesting { NSColor.black.withAlphaComponent(0.004).setFill(); bounds.fill() }
    }
    private func choose(_ index: Int) {
        let next = DotScale.bounded(index, count: labels.count)
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
        if !hudHitTesting { window?.performDrag(with: pressed) }
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
    @Environment(\.miniPalette) private var palette
    let remaining: Double
    let baseline: Double?
    var scale = DotScale(unit: .percentagePoints, durationMinutes: 300, index: 1)
    var isCurrent = true
    let color: Color
    var sampleTime: TimeInterval? = nil
    private var deviation: UsageDeviation { UsageDeviation(remaining: remaining, baseline: baseline, pointsPerDot: scale.pointsPerDot, isCurrent: isCurrent) }
    static func diamondDiameter(height: CGFloat) -> CGFloat {
        max(0, height / 2 - 8) / CGFloat(UsageDeviation.dotsPerSide) * DotScale.diamondHalfSpanInDots * 2
    }
    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width / 2
            let center = geometry.size.height / 2
            let travel = center - 8
            let diamondDiameter = Self.diamondDiameter(height: geometry.size.height)
            ZStack {
                ForEach(-2...2, id: \.self) { tick in
                    let y = center + Double(tick) / Double(UsageDeviation.dotsPerSide) * travel
                    let dotX = x - 22
                    if tick == 0 {
                        Path { path in
                            path.move(to: CGPoint(x: dotX - 2.5, y: y)); path.addLine(to: CGPoint(x: dotX + 2.5, y: y))
                            path.move(to: CGPoint(x: dotX, y: y - 2.5)); path.addLine(to: CGPoint(x: dotX, y: y + 2.5))
                        }.stroke(palette.hud ? palette.ink : palette.muted.opacity(0.85), lineWidth: palette.hud ? 1 : 0.75)
                    } else {
                        Circle().stroke(palette.hud ? palette.ink : palette.muted.opacity(0.65), lineWidth: palette.hud ? 1 : 0.75)
                            .frame(width: 3, height: 3).position(x: dotX, y: y)
                    }
                }
                if deviation.difference != nil {
                    let y = center - deviation.normalized * travel
                    Rectangle().fill(palette.ink).frame(width: 32, height: 1.25).position(x: x, y: y)
                        .help("Linear baseline: \(Formats.percent(baseline!))").opacity(isCurrent ? 1 : 0.4)
                    if deviation.outsideScale {
                        Path { path in
                            let direction = deviation.normalized > 0 ? -1.0 : 1.0
                            path.move(to: CGPoint(x: x - 3, y: y + direction * 3))
                            path.addLine(to: CGPoint(x: x, y: y + direction * 6))
                            path.addLine(to: CGPoint(x: x + 3, y: y + direction * 3))
                        }.stroke(palette.ink.opacity(isCurrent ? 1 : 0.4), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }
                }
                FixedUsageDiamond(warning: deviation.warning, color: color, diameter: diamondDiameter, sampleTime: sampleTime)
                    .position(x: x, y: center)
                    .help("Current remaining usage: \(Formats.percent(remaining)). Diamond span: ±\(scale.diamondHalfSpanText).")
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Remaining usage against linear baseline")
            .accessibilityValue(accessibilitySummary)
            .help("Diamond: current remaining usage, fixed at center; its top and bottom mark ±\(scale.diamondHalfSpanText). White bar: linear baseline. \(scale.optionNames[scale.index]); limits ±\(scale.limitText). Bar above center: below budget. \(palette.hud ? "Blinking hollow green diamond" : "Alternating red"): \(scale.warningText).\(scale.unit == .time ? " Time measures the linear budget difference, not a depletion forecast." : "")\(isCurrent ? "" : " Last observation; alert paused.")")
    }
    private var accessibilitySummary: String {
        let reference = baseline.map(Formats.percent) ?? "unavailable"
        let alert = deviation.warning ? "; \(scale.warningText)" : ""
        return "Remaining \(Formats.percent(remaining)); baseline \(reference); \(scale.optionNames[scale.index]); diamond span ±\(scale.diamondHalfSpanText)\(alert)\(isCurrent ? "" : "; last observation, alert paused")"
    }
}

struct FixedUsageDiamond: View {
    @Environment(\.miniPalette) private var palette
    let warning: Bool
    let color: Color
    let diameter: CGFloat
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
            } else { diamond(red: warning && !palette.hud) }
        }.frame(width: diameter, height: diameter).transaction { $0.animation = nil }
    }
    @ViewBuilder private func diamond(red: Bool) -> some View {
        if palette.hud {
            UsageDiamondShape().stroke(MiniPalette.hudGreen, lineWidth: 1.5)
                // Clip the outline inward to retain the calibrated ±0.4-dot outer span.
                .clipShape(UsageDiamondShape())
                .opacity(warning && red ? 0 : 1)
        } else {
            UsageDiamondShape().fill(red ? FlightDeck.alert : color)
                // Keep the separator behind the fill so its visible tips retain the calibrated span.
                .background(UsageDiamondShape().stroke(palette.panel, lineWidth: 1))
        }
    }
}

struct UsageDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

/// A shared 0–100% reference for the two remaining-usage and remaining-time bars.
struct SharedRemainingTicks: View {
    @Environment(\.miniPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width / 2
            ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                let y = geometry.size.height * (1 - fraction)
                Path { path in
                    path.move(to: CGPoint(x: x - 2.5, y: y))
                    path.addLine(to: CGPoint(x: x + 2.5, y: y))
                }.stroke(palette.hud ? palette.ink : palette.muted.opacity(0.75), lineWidth: palette.hud ? 1 : 0.75)
            }
        }
    }
}

struct RemainingBar: View {
    @Environment(\.miniPalette) private var palette
    let remaining: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.08))
                Rectangle().fill(color).frame(height: geometry.size.height * min(1, max(0, remaining / 100)))
            }.clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(palette.hud ? palette.ink : palette.muted.opacity(0.5), lineWidth: palette.hud ? 1 : 0.75))
        }.frame(width: 7, height: 64)
            .help("Actual remaining usage: \(Formats.percent(remaining)). Full height is 100%.")
            .accessibilityElement(children: .ignore).accessibilityLabel("Actual remaining usage")
            .accessibilityValue(Formats.percent(remaining))
    }
}

struct ResetBar: View {
    @Environment(\.miniPalette) private var palette
    let progress: Double?
    let expired: Bool
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            RemainingBar(remaining: progress ?? 0, color: palette.ink)
                .accessibilityHidden(true)
            Image(systemName: progress == nil ? "pause" : expired ? "arrow.clockwise" : "clock")
                .font(.system(size: 9)).foregroundStyle(palette.muted).frame(height: 10)
        }.frame(width: 12)
            .help(progress == nil ? "The reset window has not started" : expired ? "Waiting for a new reset window" : "Time left until reset")
            .accessibilityElement(children: .ignore).accessibilityLabel("Time left until reset")
            .accessibilityValue(progress.map(Formats.percent) ?? "Not started")
    }
}

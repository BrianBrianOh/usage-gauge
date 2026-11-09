import AppKit
import SwiftUI
import Charts

struct Sample: Codable, Identifiable {
    let t: Double
    let remaining: Double
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}

struct Quota: Codable, Identifiable {
    let id: String
    let name: String
    let durationMinutes: Double
    let resetAt: Double
    let remaining: Double
    let observedAt: Double
    let points: [Sample]
    var severity: String? = nil
    var active: Bool? = nil
    var idle: Bool? = nil
    var isIdle: Bool { idle == true }
    var start: Double { resetAt - durationMinutes * 60 }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var resetDate: Date { Date(timeIntervalSince1970: resetAt) }
    var observedDate: Date { Date(timeIntervalSince1970: observedAt) }
    var title: String {
        let duration = durationMinutes == 10080 ? "Weekly limit" : durationMinutes == 300 ? "5-hour limit" : "\(Int(durationMinutes / 60))-hour limit"
        return name == "codex" || name == "claude" ? duration : "\(name) · \(duration)"
    }
    func baseline(_ timestamp: Double) -> Double {
        guard durationMinutes > 0 else { return 0 }
        return min(100, max(0, (resetAt - timestamp) / (durationMinutes * 60) * 100))
    }
    var gap: Double { remaining - baseline(observedAt) }
    /// One day, or a fifth of a shorter window: a 5-hour window never holds 24 hours of history.
    var burnLookback: Double { min(86400, durationMinutes * 60 / 5) }
    var lookbackText: String {
        let hours = Int((burnLookback / 3600).rounded())
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
    /// Consumption per day, measured over the lookback.
    var dailyBurn: Double? {
        let lookback = burnLookback, target = observedAt - lookback
        guard lookback > 0, let first = points.first, first.t <= target, points.count >= 2 else { return nil }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            if b.t >= target {
                if b.t == target { return b.remaining >= remaining ? (b.remaining - remaining) * (86400 / lookback) : nil }
                guard b.t - a.t <= min(14400, lookback) else { return nil }
                let ratio = (target - a.t) / max(1, b.t - a.t)
                let delta = a.remaining + (b.remaining - a.remaining) * ratio - remaining
                // Upward quota corrections are not a negative consumption forecast.
                return delta < 0 ? nil : delta * (86400 / lookback)
            }
        }
        return nil
    }
    var projection: [Sample] {
        guard let burn = dailyBurn, observedAt < resetAt else { return [] }
        let end = burn > 0 ? min(resetAt, observedAt + remaining / burn * 86400) : resetAt
        return [Sample(t: observedAt, remaining: remaining), Sample(t: end, remaining: max(0, remaining - burn * (end - observedAt) / 86400))]
    }
    var forecastText: String {
        guard let burn = dailyBurn else { return "FORECAST N/A / requires \(lookbackText) of observations." }
        let predicted = remaining - burn * max(0, resetAt - observedAt) / 86400
        if burn > 0 && predicted < 0 {
            let hours = (resetAt - observedAt - remaining / burn * 86400) / 3600
            return String(format: "At current pace: empty about %.0fh before reset.", hours)
        }
        return String(format: "At current pace: about %.1f%% remaining at reset.", predicted)
    }
}

/// How close a limit is to stopping work. Pace against the linear baseline is a separate signal.
enum LimitRisk: Int, Comparable {
    case warning = 1, critical = 2
    static func < (a: LimitRisk, b: LimitRisk) -> Bool { a.rawValue < b.rawValue }
    var color: Color { self == .critical ? FlightDeck.alert : FlightDeck.caution }
    var label: String { self == .critical ? "Limit critical" : "Limit warning" }
}

extension Quota {
    /// Unscoped limits (the session and all-model weekly windows) count every model and surface.
    var isAccountWide: Bool { name == "codex" || name == "claude" }
    /// Claude grades its own meters; other limits use remaining capacity. Either way, a recent
    /// pace that empties the limit before it resets is at least a warning.
    func limitRisk(now: Double) -> LimitRisk? {
        guard !isIdle, now < resetAt else { return nil }
        var risk: LimitRisk?
        switch severity {
        case "critical": risk = .critical
        case "warning": risk = .warning
        case .some: risk = nil
        case nil: risk = remaining <= 10 ? .critical : remaining <= 25 ? .warning : nil
        }
        if let burn = dailyBurn, burn > 0, remaining - burn * (resetAt - observedAt) / 86400 < 0 { risk = max(risk ?? .warning, .warning) }
        return risk
    }
}

extension Snapshot {
    /// The limit a compact indicator shows: the server's pick, else the tightest started window.
    var glance: Quota? {
        windows.first { $0.active == true } ?? windows.filter { !$0.isIdle }.min { $0.remaining < $1.remaining } ?? windows.first
    }
    /// The most serious limit at risk, tightest first: what a glance at this service should report.
    func riskiest(now: Double) -> (quota: Quota, risk: LimitRisk)? {
        windows.compactMap { quota in quota.limitRisk(now: now).map { (quota: quota, risk: $0) } }
            .max { $0.risk != $1.risk ? $0.risk < $1.risk : $0.quota.remaining > $1.quota.remaining }
    }
    /// Other account-wide limits at risk, which also stop the work counted in `quota`.
    func sharedConstraints(for quota: Quota, now: Double) -> [(quota: Quota, risk: LimitRisk)] {
        windows.filter { $0.id != quota.id && $0.isAccountWide }
            .compactMap { other in other.limitRisk(now: now).map { (quota: other, risk: $0) } }
            .sorted { $0.risk > $1.risk }
    }
}

/// Claude's pay-as-you-go credits, which keep work going after a plan limit is reached.
struct ExtraUsage: Codable {
    var enabled: Bool
    var used: Double? = nil
    var limit: Double? = nil
    var currency: String? = nil
    var percent: Double? = nil
    var summary: String {
        guard enabled else { return "Extra usage off: work stops when a limit reaches 100%." }
        guard let used else { return "Extra usage on: work continues past 100%." }
        let cap = limit.map { " of " + Formats.money($0, currency) } ?? ""
        return "Extra usage on: \(Formats.money(used, currency))\(cap) used past plan limits."
    }
}

struct UsageShare: Codable, Identifiable {
    let name: String
    let percent: Double
    var id: String { name }
}

struct Snapshot: Codable {
    var accountKey: String?
    var windows: [Quota] = []
    var error: String?
    var errorCode: String?
    var fetchedAt: Double?
    var source: String?
    var plan: String?
    var extra: ExtraUsage?
    var breakdown: [UsageShare]?
    private enum CodingKeys: String, CodingKey { case windows, error, errorCode, fetchedAt, accountKey, source, plan, extra, breakdown }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decodeIfPresent([Quota].self, forKey: .windows) ?? []
        error = try values.decodeIfPresent(String.self, forKey: .error)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        fetchedAt = try values.decodeIfPresent(Double.self, forKey: .fetchedAt)
        accountKey = try values.decodeIfPresent(String.self, forKey: .accountKey)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        extra = try values.decodeIfPresent(ExtraUsage.self, forKey: .extra)
        breakdown = try values.decodeIfPresent([UsageShare].self, forKey: .breakdown)
    }
}

enum Formats {
    static let timestamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent; f.dateFormat = "MMM d · HH:mm"; return f
    }()
    static func date(_ timestamp: Double) -> String { self.timestamp.string(from: Date(timeIntervalSince1970: timestamp)) }
    static let axisTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent; f.dateFormat = "HH:mm"; return f
    }()
    static let axisDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent; f.dateFormat = "MMM d"; return f
    }()
    static var zone: String { TimeZone.autoupdatingCurrent.abbreviation() ?? TimeZone.autoupdatingCurrent.identifier }
    static func money(_ amount: Double, _ currency: String?) -> String {
        currency == nil || currency == "USD" ? String(format: "$%.2f", amount) : String(format: "%.2f %@", amount, currency!)
    }
    static func percent(_ number: Double) -> String { String(format: number.rounded() == number ? "%.0f%%" : "%.1f%%", number) }
    static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60)), hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)DAY" + (hours % 24 == 0 ? "" : " \(hours % 24)HR") }
        if hours > 0 { return "\(hours)HR" + (minutes % 60 == 0 ? "" : " \(minutes % 60)MIN") }
        return "\(minutes)MIN"
    }
}

#if SCREENSHOT_RENDER
// Documentation builds use an in-memory fixture with no accounts, preferences, or collectors.
typealias UsageModel = ScreenshotModel
#else
@MainActor final class UsageModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var claudeSnapshot = Snapshot()
    @Published var claudeRefreshing = false
    @Published var provider = UserDefaults.standard.string(forKey: "selectedProvider") ?? "codex" {
        didSet {
            UserDefaults.standard.set(provider, forKey: "selectedProvider")
            selectedID = provider == "claude" ? claudeSnapshot.windows.first(where: { $0.active == true })?.id ?? "claude:seven_day" : "codex:primary"
            selectedDate = nil; onChange?()
        }
    }
    @Published var refreshing = false
    @Published var transientError: String?
    @Published var selectedID = UserDefaults.standard.string(forKey: "selectedLimit") ?? "codex:primary" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedLimit"); selectedDate = nil; onChange?() }
    }
    @Published var selectedDate: Date?
    @Published var spanIndex = GaugeScale.bounded(UserDefaults.standard.object(forKey: "spanIndex") as? Int ?? 4) {
        didSet { selectedDate = nil; UserDefaults.standard.set(spanIndex, forKey: "spanIndex") }
    }
    @Published var stepIndex = GaugeScale.bounded(UserDefaults.standard.object(forKey: "stepIndex") as? Int ?? 0) {
        didSet { UserDefaults.standard.set(stepIndex, forKey: "stepIndex") }
    }
    var displayStep: Double { GaugeScale.steps[stepIndex] }
    @Published var interval: Int = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 120 {
        didSet { UserDefaults.standard.set(interval, forKey: "refreshInterval"); schedule() }
    }
    @Published var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop") {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop"); onChange?() }
    }
    @Published var miniMode = UserDefaults.standard.bool(forKey: "miniMode") {
        didSet { UserDefaults.standard.set(miniMode, forKey: "miniMode"); onChange?() }
    }
    @Published var miniOnTop = UserDefaults.standard.object(forKey: "miniOnTop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(miniOnTop, forKey: "miniOnTop"); onChange?() }
    }
    @Published var miniSymbols = UserDefaults.standard.bool(forKey: "miniSymbols") {
        didSet { UserDefaults.standard.set(miniSymbols, forKey: "miniSymbols"); onChange?() }
    }
    @Published var miniHUD = UserDefaults.standard.bool(forKey: "miniHUD") {
        didSet { UserDefaults.standard.set(miniHUD, forKey: "miniHUD"); onChange?() }
    }
    @Published var miniAutoContrast = UserDefaults.standard.bool(forKey: "miniAutoContrast") {
        didSet { UserDefaults.standard.set(miniAutoContrast, forKey: "miniAutoContrast"); onChange?() }
    }
    @Published var hudContrastMap: NSImage?
    @Published var hudControlsHovered = false
    @Published var hudContrastUnits: [HUDContrastUnit] = [] {
        didSet { if hudContrastUnits != oldValue { onHUDContrastUnitsChanged?(hudContrastUnits) } }
    }
    var onHUDContrastUnitsChanged: (([HUDContrastUnit]) -> Void)?
    @Published var hudContrastStatus = HUDContrastStatus.off
    var onRequestHUDContrastPermission: (() -> Void)?
    @Published var miniScaleIndex = DotScale.bounded(UserDefaults.standard.object(forKey: "miniScaleIndex") as? Int ?? 1) {
        didSet { UserDefaults.standard.set(miniScaleIndex, forKey: "miniScaleIndex") }
    }
    @Published var miniDotUnit = DotUnit(rawValue: UserDefaults.standard.string(forKey: "miniDotUnit") ?? "") ?? .time {
        didSet { UserDefaults.standard.set(miniDotUnit.rawValue, forKey: "miniDotUnit") }
    }
    @Published var miniSessionTimeIndex = DotScale.bounded(UserDefaults.standard.object(forKey: "miniSessionTimeIndex") as? Int ?? 0) {
        didSet { UserDefaults.standard.set(miniSessionTimeIndex, forKey: "miniSessionTimeIndex") }
    }
    @Published var miniWeeklyTimeIndex = DotScale.bounded(UserDefaults.standard.object(forKey: "miniWeeklyTimeIndex") as? Int ?? 1, count: DotScale.weeklyMinutes.count) {
        didSet { UserDefaults.standard.set(miniWeeklyTimeIndex, forKey: "miniWeeklyTimeIndex") }
    }
    var miniDotIndex: Int {
        get {
            if miniDotUnit == .percentagePoints { return miniScaleIndex }
            return DotScale.isLongWindow(quota?.durationMinutes ?? 300) ? miniWeeklyTimeIndex : miniSessionTimeIndex
        }
        set {
            if miniDotUnit == .percentagePoints { miniScaleIndex = DotScale.bounded(newValue) }
            else if DotScale.isLongWindow(quota?.durationMinutes ?? 300) { miniWeeklyTimeIndex = DotScale.bounded(newValue, count: DotScale.weeklyMinutes.count) }
            else { miniSessionTimeIndex = DotScale.bounded(newValue) }
        }
    }
    var miniDotScale: DotScale { DotScale(unit: miniDotUnit, durationMinutes: quota?.durationMinutes ?? 300, index: miniDotIndex) }
    @Published var miniOpacity = MiniLayout.opacity(UserDefaults.standard.object(forKey: "miniOpacity") as? Double ?? 1) {
        didSet { UserDefaults.standard.set(miniOpacity, forKey: "miniOpacity"); onChange?() }
    }
    var onMoveMini: ((MiniCorner) -> Void)?
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var process: Process?
    private var claudeService: ClaudeService?
    let dataDirectory: URL
    var activeSnapshot: Snapshot { provider == "claude" ? claudeSnapshot : snapshot }
    var quota: Quota? { activeSnapshot.windows.first(where: { $0.id == selectedID }) ?? activeSnapshot.windows.first }
    /// The single limit a compact indicator shows: the server's pick, else for Claude the tightest started window.
    var headline: Quota? {
        let windows = activeSnapshot.windows
        if let pick = windows.first(where: { $0.active == true }) { return pick }
        guard provider == "claude" else { return quota }
        return windows.filter { !$0.isIdle }.min(by: { $0.remaining < $1.remaining }) ?? quota
    }
    var sourceLabel: String {
        guard provider == "claude" else { return "Account" }
        return claudeSnapshot.source ?? "claude.ai"
    }
    var error: String? { provider == "claude" ? claudeSnapshot.error : transientError ?? snapshot.error }
    var isRefreshing: Bool { provider == "claude" ? claudeRefreshing : refreshing }
    var accent: Color { FlightDeck.cyan }

    init() {
        dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Usage Gauge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        loadSnapshot()
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("claude-state.json")), let value = try? JSONDecoder().decode(Snapshot.self, from: data) { claudeSnapshot = value }
        if !activeSnapshot.windows.contains(where: { $0.id == selectedID }), let pick = headline { selectedID = pick.id }
    }
    func loadSnapshot() {
        let own = dataDirectory.appendingPathComponent("state.json")
        guard let bytes = try? Data(contentsOf: own), let parsed = try? JSONDecoder().decode(Snapshot.self, from: bytes) else { return }
        if snapshot.windows.first?.resetAt != parsed.windows.first?.resetAt { selectedDate = nil }
        snapshot = parsed
        onChange?()
    }
    func start() {
        claudeService = ClaudeService(directory: dataDirectory) { [weak self] value in
            self?.claudeSnapshot = value; self?.claudeRefreshing = false; self?.onChange?()
        }
        refreshAll(); schedule()
    }
    func connectClaude() { claudeService?.showConnection() }
    func refreshAll() { refreshCodex(); claudeRefreshing = true; claudeService?.refresh() }
    func schedule() {
        timer?.invalidate()
        guard interval > 0 else { return }
        let scheduled = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer = scheduled; RunLoop.main.add(scheduled, forMode: .common)
    }
    func refresh() {
        if provider == "claude" { claudeRefreshing = true; claudeService?.refresh() }
        else { refreshCodex() }
    }
    private func refreshCodex() {
        guard !refreshing else { return }
        guard let helper = Bundle.main.url(forResource: "native_refresh", withExtension: "py") else {
            transientError = "The usage reader is missing from this app."; return
        }
        refreshing = true; transientError = nil; onChange?()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [helper.path, "--state-dir", dataDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        process = task
        task.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil; self.refreshing = false
                self.loadSnapshot()
                if completed.terminationStatus != 0 && self.snapshot.error == nil {
                    self.transientError = "Unable to refresh usage. Try again."
                }
                self.onChange?()
            }
        }
        do { try task.run() }
        catch { process = nil; refreshing = false; transientError = "Unable to start the usage reader."; onChange?() }
    }
    func stop() { timer?.invalidate(); process?.terminate() }
}
#endif

struct LegendItem: View {
    let text: String
    let color: Color
    var dashed = false
    var body: some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 15, y: 0)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3,2] : []))
                .frame(width: 15, height: 1)
            Text(text).font(FlightDeck.label(8)).tracking(0.5).foregroundStyle(FlightDeck.muted)
        }
    }
}

/// Says when another account-wide limit can stop work before the selected one.
struct SharedLimitBanner: View {
    let constraint: (quota: Quota, risk: LimitRisk)
    let extra: ExtraUsage?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(constraint.quota.title): \(Formats.percent(constraint.quota.remaining)) left · \(constraint.risk.label)")
                    .font(.system(size: 11, weight: .medium))
                Text("It counts all usage, so it can stop work before this limit does." + (extra.map { $0.enabled ? " Extra usage is on." : " Extra usage is off." } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(FlightDeck.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(constraint.risk.color)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(constraint.risk.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(constraint.risk.color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Marks a service whose limits are at risk, including the one not on screen.
struct RiskDot: View {
    let risk: LimitRisk?
    var tint: Color? = nil
    var body: some View {
        if let risk {
            Circle().fill(tint ?? risk.color).frame(width: 5, height: 5).accessibilityLabel(risk.label)
        }
    }
}

struct LiveMetrics: View {
    let quota: Quota
    let accent: Color
    let step: Double
    var condition = DataCondition.live
    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            let baseline = quota.baseline(context.date.timeIntervalSince1970)
            let gap = quota.remaining - baseline
            HStack(spacing: 16) {
                ReserveDial(remaining: quota.remaining, accent: condition.permitsReference ? quota.limitRisk(now: context.date.timeIntervalSince1970)?.color ?? accent : FlightDeck.caution,
                            caption: condition.isLastKnown ? "LAST REMAINING" : "REMAINING")
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 88)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("LINEAR BASELINE").font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                        Spacer(minLength: 2)
                        Text("\(String(format: "%g", step))s").font(FlightDeck.label(9)).foregroundStyle(accent.opacity(0.8))
                    }
                    Text(condition.permitsReference ? String(format: "%.*f%%", min(2, GaugeScale.precision(step)), baseline) : "N/A")
                        .font(.system(size: 31, weight: .regular, design: .monospaced)).tracking(0).monospacedDigit().foregroundStyle(accent)

                        .contentTransition(.numericText(countsDown: true))
                        .minimumScaleFactor(0.75).lineLimit(1)
                    if condition.permitsReference { ReferenceTape(value: baseline, accent: accent) }
                    else { BarberPole(color: FlightDeck.caution).frame(height: 5) }
                    HStack(spacing: 5) {
                        Text(condition.permitsReference ? (gap >= 0 ? "ABOVE BASELINE" : "BELOW BASELINE") : condition.token + " / LAST OBS").font(FlightDeck.label(8)).tracking(0.5)
                        Spacer(minLength: 2)
                        Text(condition.permitsReference ? String(format: "%@%.*f pp", gap >= 0 ? "+" : "−", min(2, GaugeScale.precision(step)), abs(gap)) : "N/A")
                            .font(FlightDeck.label(11)).monospacedDigit()
                    }.foregroundStyle(gap >= 0 ? FlightDeck.green : FlightDeck.amber)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 12).frame(height: 138).modifier(Bezel())
        }
    }
}

struct LiveCountdown: View {
    let resetAt: Double
    let accent: Color
    let step: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            let tenths = max(0, Int((resetAt - context.date.timeIntervalSince1970) * 10))
            let seconds = tenths / 10
            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RESET IN").font(FlightDeck.label(8)).tracking(0.6).foregroundStyle(FlightDeck.muted)

                }
                Spacer(minLength: 2)
                Text(step < 1 ? String(format: "%02d:%02d:%02d.%01d", seconds / 3600, seconds / 60 % 60, seconds % 60, tenths % 10) : String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                    .font(.system(size: 24, weight: .regular, design: .monospaced)).foregroundStyle(accent).tracking(0.5)
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Reset · \(Formats.zone)").font(FlightDeck.label(7)).foregroundStyle(FlightDeck.muted.opacity(0.65))
                    Text(Formats.date(resetAt)).font(FlightDeck.label(9)).foregroundStyle(FlightDeck.ink)
                }
            }
        }
    }
}

struct TrendChart: View {
    let quota: Quota
    @ObservedObject var model: UsageModel
    var referenceValid = true
    private var domain: ClosedRange<Date> { GaugeScale.domain(quota, index: model.spanIndex, now: referenceValid ? Date().timeIntervalSince1970 : quota.observedAt) }
    private var vertical: (range: ClosedRange<Double>, ticks: [Double]) {
        referenceValid ? GaugeScale.vertical(quota, index: model.spanIndex, domain: domain) : (0...100, [0,25,50,75,100])
    }
    private var selected: Sample? {
        guard let date = model.selectedDate else { return nil }
        return observed.min(by: { abs($0.t - date.timeIntervalSince1970) < abs($1.t - date.timeIntervalSince1970) })
    }
    private var observed: [Sample] { quota.points.filter { domain.contains($0.date) } }
    private var segments: [[Sample]] {
        var result: [[Sample]] = []; var segment: [Sample] = []
        for point in observed {
            if let previous = segment.last, point.t - previous.t > 14400 { result.append(segment); segment = [] }
            segment.append(point)
        }
        if !segment.isEmpty { result.append(segment) }; return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("HISTORY").font(FlightDeck.label(9)).tracking(0.8).foregroundStyle(FlightDeck.ink)
                Spacer(minLength: 2)
                LegendItem(text: "Remaining", color: model.accent)
                LegendItem(text: "Linear", color: FlightDeck.muted, dashed: true)
                if referenceValid && model.spanIndex == 4 && !quota.projection.isEmpty { LegendItem(text: "FCST", color: FlightDeck.forecast, dashed: true) }
            }
            Chart {
                ForEach(referenceValid && !observed.isEmpty ? [Sample(t: domain.lowerBound.timeIntervalSince1970, remaining: quota.baseline(domain.lowerBound.timeIntervalSince1970)), Sample(t: domain.upperBound.timeIntervalSince1970, remaining: quota.baseline(domain.upperBound.timeIntervalSince1970))] : []) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "baseline"))
                        .foregroundStyle(FlightDeck.muted.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 0.85, dash: [4,4]))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, points in
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "actual-\(index)"))
                            .foregroundStyle(model.accent).lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(referenceValid && model.spanIndex == 4 ? quota.projection : []) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "forecast"))
                        .foregroundStyle(FlightDeck.forecast).lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1,4]))
                }
                if !observed.isEmpty && domain.contains(quota.observedDate) {
                    PointMark(x: .value("Time", quota.observedDate), y: .value("Remaining", quota.remaining))
                        .foregroundStyle(model.accent).symbolSize(12)
                }

                if let point = selected {
                    RuleMark(x: .value("Observation time", point.date)).foregroundStyle(FlightDeck.muted.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.7))
                    PointMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining)).foregroundStyle(model.accent).symbolSize(20)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: vertical.range)
            .chartYAxis {
                AxisMarks(position: .leading, values: vertical.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(FlightDeck.muted.opacity(0.14))
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(Formats.percent(amount)).font(FlightDeck.label(8)) } }
                }
            }
            .chartPlotStyle { plot in plot.background(FlightDeck.screen) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(FlightDeck.muted.opacity(0.07))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text((domain.upperBound.timeIntervalSince(domain.lowerBound) <= 86400 ? Formats.axisTime : Formats.axisDate).string(from: date))
                                .font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                        }
                    }
                }
            }
            .chartXSelection(value: $model.selectedDate)
            .help("Click or drag to inspect observations")
            .frame(minHeight: 100, idealHeight: 130, maxHeight: .infinity)
            .overlay {
                if observed.isEmpty {
                    VStack(spacing: 7) {
                        Text("HISTORY N/A").font(FlightDeck.label(12))
                        BarberPole(color: FlightDeck.muted).frame(width: 72, height: 5)
                    }.foregroundStyle(FlightDeck.muted).padding(10).background(FlightDeck.screen)
                }
            }
            .accessibilityLabel("Remaining usage and linear reference until reset")
            .accessibilityValue(referenceValid ? "Actual \(Formats.percent(quota.remaining)), reference \(Formats.percent(quota.baseline(quota.observedAt)))" : "Last observation \(Formats.percent(quota.remaining)); live reference N/A")
            Text(model.spanIndex == 4 ? "Scale 0–100%" : "Scale \(Formats.percent(vertical.range.lowerBound))–\(Formats.percent(vertical.range.upperBound))")
                .font(FlightDeck.label(8)) .foregroundStyle(FlightDeck.muted).monospacedDigit()
            Text(selected.map { "\(Formats.date($0.t)) · Remaining \(Formats.percent($0.remaining)) · Linear \(Formats.percent(quota.baseline($0.t)))" } ?? (observed.isEmpty ? "No observations in this range." : ""))
                .font(FlightDeck.label(8)).foregroundStyle(FlightDeck.muted).monospacedDigit().lineLimit(1)
        }.padding(12).modifier(Bezel())
    }
}

struct GaugeView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header
                sourceSelector
                let condition = model.availability(now: context.date.timeIntervalSince1970).condition
                if let quota = model.quota, condition.permitsObservation {
                    if condition.permitsReference, let constraint = model.activeSnapshot.sharedConstraints(for: quota, now: context.date.timeIntervalSince1970).first {
                        SharedLimitBanner(constraint: constraint, extra: model.provider == "claude" ? model.claudeSnapshot.extra : nil)
                    }
                    if quota.isIdle {
                        Spacer(minLength: 0)
                        idleCard(quota)
                        Spacer(minLength: 0)
                    } else {
                        LiveMetrics(quota: quota, accent: model.accent, step: model.displayStep, condition: condition).id(model.stepIndex)
                        TrendChart(quota: quota, model: model, referenceValid: condition.permitsReference).id(quota.id + String(quota.resetAt))
                        details(quota, now: context.date)
                    }
                } else { unavailableDashboard(condition) }
                InstrumentPanel(model: model)
                controls
            }
            .padding(16)
            .frame(minWidth: 448, minHeight: 718)
            .foregroundStyle(FlightDeck.ink)
            .background(FlightDeck.shell)
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        }
    }
    private func unavailableDashboard(_ condition: DataCondition) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                ForEach(["REMAINING", "LINEAR BASELINE"], id: \.self) { label in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(label).font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                        Text("N/A").font(FlightDeck.label(32)).foregroundStyle(condition.color)
                        BarberPole(color: condition.color).frame(height: 5)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(18).frame(height: 138).modifier(Bezel())
            VStack(spacing: 12) {
                DataFlag(condition: condition)
                Text(condition.detail).font(FlightDeck.label(12)).multilineTextAlignment(.center)
                Text("HISTORY / RESET / FORECAST   N/A").font(FlightDeck.label(10)).foregroundStyle(FlightDeck.muted)
                BarberPole(color: condition.color).frame(width: 96, height: 6)
                if let error = model.error {
                    Text(error).font(FlightDeck.label(10)).foregroundStyle(FlightDeck.muted).lineLimit(3).multilineTextAlignment(.center).help(error)
                }
                HStack(spacing: 8) {
                    if model.provider == "claude" {
                        Button("CONNECT CLAUDE", action: model.connectClaude).buttonStyle(PanelButton(active: true, accent: model.accent))
                    }
                    Button("REFRESH", action: model.refresh).buttonStyle(PanelButton()).disabled(model.isRefreshing)
                }
                if condition == .authentication && model.provider == "codex" {
                    Text("Sign in to the Codex CLI or desktop app, then refresh.").font(FlightDeck.label(10)).foregroundStyle(FlightDeck.muted)
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).modifier(Bezel())
        }
    }
    private var header: some View {
        HStack {
            Text("USAGE GAUGE").font(FlightDeck.label(15)).tracking(1)
            Spacer()
            Button { model.miniMode = true } label: {
                Text("MINI")
            }.buttonStyle(PanelButton()).help("Switch to the small window · Shift-Command-M")
        }.frame(height: 30)
    }
    private var sourceSelector: some View {
        HStack(spacing: 7) {
            ForEach(["codex", "claude"], id: \.self) { provider in
                let snapshot = provider == "claude" ? model.claudeSnapshot : model.snapshot
                let state = DataAvailability.evaluate(snapshot: snapshot, quota: snapshot.glance, refreshing: false, interval: model.interval, now: Date().timeIntervalSince1970)
                let alert = state.condition.permitsReference ? snapshot.riskiest(now: Date().timeIntervalSince1970) : nil
                Button { model.provider = provider } label: {
                    HStack(spacing: 6) {
                        Text(provider.uppercased())
                        if state.condition != .live && state.condition != .idle {
                            Text(state.condition.token).font(FlightDeck.label(8)).foregroundStyle(state.condition.color)
                        } else {
                            HUDServiceMark(health: alert?.risk == .critical ? .critical : alert?.risk == .warning ? .warning : .normal,
                                           color: alert?.risk.color ?? FlightDeck.muted)
                        }
                    }
                }.buttonStyle(PanelButton(active: model.provider == provider, accent: model.accent))
                .help(alert.map { "\($0.quota.title): \(Formats.percent($0.quota.remaining)) left · \($0.risk.label)" } ?? "")
                .accessibilityLabel(provider.capitalized + (alert.map { ", " + $0.risk.label } ?? ""))
                .accessibilityAddTraits(model.provider == provider ? .isSelected : [])
            }
            Spacer(minLength: 4)
            if model.activeSnapshot.windows.count > 1 {
                Menu {
                    ForEach(model.activeSnapshot.windows) { quota in
                        Button(quota.title) { model.selectedID = quota.id }
                    }
                } label: {
                    HStack {
                        Text(model.quota?.title.uppercased() ?? "LIMIT N/A").lineLimit(1)
                        Spacer(minLength: 2)
                        Text("⌄")
                    }.font(FlightDeck.label(9)).foregroundStyle(FlightDeck.ink).padding(8)
                        .background(FlightDeck.panel).overlay(Rectangle().strokeBorder(FlightDeck.muted.opacity(0.3), lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 130)
                    .accessibilityLabel("Limit").accessibilityValue(model.quota?.title ?? "N/A")
            } else {
                Text(model.quota?.title ?? "Account limit").font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
            }
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                .buttonStyle(PanelButton()).disabled(model.isRefreshing)
                .keyboardShortcut("r", modifiers: .command).help("Refresh account usage").accessibilityLabel("Refresh usage")
        }.frame(height: 32)
    }
    private func details(_ quota: Quota, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            let expired = now.timeIntervalSince1970 >= quota.resetAt
            let condition = model.availability(now: now.timeIntervalSince1970).condition
            if condition.permitsReference {
                LiveCountdown(resetAt: quota.resetAt, accent: model.accent, step: model.displayStep).id(model.stepIndex)
            } else {
                HStack {
                    Text("RESET IN").font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                    Spacer()
                    Text("N/A").font(FlightDeck.label(24)).foregroundStyle(FlightDeck.caution)
                    DataFlag(condition: condition)
                }.frame(height: 32)
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: expired ? "clock" : "arrow.up.right").font(.system(size: 9))
                Text(!condition.permitsReference ? "FORECAST N/A / " + condition.detail : expired ? "Reset time passed. Waiting for a new observation." : quota.forecastText)
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
            }.foregroundStyle(FlightDeck.muted).help("Estimate based on the most recent \(quota.lookbackText) of observed consumption.")
            if model.provider == "claude" && condition.permitsReference { claudeNotes(quota, now: now) }
            HStack {
                if let error = model.error {
                    Annunciator(label: "Refresh failed · last known data", color: FlightDeck.amber).help(error)
                } else if now.timeIntervalSince1970 - quota.observedAt > Double(max(model.interval * 3, 600)) {
                    Annunciator(label: "Updated \(Formats.duration(now.timeIntervalSince1970 - quota.observedAt)) ago", color: FlightDeck.amber)
                } else {
                    Text("Updated \(Formats.date(quota.observedAt)) \(Formats.zone)").font(FlightDeck.label(8)).foregroundStyle(FlightDeck.muted)
                }
                Spacer(minLength: 2)
                if condition.permitsReference, let risk = quota.limitRisk(now: now.timeIntervalSince1970) {
                    Annunciator(label: risk.label, color: risk.color)
                        .help(quota.severity != nil ? "Claude's own reading of how close this limit is to stopping work" : "Little capacity left, or the recent pace empties this limit before it resets")
                }
                Text(model.sourceLabel).font(FlightDeck.label(7)).foregroundStyle(FlightDeck.muted.opacity(0.7))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).modifier(Bezel())
    }
    @ViewBuilder private func claudeNotes(_ quota: Quota, now: Date) -> some View {
        // The shared-limit banner already states extra usage when it is shown.
        if let extra = model.claudeSnapshot.extra, model.activeSnapshot.sharedConstraints(for: quota, now: now.timeIntervalSince1970).isEmpty {
            HStack(spacing: 5) {
                Image(systemName: extra.enabled ? "plus.circle" : "stop.circle").font(.system(size: 9))
                Text(extra.summary).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
            }.foregroundStyle(extra.enabled ? FlightDeck.green : FlightDeck.muted)
        }
        if quota.id == "claude:seven_day", let shares = model.claudeSnapshot.breakdown?.filter({ $0.percent > 0 }), !shares.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "chart.pie").font(.system(size: 9))
                Text("This week: " + shares.sorted { $0.percent > $1.percent }.prefix(3).map { "\($0.name) \(Formats.percent($0.percent))" }.joined(separator: " · "))
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
            }.foregroundStyle(FlightDeck.muted).help("Where this week's usage went, as reported by Claude")
        }
    }
    private func idleCard(_ quota: Quota) -> some View {
        VStack(spacing: 12) {
            ReserveDial(remaining: quota.remaining, accent: model.accent)
            Text(quota.durationMinutes == 300 ? "Session not started" : "Window not started").font(FlightDeck.label(14))
            Text(quota.durationMinutes == 300 ? "The 5-hour window starts with your next Claude message." : "This window starts with your next use.")
                .font(.system(size: 12)).foregroundStyle(FlightDeck.muted).multilineTextAlignment(.center)
            DataFlag(condition: .idle)
            Text("BASELINE / TTR / FORECAST   N/A").font(FlightDeck.label(10)).foregroundStyle(FlightDeck.muted)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(FlightDeck.amber).multilineTextAlignment(.center)
            } else {
                Text("Updated \(Formats.date(quota.observedAt)) \(Formats.zone)  /  \(model.sourceLabel)").font(FlightDeck.label(8)).foregroundStyle(FlightDeck.muted)
            }
        }.padding(24).frame(maxWidth: .infinity).modifier(Bezel())
    }
    private var controls: some View {
        HStack(spacing: 9) {
            Toggle("Keep on top", isOn: $model.alwaysOnTop).toggleStyle(.switch).controlSize(.mini).tint(model.accent)
                .help("Keep this window on top")
            if model.provider == "claude" {
                Button("Account", action: model.connectClaude).buttonStyle(.plain).foregroundStyle(FlightDeck.muted)
                    .help("Manage your Claude connection")
            }
            Spacer(minLength: 2)
            Text("Refresh").foregroundStyle(FlightDeck.muted)
            Picker("Usage polling interval", selection: $model.interval) {
                Text("1 min").tag(60); Text("2 min").tag(120)
                Text("5 min").tag(300); Text("15 min").tag(900)
            }.labelsHidden().controlSize(.mini).frame(width: 80)
                .help("Account usage is fetched at this interval. Display step only changes the local instruments.")
        }.font(FlightDeck.label(9)).frame(height: 24).padding(.horizontal, 3)
    }
}

/// Menu bar batteries with the service letter and percentage drawn inside, as on the iOS battery.
enum StatusBattery {
    struct Gauge {
        let letter: String
        let remaining: Double?
        let risk: LimitRisk?
        var failed = false
    }
    static let body = NSSize(width: 28, height: 13)
    static let nub = NSSize(width: 1.5, height: 5)
    static let gap: CGFloat = 3
    static let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    static func label(_ gauge: Gauge) -> String { "\(gauge.letter)\(gauge.remaining.map { String(Int($0.rounded())) } ?? "N/A")" }
    static func image(_ gauges: [Gauge], description: String, hud: Bool = false) -> NSImage {
        let slot = body.width + 1 + nub.width
        let size = NSSize(width: CGFloat(gauges.count) * slot + CGFloat(max(0, gauges.count - 1)) * gap, height: body.height + 2)
        // Normal ink follows the menu bar appearance; HUD ink stays green.
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, gauge) in gauges.enumerated() {
                draw(gauge, in: NSRect(x: CGFloat(index) * (slot + gap), y: 1, width: body.width, height: body.height), hud: hud)
            }
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }
    private static func draw(_ gauge: Gauge, in frame: NSRect, hud: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = (hud ? NSColor(MiniPalette.hudGreen) : .labelColor).withAlphaComponent(gauge.failed ? 0.45 : 1)
        let riskColor: NSColor? = hud ? nil : gauge.risk == .critical ? .systemRed : gauge.risk == .warning ? .systemOrange : nil
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // A nearly empty fill is only a sliver, so a limit at risk also colours the case.
        (riskColor ?? ink.withAlphaComponent(ink.alphaComponent * 0.5)).set()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1; outline.stroke()
        NSBezierPath(roundedRect: NSRect(x: frame.maxX + 1, y: frame.midY - nub.height / 2, width: nub.width, height: nub.height), xRadius: 0.75, yRadius: 0.75).fill()
        let inner = frame.insetBy(dx: 2, dy: 2)
        if gauge.remaining == nil {
            // A local invalid-data hatch must not look like an empty (0%) battery.
            context.saveGState(); context.clip(to: inner)
            ink.withAlphaComponent(0.3).setStroke()
            let stripes = NSBezierPath()
            for x in stride(from: inner.minX - inner.height, through: inner.maxX, by: 4) {
                stripes.move(to: NSPoint(x: x, y: inner.minY)); stripes.line(to: NSPoint(x: x + inner.height, y: inner.maxY))
            }
            stripes.lineWidth = 0.75; stripes.stroke(); context.restoreGState()
            let text = NSAttributedString(string: label(gauge), attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(1)])
            text.draw(at: NSPoint(x: frame.midX - text.size().width / 2, y: frame.midY - font.capHeight / 2 + font.descender))
            context.endTransparencyLayer(); return
        }
        (riskColor ?? ink).setFill()
        let level = min(1, max(0, (gauge.remaining ?? 0) / 100))
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * level, height: inner.height), xRadius: 1.5, yRadius: 1.5).fill()
        // XOR cuts the text out of the fill and keeps it solid over the empty part.
        context.setBlendMode(.xor)
        let text = NSAttributedString(string: label(gauge), attributes: [.font: font, .foregroundColor: ink])
        let width = text.size().width
        text.draw(at: NSPoint(x: frame.midX - width / 2, y: frame.midY - font.capHeight / 2 + font.descender))
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = UsageModel()
    var window: NSWindow!
    var miniWindow: MiniPanel!
    var displayedMini: Bool?
    var statusItem: NSStatusItem!
    var topMenuItem: NSMenuItem!
    var miniMenuItem: NSMenuItem!
    var hudMenuItem: NSMenuItem!
    var wakeObserver: NSObjectProtocol?
    var screenObserver: NSObjectProtocol?
    var contrastController: HUDContrastController?
    private var hudInkRefreshScheduled = false
    private var hudInkCapturedUnits: [HUDContrastUnit] = []
    private var hudInkCapturedScale: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let appMenu = NSMenu()
        let menu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = menu; appMenu.addItem(appItem)
        let mode = menu.addItem(withTitle: "Toggle Mini Mode", action: #selector(toggleMiniMode), keyEquivalent: "m")
        mode.keyEquivalentModifierMask = [.command, .shift]; mode.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Usage Gauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 780), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Usage Gauge"
        window.backgroundColor = NSColor(FlightDeck.shell)
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 480, height: 750)
        window.contentView = NSHostingView(rootView: GaugeView(model: model))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("UsageGaugeMainWindow")
        if window.contentLayoutRect.height < 750 { window.setContentSize(NSSize(width: max(480, window.contentLayoutRect.width), height: 750)) }
        miniWindow = MiniPanel(contentRect: NSRect(origin: .zero, size: MiniLayout.size(symbols: model.miniSymbols)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        miniWindow.title = "Usage Gauge Mini"
        miniWindow.isReleasedWhenClosed = false; miniWindow.isFloatingPanel = true; miniWindow.hidesOnDeactivate = false
        miniWindow.isMovableByWindowBackground = !model.miniHUD; miniWindow.isOpaque = false; miniWindow.backgroundColor = .clear; miniWindow.hasShadow = !model.miniHUD
        miniWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let miniHost = MiniHostingView(rootView: MiniView(model: model))
        miniHost.sizingOptions = []
        miniHost.wantsLayer = true; miniHost.layer?.backgroundColor = NSColor.clear.cgColor
        miniWindow.contentView = miniHost
        miniWindow.delegate = self
        let restoredMini = miniWindow.setFrameUsingName("UsageGaugeMiniWindow")
        if let screen = miniWindow.screen ?? NSScreen.main {
            miniWindow.setFrame(MiniLayout.resized(miniWindow.frame, to: MiniLayout.size(symbols: model.miniSymbols), in: screen.visibleFrame), display: false)
        }
        miniWindow.setFrameAutosaveName("UsageGaugeMiniWindow")
        if !restoredMini || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(miniWindow.frame) }) { moveMini(to: .topRight) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusMenu = NSMenu()
        let show = statusMenu.addItem(withTitle: "Show Usage Gauge", action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let refresh = statusMenu.addItem(withTitle: "Refresh Usage", action: #selector(refreshNow), keyEquivalent: ""); refresh.target = self
        topMenuItem = statusMenu.addItem(withTitle: "Keep on Top", action: #selector(toggleOnTop), keyEquivalent: ""); topMenuItem.target = self
        miniMenuItem = statusMenu.addItem(withTitle: "Mini Mode", action: #selector(toggleMiniMode), keyEquivalent: ""); miniMenuItem.target = self
        hudMenuItem = statusMenu.addItem(withTitle: "HUD Mode", action: #selector(toggleHUDMode), keyEquivalent: ""); hudMenuItem.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Usage Gauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = statusMenu
        model.onChange = { [weak self] in self?.updateChrome() }
        model.onMoveMini = { [weak self] corner in self?.moveMini(to: corner) }
        contrastController = HUDContrastController(regions: { [weak self] in self?.contrastRegions() ?? [] },
            onMask: { [weak self] _, image in self?.model.hudContrastMap = image },
            onStatus: { [weak self] status in self?.model.hudContrastStatus = status },
            onUserStop: { [weak self] in self?.model.miniAutoContrast = false })
        model.onRequestHUDContrastPermission = { [weak self] in self?.contrastController?.requestPermission() }
        model.onHUDContrastUnitsChanged = { [weak self] _ in self?.scheduleHUDInkRefresh() }
        scheduleHUDInkRefresh()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.contrastController?.geometryChanged(); self?.scheduleHUDInkRefresh() }
            }
        updateChrome(); showWindow(); model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshAll() }
        }
    }
    func updateChrome() {
        window?.level = model.alwaysOnTop ? .floating : .normal
        miniWindow?.level = model.miniOnTop ? .floating : .normal
        miniWindow?.alphaValue = model.miniOpacity
        miniWindow?.hasShadow = !model.miniHUD
        miniWindow?.isMovableByWindowBackground = !model.miniHUD
        miniWindow?.invalidateShadow()
        (miniWindow?.contentView as? MiniHostingView)?.updateTrackingAreas()
        if let panel = miniWindow, panel.frame.size != MiniLayout.size(symbols: model.miniSymbols), let screen = panel.screen ?? NSScreen.main {
            panel.setFrame(MiniLayout.resized(panel.frame, to: MiniLayout.size(symbols: model.miniSymbols), in: screen.visibleFrame), display: true)
            panel.saveFrame(usingName: "UsageGaugeMiniWindow")
        }
        topMenuItem?.state = (model.miniMode ? model.miniOnTop : model.alwaysOnTop) ? .on : .off
        miniMenuItem?.state = model.miniMode ? .on : .off
        hudMenuItem?.state = model.miniHUD ? .on : .off
        if displayedMini != model.miniMode {
            displayedMini = model.miniMode
            if model.miniMode { window?.orderOut(nil); miniWindow?.orderFront(nil) }
            else { miniWindow?.orderOut(nil); window?.makeKeyAndOrderFront(nil) }
        }
        updateStatusImage()
        contrastController?.setEnabled(model.miniHUD && model.miniAutoContrast && model.miniMode)
        scheduleHUDInkRefresh()
    }
    /// Cache the owned view's alpha only when glyphs or instrument geometry change.
    private func scheduleHUDInkRefresh() {
        guard model.miniHUD, model.miniAutoContrast, model.miniMode, !hudInkRefreshScheduled else { return }
        hudInkRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.hudInkRefreshScheduled = false }
            guard self.model.miniHUD, self.model.miniAutoContrast, self.model.miniMode,
                  let panel = self.miniWindow, let host = panel.contentView, !self.model.hudContrastUnits.isEmpty else { return }
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size, scale = panel.screen?.backingScaleFactor ?? 2
            guard self.hudInkCapturedUnits != self.model.hudContrastUnits || self.hudInkCapturedScale != scale else { return }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: max(1, Int((size.width * scale).rounded())), pixelsHigh: max(1, Int((size.height * scale).rounded())),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return }
            if let pixels = bitmap.bitmapData { memset(pixels, 0, bitmap.bytesPerRow * bitmap.pixelsHigh) }
            bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
            let atlas = HUDInkAtlas.make(bitmap: bitmap, pointSize: size, units: self.model.hudContrastUnits)
            self.hudInkCapturedUnits = self.model.hudContrastUnits; self.hudInkCapturedScale = scale
            self.contrastController?.setInkAtlas(atlas)
        }
    }
    private func updateStatusImage() {
        guard let button = statusItem?.button else { return }
        // Both services always report: G for Codex (GPT), C for Claude.
        let now = Date().timeIntervalSince1970
        let services = [(letter: "G", name: "Codex", snapshot: model.snapshot), (letter: "C", name: "Claude", snapshot: model.claudeSnapshot)]
        let gauges = services.map { service in
            let status = DataAvailability.evaluate(snapshot: service.snapshot, quota: service.snapshot.glance, refreshing: false, interval: model.interval, now: now)
            let valid = status.condition == .live || status.condition == .idle
            return StatusBattery.Gauge(letter: service.letter, remaining: valid ? service.snapshot.glance?.remaining : nil,
                risk: valid ? service.snapshot.riskiest(now: now)?.risk : nil, failed: !valid)
        }
        let summaries = services.map { service -> String in
            let quota = service.snapshot.glance
            let status = DataAvailability.evaluate(snapshot: service.snapshot, quota: quota, refreshing: false, interval: model.interval, now: now)
            return service.name + " · " + status.condition.token + " · " + status.condition.detail
                + (status.condition.permitsObservation ? quota.map { " Last observation " + Formats.percent($0.remaining) + " at " + Formats.date($0.observedAt) } ?? "" : "")
        }
        button.title = ""
        button.image = StatusBattery.image(gauges, description: summaries.joined(separator: "; "), hud: model.miniHUD)
        button.imagePosition = .imageOnly
        button.toolTip = summaries.joined(separator: "\n")
    }
    private func contrastRegions() -> [HUDCaptureRegion] {
        var result: [HUDCaptureRegion] = []
        if model.miniMode, let panel = miniWindow, panel.isVisible {
            result.append(HUDCaptureRegion(target: .mini, frame: panel.frame, scale: panel.screen?.backingScaleFactor ?? 2))
        }
        return result
    }
    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === miniWindow { contrastController?.geometryChanged(.mini); scheduleHUDInkRefresh() }
    }
    func windowDidResize(_ notification: Notification) {
        if notification.object as? NSWindow === miniWindow { contrastController?.geometryChanged(.mini); scheduleHUDInkRefresh() }
    }
    func moveMini(to corner: MiniCorner) {
        guard let panel = miniWindow, let screen = panel.screen ?? window?.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(MiniLayout.origin(corner, in: screen.visibleFrame, size: panel.frame.size))
        panel.saveFrame(usingName: "UsageGaugeMiniWindow")
    }
    @objc func showWindow() {
        if model.miniMode { miniWindow.orderFront(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func toggleMiniMode() { model.miniMode.toggle() }
    @objc func toggleHUDMode() {
        model.miniHUD.toggle()
        if model.miniHUD { model.miniMode = true }
    }
    @objc func refreshNow() { model.refresh() }
    @objc func toggleOnTop() { if model.miniMode { model.miniOnTop.toggle() } else { model.alwaysOnTop.toggle() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { contrastController?.stop(); model.stop() }
}

#if !DEMO_RENDER
@main struct UsageGaugeMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            DataAvailability.selfTest()
            HUDContrastMask.selfTest()
            let points = (0...72).map { Sample(t: Double($0 * 3600), remaining: 100 - Double($0) / 24 * 20) }
            let quota = Quota(id: "test", name: "codex", durationMinutes: 10080, resetAt: 604800, remaining: 40, observedAt: 259200, points: points)
            precondition(abs(quota.baseline(259200) - 57.142857) < 0.00001)
            precondition(quota.dailyBurn == 20)
            precondition(quota.projection.last?.t == 432000)
            precondition(quota.projection.last?.remaining == 0)
            let empty = Quota(id: "test", name: "codex", durationMinutes: 10080, resetAt: 604800, remaining: 40, observedAt: 259200, points: [])
            precondition(empty.dailyBurn == nil && empty.projection.isEmpty)
            let failed = try! JSONDecoder().decode(Snapshot.self, from: Data("{\"error\":\"offline\"}".utf8))
            precondition(failed.windows.isEmpty && failed.error == "offline")
            let oneHour = GaugeScale.domain(quota, index: 0, now: 259200)
            precondition(oneHour.lowerBound.timeIntervalSince1970 == 255600 && oneHour.upperBound.timeIntervalSince1970 == 259200)
            precondition(quota.baseline(oneHour.lowerBound.timeIntervalSince1970) < 60)
            let fullCycle = GaugeScale.domain(quota, index: 4, now: 259200)
            precondition(fullCycle.lowerBound == quota.startDate && fullCycle.upperBound == quota.resetDate)
            precondition(GaugeScale.domain(quota, index: 3, now: 3600).lowerBound == quota.startDate)
            precondition(GaugeScale.domain(quota, index: 0, now: 700000).upperBound == quota.resetDate)
            let zoom = GaugeScale.vertical(quota, index: 0, domain: oneHour)
            precondition(zoom.range.lowerBound <= 40 && zoom.range.upperBound >= quota.baseline(255600))
            precondition(zoom.range.upperBound - zoom.range.lowerBound < 100)
            precondition(GaugeScale.vertical(quota, index: 4, domain: fullCycle).range == 0...100)
            precondition(GaugeScale.precision(0.1) == 5 && GaugeScale.precision(2) == 1)
            precondition(ClaudeUsage.sameCycle(1920434399.539, 1920434400.34))
            precondition(!ClaudeUsage.sameCycle(1920434400, 1920434400 + 18000))
            // Claude Code fails, the web fallback starts, then the person opens email sign-in
            // (which cancels the web wait) and closes the window without finishing.
            var reads = ClaudeReadState()
            precondition(reads.begin(now: 0) && !reads.begin(now: 1))
            reads.fallBackToWeb(); reads.signInStarted()
            precondition(reads.begin(now: 600), "Claude reads stay blocked after an abandoned sign-in")
            // Sign-in during the Claude Code read leaves that read alone; a timeout ends a web wait.
            let cliRead = reads.generation
            precondition(!reads.signInStarted() && reads.isCurrent(cliRead))
            reads.fallBackToWeb(); reads.finish()
            precondition(!reads.isCurrent(cliRead) && reads.begin(now: 601))
            // A reader that never answers is abandoned after the stale bound, and its late answer ignored.
            let stalled = reads.generation
            precondition(!reads.begin(now: 601 + ClaudeReadState.staleAfter - 1))
            precondition(reads.begin(now: 601 + ClaudeReadState.staleAfter) && !reads.isCurrent(stalled))
            // A 5-hour window forecasts from its last hour instead of waiting for 24 hours.
            let session = Quota(id: "test", name: "claude", durationMinutes: 300, resetAt: 18000, remaining: 80, observedAt: 7200,
                                points: (0...4).map { Sample(t: Double($0 * 1800), remaining: 100 - Double($0) * 5) })
            precondition(session.burnLookback == 3600 && session.dailyBurn == 240 && session.lookbackText == "1 hour")
            precondition(session.projection.last?.t == 18000 && session.projection.last?.remaining == 50)
            // Claude: server rows by kind, a session that has not started, model-scoped weekly, extras.
            func body(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
            let rows = body(#"""
            {"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":97,"resets_at":"2030-11-09T06:00:00.115328+00:00"},"seven_day_opus":null,
             "limits":[{"kind":"session","group":"session","percent":0,"resets_at":null,"severity":"normal","is_active":false,"scope":null},
                       {"kind":"weekly_all","group":"weekly","percent":97,"resets_at":"2030-11-09T06:00:00.115328+00:00","severity":"critical","is_active":true,"scope":null},
                       {"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"2030-11-09T06:00:00+00:00","severity":"normal","is_active":false,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],
             "spend":{"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":null,"percent":0,"enabled":true},
             "seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":100},{"key":"chat","display_name":"Chats","percent":0}]}}
            """#)
            let parsed = ClaudeUsage.limits(rows)
            precondition(parsed.map(\.id) == ["claude:five_hour", "claude:seven_day", "claude:weekly:fable"])
            precondition(parsed[0].resetAt == nil && parsed[1].severity == "critical" && parsed[1].active == true && parsed[2].name == "Fable")
            precondition(abs(parsed[1].resetAt! - 1920434400.115328) < 0.001)
            let first = ClaudeUsage.merge(parsed, into: Snapshot(), account: "a", now: 1920309663)
            precondition(first[0].isIdle && first[0].remaining == 100 && first[0].points.isEmpty)
            precondition(first[1].resetAt == 1920434400 && first[1].remaining == 3 && first[2].title == "Fable · Weekly limit")
            var stored = Snapshot(); stored.accountKey = "a"; stored.windows = first
            let jittered = ClaudeUsage.limits(body(#"{"limits":[{"kind":"weekly_all","group":"weekly","percent":96,"resets_at":"2030-11-09T06:00:00.340000+00:00"}]}"#))
            let second = ClaudeUsage.merge(jittered, into: stored, account: "a", now: 1920309783)
            precondition(second.count == 1 && second[0].points.count == 2 && second[0].resetAt == 1920434400)
            precondition(ClaudeUsage.merge(jittered, into: stored, account: "b", now: 1920309783)[0].points.count == 1)
            // Limit risk, separate from pace: Claude's grade first. The critical all-model weekly
            // limit constrains the idle session and the Fable limit, which look untouched on their own.
            let at = 1920309663.0
            precondition(first[0].limitRisk(now: at) == nil && first[1].limitRisk(now: at) == .critical && first[2].limitRisk(now: at) == nil)
            precondition(stored.riskiest(now: at)?.quota.id == "claude:seven_day" && stored.glance?.id == "claude:seven_day")
            precondition(StatusBattery.label(.init(letter: "G", remaining: 12.4, risk: nil)) == "G12")
            precondition(StatusBattery.label(.init(letter: "C", remaining: nil, risk: nil)) == "CN/A")
            for label in ["G100", "CN/A"] {
                let width = NSAttributedString(string: label, attributes: [.font: StatusBattery.font]).size().width
                precondition(width <= StatusBattery.body.width - 4, "Menu-bar 100 and N/A labels must fit without clipping")
            }
            precondition(stored.sharedConstraints(for: first[2], now: at).map(\.quota.id) == ["claude:seven_day"])
            precondition(stored.sharedConstraints(for: first[0], now: at).map(\.quota.id) == ["claude:seven_day"])
            precondition(stored.sharedConstraints(for: first[1], now: at).isEmpty)
            precondition(first[1].limitRisk(now: first[1].resetAt) == nil)
            // Without a grade: 10% and 25% bounds; a server "normal" is trusted; an emptying pace warns.
            func codex(_ remaining: Double, severity: String? = nil) -> Quota {
                Quota(id: "c", name: "codex", durationMinutes: 10080, resetAt: 604800, remaining: remaining, observedAt: 0, points: [], severity: severity)
            }
            precondition(codex(10).limitRisk(now: 1) == .critical && codex(25).limitRisk(now: 1) == .warning && codex(26).limitRisk(now: 1) == nil)
            precondition(codex(5, severity: "normal").limitRisk(now: 1) == nil)
            precondition(quota.limitRisk(now: 259200) == .warning)
            let extra = ClaudeUsage.extra(rows)
            precondition(extra?.enabled == true && extra?.used == 12.5 && extra?.summary.contains("$12.50") == true)
            precondition(ClaudeUsage.breakdown(rows)?.first?.name == "Claude Code")
            let legacy = ClaudeUsage.limits(body(#"{"five_hour":{"utilization":40,"resets_at":"2030-11-08T00:20:00.2+00:00"},"seven_day":{"utilization":97,"resets_at":"2030-11-09T06:00:00Z"},"seven_day_opus":null,"model_scoped":[{"display_name":"Fable","utilization":5,"resets_at":"2030-11-09T06:00:00Z"}]}"#))
            precondition(legacy.map(\.id) == ["claude:five_hour", "claude:seven_day", "claude:weekly:fable"] && legacy[0].resetAt != nil)
            if case .failure(let message) = ClaudeCLI.parse(Data(#"{"ok":false,"error":"Claude Code is not installed."}"#.utf8)) {
                precondition(message == "Claude Code is not installed.")
            } else { preconditionFailure("CLI failure was not reported") }
            if case .authenticationRequired = ClaudeCLI.parse(Data(#"{"ok":false,"error":"Sign-in required","errorCode":"auth_required"}"#.utf8)) {} else {
                preconditionFailure("Explicit auth failure was not distinguished")
            }
            if case .failure = ClaudeCLI.parse(Data(#"{"ok":false,"error":"Temporary error; check sign-in if it persists","errorCode":"unavailable"}"#.utf8)) {} else {
                preconditionFailure("A transport failure must not be classified as sign-out from its wording")
            }
            let secondaryDisplay = NSRect(x: -1920, y: 100, width: 1920, height: 1056)
            for corner in MiniCorner.allCases {
                for size in [MiniLayout.valueSize, MiniLayout.symbolSize] {
                    precondition(secondaryDisplay.contains(NSRect(origin: MiniLayout.origin(corner, in: secondaryDisplay, size: size), size: size)))
                }
            }
            let fullMini = NSRect(origin: MiniLayout.origin(.topRight, in: secondaryDisplay), size: MiniLayout.valueSize)
            let smallMini = MiniLayout.resized(fullMini, to: MiniLayout.symbolSize, in: secondaryDisplay)
            precondition(fullMini.maxX == smallMini.maxX && fullMini.maxY == smallMini.maxY)
            precondition(MiniLayout.resized(smallMini, to: MiniLayout.valueSize, in: secondaryDisplay) == fullMini)
            precondition(MiniLayout.countdown(-5) == "00:00:00" && MiniLayout.countdown(172801) == "48:00:01")
            precondition(MiniLayout.opacity(0) == 0.3 && MiniLayout.opacity(2) == 1 && MiniLayout.opacity(0.65) == 0.65)
            // The reference moves up for a deficit, down for a reserve; one dot is 2 pp.
            precondition(UsageDeviation(remaining: 30, baseline: 30).normalized == 0)
            precondition(UsageDeviation(remaining: 30, baseline: 32).normalized == 0.5)
            precondition(UsageDeviation(remaining: 32, baseline: 30).normalized == -0.5)
            precondition(!UsageDeviation(remaining: 30, baseline: 33.999).warning)
            precondition(UsageDeviation(remaining: 30, baseline: 34).warning)
            let aboveScale = UsageDeviation(remaining: 2, baseline: 20)
            precondition(aboveScale.normalized == 1 && aboveScale.outsideScale && aboveScale.warning)
            let belowScale = UsageDeviation(remaining: 90, baseline: 20)
            precondition(belowScale.normalized == -1 && belowScale.outsideScale && !belowScale.warning)
            precondition(!UsageDeviation(remaining: 2, baseline: 20, isCurrent: false).warning)
            precondition(!UsageDeviation(remaining: 2, baseline: nil).warning)
            for spacing in DotScale.values {
                let oneDot = UsageDeviation(remaining: 30, baseline: 30 + spacing, pointsPerDot: spacing)
                precondition(oneDot.normalized == 0.5 && !oneDot.warning)
                precondition(UsageDeviation(remaining: 30, baseline: 30 + 2 * spacing, pointsPerDot: spacing).warning)
            }
            precondition(DotScale.points(-1) == 1 && DotScale.points(3) == 5)
            let sessionScale = DotScale(unit: .time, durationMinutes: 300, index: DotScale.defaultIndex(unit: .time, durationMinutes: 300))
            let weeklyScale = DotScale(unit: .time, durationMinutes: 10080, index: DotScale.defaultIndex(unit: .time, durationMinutes: 10080))
            precondition(sessionScale.caption == "5MIN/dot" && sessionScale.options == [5, 10, 15] && sessionScale.limitText == "10 minutes")
            precondition(weeklyScale.caption == "4HR/dot" && weeklyScale.options == DotScale.weeklyMinutes && weeklyScale.limitText == "8 hours")
            for duration in [300.0, 10080.0] {
                for index in 0..<(duration >= 1440 ? DotScale.weeklyMinutes.count : 3) {
                    let scale = DotScale(unit: .time, durationMinutes: duration, index: index)
                    precondition(abs(scale.pointsPerDot * duration / 100 - scale.options[index]) < 1e-9)
                    let one = UsageDeviation(remaining: 50, baseline: 50 + scale.pointsPerDot, pointsPerDot: scale.pointsPerDot)
                    precondition(abs(one.normalized - 0.5) < 1e-9 && !one.warning)
                    let edge = UsageDeviation(remaining: 50, baseline: 50 + scale.pointsPerDot * 2, pointsPerDot: scale.pointsPerDot)
                    precondition(edge.warning && !edge.outsideScale)
                    precondition(!UsageDeviation(remaining: 50, baseline: 50 + scale.pointsPerDot * 2 - 0.001, pointsPerDot: scale.pointsPerDot).warning)
                    let reserve = UsageDeviation(remaining: 50 + scale.pointsPerDot, baseline: 50, pointsPerDot: scale.pointsPerDot)
                    precondition(abs(reserve.normalized + 0.5) < 1e-9 && !reserve.warning)
                }
            }
            precondition(DotScale(unit: .percentagePoints, durationMinutes: 10080, index: 1).caption == "2 pp/dot")
            precondition((0..<6).map { DotScale(unit: .time, durationMinutes: 10080, index: $0).compactCaption } == ["2HR", "4HR", "8HR", "1DAY", "2DAY", "4DAY"])
            for (value, expected) in [(0.0, "0%"), (0.4, "<1%"), (0.99, "<1%"), (1.0, "1%"), (8.7, "8%"), (9.99, "9%"), (10.0, "REM"), (100.0, "REM")] {
                precondition(InstrumentCaption.remaining(value, symbols: true, condition: .live) == expected)
            }
            for condition in [DataCondition.stale, .resetPending, .authentication, .invalid, .unavailable] {
                precondition(InstrumentCaption.remaining(8, symbols: true, condition: condition) == "REM")
            }
            precondition(InstrumentCaption.remaining(8, symbols: false, condition: .live) == "REM")
            precondition(Formats.duration(300) == "5MIN" && Formats.duration(28800) == "8HR" && Formats.duration(345600) == "4DAY")
            precondition(DotScale(unit: .time, durationMinutes: 10080, index: 5).diamondHalfSpanText == "1 day 14 hours 24 minutes")
            precondition(WarningFlash.isRed(at: 0) && WarningFlash.isRed(at: 0.799))
            precondition(!WarningFlash.isRed(at: 0.8) && !WarningFlash.isRed(at: 1.599) && WarningFlash.isRed(at: 1.6))
            print("PASS: session/weekly time defaults and conversion, time alert boundaries, pp scales, binary flash timing, deviation direction/clipping/stale suppression, mini placement/countdown, baseline, forecast, missing history, offline snapshot, time bounds, adaptive vertical axis, display precision, Claude cycle jitter, short-window forecast, Claude limits/idle/extras/legacy, Claude read recovery, limit risk and shared limits")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif

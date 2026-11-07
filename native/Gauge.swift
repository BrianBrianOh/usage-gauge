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
        guard let burn = dailyBurn else { return "Forecast available after \(lookbackText) of observations." }
        let predicted = remaining - burn * max(0, resetAt - observedAt) / 86400
        if burn > 0 && predicted < 0 {
            let hours = (resetAt - observedAt - remaining / burn * 86400) / 3600
            return String(format: "At current pace: empty about %.0fh before reset.", hours)
        }
        return String(format: "At current pace: about %.1f%% remaining at reset.", predicted)
    }
}

extension Quota {
    /// The server's own grading of this meter, when it sends one.
    var severityColor: Color? {
        switch severity {
        case "warning": return FlightDeck.caution
        case "critical": return FlightDeck.alert
        default: return nil
        }
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
    var fetchedAt: Double?
    var source: String?
    var plan: String?
    var extra: ExtraUsage?
    var breakdown: [UsageShare]?
    private enum CodingKeys: String, CodingKey { case windows, error, fetchedAt, accountKey, source, plan, extra, breakdown }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decodeIfPresent([Quota].self, forKey: .windows) ?? []
        error = try values.decodeIfPresent(String.self, forKey: .error)
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
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

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
    @Published var miniScaleIndex = DotScale.bounded(UserDefaults.standard.object(forKey: "miniScaleIndex") as? Int ?? 1) {
        didSet {
            UserDefaults.standard.set(miniScaleIndex, forKey: "miniScaleIndex")
            guard oldValue != miniScaleIndex else { return }
            miniScaleFeedbackTask?.cancel()
            miniScaleFeedback = true
            miniScaleFeedbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.miniScaleFeedback = false
            }
        }
    }
    @Published var miniScaleFeedback = false
    private var miniScaleFeedbackTask: Task<Void, Never>?
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
    var accent: Color { provider == "claude" ? FlightDeck.amber : FlightDeck.cyan }

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
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

struct LiveMetrics: View {
    let quota: Quota
    let accent: Color
    let step: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            let baseline = quota.baseline(context.date.timeIntervalSince1970)
            let gap = quota.remaining - baseline
            HStack(spacing: 16) {
                ReserveDial(remaining: quota.remaining, accent: quota.severityColor ?? accent)
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 88)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Linear baseline").font(FlightDeck.label(9)).foregroundStyle(FlightDeck.muted)
                        Spacer(minLength: 2)
                        Text("\(String(format: "%g", step))s").font(FlightDeck.label(9)).foregroundStyle(accent.opacity(0.8))
                    }
                    Text(String(format: "%.*f%%", GaugeScale.precision(step), baseline))
                        .font(.system(size: 31, weight: .medium, design: .monospaced)).tracking(-1.1).monospacedDigit().foregroundStyle(accent)

                        .contentTransition(.numericText(countsDown: true))
                        .minimumScaleFactor(0.75).lineLimit(1)
                    ReferenceTape(value: baseline, accent: accent)
                    HStack(spacing: 5) {
                        Text(gap >= 0 ? "Above baseline" : "Below baseline").font(FlightDeck.label(8)).tracking(0.5)
                        Spacer(minLength: 2)
                        Text(String(format: "%@%.*f pp", gap >= 0 ? "+" : "−", min(3, GaugeScale.precision(step)), abs(gap)))
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
                    Text("Resets in").font(FlightDeck.label(8)).tracking(0.6).foregroundStyle(FlightDeck.muted)

                }
                Spacer(minLength: 2)
                Text(step < 1 ? String(format: "%02d:%02d:%02d.%01d", seconds / 3600, seconds / 60 % 60, seconds % 60, tenths % 10) : String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                    .font(.system(size: 24, weight: .medium, design: .monospaced)).foregroundStyle(accent).tracking(0.5)
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
    private var domain: ClosedRange<Date> { GaugeScale.domain(quota, index: model.spanIndex, now: Date().timeIntervalSince1970) }
    private var vertical: (range: ClosedRange<Double>, ticks: [Double]) { GaugeScale.vertical(quota, index: model.spanIndex, domain: domain) }
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
                Text("History").font(FlightDeck.label(9)).tracking(0.8).foregroundStyle(FlightDeck.ink)
                Spacer(minLength: 2)
                LegendItem(text: "Remaining", color: model.accent)
                LegendItem(text: "Linear", color: FlightDeck.muted, dashed: true)
                if model.spanIndex == 4 && !quota.projection.isEmpty { LegendItem(text: "Forecast", color: FlightDeck.forecast, dashed: true) }
            }
            Chart {
                ForEach([Sample(t: domain.lowerBound.timeIntervalSince1970, remaining: quota.baseline(domain.lowerBound.timeIntervalSince1970)), Sample(t: domain.upperBound.timeIntervalSince1970, remaining: quota.baseline(domain.upperBound.timeIntervalSince1970))]) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "baseline"))
                        .foregroundStyle(FlightDeck.muted.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 0.85, dash: [4,4]))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, points in
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "actual-\(index)"))
                            .foregroundStyle(model.accent).lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(model.spanIndex == 4 ? quota.projection : []) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "forecast"))
                        .foregroundStyle(FlightDeck.forecast).lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1,4]))
                }
                if domain.contains(quota.observedDate) {
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
            .accessibilityLabel("Remaining usage and linear reference until reset")
            .accessibilityValue("Actual \(Formats.percent(quota.remaining)), reference \(Formats.percent(quota.baseline(quota.observedAt)))")
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
                if let quota = model.quota, quota.isIdle {
                    Spacer()
                    idleCard(quota)
                    Spacer()
                } else if let quota = model.quota {
                    LiveMetrics(quota: quota, accent: model.accent, step: model.displayStep).id(model.stepIndex)
                    TrendChart(quota: quota, model: model).id(quota.id + String(quota.resetAt))
                    details(quota, now: context.date)
                    InstrumentPanel(model: model)
                } else {
                    let claudeWaiting = model.provider == "claude" && !model.isRefreshing
                    Spacer()
                    VStack(spacing: 15) {
                        Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 45)).foregroundStyle(model.accent)
                        Text(claudeWaiting ? "Connect Claude" : "Loading usage…")
                            .font(FlightDeck.label(15))
                        Text(model.provider == "claude" ? "Limits appear automatically when Claude Code is signed in. Without Claude Code, connect your claude.ai account." : "Reading the limits for your signed-in Codex account.")
                            .font(.system(size: 12)).foregroundStyle(FlightDeck.muted).multilineTextAlignment(.center)
                        if claudeWaiting {
                            Button("Connect Claude", action: model.connectClaude).buttonStyle(PanelButton(active: true, accent: model.accent))
                        } else { ProgressView().controlSize(.small) }
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(FlightDeck.amber).multilineTextAlignment(.center) }
                    }.padding(24).frame(maxWidth: .infinity).modifier(Bezel())
                    Spacer()
                }
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
    private var header: some View {
        HStack {
            Text("Usage Gauge").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button { model.miniMode = true } label: {
                Label("Mini", systemImage: "arrow.down.right.and.arrow.up.left")
            }.buttonStyle(PanelButton()).help("Switch to the small window · Shift-Command-M")
        }.frame(height: 30)
    }
    private var sourceSelector: some View {
        HStack(spacing: 7) {
            ForEach(["codex", "claude"], id: \.self) { provider in
                Button { model.provider = provider } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.provider == provider ? model.accent : FlightDeck.muted.opacity(0.35)).frame(width: 4, height: 4)
                        Text(provider.capitalized)
                    }
                }.buttonStyle(PanelButton(active: model.provider == provider, accent: model.accent))
                .accessibilityLabel(provider.capitalized)
                .accessibilityAddTraits(model.provider == provider ? .isSelected : [])
            }
            Spacer(minLength: 4)
            if model.activeSnapshot.windows.count > 1 {
                Picker("Limit", selection: $model.selectedID) {
                    ForEach(model.activeSnapshot.windows) { quota in Text(quota.title).tag(quota.id) }
                }.labelsHidden().controlSize(.small).frame(maxWidth: 130)
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
            LiveCountdown(resetAt: quota.resetAt, accent: model.accent, step: model.displayStep).id(model.stepIndex)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: expired ? "clock" : "arrow.up.right").font(.system(size: 9))
                Text(expired ? "Reset time passed. Waiting for a new observation." : quota.forecastText)
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
            }.foregroundStyle(FlightDeck.muted).help("Estimate based on the most recent \(quota.lookbackText) of observed consumption.")
            if model.provider == "claude" { claudeNotes(quota) }
            HStack {
                if let error = model.error {
                    Annunciator(label: "Refresh failed · last known data", color: FlightDeck.amber).help(error)
                } else if now.timeIntervalSince1970 - quota.observedAt > Double(max(model.interval * 3, 600)) {
                    Annunciator(label: "Updated \(Formats.duration(now.timeIntervalSince1970 - quota.observedAt)) ago", color: FlightDeck.amber)
                } else {
                    Text("Updated \(Formats.date(quota.observedAt)) \(Formats.zone)").font(FlightDeck.label(8)).foregroundStyle(FlightDeck.muted)
                }
                Spacer(minLength: 2)
                if let color = quota.severityColor {
                    Annunciator(label: quota.severity == "critical" ? "Critical" : "Warning", color: color)
                        .help("Claude's own reading of this limit")
                }
                Text(model.sourceLabel).font(FlightDeck.label(7)).foregroundStyle(FlightDeck.muted.opacity(0.7))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).modifier(Bezel())
    }
    @ViewBuilder private func claudeNotes(_ quota: Quota) -> some View {
        if let extra = model.claudeSnapshot.extra {
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = UsageModel()
    var window: NSWindow!
    var miniWindow: MiniPanel!
    var displayedMini: Bool?
    var statusItem: NSStatusItem!
    var topMenuItem: NSMenuItem!
    var miniMenuItem: NSMenuItem!
    var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        miniWindow.isMovableByWindowBackground = true; miniWindow.isOpaque = false; miniWindow.backgroundColor = .clear; miniWindow.hasShadow = true
        miniWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let miniHost = MiniHostingView(rootView: MiniView(model: model))
        miniHost.sizingOptions = []
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
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Usage Gauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = statusMenu
        model.onChange = { [weak self] in self?.updateChrome() }
        model.onMoveMini = { [weak self] corner in self?.moveMini(to: corner) }
        updateChrome(); showWindow(); model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshAll() }
        }
    }
    func updateChrome() {
        window?.level = model.alwaysOnTop ? .floating : .normal
        miniWindow?.level = model.miniOnTop ? .floating : .normal
        if let panel = miniWindow, panel.frame.size != MiniLayout.size(symbols: model.miniSymbols), let screen = panel.screen ?? NSScreen.main {
            panel.setFrame(MiniLayout.resized(panel.frame, to: MiniLayout.size(symbols: model.miniSymbols), in: screen.visibleFrame), display: true)
            panel.saveFrame(usingName: "UsageGaugeMiniWindow")
        }
        topMenuItem?.state = (model.miniMode ? model.miniOnTop : model.alwaysOnTop) ? .on : .off
        miniMenuItem?.state = model.miniMode ? .on : .off
        if displayedMini != model.miniMode {
            displayedMini = model.miniMode
            if model.miniMode { window?.orderOut(nil); miniWindow?.orderFront(nil) }
            else { miniWindow?.orderOut(nil); window?.makeKeyAndOrderFront(nil) }
        }
        guard let button = statusItem?.button else { return }
        let headline = model.headline
        let percentage = headline.map { Formats.percent($0.remaining) } ?? "—"
        button.title = " " + (model.provider == "claude" ? "A " : "C ") + percentage + (model.error == nil ? "" : " !")
        let level = min(100, max(0, Int((headline?.remaining ?? 0) / 25) * 25))
        button.image = NSImage(systemSymbolName: "battery.\(level)percent", accessibilityDescription: "Account usage")
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "\(model.provider == "claude" ? "Claude" : "Codex") · \(headline?.title ?? "Usage") · \(percentage) remaining"
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
    @objc func refreshNow() { model.refresh() }
    @objc func toggleOnTop() { if model.miniMode { model.miniOnTop.toggle() } else { model.alwaysOnTop.toggle() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

#if !DEMO_RENDER
@main struct UsageGaugeMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
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
            let extra = ClaudeUsage.extra(rows)
            precondition(extra?.enabled == true && extra?.used == 12.5 && extra?.summary.contains("$12.50") == true)
            precondition(ClaudeUsage.breakdown(rows)?.first?.name == "Claude Code")
            let legacy = ClaudeUsage.limits(body(#"{"five_hour":{"utilization":40,"resets_at":"2030-11-08T00:20:00.2+00:00"},"seven_day":{"utilization":97,"resets_at":"2030-11-09T06:00:00Z"},"seven_day_opus":null,"model_scoped":[{"display_name":"Fable","utilization":5,"resets_at":"2030-11-09T06:00:00Z"}]}"#))
            precondition(legacy.map(\.id) == ["claude:five_hour", "claude:seven_day", "claude:weekly:fable"] && legacy[0].resetAt != nil)
            if case .failure(let message) = ClaudeCLI.parse(Data(#"{"ok":false,"error":"Claude Code is not installed."}"#.utf8)) {
                precondition(message == "Claude Code is not installed.")
            } else { preconditionFailure("CLI failure was not reported") }
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
            precondition(WarningFlash.isRed(at: 0) && WarningFlash.isRed(at: 0.799))
            precondition(!WarningFlash.isRed(at: 0.8) && !WarningFlash.isRed(at: 1.599) && WarningFlash.isRed(at: 1.6))
            print("PASS: 1/2/5-pp scales, binary flash timing, deviation direction/clipping/alert threshold/stale suppression, mini placement/countdown, baseline, forecast, missing history, offline snapshot, time bounds, adaptive vertical axis, display precision, Claude cycle jitter, short-window forecast, Claude limits/idle/extras/legacy")
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

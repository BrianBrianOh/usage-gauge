import AppKit
import SwiftUI

/// A missing number, an old observation, and a real zero are different instrument states.
enum DataCondition: String, CaseIterable {
    case live, idle, loading, authentication, noLimits, unavailable, stale, resetPending, invalid
    var token: String {
        switch self {
        case .live: return "VALID"
        case .idle: return "IDLE"
        case .loading: return "WAIT"
        case .authentication: return "AUTH"
        case .noLimits: return "N/A"
        case .unavailable: return "DATA"
        case .stale: return "STALE"
        case .resetPending: return "RESET"
        case .invalid: return "INVALID"
        }
    }
    var detail: String {
        switch self {
        case .live: return "Current observation"
        case .idle: return "Window not started; time and baseline do not apply yet."
        case .loading: return "Waiting for the first observation."
        case .authentication: return "Sign-in required. Account instruments are unavailable."
        case .noLimits: return "No subscription limits are available for this account."
        case .unavailable: return "Usage data is unavailable. Refresh or check the account connection."
        case .stale: return "Last observation only. Live baseline, reset time and forecast are inhibited."
        case .resetPending: return "The observed window ended. Waiting for the next window."
        case .invalid: return "Invalid observation. Instrument indications are inhibited."
        }
    }
    var permitsObservation: Bool { [.live, .idle, .stale, .resetPending].contains(self) }
    var permitsReference: Bool { self == .live }
    var isLastKnown: Bool { self == .stale || self == .resetPending }
    var color: Color { self == .live || self == .idle ? FlightDeck.ink : self == .loading ? FlightDeck.muted : FlightDeck.caution }
}

struct DataAvailability: Equatable {
    let condition: DataCondition
    let observedAt: Double?
    static func evaluate(snapshot: Snapshot, quota: Quota?, refreshing: Bool, interval: Int,
                         error: String? = nil, now: Double) -> DataAvailability {
        func state(_ value: DataCondition) -> DataAvailability { DataAvailability(condition: value, observedAt: quota?.observedAt) }
        if snapshot.errorCode == "auth_required" { return state(.authentication) }
        if snapshot.errorCode == "no_limits" { return state(.noLimits) }
        if snapshot.errorCode == "invalid_data" { return state(.invalid) }
        guard let quota else {
            if refreshing { return state(.loading) }
            if error != nil || snapshot.error != nil { return state(.unavailable) }
            return state(snapshot.fetchedAt == nil ? .unavailable : .noLimits)
        }
        guard quota.remaining.isFinite, (0...100).contains(quota.remaining),
              quota.durationMinutes.isFinite, quota.durationMinutes > 0,
              quota.resetAt.isFinite, quota.resetAt > 0,
              quota.observedAt.isFinite, quota.observedAt > 0, quota.observedAt <= now + 300 else { return state(.invalid) }
        if error != nil || snapshot.error != nil || now - quota.observedAt > Double(max(interval * 3, 600)) { return state(.stale) }
        if !quota.isIdle && now >= quota.resetAt { return state(.resetPending) }
        return state(quota.isIdle ? .idle : .live)
    }
    static func selfTest() {
        let now = 10_000.0
        func quota(_ remaining: Double = 0, observed: Double = 10_000, reset: Double = 20_000, idle: Bool = false) -> Quota {
            Quota(id: "fixture", name: "codex", durationMinutes: 300, resetAt: reset, remaining: remaining, observedAt: observed, points: [], idle: idle)
        }
        func check(_ expected: DataCondition, _ q: Quota?, code: String? = nil, error: String? = nil, refreshing: Bool = false, fetched: Double? = nil) {
            var snapshot = Snapshot(); snapshot.errorCode = code; snapshot.error = error; snapshot.fetchedAt = fetched
            precondition(evaluate(snapshot: snapshot, quota: q, refreshing: refreshing, interval: 120, now: now).condition == expected)
        }
        check(.live, quota(0)); check(.live, quota(100))
        check(.authentication, quota(80), code: "auth_required"); check(.noLimits, quota(80), code: "no_limits")
        check(.invalid, quota(80), code: "invalid_data"); check(.loading, nil, refreshing: true)
        check(.unavailable, nil, error: "transport"); check(.noLimits, nil, fetched: now); check(.unavailable, nil)
        check(.stale, quota(40, observed: now - 601)); check(.stale, quota(40), error: "transport")
        check(.resetPending, quota(40, reset: now)); check(.idle, quota(100, idle: true))
        check(.invalid, quota(.nan)); check(.invalid, quota(101)); check(.invalid, quota(20, observed: now + 301))
        precondition(!DataCondition.authentication.permitsObservation && !DataCondition.stale.permitsReference && !DataCondition.idle.permitsReference)
        print("PASS: data validity, signed-out cache suppression, real zero, stale/idle/expired distinction and malformed observations")
    }
}

@MainActor extension UsageModel {
    func availability(now: Double) -> DataAvailability {
        DataAvailability.evaluate(snapshot: activeSnapshot, quota: quota, refreshing: isRefreshing, interval: interval, error: error, now: now)
    }
}

/// Static, local invalid-data texture. It never animates like a progress indicator.
struct BarberPole: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width + size.height, by: 6) {
                path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: 1)
        }.clipped().accessibilityHidden(true)
    }
}

struct DataFlag: View {
    let condition: DataCondition
    var hud = false
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            if !compact { BarberPole(color: ink).frame(width: 11, height: 10) }
            Text(condition.token).font(FlightDeck.label(compact ? 8 : 10)).tracking(0.5)
                .hudTextUnit("data-flag-label", condition.token, size: compact ? 8 : 10, design: .monospaced, tracking: 0.5)
        }.foregroundStyle(ink).padding(.horizontal, compact ? 3 : 6).padding(.vertical, compact ? 1 : 3)
            .overlay(Rectangle().strokeBorder(ink.opacity(0.65), lineWidth: 1))
            .help(condition.detail).accessibilityElement(children: .ignore)
            .accessibilityLabel(condition.token + ": " + condition.detail)
    }
    private var ink: Color { hud ? MiniPalette.hudGreen : condition.color }
}

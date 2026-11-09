import AppKit
import SwiftUI

enum FlightDeck {
    static let shell = Color(red: 0.095, green: 0.108, blue: 0.122)
    static let panel = Color(red: 0.065, green: 0.077, blue: 0.087)
    static let screen = Color(red: 0.026, green: 0.042, blue: 0.047)
    static let ink = Color(red: 0.88, green: 0.92, blue: 0.90)
    static let muted = Color(red: 0.53, green: 0.61, blue: 0.63)
    static let cyan = Color(red: 0.36, green: 0.91, blue: 0.89)
    static let amber = Color(red: 1, green: 0.76, blue: 0.25)
    static let green = Color(red: 0.59, green: 0.88, blue: 0.59)
    static let forecast = cyan
    static let caution = amber
    static let alert = Color(red: 1, green: 0.42, blue: 0.38)
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
}

struct Bezel: ViewModifier {
    var hardware: Bool = false
    func body(content: Content) -> some View {
        content
            .background(hardware ? FlightDeck.panel : FlightDeck.screen, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(FlightDeck.muted.opacity(0.28), lineWidth: 1))

    }
}

struct PanelButton: ButtonStyle {
    var active = false
    var accent: Color = FlightDeck.cyan
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FlightDeck.label(10))
            .foregroundStyle(active ? accent : FlightDeck.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(configuration.isPressed ? accent.opacity(0.14) : FlightDeck.panel, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(active ? accent.opacity(0.85) : FlightDeck.muted.opacity(0.3), lineWidth: 1))
    }
}

struct Annunciator: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 5, height: 5)
            Text(label).font(FlightDeck.label(9)).tracking(0.6).foregroundStyle(color)
        }
    }
}

struct ReserveDial: View {
    let remaining: Double
    let accent: Color
    var caption = "REMAINING"
    var body: some View {
        ZStack {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.32
                func at(_ fraction: Double, _ r: Double) -> CGPoint {
                    let a = (135 + fraction * 270) * .pi / 180
                    return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                }
                var track = Path()
                track.addArc(center: c, radius: radius, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
                context.stroke(track, with: .color(accent.opacity(0.12)), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                if remaining > 0 {
                    var fill = Path()
                    fill.addArc(center: c, radius: radius, startAngle: .degrees(135), endAngle: .degrees(135 + remaining / 100 * 270), clockwise: false)
                    context.stroke(fill, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                }
                for i in 0...40 {
                    let f = Double(i) / 40
                    var tick = Path(); tick.move(to: at(f, radius + 5)); tick.addLine(to: at(f, radius + (i % 5 == 0 ? 10 : 7)))
                    context.stroke(tick, with: .color(FlightDeck.ink.opacity(i % 5 == 0 ? 0.75 : 0.25)), lineWidth: 1)
                }
                for (value, label) in [(0.0,"0"), (0.5,"50"), (1.0,"100")] {
                    context.draw(Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(FlightDeck.muted), at: at(value, radius + 17))
                }
                let p = at(remaining / 100, radius)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.white))
            }.accessibilityHidden(true)
            VStack(spacing: 1) {
                Text(Formats.percent(remaining)).font(.system(size: 30, weight: .regular, design: .monospaced)).tracking(0).foregroundStyle(FlightDeck.ink)
                Text(caption).font(FlightDeck.label(8)).tracking(0.2).foregroundStyle(FlightDeck.muted)
            }.offset(y: 3)
        }.frame(width: 134, height: 134)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measured remaining capacity")
        .accessibilityValue(Formats.percent(remaining))
    }
}

struct ReferenceTape: View {
    let value: Double
    let accent: Color
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(0..<40, id: \.self) { index in
                    Rectangle().fill(Double(index) / 40 < value / 100 ? accent.opacity(0.8) : accent.opacity(0.10))
                }
            }.frame(width: geometry.size.width, height: 5)
        }.frame(height: 5).accessibilityHidden(true)
    }
}

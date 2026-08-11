import SwiftUI
import ZephyrKit

// MARK: - Colour language

enum Thermal {
    /// Continuous cool→hot ramp. 35 °C is calm blue, 100 °C is red.
    static func color(_ celsius: Double) -> Color {
        let t = min(max((celsius - 35) / 65, 0), 1)
        let hue = 0.55 * (1 - t)
        return Color(hue: hue, saturation: 0.78, brightness: 0.95)
    }

    static func gradient(_ celsius: Double) -> LinearGradient {
        let base = color(celsius)
        return LinearGradient(colors: [base.opacity(0.65), base],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let accent = LinearGradient(
        colors: [Color(red: 0.20, green: 0.52, blue: 0.98), Color(red: 0.34, green: 0.84, blue: 0.88)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

extension Preset {
    var color: Color {
        switch tint {
        case "indigo": return .indigo
        case "blue": return .blue
        case "teal": return .teal
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "green": return .green
        case "red": return .red
        default: return .secondary
        }
    }

    static let tintOptions = ["blue", "teal", "indigo", "purple", "pink", "orange", "green", "red"]
}

// MARK: - Ring gauge

struct RingGauge: View {
    var progress: Double            // 0…1
    var lineWidth: CGFloat = 9
    var gradient: LinearGradient
    var label: String
    var caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)) * 0.75)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.55), value: progress)

            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 1))
                .rotationEffect(.degrees(135))

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    var values: [Double]
    var range: ClosedRange<Double>
    var gradient: LinearGradient
    var filled = true

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)
            ZStack {
                if filled, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(gradient.opacity(0.18))
                }
                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(gradient, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let span = max(range.upperBound - range.lowerBound, 0.001)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = min(max((value - range.lowerBound) / span, 0), 1)
            return CGPoint(x: x, y: size.height * (1 - CGFloat(normalized)))
        }
    }
}

// MARK: - Small building blocks

struct StatusPill: View {
    var symbol: String
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct PresetChip: View {
    var preset: Preset
    var isActive: Bool
    var isForced: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 17)
                Text(preset.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(isActive ? .white : Color.primary.opacity(0.85))
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isActive
                          ? AnyShapeStyle(LinearGradient(colors: [preset.color, preset.color.opacity(0.72)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isForced ? Color.orange.opacity(0.9) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.subtitle)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

struct SensorRow: View {
    var name: String
    var symbol: String
    var celsius: Double
    var maximum: Double = 105

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer(minLength: 6)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Thermal.gradient(celsius))
                        .frame(width: geometry.size.width * min(max(celsius / maximum, 0), 1))
                        .animation(.easeOut(duration: 0.5), value: celsius)
                }
            }
            .frame(width: 74, height: 5)

            Text(String(format: "%.0f°", celsius))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Thermal.color(celsius))
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
    }
}

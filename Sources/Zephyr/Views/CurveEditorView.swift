import SwiftUI
import ZephyrKit

/// Draggable temperature → fan-speed curve.
///
/// Points are dragged directly; a click on empty canvas adds one, and the live
/// readout tracks the actual sensor so you can see where the machine sits on
/// the curve while you edit it.
struct CurveEditorView: View {
    @Binding var curve: FanCurve
    var currentTemperature: Double?
    var fan: Fan?

    private let minTemp: Double = 20
    private let maxTemp: Double = 110

    @State private var draggingID: UUID?
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    grid(in: size)
                    curveShape(in: size)
                    liveMarker(in: size)
                    handles(in: size)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    addPoint(at: location, in: size)
                }
            }
            .frame(height: 230)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

            axisLegend
            pointList
        }
    }

    // MARK: Geometry helpers

    private func position(for point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (point.temperature - minTemp) / (maxTemp - minTemp),
                y: size.height * (1 - point.percent / 100))
    }

    private func value(at location: CGPoint, in size: CGSize) -> (temperature: Double, percent: Double) {
        let temperature = minTemp + Double(location.x / max(size.width, 1)) * (maxTemp - minTemp)
        let percent = (1 - Double(location.y / max(size.height, 1))) * 100
        return (min(max(temperature, minTemp), maxTemp), min(max(percent, 0), 100))
    }

    // MARK: Layers

    private func grid(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let horizontalLines = 4
            for index in 0...horizontalLines {
                let y = canvasSize.height * CGFloat(index) / CGFloat(horizontalLines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            }
            for temperature in stride(from: minTemp, through: maxTemp, by: 15) {
                let x = canvasSize.width * (temperature - minTemp) / (maxTemp - minTemp)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func curveShape(in size: CGSize) -> some View {
        let sorted = curve.points.sorted { $0.temperature < $1.temperature }
        let points = sorted.map { position(for: $0, in: size) }

        return ZStack {
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: points[0].y))
                    path.addLine(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: size.width, y: points[points.count - 1].y))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.26), Color.accentColor.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: points[0].y))
                    path.addLine(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: size.width, y: points[points.count - 1].y))
                }
                .stroke(Thermal.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @ViewBuilder
    private func liveMarker(in size: CGSize) -> some View {
        if let temperature = currentTemperature, temperature >= minTemp {
            let x = size.width * (min(temperature, maxTemp) - minTemp) / (maxTemp - minTemp)
            let percent = curve.percent(at: temperature)
            let y = size.height * (1 - percent / 100)

            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(Thermal.color(temperature).opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))

            Circle()
                .fill(Thermal.color(temperature))
                .frame(width: 9, height: 9)
                .position(x: x, y: y)
                .shadow(color: Thermal.color(temperature).opacity(0.6), radius: 5)

            Text(readout(temperature: temperature, percent: percent))
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                .position(x: min(max(x, 44), size.width - 44), y: 13)
        }
    }

    private func readout(temperature: Double, percent: Double) -> String {
        var text = String(format: "%.0f°C → %.0f %%", temperature, percent)
        if let fan {
            text += String(format: " (%.0f RPM)", fan.rpm(forPercent: percent))
        }
        return text
    }

    private func handles(in size: CGSize) -> some View {
        ForEach(curve.points) { point in
            let location = position(for: point, in: size)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 3))
                .frame(width: selectedID == point.id ? 15 : 12,
                       height: selectedID == point.id ? 15 : 12)
                .shadow(radius: 1.5, y: 0.5)
                .position(location)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            draggingID = point.id
                            selectedID = point.id
                            update(id: point.id, to: gesture.location, in: size)
                        }
                        .onEnded { _ in
                            draggingID = nil
                            curve.normalize()
                        }
                )
        }
    }

    private var axisLegend: some View {
        HStack {
            Text("20 °C")
            Spacer()
            Text("double-click: add a point · drag: move")
                .foregroundStyle(.tertiary)
            Spacer()
            Text("110 °C")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private var pointList: some View {
        HStack(spacing: 6) {
            ForEach(curve.points.sorted { $0.temperature < $1.temperature }) { point in
                HStack(spacing: 3) {
                    Text(String(format: "%.0f°", point.temperature))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(Int(point.percent.rounded()))%")
                }
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(selectedID == point.id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                            in: Capsule())
                .onTapGesture { selectedID = point.id }
            }

            Spacer()

            Button {
                guard let selectedID, curve.points.count > 2 else { return }
                curve.points.removeAll { $0.id == selectedID }
                self.selectedID = nil
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(selectedID == nil || curve.points.count <= 2)
            .help("Delete the selected point")
        }
    }

    // MARK: Mutations

    private func update(id: UUID, to location: CGPoint, in size: CGSize) {
        guard let index = curve.points.firstIndex(where: { $0.id == id }) else { return }
        let new = value(at: location, in: size)
        curve.points[index].temperature = new.temperature
        curve.points[index].percent = new.percent
    }

    private func addPoint(at location: CGPoint, in size: CGSize) {
        let new = value(at: location, in: size)
        let point = CurvePoint(temperature: new.temperature, percent: new.percent)
        curve.points.append(point)
        curve.normalize()
        selectedID = point.id
    }
}

// MARK: - Source picker

struct CurveSourcePicker: View {
    @Binding var source: CurveSource
    var availableKeys: [(key: String, name: String, group: SensorGroup)]

    var body: some View {
        Menu {
            Button("Hottest component") { source = .hottest }
            Divider()
            ForEach(SensorGroup.controllable, id: \.self) { group in
                Button(group.title) { source = .group(group) }
            }
            Divider()
            Menu("Specific sensor") {
                ForEach(SensorGroup.allCases, id: \.self) { group in
                    let keys = availableKeys.filter { $0.group == group }
                    if !keys.isEmpty {
                        Menu(group.title) {
                            ForEach(keys, id: \.key) { entry in
                                Button("\(entry.name) (\(entry.key))") { source = .key(entry.key) }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: source.symbol)
                Text(source.title)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

import SwiftUI
import UniformTypeIdentifiers

private let bandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
private let presets = EQPreset.allCases.filter { $0 != .custom }

struct EqualizerPage: View {
    @EnvironmentObject var pods: EarPods
    @State private var fileError: String?

    var body: some View {
        VStack(spacing: 16) {
            Card("Equalizer", "slider.vertical.3") {
                Switch("Equalizer", isOn: Binding(get: { pods.eqOn }, set: pods.setEQ))
                EQStatus()
            }

            VStack(spacing: 14) {
                EQCurve(gains: pods.eqGains).frame(height: 140)
                HStack(spacing: 0) {
                    ForEach(0..<EQ.frequencies.count, id: \.self) { i in
                        BandSlider(value: pods.eqGains[i], label: bandLabels[i]) { pods.setGain($0, band: i) }
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 210)
            }
            .padding(16)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(pods.eqOn ? 1 : 0.6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets) { p in
                        Button { pods.choose(p) } label: { Chip(title: p.title, selected: pods.eqPreset == p) }
                            .buttonStyle(.plain)
                    }
                    if pods.eqPreset == .custom {
                        Chip(title: pods.eqName, selected: true).transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy, value: pods.eqPreset)

            HStack {
                Button { importEQ() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { exportEQ() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Spacer()
            }
            .alert("Couldn't use that EQ", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fileError ?? "")
            }

            Text("Shapes all sound going to your EarPods. The first time, macOS asks to allow System Audio Recording. If audio goes silent, turn the equalizer off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension EqualizerPage {
    private func importEQ() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an EQ to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pods.importEQ(from: url) } catch { fileError = error.localizedDescription }
    }

    private func exportEQ() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(pods.eqName) EQ.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try pods.exportEQ(to: url) } catch { fileError = error.localizedDescription }
    }
}

private struct Chip: View {
    let title: String, selected: Bool

    var body: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
    }
}

/// Compact on/off + preset, for the menu bar panel.
struct EQCard: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        Card("Equalizer", "slider.vertical.3") {
            Switch("Equalizer", isOn: Binding(get: { pods.eqOn }, set: pods.setEQ))
            HStack {
                Text("Preset")
                Spacer()
                Picker("Preset", selection: Binding(get: { pods.eqPreset }, set: pods.choose)) {
                    ForEach(presets) { Text($0.title).tag($0) }
                    if pods.eqPreset == .custom { Text(pods.eqName).tag(EQPreset.custom) }
                }
                .labelsHidden().fixedSize()
            }
            EQStatus()
        }
    }
}

struct EQStatus: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        if let problem = pods.eqProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if pods.eqOn {
            HStack(spacing: 5) {
                Circle().fill(pods.eqRunning ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(pods.eqRunning ? "Active on EarPods" : "Waiting for EarPods to be the sound output")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Frequency response, lined up so each band sits above its slider (bands are one octave apart).
struct EQCurve: View {
    var gains: [Double]

    var body: some View {
        Canvas { ctx, size in
            let rate = 48_000.0, c = EQ.design(gains: gains, rate: rate)
            let preamp = 20 * log10(c.last!) // drawn without the anti-clip preamp so the curve shows tone, not level
            let bands = Double(EQ.frequencies.count)
            func x(_ f: Double) -> CGFloat { CGFloat((log2(f / 32) + 0.5) / bands) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / 12) * (size.height / 2 - 6) }
            func db(_ f: Double) -> Double { EQ.response(c, at: f, rate: rate) - preamp }

            for level in [-12.0, -6, 0, 6, 12] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y(level)))
                grid.addLine(to: CGPoint(x: size.width, y: y(level)))
                ctx.stroke(grid, with: .color(.primary.opacity(level == 0 ? 0.25 : 0.08)),
                           style: StrokeStyle(lineWidth: 1, dash: level == 0 ? [] : [3, 4]))
            }

            var line = Path()
            for i in 0...200 {
                let f = 32 * pow(2, Double(i) / 200 * bands - 0.5)
                let p = CGPoint(x: x(f), y: y(db(f)))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            var wash = ctx
            wash.opacity = 0.18
            wash.fill(fill, with: .style(.tint))
            ctx.stroke(line, with: .style(.tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            for f in EQ.frequencies {
                let p = CGPoint(x: x(f), y: y(db(f)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .style(.tint))
            }
        }
        .accessibilityLabel("Equalizer curve")
    }
}

/// Vertical ±12 dB slider; the fill grows from 0 dB toward the knob.
struct BandSlider: View {
    var value: Double
    var label: String
    var onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(value > 0 ? String(format: "+%.1f", value) : String(format: "%.1f", value))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { g in
                let h = g.size.height, mid = h / 2, travel = h / 2 - 9
                let knob = mid - CGFloat(value / 12) * travel
                ZStack(alignment: .top) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 4)
                    Capsule().fill(.tint).frame(width: 4, height: abs(knob - mid)).offset(y: min(knob, mid))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(y: knob - 9)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    onChange(max(EQ.range.lowerBound, min(EQ.range.upperBound, Double((mid - drag.location.y) / travel) * 12)))
                })
            }
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue(String(format: "%.1f decibels", value))
        .accessibilityAdjustableAction { dir in onChange(min(12, max(-12, value + (dir == .increment ? 1 : -1)))) }
    }
}

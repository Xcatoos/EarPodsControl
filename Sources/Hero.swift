import SwiftUI

/// Apple's "expo out" feel: fast start, long calm settle, no overshoot.
extension Animation {
    static func reveal(_ duration: Double = 1.1) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
}

/// Fades content up into place once, after `delay`. Used to stage the Overview intro.
struct Intro: ViewModifier {
    var delay: Double = 0
    var distance: CGFloat = 14
    @AppStorage("introAnimation") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let on = shown || !enabled || reduceMotion
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : distance)
            .onAppear { withAnimation(.reveal().delay(delay)) { shown = true } }
    }
}

extension View {
    func intro(delay: Double = 0, distance: CGFloat = 14) -> some View { modifier(Intro(delay: delay, distance: distance)) }
}

/// Apple's EarPods product photo, presented still and large. It rises into focus on appear and on connect.
struct EarPodsHero: View {
    var connected = true
    var testing: Int?
    var height: CGFloat = 420
    var animated = true

    private static let aspect = 1262.0 / 2180
    // Where the buds sit in the photo, as fractions of its size.
    private static let leftBud = UnitPoint(x: 0.16, y: 0.093)
    private static let rightBud = UnitPoint(x: 0.49, y: 0.43)

    @AppStorage("introAnimation") private var introEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var photos = Photos.shared
    @State private var shown = false

    private var width: CGFloat { height * Self.aspect }
    private var motion: Bool { animated && introEnabled && !reduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let hero = photos.hero {
                    Image(nsImage: hero).resizable().interpolation(.high)
                } else { // until Apple's photo has downloaded
                    Image(systemName: "earpods").resizable().scaledToFit().fontWeight(.ultraLight)
                        .foregroundStyle(.secondary).padding(width * 0.12)
                }
            }
                .frame(width: width, height: height)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.68), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: height * 0.045, y: height * 0.03)
                .saturation(connected ? 1 : 0)
                .opacity(connected ? 1 : 0.35)
            badge("L", at: Self.leftBud, on: testing == 0)
            badge("R", at: Self.rightBud, on: testing == 1)
        }
        .frame(width: width, height: height)
        .opacity(shown || !motion ? 1 : 0)
        .scaleEffect(shown || !motion ? 1 : 1.05)
        .offset(y: shown || !motion ? 0 : height * 0.06)
        .blur(radius: shown || !motion ? 0 : 12)
        .onAppear(perform: reveal)
        .onChange(of: connected) { _, on in
            guard on, motion else { return }
            shown = false
            DispatchQueue.main.async(execute: reveal)
        }
        .animation(.easeInOut(duration: 0.5), value: connected)
        .accessibilityLabel(connected ? "EarPods, connected" : "EarPods, not connected")
    }

    private func reveal() {
        withAnimation(.reveal(1.3)) { shown = true }
    }

    private func badge(_ label: String, at u: UnitPoint, on: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.tint))
            .position(x: u.x * width + width * 0.17, y: u.y * height - width * 0.13)
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: on)
    }
}

/// Apple's photo of the inline remote; the pressed button is highlighted.
struct RemotePhoto: View {
    var press: Press?
    var height: CGFloat = 380

    @ObservedObject private var photos = Photos.shared
    private static let aspect = 240.0 / 1400
    private static let partY: [Int: Double] = [-1: 0.29, 0: 0.5, 1: 0.70] // +, center, − in the photo

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: press == nil)) { tl in
            let age = press.map { tl.date.timeIntervalSince($0.date) } ?? 9
            let glow = max(0, 1 - age / 0.9)
            let w = height * Self.aspect
            ZStack(alignment: .topLeading) {
                Group {
                    if let remote = photos.remote {
                        Image(nsImage: remote).resizable().interpolation(.high)
                    } else {
                        Capsule().fill(.quaternary).padding(.horizontal, w * 0.25).padding(.vertical, height * 0.17)
                    }
                }
                    .frame(width: w, height: height)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: 22)
                    .position(x: w / 2 + 26, y: height * (Self.partY[press?.part ?? 0] ?? 0.5))
                    .opacity(glow)
            }
            .frame(width: w, height: height)
        }
        .frame(width: 140)
        .accessibilityLabel("EarPods remote")
    }
}

enum Accent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: Self { self }
    var color: Color {
        switch self {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }
}

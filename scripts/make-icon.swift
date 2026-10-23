// Renders the app icon from an original vector drawing (no Apple artwork).
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit
import SwiftUI

let plastic = LinearGradient(colors: [Color(white: 0.8), .white, Color(white: 0.88)], startPoint: .leading, endPoint: .trailing)

struct Bud: View {
    var mirrored: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(plastic).frame(width: 26, height: 168).offset(y: 52)
            Ellipse()
                .fill(RadialGradient(colors: [.white, Color(white: 0.93), Color(white: 0.76)],
                                     center: UnitPoint(x: mirrored ? 0.62 : 0.38, y: 0.3), startRadius: 2, endRadius: 64))
                .frame(width: 84, height: 92)
                .overlay {
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.42)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30, height: 44)
                        .rotationEffect(.degrees(mirrored ? -18 : 18))
                        .offset(x: mirrored ? -13 : 13, y: 2)
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 5)
        }
        .frame(width: 84, height: 220, alignment: .top)
    }
}

struct Cable: Shape {
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 160, y: 246))
        p.addQuadCurve(to: CGPoint(x: 210, y: 360), control: CGPoint(x: 160, y: 330))
        p.move(to: CGPoint(x: 260, y: 246))
        p.addQuadCurve(to: CGPoint(x: 210, y: 360), control: CGPoint(x: 260, y: 330))
        p.move(to: CGPoint(x: 210, y: 360))
        p.addLine(to: CGPoint(x: 210, y: 438))
        return p
    }
}

struct Art: View {
    var body: some View {
        ZStack {
            Cable().stroke(Color(white: 0.93), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            Capsule().fill(plastic).frame(width: 12, height: 24).position(x: 210, y: 362)
            ZStack {
                Capsule().fill(plastic).frame(width: 20, height: 62)
                VStack(spacing: 13) { // hand-drawn + and − (SF Symbols aren't licensed for app icons)
                    ZStack { Rectangle().frame(width: 7, height: 1.6); Rectangle().frame(width: 1.6, height: 7) }
                    Circle().frame(width: 3, height: 3)
                    Rectangle().frame(width: 7, height: 1.6)
                }
                .foregroundStyle(Color(white: 0.55))
            }
            .rotationEffect(.degrees(24)).position(x: 247.5, y: 317.5)
            Bud(mirrored: false).rotationEffect(.degrees(-12), anchor: .bottom).position(x: 160, y: 140)
            Bud(mirrored: true).rotationEffect(.degrees(12), anchor: .bottom).position(x: 260, y: 140)
        }
        .frame(width: 420, height: 440)
    }
}

MainActor.assumeIsolated {
    let icon = ZStack {
        LinearGradient(colors: [Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.1, green: 0.27, blue: 0.85)],
                       startPoint: .top, endPoint: .bottom)
        Art().scaleEffect(1.65).frame(width: 693, height: 726).offset(y: 40)
    }
    .frame(width: 824, height: 824)
    .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
    .frame(width: 1024, height: 1024)
    guard let cg = ImageRenderer(content: icon).cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("render failed") }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}

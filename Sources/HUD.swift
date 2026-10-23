import AppKit
import SwiftUI

/// Floating glass pop-up in the top-right corner for "connected" and volume changes.
@MainActor
enum HUD {
    enum Content: Equatable {
        case connected(usb: Bool)
        case volume(Float)
        var isVolume: Bool { if case .volume = self { true } else { false } }
    }

    final class State: ObservableObject { @Published var content = Content.volume(0) }

    private static let state = State()
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ content: Content) {
        let panel = panel ?? makePanel()
        let blur = panel.contentView!
        let updateInPlace = panel.isVisible && content.isVolume && state.content.isVolume
        state.content = content
        if !updateInPlace {
            blur.subviews.forEach { $0.removeFromSuperview() }
            let host = NSHostingView(rootView: HUDView().environmentObject(state))
            blur.addSubview(host)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            if let screen = NSScreen.main?.visibleFrame {
                let position = UserDefaults.standard.string(forKey: "hudPosition") ?? "topRight"
                let x = position == "topRight" ? screen.maxX - size.width - 14 : screen.midX - size.width / 2
                let y = position == "bottomCenter" ? screen.minY + 90 : screen.maxY - size.height - 10
                panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        hide?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; panel.animator().alphaValue = 0 } completionHandler: {
                if panel.alphaValue < 0.01 { panel.orderOut(nil) }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (content.isVolume ? 1.5 : 3.5), execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 22
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        p.contentView = blur
        panel = p
        return p
    }
}

private struct HUDView: View {
    @EnvironmentObject var state: HUD.State
    @State private var shown = false

    var body: some View {
        Group {
            switch state.content {
            case .connected(let usb):
                HStack(spacing: 14) {
                    EarPodsHero(height: 74, animated: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EarPods").font(.headline)
                        Text("Connected · \(usb ? "USB-C" : "3.5 mm")").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                }
                .frame(width: 290)
            case .volume(let v):
                HStack(spacing: 12) {
                    Image(systemName: "earpods").font(.title3)
                    GeometryReader { g in
                        Capsule().fill(.primary.opacity(0.15))
                            .overlay(alignment: .leading) { Capsule().fill(.primary).frame(width: g.size.width * CGFloat(v)) }
                    }
                    .frame(height: 7)
                    Text("\(Int((v * 100).rounded()))").font(.callout.monospacedDigit()).frame(width: 28, alignment: .trailing)
                }
                .frame(width: 250)
                .animation(.snappy(duration: 0.2), value: v)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .scaleEffect(shown ? 1 : 0.88)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.reveal(0.6)) { shown = true } }
    }
}

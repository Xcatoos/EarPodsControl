import ServiceManagement
import SwiftUI

@main
struct EarPodsControlApp: App {
    @StateObject private var pods = EarPods()

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run(); exit(0) }
    }

    var body: some Scene {
        Window("EarPods Control", id: "main") {
            MainWindow().environmentObject(pods)
        }
        .defaultSize(width: 880, height: 680)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            Panel().environmentObject(pods)
        } label: {
            MenuBarLabel().environmentObject(pods)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar panel

struct MenuBarLabel: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("menuIcon") private var icon = "earpods"
    @AppStorage("menuShowVolume") private var showVolume = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if showVolume, pods.connected { Text("\(Int((pods.volume * 100).rounded()))%").monospacedDigit() }
        }
    }
}

struct Panel: View {
    @EnvironmentObject var pods: EarPods
    @Environment(\.openWindow) private var openWindow
    @AppStorage("accent") private var accent = Accent.system
    @AppStorage("panelSound") private var showSound = true
    @AppStorage("panelEQ") private var showEQ = true
    @AppStorage("panelMic") private var showMic = true

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "earpods")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(pods.connected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.gray.opacity(0.45))))
                VStack(alignment: .leading, spacing: 2) {
                    Text("EarPods").font(.headline)
                    StatusLine()
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit EarPods Control")
            }
            .padding(.horizontal, 4)

            if showSound { SoundCard() }
            if showEQ { EQCard() }
            if showMic { MicCard() }

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open EarPods Control", systemImage: "macwindow").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .toggleStyle(.switch)
        .tint(accent.color)
        .padding(12)
        .frame(width: 340)
    }
}

// MARK: - Shared pieces

struct StatusLine: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(pods.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(pods.connected ? "Connected · \(pods.isUSB ? "USB-C" : "3.5 mm")" : "Not connected")
                .font(.caption).foregroundStyle(.secondary)
            if pods.connected, pods.playing, !pods.muted {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Playing")
            }
        }
    }
}

struct SoundCard: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        Card("Sound", "speaker.wave.2.fill") {
            HStack(spacing: 8) {
                IconButton(pods.muted ? "speaker.slash.fill" : "speaker.fill", active: pods.muted) { pods.toggleMute() }
                Slider(value: bind(pods.volume, pods.setVolume), in: 0...1)
                Text("\(Int((pods.volume * 100).rounded()))%").valueStyle()
            }
            HStack(spacing: 8) {
                Text("L").font(.caption.weight(.semibold)).frame(width: 22)
                Slider(value: bind(pods.balance, pods.setBalance), in: 0...1)
                Text("R").font(.caption.weight(.semibold))
                Button("Center") { pods.setBalance(0.5) }
                    .controlSize(.small).disabled(abs(pods.balance - 0.5) < 0.01)
            }
            HStack {
                Text("Test channels").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { pods.testTone(right: false) } label: { Label("Left", systemImage: "play.fill") }
                Button { pods.testTone(right: true) } label: { Label("Right", systemImage: "play.fill") }
            }
            .controlSize(.small)
        }
        .disabled(!pods.connected)
    }
}

struct MicCard: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        Card("Microphone", "mic.fill") {
            HStack(spacing: 8) {
                IconButton(pods.micMuted ? "mic.slash.fill" : "mic.fill", active: pods.micMuted) { pods.toggleMic() }
                Slider(value: bind(pods.micVolume, pods.setMic), in: 0...1)
                Text("\(Int((pods.micVolume * 100).rounded()))%").valueStyle()
            }
        }
        .disabled(pods.input == nil)
    }
}

struct AccessBanner: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        if !pods.remoteReady {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility access needed").font(.callout.weight(.semibold))
                    Text("Lets EarPods Control see and remap the remote buttons.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Allow…") { pods.requestAccess() }
                    Button("Already on? Reset") { pods.resetAccess() }
                        .buttonStyle(.link).font(.caption)
                        .help("Removes the old permission entry and asks again. Turn EarPods Control on in the list that opens.")
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct RemoteRow: View {
    let click: Click
    @AppStorage private var action: RemoteAction
    @AppStorage private var shortcut: String

    init(click: Click) {
        self.click = click
        _action = AppStorage(wrappedValue: .system, click.rawValue)
        _shortcut = AppStorage(wrappedValue: "", click.rawValue + ".shortcut")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Text(click.title)
                Spacer()
                Picker(click.title, selection: $action) {
                    Text("Default (\(click.systemTitle))").tag(RemoteAction.system)
                    Divider()
                    ForEach(RemoteAction.allCases.dropFirst()) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if action == .shortcut {
                TextField("Shortcut name", text: $shortcut).textFieldStyle(.roundedBorder).controlSize(.small)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String, icon: String
    @ViewBuilder let content: Content

    init(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Switch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct IconButton: View {
    let symbol: String, active: Bool, action: () -> Void

    init(_ symbol: String, active: Bool, action: @escaping () -> Void) {
        self.symbol = symbol; self.active = active; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .white : .primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(active ? Color.red.opacity(0.85) : Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
    }
}

extension Text {
    func valueStyle() -> some View {
        monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
    }
}

func bind(_ value: Float, _ set: @escaping (Float) -> Void) -> Binding<Double> {
    Binding(get: { Double(value) }, set: { set(Float($0)) })
}

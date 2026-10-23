import Charts
import ServiceManagement
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, sound, equalizer, microphone, remote, hearing, customize, general
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: "earpods"
        case .sound: "speaker.wave.2.fill"
        case .equalizer: "slider.vertical.3"
        case .microphone: "mic.fill"
        case .remote: "hand.tap.fill"
        case .hearing: "ear.fill"
        case .customize: "paintbrush.fill"
        case .general: "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .overview: .blue
        case .sound: .pink
        case .equalizer: .green
        case .microphone: .orange
        case .remote: .purple
        case .hearing: .red
        case .customize: .indigo
        case .general: .gray
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("accent") private var accent = Accent.system
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(p.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                Group {
                    switch page ?? .overview {
                    case .overview: OverviewPage()
                    case .sound: SoundPage()
                    case .equalizer: EqualizerPage()
                    case .microphone: MicrophonePage()
                    case .remote: RemotePage()
                    case .hearing: HearingPage()
                    case .customize: CustomizePage()
                    case .general: GeneralPage()
                    }
                }
                .frame(maxWidth: 580)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle((page ?? .overview).title)
        }
        .toggleStyle(.switch)
        .tint(accent.color)
        .frame(minWidth: 780, minHeight: 600)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("showStats") private var showStats = true

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Text("EarPods").font(.system(size: 46, weight: .semibold)).tracking(-0.8)
                StatusLine().scaleEffect(1.1)
            }
            .intro()

            ZStack(alignment: .top) {
                Ellipse() // soft neutral spotlight
                    .fill(RadialGradient(colors: [Color.primary.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 250))
                    .frame(width: 540, height: 420)
                    .intro(delay: 0.1, distance: 0)
                EarPodsHero(connected: pods.connected, testing: pods.testing, height: 400)
                if let press = pods.press {
                    PressBubble(press: press).transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .frame(height: 400)
            .animation(.easeOut(duration: 0.25), value: pods.press)

            if pods.connected {
                if showStats {
                    HStack(spacing: 12) {
                        Tile(title: "Volume", value: pods.muted ? "Muted" : "\(Int((pods.volume * 100).rounded()))%", icon: "speaker.wave.2.fill")
                            .intro(delay: 0.35)
                        Tile(title: "Balance", value: balanceText, icon: "slider.horizontal.3").intro(delay: 0.42)
                        Tile(title: "Microphone", value: pods.micMuted ? "Muted" : "On", icon: "mic.fill").intro(delay: 0.49)
                        Tile(title: "Today", value: duration(pods.today.listened), icon: "headphones").intro(delay: 0.56)
                    }
                }
                SoundCard().intro(delay: 0.65)
            } else {
                Text("Plug in your EarPods to get started.")
                    .font(.title3).foregroundStyle(.secondary)
                    .intro(delay: 0.3)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: pods.connected)
    }

    private var balanceText: String {
        let b = pods.balance
        if abs(b - 0.5) < 0.01 { return "Centered" }
        return b < 0.5 ? "L \(Int(((0.5 - b) * 200).rounded()))%" : "R \(Int(((b - 0.5) * 200).rounded()))%"
    }
}

struct PressBubble: View {
    let press: Press

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill").foregroundStyle(.tint)
            Text(press.label).fontWeight(.semibold)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(press.detail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

struct Tile: View {
    let title: String, value: String, icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(value).font(.title3.weight(.semibold)).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

func duration(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: - Sound

struct SoundPage: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("volumeStep") private var volumeStep = 0.0

    var body: some View {
        VStack(spacing: 16) {
            EarPodsHero(connected: pods.connected, testing: pods.testing, height: 280)
            SoundCard()
            Card("Audio Quality", "waveform") {
                HStack {
                    Text("Sample rate")
                    Spacer()
                    Picker("Sample rate", selection: Binding(get: { pods.sampleRate }, set: pods.setSampleRate)) {
                        ForEach(pods.sampleRates, id: \.self) { Text(String(format: "%g kHz", $0 / 1000)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .disabled(!pods.connected)
            Card("Volume Buttons", "plusminus") {
                HStack {
                    Text("Change per press")
                    Spacer()
                    Picker("Change per press", selection: $volumeStep) {
                        Text("System default").tag(0.0)
                        Divider()
                        ForEach([0.01, 0.02, 0.05, 0.1], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Text("Finer steps give precise control at low volume. Also applies to keyboard volume keys while EarPods are plugged in.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!pods.remoteReady)
            AccessBanner()
        }
    }
}

// MARK: - Microphone

struct MicrophonePage: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("useEarPodsMic") private var useEarPodsMic = true

    var body: some View {
        VStack(spacing: 16) {
            Card("Live Input", "waveform.badge.mic") {
                LevelMeter(level: pods.micMuted ? 0 : Double(pods.micLevel))
                Text(pods.input == nil ? "Plug in your EarPods to test the microphone." : "Speak to see your EarPods microphone level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MicCard()
            Card("Automation", "wand.and.stars") {
                Switch("Use EarPods microphone when plugged in", isOn: $useEarPodsMic)
            }
        }
        .onAppear { pods.startMeter() }
        .onDisappear { pods.stopMeter() }
        .onChange(of: pods.input) { _, _ in pods.startMeter() }
    }
}

struct LevelMeter: View {
    var level: Double
    private let bars = 32

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<bars, id: \.self) { i in
                let f = Double(i) / Double(bars)
                Capsule()
                    .fill(f < 0.65 ? Color.green : f < 0.85 ? Color.yellow : Color.red)
                    .opacity(f < level ? 1 : 0.15)
                    .frame(height: 10 + 26 * (f < level ? 1 : 0.4))
            }
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

// MARK: - Remote

struct RemotePage: View {
    @EnvironmentObject var pods: EarPods

    var body: some View {
        VStack(spacing: 16) {
            AccessBanner()
            HStack(spacing: 28) {
                RemotePhoto(press: pods.press)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try your remote").font(.title2.bold())
                    Text("Press any button on your EarPods. The diagram lights up and shows what happens.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let press = pods.press {
                        PressBubble(press: press).transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: pods.press)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            Card("Center Button", "hand.tap.fill") {
                ForEach(Click.allCases) { RemoteRow(click: $0) }
                Text("While EarPods are plugged in, remaps also apply to the keyboard's media keys.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!pods.remoteReady)
        }
    }
}

// MARK: - Hearing

struct HearingPage: View {
    @EnvironmentObject var pods: EarPods
    @AppStorage("accent") private var accent = Accent.system
    @AppStorage("limitOn") private var limitOn = false
    @AppStorage("limitMax") private var limitMax = 0.75

    var body: some View {
        VStack(spacing: 16) {
            Card("Volume Limit", "speaker.badge.exclamationmark.fill") {
                Switch("Limit maximum volume", isOn: $limitOn)
                    .onChange(of: limitOn) { _, _ in pods.refresh() }
                if limitOn {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).frame(width: 22)
                        Slider(value: $limitMax, in: 0.2...1, step: 0.05)
                            .onChange(of: limitMax) { _, _ in pods.refresh() }
                        Text("\(Int((limitMax * 100).rounded()))%").valueStyle()
                    }
                }
            }
            .animation(.snappy, value: limitOn)

            let week = pods.week()
            HStack(spacing: 12) {
                Tile(title: "Listening today", value: duration(pods.today.listened), icon: "headphones")
                Tile(title: "Loud today", value: duration(pods.today.loud), icon: "exclamationmark.triangle.fill")
                Tile(title: "Daily average", value: duration(week.map { $0.normal + $0.loud }.reduce(0, +) / 7), icon: "calendar")
            }

            Card("This Week", "chart.bar.fill") {
                Chart(week) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.normal / 60))
                        .foregroundStyle(by: .value("Level", "Normal"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.loud / 60))
                        .foregroundStyle(by: .value("Level", "Loud"))
                }
                .chartForegroundStyleScale(["Normal": accent.color, "Loud": Color.orange])
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartYAxisLabel("minutes")
                .frame(height: 190)
            }
            Text("Time counts while audio plays through your EarPods. Loud means above \(Int(EarPods.loudLevel * 100))% volume.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @AppStorage("pauseOnUnplug") private var pauseOnUnplug = true
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 16) {
            Card("Automation", "wand.and.stars") {
                Switch("Pause media when unplugged", isOn: $pauseOnUnplug)
            }
            Card("App", "app.badge.fill") {
                Switch("Open at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        loginItem = SMAppService.mainApp.status == .enabled
                    }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Quit EarPods Control") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

// MARK: - Customize

struct CustomizePage: View {
    @AppStorage("accent") private var accent = Accent.system
    @AppStorage("menuIcon") private var menuIcon = "earpods"
    @AppStorage("menuShowVolume") private var menuShowVolume = false
    @AppStorage("panelSound") private var panelSound = true
    @AppStorage("panelEQ") private var panelEQ = true
    @AppStorage("panelMic") private var panelMic = true
    @AppStorage("showHUD") private var showHUD = true
    @AppStorage("hudPosition") private var hudPosition = "topRight"
    @AppStorage("showStats") private var showStats = true
    @AppStorage("introAnimation") private var introAnimation = true

    private let icons = ["earpods", "headphones", "waveform", "music.note", "ear"]

    var body: some View {
        VStack(spacing: 16) {
            Card("Accent Color", "paintpalette.fill") {
                HStack(spacing: 12) {
                    ForEach(Accent.allCases) { a in
                        Button { accent = a } label: {
                            Circle()
                                .fill(a == .system
                                      ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                                      : AnyShapeStyle(a.color))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().fill(.white).frame(width: 8, height: 8).opacity(accent == a ? 1 : 0))
                                .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help(a == .system ? "System accent" : a.rawValue.capitalized)
                        .accessibilityLabel(a == .system ? "System accent" : a.rawValue.capitalized)
                        .accessibilityAddTraits(accent == a ? .isSelected : [])
                    }
                }
            }

            Card("Menu Bar", "menubar.rectangle") {
                HStack {
                    Text("Icon")
                    Spacer()
                    Picker("Icon", selection: $menuIcon) {
                        ForEach(icons, id: \.self) { Image(systemName: $0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Switch("Show volume next to icon", isOn: $menuShowVolume)
                Divider()
                Text("Show in menu").font(.caption).foregroundStyle(.secondary)
                Switch("Sound", isOn: $panelSound)
                Switch("Equalizer", isOn: $panelEQ)
                Switch("Microphone", isOn: $panelMic)
            }

            Card("Pop-up", "rectangle.inset.topright.filled") {
                Switch("Show pop-up when connected", isOn: $showHUD)
                HStack {
                    Text("Position")
                    Spacer()
                    Picker("Position", selection: $hudPosition) {
                        Text("Top Right").tag("topRight")
                        Text("Top Center").tag("topCenter")
                        Text("Bottom").tag("bottomCenter")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack {
                    Spacer()
                    Button("Preview Pop-up") { HUD.show(.connected(usb: true)) }.controlSize(.small)
                }
            }

            Card("Overview", "rectangle.grid.2x2.fill") {
                Switch("Show stats", isOn: $showStats)
                Switch("Intro animation", isOn: $introAnimation)
            }
        }
    }
}

import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import SwiftUI

// MARK: - CoreAudio helpers

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let out = kAudioObjectPropertyScopeOutput
    static let inp = kAudioObjectPropertyScopeInput
    static let global = kAudioObjectPropertyScopeGlobal

    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    // AudioHardwareService understands the "virtual main" volume/balance and passes plain properties through.
    static func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
        var a = addr(sel, scope), v = initial, size = UInt32(MemoryLayout<T>.size)
        guard AudioHardwareServiceHasProperty(id, &a) else { return nil }
        return AudioHardwareServiceGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: T) -> Bool {
        var a = addr(sel, scope), v = value, ok: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &a),
              AudioObjectIsPropertySettable(id, &a, &ok) == noErr, ok.boolValue else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static func devices() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices, global), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioObjectID) -> String {
        var a = addr(kAudioObjectPropertyName, global), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr else { return "" }
        return s?.takeRetainedValue() as String? ?? ""
    }

    static func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    // shortcut: name-based match; any wired headset on the 3.5 mm jack ("External Headphones/Microphone") counts as EarPods.
    static func earPods(_ scope: AudioObjectPropertyScope) -> AudioObjectID? {
        devices().first { id in
            let n = name(id)
            return hasStreams(id, scope) && (n.contains("EarPods") || n.hasPrefix("External Headphones") || n.hasPrefix("External Microphone"))
        }
    }

    static func isUSB(_ id: AudioObjectID) -> Bool {
        get(id, kAudioDevicePropertyTransportType, global, UInt32(0)) == kAudioDeviceTransportTypeUSB
    }

    static func sampleRates(_ id: AudioObjectID) -> [Double] {
        var a = addr(kAudioDevicePropertyAvailableNominalSampleRates, global), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: .init(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges) == noErr else { return [] }
        return Array(Set(ranges.map(\.mMinimum))).sorted()
    }

    static func uid(_ id: AudioObjectID) -> String? {
        var a = addr(kAudioDevicePropertyDeviceUID, global), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }

    static func ownProcess() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject, global), pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    static func defaultOutput() -> AudioObjectID? {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, global, AudioObjectID(0))
    }

    static func makeDefault(_ id: AudioObjectID, input: Bool) {
        set(system, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, global, id)
    }
}

// MARK: - Inline remote (media key) interception

final class Remote {
    static let volumeUp: Int32 = 0, volumeDown: Int32 = 1, play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18 // NX_KEYTYPE_*
    private static let marker: Int64 = 0x4541_5250 // tags events we post so we don't remap our own presses

    /// Called for every remote press; return true to swallow the event.
    var onKey: (_ key: Int32, _ down: Bool) -> Bool = { _, _ in false }
    private var tap: CFMachPort?

    static func decode(_ data1: Int) -> (key: Int32, down: Bool) {
        (Int32((data1 & 0xFFFF_0000) >> 16), (data1 & 0xFF00) >> 8 == 0xA)
    }

    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<Remote>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUserData) != Remote.marker,
                      let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                let (key, down) = Remote.decode(ns.data1)
                if me.onKey(key, down) { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED), callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }

    static func press(_ key: Int32) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: .init(rawValue: UInt(state << 8)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: Int(key) << 16 | state << 8, data2: -1)
            guard let cg = ev?.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: marker)
            cg.post(tap: .cghidEventTap)
        }
    }
}

enum Media {
    // MediaRemote is private; looked up at runtime so the app still runs if Apple removes it.
    static func pause() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return }
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        _ = unsafeBitCast(sym, to: Send.self)(1, nil) // kMRPause
    }
}

// MARK: - Left/right channel test tone

enum Tone {
    private static var engine: AVAudioEngine?

    static func play(channel: Int, on device: AudioObjectID) {
        engine?.stop()
        let engine = AVAudioEngine()
        var dev = device
        if let unit = engine.outputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        let rate = 44_100.0, total = Int(rate * 0.7), fade = 1_500.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var frame = 0
        let source = AVAudioSourceNode(format: format) { _, _, count, list in
            for f in 0..<Int(count) {
                let env = frame < total ? min(1, Double(frame) / fade, Double(total - frame) / fade) : 0 // fades avoid clicks
                let s = Float(sin(2 * .pi * 660 * Double(frame) / rate) * 0.25 * env)
                for (i, buf) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
                    buf.mData!.assumingMemoryBound(to: Float.self)[f] = i == channel ? s : 0
                }
                frame += 1
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        guard (try? engine.start()) != nil else { return }
        self.engine = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if self.engine === engine { engine.stop(); self.engine = nil }
        }
    }
}

// MARK: - Settings

enum Click: String, CaseIterable, Identifiable {
    case single, double, triple
    var id: String { rawValue }
    var title: String { ["Click", "Double-click", "Triple-click"][Click.allCases.firstIndex(of: self)!] }
    var key: Int32 { [Remote.play, Remote.next, Remote.previous][Click.allCases.firstIndex(of: self)!] }
    var systemTitle: String { ["Play / Pause", "Next Track", "Previous Track"][Click.allCases.firstIndex(of: self)!] }
}

enum RemoteAction: String, CaseIterable, Identifiable {
    case system, playPause, next, previous, toggleMic, toggleMute, siri, shortcut, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Default"
        case .playPause: "Play / Pause"
        case .next: "Next Track"
        case .previous: "Previous Track"
        case .toggleMic: "Mute Microphone"
        case .toggleMute: "Mute Sound"
        case .siri: "Siri"
        case .shortcut: "Run Shortcut…"
        case .nothing: "Do Nothing"
        }
    }
}

// MARK: - Model

/// One remote button press, shown in the UI. part: -1 = volume up, 0 = center, 1 = volume down.
struct Press: Equatable {
    let label: String, detail: String, part: Int
    let date = Date()
}

struct DayStat: Identifiable {
    let date: Date, normal: Double, loud: Double
    var id: Date { date }
}

@MainActor
final class EarPods: ObservableObject {
    @Published private(set) var output: AudioObjectID?
    @Published private(set) var input: AudioObjectID?
    @Published private(set) var volume: Float = 0
    @Published private(set) var balance: Float = 0.5
    @Published private(set) var muted = false
    @Published private(set) var micVolume: Float = 0
    @Published private(set) var micMuted = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var playing = false
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var sampleRates: [Double] = []
    @Published private(set) var remoteReady = false
    @Published private(set) var press: Press?
    @Published private(set) var testing: Int?
    @Published private(set) var listened: [String: Double]
    @Published private(set) var loud: [String: Double]
    @Published private(set) var eqOn: Bool
    @Published private(set) var eqRunning = false
    @Published private(set) var eqProblem: String?
    @Published private(set) var eqPreset: EQPreset
    @Published private(set) var eqGains: [Double]
    @Published private(set) var eqCustomName: String?

    var connected: Bool { output != nil }
    var isUSB: Bool { output.map(CA.isUSB) ?? false }
    static let loudLevel: Float = 0.8
    private let defaults = UserDefaults.standard
    private let remote = Remote()
    private var watched = Set<AudioObjectID>()
    private var launched = false
    private var savedMic: Float = 0.7
    private var meter: AVAudioEngine?
    private let eq = EQEngine()
    private var eqRate = 0.0
    private var eqAnimation: Timer?

    init() {
        defaults.register(defaults: ["pauseOnUnplug": true, "useEarPodsMic": true, "limitOn": false, "limitMax": 0.75,
                                     "volumeStep": 0.0, "showHUD": true, "eqOn": false])
        listened = defaults.dictionary(forKey: "listened") as? [String: Double] ?? [:]
        loud = defaults.dictionary(forKey: "loud") as? [String: Double] ?? [:]
        eqOn = defaults.bool(forKey: "eqOn")
        let preset = EQPreset(rawValue: defaults.string(forKey: "eqPreset") ?? "") ?? .flat
        eqPreset = preset
        let saved = (defaults.array(forKey: "eqGains") as? [Double]).flatMap { $0.count == EQ.frequencies.count ? $0 : nil }
        eqGains = preset.gains ?? saved ?? EQPreset.flat.gains! // presets pick up retuning
        eqCustomName = defaults.string(forKey: "eqCustomName")
        listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice, CA.global)
        listen(CA.system, kAudioHardwarePropertyDevices, CA.global)
        refresh()
        launched = true
        remote.onKey = { [weak self] key, down in
            MainActor.assumeIsolated { self?.handle(key: key, down: down) ?? false }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.remote.start() else { return }
                self.remoteReady = true
                timer.invalidate()
            }
        }.fire()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(1) }
        }
    }

    private func listen(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) {
        var a = CA.addr(sel, scope, kAudioObjectPropertyElementWildcard)
        AudioObjectAddPropertyListenerBlock(id, &a, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let out = CA.earPods(CA.out), inp = CA.earPods(CA.inp)
        if launched {
            if output != nil, out == nil, defaults.bool(forKey: "pauseOnUnplug") { Media.pause() }
            if output == nil, let out, defaults.bool(forKey: "showHUD") { HUD.show(.connected(usb: CA.isUSB(out))) }
            if let inp, inp != input, defaults.bool(forKey: "useEarPodsMic") { CA.makeDefault(inp, input: true) }
        }
        if inp != input { stopMeter() }
        output = out
        input = inp
        for (id, scope) in [(out, CA.out), (inp, CA.inp)] {
            guard let id, watched.insert(id).inserted else { continue }
            for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] { listen(id, sel, scope) }
            for sel in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsRunningSomewhere] { listen(id, sel, CA.global) }
        }
        if let out {
            volume = CA.get(out, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, CA.out, Float32(0)) ?? 0
            balance = CA.get(out, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, CA.out, Float32(0.5)) ?? 0.5
            muted = CA.get(out, kAudioDevicePropertyMute, CA.out, UInt32(0)) == 1
            // shortcut: "running somewhere" means an app has the device open; some apps keep it open while paused.
            if !eqRunning { playing = CA.get(out, kAudioDevicePropertyDeviceIsRunningSomewhere, CA.global, UInt32(0)) == 1 }
            sampleRate = CA.get(out, kAudioDevicePropertyNominalSampleRate, CA.global, Float64(0)) ?? 0
            sampleRates = CA.sampleRates(out)
            if defaults.bool(forKey: "limitOn"), volume > limit { setVolume(limit) }
        } else {
            playing = false
        }
        updateEQ()
        if let inp {
            micVolume = CA.get(inp, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, CA.inp, Float32(0)) ?? 0
            micMuted = CA.get(inp, kAudioDevicePropertyMute, CA.inp, UInt32(0)) == 1 || micVolume == 0
        }
    }

    private var limit: Float { Float(defaults.double(forKey: "limitMax")) }

    func setVolume(_ v: Float) {
        guard let output else { return }
        let v = defaults.bool(forKey: "limitOn") ? min(v, limit) : v
        if muted { CA.set(output, kAudioDevicePropertyMute, CA.out, UInt32(0)) }
        CA.set(output, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, CA.out, Float32(v))
        volume = v
    }

    func setBalance(_ b: Float) {
        guard let output else { return }
        CA.set(output, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, CA.out, Float32(b))
        balance = b
    }

    func setSampleRate(_ rate: Double) {
        if let output { CA.set(output, kAudioDevicePropertyNominalSampleRate, CA.global, Float64(rate)) }
    }

    func toggleMute() {
        guard let output else { return }
        CA.set(output, kAudioDevicePropertyMute, CA.out, UInt32(muted ? 0 : 1))
        refresh()
    }

    func setMic(_ v: Float) {
        guard let input else { return }
        if v > 0 { CA.set(input, kAudioDevicePropertyMute, CA.inp, UInt32(0)) }
        CA.set(input, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, CA.inp, Float32(v))
        micVolume = v
        micMuted = v == 0
    }

    func toggleMic() {
        guard let input else { return }
        if !CA.set(input, kAudioDevicePropertyMute, CA.inp, UInt32(micMuted ? 0 : 1)) {
            // shortcut: mics without a mute control are muted by setting their gain to 0.
            if micMuted { setMic(savedMic) } else { savedMic = micVolume; setMic(0) }
        }
        refresh()
        NSSound(named: micMuted ? "Bottle" : "Pop")?.play()
    }

    func testTone(right: Bool) {
        guard let output else { return }
        let channel = right ? 1 : 0
        Tone.play(channel: channel, on: output)
        testing = channel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.testing == channel { self?.testing = nil }
        }
    }

    // MARK: Equalizer

    func setEQ(on: Bool) {
        defaults.set(on, forKey: "eqOn")
        eqOn = on
        eqProblem = nil
        updateEQ()
    }

    /// Runs the EQ only while it's on and the EarPods are the Mac's current output.
    private func updateEQ() {
        guard eqOn, let output, CA.defaultOutput() == output else {
            if eq.device != nil { eq.stop() }
            eqRunning = false
            return
        }
        guard eq.device != output || eqRate != sampleRate else { return }
        eqRunning = eq.start(on: output, gains: eqGains)
        eqRate = CA.get(output, kAudioDevicePropertyNominalSampleRate, CA.global, Float64(0)) ?? 0
        if !eqRunning {
            defaults.set(false, forKey: "eqOn")
            eqOn = false
            eqProblem = "Couldn't start the equalizer. Allow System Audio Recording for EarPods Control in Privacy & Security."
        }
    }

    func setGain(_ gain: Double, band: Int) {
        eqAnimation?.invalidate()
        var g = eqGains
        g[band] = (gain * 2).rounded() / 2
        applyGains(g, preset: EQPreset.allCases.first { $0.gains == g } ?? .custom)
        setCustomName(nil) // hand-edited, so it's no longer the imported EQ
    }

    var eqName: String { eqPreset == .custom ? eqCustomName ?? "Custom" : eqPreset.title }

    func exportEQ(to url: URL) throws {
        try EQFile(name: eqName, frequencies: EQ.frequencies, gains: eqGains).encoded().write(to: url, options: .atomic)
    }

    func importEQ(from url: URL) throws {
        let file = try EQFile.decode(Data(contentsOf: url))
        glide(to: file.gains, preset: EQPreset.allCases.first { $0.gains == file.gains } ?? .custom)
        setCustomName(file.name)
    }

    private func setCustomName(_ name: String?) {
        eqCustomName = name
        defaults.set(name, forKey: "eqCustomName")
    }

    /// Glides to the preset over ~0.3 s so both the sliders and the sound move smoothly.
    func choose(_ preset: EQPreset) {
        if let target = preset.gains { glide(to: target, preset: preset) }
    }

    private func glide(to target: [Double], preset: EQPreset) {
        eqAnimation?.invalidate()
        let start = eqGains
        var step = 0.0
        eqAnimation = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                step = min(1, step + 1 / 18)
                let e = 1 - pow(1 - step, 3) // ease-out
                self?.applyGains(zip(start, target).map { $0 + ($1 - $0) * e }, preset: preset)
                if step >= 1 { timer.invalidate() }
            }
        }
    }

    private func applyGains(_ g: [Double], preset: EQPreset) {
        eqGains = g
        eqPreset = preset
        defaults.set(g, forKey: "eqGains")
        defaults.set(preset.rawValue, forKey: "eqPreset")
        if eqRunning { eq.setGains(g) }
    }

    // MARK: Live mic level

    func startMeter() {
        guard meter == nil, var device = input else { return }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let unit = node.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let db = 10 * log10(sum / Float(buffer.frameLength) + 1e-9) // RMS in dBFS
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { [weak self] in
                if self?.meter != nil { self?.micLevel = level }
            }
        }
        guard (try? engine.start()) != nil else { node.removeTap(onBus: 0); return }
        meter = engine
    }

    func stopMeter() {
        meter?.inputNode.removeTap(onBus: 0)
        meter?.stop()
        meter = nil
        micLevel = 0
    }

    // MARK: Listening stats

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func tick(_ seconds: Double) {
        if eqRunning { // the EQ keeps the EarPods busy, so "playing" comes from the actual signal instead
            playing = eq.peak > 0.0005
            eq.peak = 0
        }
        guard connected, playing else { return }
        let day = Self.dayFormat.string(from: Date())
        // shortcut: one entry per day is kept forever (a few bytes/day); prune if it ever matters.
        listened[day, default: 0] += seconds
        if volume >= Self.loudLevel { loud[day, default: 0] += seconds }
        defaults.set(listened, forKey: "listened")
        defaults.set(loud, forKey: "loud")
    }

    func week() -> [DayStat] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        return (0..<7).reversed().map { back in
            let date = cal.date(byAdding: .day, value: -back, to: today)!
            let key = Self.dayFormat.string(from: date)
            let l = loud[key] ?? 0
            return DayStat(date: date, normal: (listened[key] ?? 0) - l, loud: l)
        }
    }

    var today: (listened: Double, loud: Double) {
        let key = Self.dayFormat.string(from: Date())
        return (listened[key] ?? 0, loud[key] ?? 0)
    }

    // MARK: Remote

    func requestAccess() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Clears a stale Accessibility entry (left by an older build) and asks again.
    func resetAccess() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier!]
        try? reset.run()
        reset.waitUntilExit()
        requestAccess()
    }

    private func show(_ p: Press) {
        press = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.press == p { self?.press = nil }
        }
    }

    private func handle(key: Int32, down: Bool) -> Bool {
        guard connected else { return false }
        if key == Remote.volumeUp || key == Remote.volumeDown {
            let up = key == Remote.volumeUp, step = Float(defaults.double(forKey: "volumeStep"))
            if down { show(Press(label: up ? "Volume +" : "Volume −", detail: up ? "Louder" : "Quieter", part: up ? -1 : 1)) }
            guard step > 0 else { return false }
            if down {
                setVolume(max(0, min(1, volume + (up ? step : -step))))
                HUD.show(.volume(volume))
            }
            return true
        }
        guard let click = Click.allCases.first(where: { $0.key == key }) else { return false }
        let action = RemoteAction(rawValue: defaults.string(forKey: click.rawValue) ?? "") ?? .system
        if down { show(Press(label: click.title, detail: action == .system ? click.systemTitle : action.title, part: 0)) }
        guard action != .system else { return false }
        guard down else { return true }
        switch action {
        case .playPause: Remote.press(Remote.play)
        case .next: Remote.press(Remote.next)
        case .previous: Remote.press(Remote.previous)
        case .toggleMic: toggleMic()
        case .toggleMute: toggleMute()
        case .siri: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Siri.app"))
        case .shortcut:
            let name = defaults.string(forKey: click.rawValue + ".shortcut") ?? ""
            if !name.isEmpty { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", name]) }
        case .system, .nothing: break
        }
        return true
    }
}

// MARK: - Self-test (`EarPodsControl --selftest`)

enum SelfTest {
    static func run() {
        precondition(Remote.decode(16 << 16 | 0xA << 8) == (16, true))
        precondition(Remote.decode(18 << 16 | 0xB << 8) == (18, false))
        precondition(NSImage(systemSymbolName: "earpods", accessibilityDescription: nil) != nil)
        precondition(FileManager.default.fileExists(atPath: "/System/Library/CoreServices/Siri.app"))
        let flat = EQ.design(gains: EQPreset.flat.gains!, rate: 48_000)
        precondition(abs(EQ.response(flat, at: 1000, rate: 48_000)) < 0.001)
        precondition(Photos.crop(Data("not an image".utf8), to: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        let roundTrip = try! EQFile.decode(EQFile(name: " Mine ", frequencies: EQ.frequencies, gains: EQPreset.earpods.gains!).encoded())
        precondition(roundTrip.name == "Mine" && roundTrip.gains == EQPreset.earpods.gains!)
        precondition(try! EQFile.decode(#"{"name":"x","gains":[99,0,0,0,0,0,0,0,0,-99]}"#.data(using: .utf8)!).gains.first == 12)
        precondition((try? EQFile.decode(#"{"name":"x","gains":[1,2,3]}"#.data(using: .utf8)!)) == nil)
        precondition((try? EQFile.decode(Data("not json".utf8))) == nil)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: "EQs")) ?? [] where f.hasSuffix(".json") {
            precondition((try? EQFile.decode(Data(contentsOf: URL(fileURLWithPath: "EQs/" + f)))) != nil, "bad sample EQ: \(f)")
        }
        var boost = EQPreset.flat.gains!; boost[5] = 6 // +6 dB at 1 kHz, preamp -6 dB → ~0 dB at 1 kHz
        let c = EQ.design(gains: boost, rate: 48_000)
        precondition(abs(EQ.response(c, at: 1000, rate: 48_000)) < 0.05 && EQ.response(c, at: 100, rate: 48_000) < -5.5)
        for p in EQPreset.allCases { // no preset may push the signal above 0 dB
            guard let g = p.gains else { continue }
            let d = EQ.design(gains: g, rate: 48_000)
            precondition((0...200).allSatisfy { EQ.response(d, at: 20 * pow(1000, Double($0) / 200), rate: 48_000) < 0.05 }, "\(p) clips")
        }
        for scope in [CA.out, CA.inp] {
            guard let id = CA.earPods(scope) else { print("no EarPods for scope \(scope)"); continue }
            let vol = CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, Float32(-1))
            let bal = CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope, Float32(-1))
            if let vol { precondition(CA.set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, vol), "volume not settable") }
            if let bal { precondition(CA.set(id, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope, bal), "balance not settable") }
            print("\(CA.name(id)) usb=\(CA.isUSB(id)) volume=\(vol as Any) balance=\(bal as Any) rates=\(CA.sampleRates(id))")
        }
        print("selftest ok")
    }
}

import AudioToolbox
import CoreAudio
import Foundation
import os

// MARK: - Presets and filter design

enum EQ {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range = -12.0...12.0
    private static let q = 1.41 // one-octave bands

    /// Peaking-filter coefficients (RBJ cookbook), 5 per band: b0 b1 b2 a1 a2, plus a trailing preamp gain.
    static func design(gains: [Double], rate: Double) -> [Double] {
        var c: [Double] = []
        for (f, g) in zip(frequencies, gains) {
            let a = pow(10, g / 40), w = 2 * .pi * min(f, rate * 0.45) / rate, alpha = sin(w) / (2 * q), cw = cos(w)
            let a0 = 1 + alpha / a
            c += [(1 + alpha * a) / a0, -2 * cw / a0, (1 - alpha * a) / a0, -2 * cw / a0, (1 - alpha / a) / a0]
        }
        // Lower everything by the curve's real peak (neighbouring boosts stack) so nothing clips.
        let probes = frequencies + (0...200).map { 20 * pow(1000, Double($0) / 200) }
        let peak = probes.map { response(c + [1], at: $0, rate: rate) }.max()!
        return c + [pow(10, -max(0, peak) / 20)]
    }

    /// Total response in dB at `freq` for the given coefficients (used to draw the curve).
    static func response(_ c: [Double], at freq: Double, rate: Double) -> Double {
        let w = 2 * .pi * freq / rate, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        var db = 20 * log10(c.last!)
        for i in stride(from: 0, to: c.count - 1, by: 5) {
            let (b0, b1, b2, a1, a2) = (c[i], c[i + 1], c[i + 2], c[i + 3], c[i + 4])
            let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
            let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
            db += 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        return db
    }
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat, earpods, bass, vocal, treble, podcast, loudness, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .flat: "Flat"
        case .earpods: "EarPods+"
        case .bass: "Bass Boost"
        case .vocal: "Vocal"
        case .treble: "Treble"
        case .podcast: "Podcast"
        case .loudness: "Loudness"
        case .custom: "Custom"
        }
    }
    var gains: [Double]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        // Deep bass without mud (250 Hz cut), plus presence and air so voices stay clear.
        case .earpods: [5, 4.5, 2, -1.5, -1, 0.5, 2.5, 3.5, 2.5, 1.5]
        case .bass: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]
        case .vocal: [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .treble: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]
        case .podcast: [-6, -4, -2, 0, 2, 3, 3, 2, 0, -2]
        case .loudness: [6, 4, 2, 0, -1, 0, 1, 3, 4, 3]
        case .custom: nil
        }
    }
}

// MARK: - EQ files (import / export)

/// A shareable EQ: `{"name": "...", "frequencies": [32, ...], "gains": [5, 4.5, ...]}`.
struct EQFile: Codable {
    var name: String
    var frequencies: [Double]?
    var gains: [Double]

    enum Problem: LocalizedError {
        case notEQ, wrongBands
        var errorDescription: String? {
            switch self {
            case .notEQ: "This file isn't an EarPods Control EQ."
            case .wrongBands: "This EQ uses different bands (needs 10 bands, 32 Hz to 16 kHz)."
            }
        }
    }

    /// Validates untrusted file contents; gains are clamped to the slider range.
    static func decode(_ data: Data) throws -> EQFile {
        guard var file = try? JSONDecoder().decode(EQFile.self, from: data) else { throw Problem.notEQ }
        guard file.gains.count == EQ.frequencies.count, file.frequencies.map({ $0 == EQ.frequencies }) ?? true else { throw Problem.wrongBands }
        file.gains = file.gains.map { min(EQ.range.upperBound, max(EQ.range.lowerBound, $0)) }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        file.name = name.isEmpty ? "Imported" : String(name.prefix(40))
        return file
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

// MARK: - System-wide EQ engine

/// Taps all system audio (muting the original), runs it through the EQ, and plays it on the EarPods.
final class EQEngine {
    private let unknown = AudioObjectID(kAudioObjectUnknown)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private(set) var device: AudioObjectID?
    private(set) var rate = 48_000.0
    /// Loudest input sample since last reset. Written by the audio thread; a torn read only skews one UI tick.
    var peak: Float = 0

    private let pending = OSAllocatedUnfairLock<[Double]?>(initialState: nil)
    // Audio-thread state.
    private var coeffs: [Double] = []
    private var state = [Double](repeating: 0, count: 2 * EQ.frequencies.count * 2) // channel × band × (z1, z2)

    func setGains(_ gains: [Double]) {
        let c = EQ.design(gains: gains, rate: rate)
        pending.withLock { $0 = c }
    }

    func start(on output: AudioObjectID, gains: [Double]) -> Bool {
        stop()
        // Excluding ourselves keeps our own EQ'd output from being tapped again (a feedback loop).
        guard let uid = CA.uid(output), let me = CA.ownProcess() else { return false }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        desc.name = "EarPods Control EQ"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return false }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Control EQ Engine",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else { stop(); return false }
        rate = CA.get(aggregate, kAudioDevicePropertyNominalSampleRate, CA.global, Float64(0)) ?? 48_000
        coeffs = EQ.design(gains: gains, rate: rate)
        state = state.map { _ in 0 }

        let block: AudioDeviceIOBlock = { [unowned self] _, input, _, output, _ in self.render(input, output) }
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, block) == noErr,
              AudioDeviceStart(aggregate, proc) == noErr else { stop(); return false }
        device = output
        return true
    }

    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != unknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != unknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = unknown
        tap = unknown
        device = nil
    }

    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        // shortcut: the swapped-out coefficient array is freed on the audio thread; fine at this size.
        if let new = pending.withLockIfAvailable({ p -> [Double]? in defer { p = nil }; return p }) ?? nil { coeffs = new }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        // The tap is the last input stream; earlier ones belong to the EarPods mic.
        guard let tapBuf = ins.last, let src = tapBuf.mData?.assumingMemoryBound(to: Float.self), tapBuf.mNumberChannels > 0 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let inCh = Int(tapBuf.mNumberChannels), frames = Int(tapBuf.mDataByteSize) / (4 * inCh)
        let bands = EQ.frequencies.count, preamp = coeffs.last ?? 1
        for i in 0..<frames * inCh { peak = max(peak, abs(src[i])) }

        coeffs.withUnsafeBufferPointer { c in
            state.withUnsafeMutableBufferPointer { z in
                for out in outs {
                    guard let dst = out.mData?.assumingMemoryBound(to: Float.self), out.mNumberChannels > 0 else { continue }
                    let outCh = Int(out.mNumberChannels), n = min(frames, Int(out.mDataByteSize) / (4 * outCh))
                    for f in 0..<n {
                        for ch in 0..<outCh {
                            var x = Double(src[f * inCh + min(ch, inCh - 1)]) * preamp
                            let side = min(ch, 1) * bands * 2
                            for b in 0..<bands { // transposed direct form II
                                let k = b * 5, s = side + b * 2
                                let y = c[k] * x + z[s]
                                z[s] = c[k + 1] * x - c[k + 3] * y + z[s + 1]
                                z[s + 1] = c[k + 2] * x - c[k + 4] * y
                                x = y
                            }
                            dst[f * outCh + ch] = Float(x)
                        }
                    }
                }
            }
        }
    }
}

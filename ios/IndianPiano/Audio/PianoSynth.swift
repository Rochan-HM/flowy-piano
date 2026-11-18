import Accelerate
import AVFoundation
import Foundation
import os
import QuartzCore

enum AudioSessionConfigurator {
    /// Playback-only until the microphone is needed: a record-capable session makes every audio
    /// engine open the input device too, which (on the Simulator) waits on the Mac's microphone.
    static func configure(recording: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if recording {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            Logger(subsystem: "com.rochan.indianpiano", category: "audio").error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Polyphonic additive piano-like synth rendered by an `AVAudioSourceNode`.
///
/// The `at:` times are `CACurrentMediaTime()` seconds. The render thread starts each scheduled
/// event on its exact sample, so events sent a little ahead of time play without timer jitter.
final class PianoSynth: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let core = SynthCore(maxVoices: 32)
    /// Engine setup and (re)starts happen here: they can block inside CoreAudio when the audio
    /// session changes (e.g. when the microphone is switched on).
    private let queue = DispatchQueue(label: "com.rochan.indianpiano.synth", qos: .userInitiated)
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var recordingFile: AVAudioFile?

    var isRunning: Bool { engine.isRunning }

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !engine.isRunning else { return }
        if sourceNode == nil {
            var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if sampleRate <= 0 { sampleRate = AVAudioSession.sharedInstance().sampleRate }
            if sampleRate <= 0 { sampleRate = 44_100 }
            core.setSampleRate(Float(sampleRate))
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
            let core = self.core
            let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let frames = Int(frameCount)
                core.render(into: first, frames: frames, time: core.clockTime(of: timestamp.pointee))
                if buffers.count > 1 {
                    for index in 1..<buffers.count {
                        buffers[index].mData?.copyMemory(from: first, byteCount: frames * MemoryLayout<Float>.size)
                    }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.9
            sourceNode = node
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.start()
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Logger(subsystem: "com.rochan.indianpiano", category: "audio").error("Synth failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func noteOn(_ midi: Int, velocity: Float = 0.8, at time: TimeInterval = 0) {
        if !isRunning { start() }
        core.enqueue(.noteOn, midi: midi, velocity: velocity, at: time)
    }

    func noteOff(_ midi: Int, at time: TimeInterval = 0) { core.enqueue(.noteOff, midi: midi, velocity: 0, at: time) }

    func allNotesOff() { core.enqueue(.allOff, midi: 0, velocity: 0) }

    /// Plays a note for a fixed duration.
    func play(_ midi: Int, duration: TimeInterval, velocity: Float = 0.7) {
        noteOn(midi, velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.08, duration)) { [weak self] in self?.noteOff(midi) }
    }

    /// A metronome click; accented clicks (the first beat of a bar) are brighter and louder.
    func click(accent: Bool, at time: TimeInterval) {
        if !isRunning { start() }
        core.enqueue(.click, midi: accent ? 1 : 0, velocity: 1, at: time, group: .metronome)
    }

    /// Drops the group's scheduled events that haven't started yet.
    func cancelScheduled(_ group: SynthCore.Group) {
        core.enqueue(.cancel, midi: 0, velocity: 0, group: group)
    }

    /// Writes everything the synth plays to a file, to put sound on screen recordings.
    func record(to url: URL) {
        queue.async {
            self.startOnQueue()
            let mixer = self.engine.mainMixerNode
            let format = mixer.outputFormat(forBus: 0)
            let log = Logger(subsystem: "com.rochan.indianpiano", category: "audio")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                self.recordingFile = file
                var announced = false
                mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                    if !announced, time.isHostTimeValid {
                        announced = true
                        let start = Date().timeIntervalSince1970 - (CACurrentMediaTime() - AVAudioTime.seconds(forHostTime: time.hostTime))
                        log.info("Recording synth output to \(url.path, privacy: .public), first sample at \(String(format: "%.3f", start), privacy: .public)")
                    }
                    try? file.write(from: buffer)
                }
            } catch {
                log.error("Couldn't record synth output: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Real-time voice state. All storage is preallocated; the render thread never allocates or blocks.
///
/// Each voice is rendered a block at a time with Accelerate (vectorized sines and gain ramps), so a
/// full chord stays far inside the audio deadline even in an unoptimized build. The mix goes through
/// a look-ahead peak limiter: many notes at once are turned down smoothly instead of being clipped.
final class SynthCore: @unchecked Sendable {
    enum Command: UInt8 { case noteOn, noteOff, allOff, click, cancel }
    /// Scheduled events are tagged so the demo and the metronome can each cancel only their own.
    enum Group: UInt8 { case notes, metronome }

    /// What the render thread has done so far, for tests and diagnostics.
    struct Statistics: Equatable {
        var mostVoicesSounding = 0
        var voicesStolen = 0
        /// Lowest gain the output limiter applied; 1 means it never engaged.
        var lowestLimiterGain: Float = 1
    }

    private struct Event {
        var command: Command
        var note: Int32
        var velocity: Float
        /// Clock time to start at; 0 means as soon as possible.
        var time: Double
        var group: Group
    }

    private struct Biquad {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init() {}

        init(bandPass center: Float, q: Float, sampleRate: Float) {
            let w0 = 2 * Float.pi * center / sampleRate
            let alpha = sinf(w0) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = -2 * cosf(w0) / a0
            a2 = (1 - alpha) / a0
        }

        init(highPass cutoff: Float, q: Float, sampleRate: Float) {
            let w0 = 2 * Float.pi * cutoff / sampleRate
            let alpha = sinf(w0) / (2 * q)
            let a0 = 1 + alpha
            let c = cosf(w0)
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
            b2 = b0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    static let partialCount = 8
    static let clickVoiceCount = 4
    /// Relative amplitudes of harmonics 1...7; the eighth partial is a slightly detuned unison.
    private static let partialShape: [Float] = [1.0, 0.55, 0.32, 0.22, 0.14, 0.09, 0.05]
    /// Clicks are noise band-passed well above the notes' fundamentals, then high-passed: no
    /// stable pitch for the microphone's YIN detector, and almost nothing in the band below
    /// 1.5 kHz that `MicAnalyzer` judges key strikes on.
    static let clickCenter: (normal: Float, accent: Float) = (4_200, 5_600)
    static let clickHighPass: Float = 2_600
    static let clickGain: (normal: Float, accent: Float) = (0.32, 0.5)
    private static let clickSections = 4
    /// Longer render calls are split: keeps the scratch buffers small and the sine phase ramps precise.
    private static let chunkFrames = 512
    /// A stolen, restruck or expired voice fades out over this long rather than stopping mid-wave.
    static let fadeSeconds: Float = 0.005
    /// Output peaks stay at or below this, about -1 dBFS.
    static let limiterCeiling: Float = 0.89
    /// How far ahead the limiter sees, so it has turned down before a loud onset reaches the output.
    /// Scheduled events start this much earlier to make up for the delay.
    static let limiterLookahead: Float = 0.002
    /// Longer than half a period of the lowest piano note, so the gain doesn't ripple with the waveform.
    private static let limiterHold: Float = 0.025
    private static let limiterRelease: Float = 0.15
    private static let maxLookaheadFrames = 1_024

    /// Voices that may sound at once; the slots beyond these hold voices fading out.
    private let maxVoices: Int
    private let slotCount: Int
    private var sampleRate: Float = 44_100
    private var voiceGain: Float = 0.16
    private let hostTicksToSeconds: Double

    private var attackFrames: Int32 = 1
    private var fadeFrames: Int32 = 1
    private var maxAgeFrames: Int32 = 1
    private var lookaheadFrames = 1
    private var holdFrames: Int32 = 1
    private var releaseCoefficient: Float = 0
    private var attackCoefficient: Float = 1

    private let active: UnsafeMutablePointer<Bool>
    private let released: UnsafeMutablePointer<Bool>
    private let fading: UnsafeMutablePointer<Bool>
    private let note: UnsafeMutablePointer<Int32>
    private let age: UnsafeMutablePointer<Int32>
    private let fadeLeft: UnsafeMutablePointer<Int32>
    private let level: UnsafeMutablePointer<Float>
    /// Per-frame natural-log decay rates: `value *= exp(rate * frames)`.
    private let releaseRate: UnsafeMutablePointer<Float>
    private let transient: UnsafeMutablePointer<Float>
    private let transientRate: UnsafeMutablePointer<Float>
    private let phase: UnsafeMutablePointer<Float>
    private let increment: UnsafeMutablePointer<Float>
    private let amplitude: UnsafeMutablePointer<Float>
    private let decayRate: UnsafeMutablePointer<Float>

    private let phaseScratch: UnsafeMutablePointer<Float>
    private let sineScratch: UnsafeMutablePointer<Float>
    private let voiceScratch: UnsafeMutablePointer<Float>
    private let rampStart: UnsafeMutablePointer<Float>
    private let rampStep: UnsafeMutablePointer<Float>

    private let delayLine: UnsafeMutablePointer<Float>
    private var delayIndex = 0
    private var limiterTarget: Float = 1
    private var limiterGain: Float = 1
    private var holdLeft: Int32 = 0
    private(set) var statistics = Statistics()

    private let clickActive: UnsafeMutablePointer<Bool>
    private let clickAge: UnsafeMutablePointer<Int32>
    private let clickLevel: UnsafeMutablePointer<Float>
    private let clickDecay: UnsafeMutablePointer<Float>
    /// `clickSections` filter sections per voice: two band-passes, then a fourth-order high-pass.
    private let clickFilter: UnsafeMutablePointer<Biquad>
    private var noiseSeed: UInt32 = 0x2545_F491

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let queueCapacity = 256
    private let queued: UnsafeMutablePointer<Event>
    private var queuedCount = 0
    /// Scheduled events waiting for their time, sorted by time (render thread only).
    private let pendingCapacity = 512
    private let pending: UnsafeMutablePointer<Event>
    private var pendingCount = 0

    init(maxVoices: Int) {
        self.maxVoices = maxVoices
        slotCount = maxVoices + max(4, maxVoices / 2)
        func alloc<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
            pointer.initialize(repeating: value, count: count)
            return pointer
        }
        let partials = slotCount * Self.partialCount
        active = alloc(slotCount, false)
        released = alloc(slotCount, false)
        fading = alloc(slotCount, false)
        note = alloc(slotCount, 0)
        age = alloc(slotCount, 0)
        fadeLeft = alloc(slotCount, 0)
        level = alloc(slotCount, 0)
        releaseRate = alloc(slotCount, 0)
        transient = alloc(slotCount, 0)
        transientRate = alloc(slotCount, 0)
        phase = alloc(partials, 0)
        increment = alloc(partials, 0)
        amplitude = alloc(partials, 0)
        decayRate = alloc(partials, 0)
        phaseScratch = alloc(Self.partialCount * Self.chunkFrames, 0)
        sineScratch = alloc(Self.partialCount * Self.chunkFrames, 0)
        voiceScratch = alloc(Self.chunkFrames, 0)
        rampStart = alloc(Self.partialCount, 0)
        rampStep = alloc(Self.partialCount, 0)
        delayLine = alloc(Self.maxLookaheadFrames, 0)
        clickActive = alloc(Self.clickVoiceCount, false)
        clickAge = alloc(Self.clickVoiceCount, 0)
        clickLevel = alloc(Self.clickVoiceCount, 0)
        clickDecay = alloc(Self.clickVoiceCount, 0)
        clickFilter = alloc(Self.clickVoiceCount * Self.clickSections, Biquad())
        let empty = Event(command: .noteOn, note: 0, velocity: 0, time: 0, group: .notes)
        queued = alloc(queueCapacity, empty)
        pending = alloc(pendingCapacity, empty)
        lock = alloc(1, os_unfair_lock())
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        hostTicksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        updateRateDependentValues()
    }

    deinit {
        for pointer in [active, released, fading, clickActive] { pointer.deallocate() }
        for pointer in [note, age, fadeLeft, clickAge] { pointer.deallocate() }
        for pointer in [level, releaseRate, transient, transientRate, phase, increment, amplitude, decayRate,
                        phaseScratch, sineScratch, voiceScratch, rampStart, rampStep, delayLine, clickLevel, clickDecay] {
            pointer.deallocate()
        }
        clickFilter.deallocate()
        queued.deallocate()
        pending.deallocate()
        lock.deallocate()
    }

    func setSampleRate(_ rate: Float) {
        os_unfair_lock_lock(lock)
        sampleRate = rate
        updateRateDependentValues()
        os_unfair_lock_unlock(lock)
    }

    private func updateRateDependentValues() {
        attackFrames = max(1, Int32((sampleRate * 0.004).rounded()))
        fadeFrames = max(1, Int32((sampleRate * Self.fadeSeconds).rounded()))
        maxAgeFrames = Int32(sampleRate * 12)
        lookaheadFrames = min(Self.maxLookaheadFrames, max(1, Int((sampleRate * Self.limiterLookahead).rounded())))
        holdFrames = Int32(sampleRate * Self.limiterHold)
        releaseCoefficient = expf(-1 / (Self.limiterRelease * sampleRate))
        // Within the look-ahead the gain gets 98% of the way to what the coming peak needs.
        attackCoefficient = 1 - expf(-4 / Float(lookaheadFrames))
        delayLine.update(repeating: 0, count: Self.maxLookaheadFrames)
        delayIndex = 0
    }

    /// `CACurrentMediaTime()` seconds of a render call's first frame.
    func clockTime(of timestamp: AudioTimeStamp) -> Double {
        let ticks = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
        return Double(ticks) * hostTicksToSeconds
    }

    func enqueue(_ command: Command, midi: Int, velocity: Float, at time: Double = 0, group: Group = .notes) {
        os_unfair_lock_lock(lock)
        if queuedCount < queueCapacity {
            queued[queuedCount] = Event(command: command, note: Int32(midi), velocity: velocity, time: time, group: group)
            queuedCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    /// `time` is the clock time of the first frame; without it scheduled events start immediately.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int, time: Double? = nil) {
        if os_unfair_lock_trylock(lock) {
            for index in 0..<queuedCount {
                let event = queued[index]
                if event.time > 0, time != nil, event.command != .cancel {
                    schedule(event)
                } else {
                    apply(event)
                }
            }
            queuedCount = 0
            os_unfair_lock_unlock(lock)
        }

        output.initialize(repeating: 0, count: frames)
        let rate = Double(sampleRate)
        let lead = lookaheadFrames
        var cursor = 0
        while cursor < frames {
            var end = min(frames, cursor + Self.chunkFrames)
            while pendingCount > 0 {
                let due = time.map { Int(((pending[0].time - $0) * rate).rounded(.down)) - lead } ?? cursor
                if due > cursor {
                    end = min(end, due)
                    break
                }
                apply(pending[0])
                removeFirstPending()
            }
            renderVoices(into: output + cursor, frames: end - cursor)
            renderClicks(into: output + cursor, frames: end - cursor)
            cursor = end
        }
        limit(output, frames: frames)
    }

    private func apply(_ event: Event) {
        switch event.command {
        case .noteOn: startVoice(Int(event.note), velocity: event.velocity)
        case .noteOff: releaseVoices(Int(event.note))
        case .allOff: for voice in 0..<slotCount where active[voice] && !fading[voice] { released[voice] = true }
        case .click: startClick(accent: event.note != 0, level: event.velocity)
        case .cancel: cancelPending(event.group)
        }
    }

    /// Inserts after events with the same time, so e.g. a note-off still precedes the next note-on.
    private func schedule(_ event: Event) {
        guard pendingCount < pendingCapacity else { return }
        var index = pendingCount
        while index > 0 && pending[index - 1].time > event.time {
            pending[index] = pending[index - 1]
            index -= 1
        }
        pending[index] = event
        pendingCount += 1
    }

    private func removeFirstPending() {
        pendingCount -= 1
        for index in 0..<pendingCount { pending[index] = pending[index + 1] }
    }

    private func cancelPending(_ group: Group) {
        var kept = 0
        for index in 0..<pendingCount where pending[index].group != group {
            pending[kept] = pending[index]
            kept += 1
        }
        pendingCount = kept
    }

    // MARK: Voices

    private func renderVoices(into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let length = vDSP_Length(frames)
        let twoPi = Float.pi * 2
        for voice in 0..<slotCount where active[voice] {
            let base = voice * Self.partialCount
            var rows = 0
            for partial in 0..<Self.partialCount {
                let index = base + partial
                let start = amplitude[index]
                guard start > 1e-5 else { continue }
                let end = start * expf(decayRate[index] * Float(frames))
                var firstPhase = phase[index]
                var step = increment[index]
                vDSP_vramp(&firstPhase, &step, phaseScratch + rows * frames, 1, length)
                phase[index] = fmodf(firstPhase + step * Float(frames), twoPi)
                amplitude[index] = end
                rampStart[rows] = start
                rampStep[rows] = (end - start) / Float(frames)
                rows += 1
            }
            guard rows > 0 else {
                active[voice] = false
                continue
            }
            var count = Int32(rows * frames)
            vvsinf(sineScratch, phaseScratch, &count)
            vDSP_vclr(voiceScratch, 1, length)
            for row in 0..<rows {
                var start = rampStart[row]
                var step = rampStep[row]
                vDSP_vrampmuladd(sineScratch + row * frames, 1, &start, &step, voiceScratch, 1, length)
            }
            applyEnvelope(voice, from: voiceScratch, into: output, frames: frames)

            guard active[voice] else { continue }
            let fundamentalGone = amplitude[base] < 1e-4 && amplitude[base + 1] < 1e-4
            if level[voice] < 1e-4 || fundamentalGone {
                active[voice] = false
            } else if age[voice] > maxAgeFrames {
                beginFade(voice)
            }
        }
    }

    /// Adds the voice's partials times its envelope. The envelope is ramped linearly between its exact
    /// values at the ends of each stretch, split where the attack or a fade-out ends.
    private func applyEnvelope(_ voice: Int, from source: UnsafeMutablePointer<Float>, into output: UnsafeMutablePointer<Float>, frames: Int) {
        var offset = 0
        while offset < frames {
            var length = frames - offset
            if age[voice] < attackFrames { length = min(length, Int(attackFrames - age[voice])) }
            if fading[voice] { length = min(length, Int(fadeLeft[voice])) }
            var start = envelope(voice)
            advanceEnvelope(voice, by: length)
            var step = (envelope(voice) - start) / Float(length)
            vDSP_vrampmuladd(source + offset, 1, &start, &step, output + offset, 1, vDSP_Length(length))
            offset += length
            if fading[voice] && fadeLeft[voice] <= 0 {
                active[voice] = false
                return
            }
        }
    }

    private func envelope(_ voice: Int) -> Float {
        let attack = age[voice] < attackFrames ? Float(age[voice]) / Float(attackFrames) : 1
        let fade = fading[voice] ? Float(fadeLeft[voice]) / Float(fadeFrames) : 1
        return voiceGain * level[voice] * attack * (1 + transient[voice]) * fade
    }

    private func advanceEnvelope(_ voice: Int, by frames: Int) {
        let count = Float(frames)
        age[voice] &+= Int32(frames)
        if released[voice] { level[voice] *= expf(releaseRate[voice] * count) }
        transient[voice] *= expf(transientRate[voice] * count)
        if fading[voice] { fadeLeft[voice] -= Int32(frames) }
    }

    private func beginFade(_ voice: Int) {
        guard active[voice], !fading[voice] else { return }
        fading[voice] = true
        fadeLeft[voice] = fadeFrames
    }

    /// How loud the voice is now, ignoring the attack ramp, so a note that just started isn't taken for a quiet one.
    private func loudness(_ voice: Int) -> Float {
        let base = voice * Self.partialCount
        return level[voice] * (amplitude[base] + amplitude[base + 1])
    }

    private func startVoice(_ midi: Int, velocity: Float) {
        // A restruck key's old sound fades out under the new strike instead of jumping to silence.
        var sounding = 0
        for voice in 0..<slotCount where active[voice] && !fading[voice] {
            if note[voice] == Int32(midi) { beginFade(voice) } else { sounding += 1 }
        }
        if sounding >= maxVoices {
            var quietest = -1
            var lowest = Float.infinity
            for voice in 0..<slotCount where active[voice] && !fading[voice] && loudness(voice) < lowest {
                lowest = loudness(voice)
                quietest = voice
            }
            if quietest >= 0 {
                beginFade(quietest)
                sounding -= 1
                statistics.voicesStolen += 1
            }
        }
        var slot = -1
        for voice in 0..<slotCount where !active[voice] { slot = voice; break }
        if slot < 0 {
            // Every slot is sounding or fading out: take over the fade closest to silence.
            var shortest = Int32.max
            for voice in 0..<slotCount where fading[voice] && fadeLeft[voice] < shortest {
                shortest = fadeLeft[voice]
                slot = voice
            }
        }
        guard slot >= 0 else { return }

        let velocity = max(0.05, min(1, velocity))
        let fundamental = 440 * powf(2, (Float(midi) - 69) / 12)
        let baseDecay = min(5, max(0.35, 3.5 * powf(2, -(Float(midi) - 48) / 18)))
        let brightness = max(0.25, 1 - (Float(midi) - 60) / 60)
        let inharmonicity: Float = 0.0003
        let shape = Self.partialShape

        active[slot] = true
        released[slot] = false
        fading[slot] = false
        fadeLeft[slot] = 0
        note[slot] = Int32(midi)
        age[slot] = 0
        level[slot] = 1
        releaseRate[slot] = -1 / (0.18 * sampleRate)
        transient[slot] = 0.8 * velocity
        transientRate[slot] = -1 / (0.05 * sampleRate)

        let base = slot * Self.partialCount
        for partial in 0..<Self.partialCount {
            let index = base + partial
            let frequency: Float
            var amp: Float
            let tau: Float
            if partial < shape.count {
                let n = Float(partial + 1)
                frequency = n * fundamental * sqrtf(1 + inharmonicity * n * n)
                amp = shape[partial] * powf(velocity, 1 + 0.35 * Float(partial)) * (partial == 0 ? 1 : powf(brightness, Float(partial) * 0.5))
                tau = baseDecay / (1 + 0.7 * Float(partial))
            } else {
                frequency = fundamental * powf(2, 1.5 / 1200)
                amp = 0.35 * velocity
                tau = baseDecay * 0.8
            }
            if frequency > sampleRate * 0.45 { amp = 0 }
            phase[index] = 0
            increment[index] = 2 * Float.pi * frequency / sampleRate
            amplitude[index] = amp
            decayRate[index] = -1 / (tau * sampleRate)
        }
        statistics.mostVoicesSounding = max(statistics.mostVoicesSounding, sounding + 1)
    }

    private func releaseVoices(_ midi: Int) {
        for voice in 0..<slotCount where active[voice] && !fading[voice] && note[voice] == Int32(midi) { released[voice] = true }
    }

    // MARK: Output limiter

    /// Look-ahead peak limiter: the gain heads for what the loudest sample about to come out needs,
    /// holds through the waveform's cycles and recovers slowly. A soft knee above the ceiling catches
    /// any small overshoot, so the output never reaches full scale.
    private func limit(_ output: UnsafeMutablePointer<Float>, frames: Int) {
        let ceiling = Self.limiterCeiling
        let lookahead = lookaheadFrames
        var target = limiterTarget, gain = limiterGain, hold = holdLeft, index = delayIndex
        var lowest = gain
        for frame in 0..<frames {
            let input = output[frame]
            let magnitude = abs(input)
            let needed = magnitude > ceiling ? ceiling / magnitude : 1
            if needed <= target {
                target = needed
                hold = holdFrames
            } else if hold > 0 {
                hold -= 1
            } else {
                let recovered = 1 - (1 - target) * releaseCoefficient
                if needed < recovered {
                    target = needed
                    hold = holdFrames
                } else {
                    target = recovered
                }
            }
            gain = target < gain ? gain + (target - gain) * attackCoefficient : target
            lowest = min(lowest, gain)

            var sample = delayLine[index] * gain
            delayLine[index] = input
            index += 1
            if index >= lookahead { index = 0 }
            let peak = abs(sample)
            if peak > ceiling {
                sample = copysignf(ceiling + (1 - ceiling) * tanhf((peak - ceiling) / (1 - ceiling)), sample)
            }
            output[frame] = sample
        }
        limiterTarget = target
        limiterGain = gain
        holdLeft = hold
        delayIndex = index
        if lowest < statistics.lowestLimiterGain { statistics.lowestLimiterGain = lowest }
    }

    // MARK: Metronome clicks

    private func startClick(accent: Bool, level: Float) {
        var slot = 0
        var oldest: Int32 = -1
        for voice in 0..<Self.clickVoiceCount {
            if !clickActive[voice] { slot = voice; break }
            if clickAge[voice] > oldest { oldest = clickAge[voice]; slot = voice }
        }
        let center = min(accent ? Self.clickCenter.accent : Self.clickCenter.normal, sampleRate * 0.4)
        let filter = clickFilter + slot * Self.clickSections
        filter[0] = Biquad(bandPass: center, q: 1.4, sampleRate: sampleRate)
        filter[1] = filter[0]
        filter[2] = Biquad(highPass: Self.clickHighPass, q: 0.541_196, sampleRate: sampleRate)
        filter[3] = Biquad(highPass: Self.clickHighPass, q: 1.306_563, sampleRate: sampleRate)
        clickLevel[slot] = level * (accent ? Self.clickGain.accent : Self.clickGain.normal)
        clickDecay[slot] = expf(-1 / ((accent ? 0.009 : 0.007) * sampleRate))
        clickAge[slot] = 0
        clickActive[slot] = true
    }

    private func renderClicks(into output: UnsafeMutablePointer<Float>, frames: Int) {
        let attackSamples = max(1, sampleRate * 0.0005)
        for voice in 0..<Self.clickVoiceCount where clickActive[voice] {
            let filter = clickFilter + voice * Self.clickSections
            var gain = clickLevel[voice]
            let factor = clickDecay[voice]
            var sampleAge = clickAge[voice]
            for frame in 0..<frames {
                noiseSeed = noiseSeed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(Int32(bitPattern: noiseSeed)) / Float(Int32.max)
                let ramp = Float(sampleAge) < attackSamples ? Float(sampleAge) / attackSamples : 1
                var sample = noise * gain * ramp
                for section in 0..<Self.clickSections { sample = filter[section].process(sample) }
                output[frame] += sample
                gain *= factor
                sampleAge &+= 1
            }
            clickLevel[voice] = gain
            clickAge[voice] = sampleAge
            if sampleAge > Int32(sampleRate * 0.08) { clickActive[voice] = false }
        }
    }
}

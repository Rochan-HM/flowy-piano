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
final class SynthCore: @unchecked Sendable {
    enum Command: UInt8 { case noteOn, noteOff, allOff, click, cancel }
    /// Scheduled events are tagged so the demo and the metronome can each cancel only their own.
    enum Group: UInt8 { case notes, metronome }

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
    private let maxVoices: Int
    private var sampleRate: Float = 44_100
    private var voiceGain: Float = 0.16
    private let hostTicksToSeconds: Double

    private let active: UnsafeMutablePointer<Bool>
    private let released: UnsafeMutablePointer<Bool>
    private let note: UnsafeMutablePointer<Int32>
    private let age: UnsafeMutablePointer<Int32>
    private let level: UnsafeMutablePointer<Float>
    private let releaseFactor: UnsafeMutablePointer<Float>
    private let transient: UnsafeMutablePointer<Float>
    private let transientFactor: UnsafeMutablePointer<Float>
    private let phase: UnsafeMutablePointer<Float>
    private let increment: UnsafeMutablePointer<Float>
    private let amplitude: UnsafeMutablePointer<Float>
    private let decay: UnsafeMutablePointer<Float>

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
        func alloc<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
            pointer.initialize(repeating: value, count: count)
            return pointer
        }
        let partials = maxVoices * Self.partialCount
        active = alloc(maxVoices, false)
        released = alloc(maxVoices, false)
        note = alloc(maxVoices, 0)
        age = alloc(maxVoices, 0)
        level = alloc(maxVoices, 0)
        releaseFactor = alloc(maxVoices, 1)
        transient = alloc(maxVoices, 0)
        transientFactor = alloc(maxVoices, 0)
        phase = alloc(partials, 0)
        increment = alloc(partials, 0)
        amplitude = alloc(partials, 0)
        decay = alloc(partials, 1)
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
    }

    deinit {
        active.deallocate()
        released.deallocate()
        note.deallocate()
        age.deallocate()
        level.deallocate()
        releaseFactor.deallocate()
        transient.deallocate()
        transientFactor.deallocate()
        phase.deallocate()
        increment.deallocate()
        amplitude.deallocate()
        decay.deallocate()
        clickActive.deallocate()
        clickAge.deallocate()
        clickLevel.deallocate()
        clickDecay.deallocate()
        clickFilter.deallocate()
        queued.deallocate()
        pending.deallocate()
        lock.deallocate()
    }

    func setSampleRate(_ rate: Float) {
        os_unfair_lock_lock(lock)
        sampleRate = rate
        os_unfair_lock_unlock(lock)
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
        var cursor = 0
        while cursor < frames {
            var end = frames
            while pendingCount > 0 {
                let due = time.map { Int(((pending[0].time - $0) * rate).rounded(.down)) } ?? cursor
                if due > cursor {
                    end = min(frames, due)
                    break
                }
                apply(pending[0])
                removeFirstPending()
            }
            renderVoices(into: output + cursor, frames: end - cursor)
            renderClicks(into: output + cursor, frames: end - cursor)
            cursor = end
        }

        for frame in 0..<frames { output[frame] = tanhf(output[frame]) }
    }

    private func apply(_ event: Event) {
        switch event.command {
        case .noteOn: startVoice(Int(event.note), velocity: event.velocity)
        case .noteOff: releaseVoices(Int(event.note))
        case .allOff: for voice in 0..<maxVoices where active[voice] { released[voice] = true }
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

    private func renderVoices(into output: UnsafeMutablePointer<Float>, frames: Int) {
        let attackSamples = sampleRate * 0.004
        let twoPi = Float.pi * 2

        for voice in 0..<maxVoices where active[voice] {
            let base = voice * Self.partialCount
            var envelope = level[voice]
            var hammer = transient[voice]
            let hammerFactor = transientFactor[voice]
            let isReleased = released[voice]
            let release = releaseFactor[voice]
            var sampleAge = age[voice]

            for frame in 0..<frames {
                var sample: Float = 0
                for partial in 0..<Self.partialCount {
                    let index = base + partial
                    let amp = amplitude[index]
                    if amp > 1e-5 {
                        sample += amp * sinf(phase[index])
                        var next = phase[index] + increment[index]
                        if next >= twoPi { next -= twoPi }
                        phase[index] = next
                        amplitude[index] = amp * decay[index]
                    }
                }
                let attack = Float(sampleAge) < attackSamples ? Float(sampleAge) / attackSamples : 1
                output[frame] += sample * envelope * attack * (1 + hammer) * voiceGain
                hammer *= hammerFactor
                if isReleased { envelope *= release }
                sampleAge &+= 1
            }

            level[voice] = envelope
            transient[voice] = hammer
            age[voice] = sampleAge
            let fundamentalGone = amplitude[base] < 1e-4 && amplitude[base + 1] < 1e-4
            if envelope < 1e-4 || fundamentalGone || sampleAge > Int32(sampleRate * 12) {
                active[voice] = false
            }
        }
    }

    private func startVoice(_ midi: Int, velocity: Float) {
        var slot = -1
        for voice in 0..<maxVoices where active[voice] && note[voice] == Int32(midi) { slot = voice; break }
        if slot < 0 { for voice in 0..<maxVoices where !active[voice] { slot = voice; break } }
        if slot < 0 {
            var oldest: Int32 = -1
            for voice in 0..<maxVoices where age[voice] > oldest { oldest = age[voice]; slot = voice }
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
        note[slot] = Int32(midi)
        age[slot] = 0
        level[slot] = 1
        releaseFactor[slot] = expf(-1 / (0.18 * sampleRate))
        transient[slot] = 0.8 * velocity
        transientFactor[slot] = expf(-1 / (0.05 * sampleRate))

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
            decay[index] = expf(-1 / (tau * sampleRate))
        }
    }

    private func releaseVoices(_ midi: Int) {
        for voice in 0..<maxVoices where active[voice] && note[voice] == Int32(midi) { released[voice] = true }
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

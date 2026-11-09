import AVFoundation
import Foundation
import os

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
final class PianoSynth: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let core = SynthCore(maxVoices: 32)
    /// Engine setup and (re)starts happen here: they can block inside CoreAudio when the audio
    /// session changes (e.g. when the microphone is switched on).
    private let queue = DispatchQueue(label: "com.rochan.indianpiano.synth", qos: .userInitiated)
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?

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
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let frames = Int(frameCount)
                core.render(into: first, frames: frames)
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

    func noteOn(_ midi: Int, velocity: Float = 0.8) {
        if !isRunning { start() }
        core.enqueue(.noteOn, midi: midi, velocity: velocity)
    }

    func noteOff(_ midi: Int) { core.enqueue(.noteOff, midi: midi, velocity: 0) }

    func allNotesOff() { core.enqueue(.allOff, midi: 0, velocity: 0) }

    /// Plays a note for a fixed duration.
    func play(_ midi: Int, duration: TimeInterval, velocity: Float = 0.7) {
        noteOn(midi, velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.08, duration)) { [weak self] in self?.noteOff(midi) }
    }
}

/// Real-time voice state. All storage is preallocated; the render thread never allocates or blocks.
final class SynthCore: @unchecked Sendable {
    enum Command: UInt8 { case noteOn, noteOff, allOff }

    static let partialCount = 8
    /// Relative amplitudes of harmonics 1...7; the eighth partial is a slightly detuned unison.
    private static let partialShape: [Float] = [1.0, 0.55, 0.32, 0.22, 0.14, 0.09, 0.05]
    private let maxVoices: Int
    private var sampleRate: Float = 44_100
    private var voiceGain: Float = 0.16

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

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let queueCapacity = 256
    private let queuedKind: UnsafeMutablePointer<UInt8>
    private let queuedNote: UnsafeMutablePointer<Int32>
    private let queuedVelocity: UnsafeMutablePointer<Float>
    private var queuedCount = 0

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
        queuedKind = alloc(queueCapacity, 0)
        queuedNote = alloc(queueCapacity, 0)
        queuedVelocity = alloc(queueCapacity, 0)
        lock = alloc(1, os_unfair_lock())
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
        queuedKind.deallocate()
        queuedNote.deallocate()
        queuedVelocity.deallocate()
        lock.deallocate()
    }

    func setSampleRate(_ rate: Float) {
        os_unfair_lock_lock(lock)
        sampleRate = rate
        os_unfair_lock_unlock(lock)
    }

    func enqueue(_ command: Command, midi: Int, velocity: Float) {
        os_unfair_lock_lock(lock)
        if queuedCount < queueCapacity {
            queuedKind[queuedCount] = command.rawValue
            queuedNote[queuedCount] = Int32(midi)
            queuedVelocity[queuedCount] = velocity
            queuedCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(lock) {
            for index in 0..<queuedCount {
                switch Command(rawValue: queuedKind[index]) {
                case .noteOn?: startVoice(Int(queuedNote[index]), velocity: queuedVelocity[index])
                case .noteOff?: releaseVoices(Int(queuedNote[index]))
                case .allOff?: for voice in 0..<maxVoices where active[voice] { released[voice] = true }
                case nil: break
                }
            }
            queuedCount = 0
            os_unfair_lock_unlock(lock)
        }

        output.initialize(repeating: 0, count: frames)
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

        for frame in 0..<frames { output[frame] = tanhf(output[frame]) }
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
}

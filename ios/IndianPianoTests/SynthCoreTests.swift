import QuartzCore
import XCTest
@testable import IndianPiano

final class SynthCoreTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let base = 10.0

    private func makeCore() -> SynthCore {
        let core = SynthCore(maxVoices: 8)
        core.setSampleRate(Float(sampleRate))
        return core
    }

    /// Renders in 512-frame blocks, as the audio engine does, with `base` as the first frame's clock time.
    private func render(_ core: SynthCore, seconds: Double) -> [Float] {
        var signal = [Float](repeating: 0, count: Int(seconds * sampleRate))
        signal.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let frames = min(512, buffer.count - start)
                core.render(into: buffer.baseAddress! + start, frames: frames, time: base + Double(start) / sampleRate)
                start += frames
            }
        }
        return signal
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
    }

    func testScheduledNotesStartAndStopOnTheirSample() {
        let core = makeCore()
        // Inside the second render block, half a frame past frame 700.
        core.enqueue(.noteOn, midi: 60, velocity: 0.75, at: base + 700.5 / sampleRate)
        core.enqueue(.noteOff, midi: 60, velocity: 0, at: base + 0.5)
        let signal = render(core, seconds: 1.5)
        XCTAssertTrue(signal[..<701].allSatisfy { $0 == 0 }, "silent before the note's sample")
        XCTAssertTrue(signal[701..<720].contains { $0 != 0 })
        XCTAssertLessThan(rms(signal[Int(1.4 * sampleRate)...]), rms(signal[Int(0.4 * sampleRate)..<Int(0.5 * sampleRate)]) / 30,
                          "released after its note-off")
    }

    func testCancellingOneGroupKeepsTheOther() {
        let core = makeCore()
        core.enqueue(.noteOn, midi: 60, velocity: 0.75, at: base + 0.1)
        core.enqueue(.click, midi: 1, velocity: 1, at: base + 0.1, group: .metronome)
        core.enqueue(.cancel, midi: 0, velocity: 0, group: .notes)
        let clickOnly = render(core, seconds: 0.4)
        XCTAssertGreaterThan(rms(clickOnly[4_800..<5_800]), 0.005, "the click still sounds")
        XCTAssertTrue(clickOnly[Int(0.2 * sampleRate)...].allSatisfy { $0 == 0 }, "the note was dropped")

        let core2 = makeCore()
        core2.enqueue(.noteOn, midi: 60, velocity: 0.75, at: base + 0.1)
        core2.enqueue(.click, midi: 1, velocity: 1, at: base + 0.1, group: .metronome)
        core2.enqueue(.cancel, midi: 0, velocity: 0, group: .metronome)
        let noteOnly = render(core2, seconds: 0.4)
        XCTAssertGreaterThan(rms(noteOnly[Int(0.2 * sampleRate)...]), 0.01, "the note still sounds")
    }

    // MARK: Dense playing (static and crackle on big chords)

    private func makeCore(voices: Int) -> SynthCore {
        let core = SynthCore(maxVoices: voices)
        core.setSampleRate(Float(sampleRate))
        return core
    }

    private func chord(_ core: SynthCore, _ notes: [Int], at time: Double, length: Double, velocity: Float) {
        for midi in notes {
            core.enqueue(.noteOn, midi: midi, velocity: velocity, at: base + time)
            core.enqueue(.noteOff, midi: midi, velocity: 0, at: base + time + length)
        }
    }

    func testDenseChordsStayCleanBelowFullScale() {
        let core = makeCore(voices: 32)
        chord(core, [36, 43, 48, 52, 55, 60, 64, 67, 72, 76, 79, 84], at: 0.05, length: 1.2, velocity: 1)
        chord(core, [29, 41], at: 1.3, length: 1.6, velocity: 1)
        for index in 0..<6 {
            chord(core, [53, 57, 60, 65, 69, 72, 77, 81], at: 1.3 + Double(index) * 0.25, length: 0.22, velocity: 1)
        }
        let signal = render(core, seconds: 3.2)
        let peak = signal.map(abs).max() ?? 0
        XCTAssertLessThan(peak, 0.95, "a 12-note fortissimo chord must not reach full scale")
        XCTAssertGreaterThan(peak, 0.5, "and still plays out loud")
        let noise = SynthSignalCheck.highBandNoise(signal, sampleRate: sampleRate)
        XCTAssertLessThan(noise.shareDB, -70, "no distortion products above the notes' partials")
        XCTAssertLessThan(noise.loudestFrameDBFS, -60, "no crackle in any millisecond")
    }

    func testStolenVoicesFadeOutInsteadOfClicking() {
        let core = makeCore(voices: 8)
        // Three times as many ringing notes as voices.
        for index in 0..<24 {
            let midi = 48 + (index * 5) % 24
            core.enqueue(.noteOn, midi: midi, velocity: 0.75, at: base + 0.05 + Double(index) * 0.06)
            core.enqueue(.noteOff, midi: midi, velocity: 0, at: base + 0.05 + Double(index) * 0.06 + 1.5)
        }
        let signal = render(core, seconds: 2)
        let noise = SynthSignalCheck.highBandNoise(signal, sampleRate: sampleRate)
        XCTAssertLessThan(noise.loudestFrameDBFS, -60, "a stolen voice is faded, not cut off mid-wave")
    }

    func testRestrikingARingingKeyDoesNotClick() {
        let core = makeCore(voices: 8)
        for time in [0.05, 0.35, 0.65, 0.95] {
            core.enqueue(.noteOn, midi: 55, velocity: 0.9, at: base + time)
        }
        core.enqueue(.noteOff, midi: 55, velocity: 0, at: base + 1.3)
        let signal = render(core, seconds: 1.6)
        let noise = SynthSignalCheck.highBandNoise(signal, sampleRate: sampleRate)
        XCTAssertLessThan(noise.loudestFrameDBFS, -60, "the restruck key's old sound fades rather than jumping to silence")
        XCTAssertGreaterThan(rms(signal[Int(0.97 * sampleRate)..<Int(1.07 * sampleRate)]), 0.01, "the last strike sounds")
    }

    /// The render thread has 5.3 ms per 256-frame block; this must hold even in an unoptimized build.
    func testThirtyTwoVoicesRenderWellWithinRealTime() {
        let core = makeCore(voices: 32)
        chord(core, Array(stride(from: 36, to: 100, by: 2)), at: 0, length: 3, velocity: 0.8)
        let began = CACurrentMediaTime()
        _ = render(core, seconds: 2)
        let elapsed = CACurrentMediaTime() - began
        XCTAssertLessThan(elapsed, 2 * 0.25, "rendering 2 s of 32 voices took \(elapsed) s")
    }

    func testClicksAreShortAndQuieterThanNotes() {
        let beat = 0.5
        let clickCore = makeCore()
        clickCore.enqueue(.click, midi: 1, velocity: 1, at: base + 0.01, group: .metronome)
        let click = render(clickCore, seconds: beat)
        XCTAssertTrue(click[Int(0.12 * sampleRate)...].allSatisfy { $0 == 0 }, "an accented click is over within about 100 ms")

        let noteCore = makeCore()
        noteCore.enqueue(.noteOn, midi: 72, velocity: DemoSchedule.velocity, at: base + 0.01)
        let note = render(noteCore, seconds: beat)

        // Over a beat, even the accented click carries far less energy than a note, and peaks lower.
        let clickLevel = rms(click[...]), noteLevel = rms(note[...])
        XCTAssertLessThan(clickLevel, noteLevel / 4, "click \(clickLevel) vs note \(noteLevel)")
        let clickPeak = click.map(abs).max() ?? 0, notePeak = note.map(abs).max() ?? 0
        XCTAssertLessThan(clickPeak, notePeak, "click peak \(clickPeak) vs note peak \(notePeak)")
    }
}

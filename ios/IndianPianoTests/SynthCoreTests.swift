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

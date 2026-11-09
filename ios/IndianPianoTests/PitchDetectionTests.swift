import XCTest
@testable import IndianPiano

final class PitchDetectionTests: XCTestCase {
    // MARK: Signal helpers

    /// Sum of harmonics: `weights[k]` is the amplitude of harmonic k+1.
    static func tone(_ frequency: Double, sampleRate: Double, count: Int, weights: [Double] = [1],
                     amplitude: Double = 0.4, decay: Double = 0) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / sampleRate
            var value = 0.0
            for (k, weight) in weights.enumerated() {
                let harmonic = Double(k + 1) * frequency
                guard harmonic < sampleRate / 2 else { continue }
                value += weight * sin(2 * .pi * harmonic * t)
            }
            return Float(amplitude * value * exp(-decay * t))
        }
    }

    /// Deterministic white noise in -amplitude...amplitude.
    static func noise(count: Int, amplitude: Float, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 33) / Float(UInt32.max >> 1) * 2 - 1) * amplitude
        }
    }

    static func midiFrequency(_ midi: Int) -> Double { MIDINote.frequency(Double(midi)) }

    // MARK: YIN

    func testSineTonesAcrossThePianoRange() {
        for sampleRate in [44_100.0, 48_000.0] {
            let detector = YINPitchDetector(sampleRate: sampleRate)
            for midi in 36...96 {
                let signal = Self.tone(Self.midiFrequency(midi), sampleRate: sampleRate, count: 2048)
                guard let estimate = detector.detect(signal) else {
                    XCTFail("No pitch for MIDI \(midi) at \(sampleRate) Hz")
                    continue
                }
                XCTAssertEqual(estimate.nearestMIDI, midi, "MIDI \(midi) at \(sampleRate) Hz")
                XCTAssertLessThan(abs(estimate.cents), 8, "MIDI \(midi) at \(sampleRate) Hz is \(estimate.cents) cents off")
                XCTAssertGreaterThan(estimate.confidence, 0.9)
            }
        }
    }

    func testPianoLikeToneWithStrongOvertonesIsNotAnOctaveOff() {
        let detector = YINPitchDetector(sampleRate: 48_000)
        let weights = [0.6, 1.0, 0.55, 0.4, 0.25, 0.15, 0.1]
        for midi in stride(from: 40, through: 88, by: 3) {
            let signal = Self.tone(Self.midiFrequency(midi), sampleRate: 48_000, count: 2048, weights: weights, decay: 2)
            XCTAssertEqual(detector.detect(signal)?.nearestMIDI, midi, "MIDI \(midi)")
        }
    }

    func testDetunedNoteReportsCents() throws {
        let detector = YINPitchDetector(sampleRate: 44_100)
        let frequency = 440 * pow(2, 20.0 / 1200)
        let estimate = try XCTUnwrap(detector.detect(Self.tone(frequency, sampleRate: 44_100, count: 2048)))
        XCTAssertEqual(estimate.nearestMIDI, 69)
        XCTAssertEqual(estimate.cents, 20, accuracy: 3)
    }

    func testToneInNoiseIsStillDetected() {
        let detector = YINPitchDetector(sampleRate: 44_100)
        let clean = Self.tone(Self.midiFrequency(67), sampleRate: 44_100, count: 2048, weights: [1, 0.5, 0.3])
        let noisy = zip(clean, Self.noise(count: 2048, amplitude: 0.04)).map { $0 + $1 }
        XCTAssertEqual(detector.detect(noisy)?.nearestMIDI, 67)
    }

    func testSilenceAndNoiseAreRejected() {
        let detector = YINPitchDetector(sampleRate: 44_100)
        XCTAssertNil(detector.detect([Float](repeating: 0, count: 2048)))
        if let estimate = detector.detect(Self.noise(count: 2048, amplitude: 0.3)) {
            XCTAssertLessThan(estimate.confidence, 0.8, "white noise looked periodic: \(estimate)")
        }
    }

    func testDetectsTheAppsOwnSynthVoice() {
        let sampleRate: Float = 44_100
        for midi in [48, 60, 67, 79] {
            let core = SynthCore(maxVoices: 4)
            core.setSampleRate(sampleRate)
            core.enqueue(.noteOn, midi: midi, velocity: 0.8)
            var buffer = [Float](repeating: 0, count: 4096)
            buffer.withUnsafeMutableBufferPointer { core.render(into: $0.baseAddress!, frames: 4096) }
            let frame = Array(buffer[2048..<4096])
            XCTAssertEqual(YINPitchDetector(sampleRate: Double(sampleRate)).detect(frame)?.nearestMIDI, midi, "synth MIDI \(midi)")
        }
    }

    // MARK: Onset tracking

    func testOnsetTrackerReportsRepeatedAndChangedNotes() {
        var tracker = NoteOnsetTracker(gateRMS: 0.01)
        func estimate(_ midi: Int) -> PitchEstimate { PitchEstimate(frequency: Self.midiFrequency(midi), confidence: 0.95) }
        var onsets: [Int] = []
        func feed(_ midi: Int?, _ rms: Float) {
            if let note = tracker.process(midi.map(estimate), rms: rms) { onsets.append(note) }
        }

        // C4 struck and decaying: one onset.
        for rms in [0.2, 0.18, 0.16, 0.14, 0.12, 0.1] { feed(60, Float(rms)) }
        // C4 struck again (loudness jumps): a second onset.
        for rms in [0.25, 0.22, 0.2] { feed(60, Float(rms)) }
        // Moves to D4 without a gap: a third onset.
        for rms in [0.19, 0.18, 0.17] { feed(62, Float(rms)) }
        // Silence, then D4 again: a fourth onset.
        for _ in 0..<3 { feed(nil, 0.001) }
        for rms in [0.2, 0.19] { feed(62, Float(rms)) }

        XCTAssertEqual(onsets, [60, 60, 62, 62])
    }

    func testOnsetTrackerIgnoresQuietAndUnsureFrames() {
        var tracker = NoteOnsetTracker(gateRMS: 0.05)
        let unsure = PitchEstimate(frequency: 440, confidence: 0.4)
        let sure = PitchEstimate(frequency: 440, confidence: 0.95)
        XCTAssertNil(tracker.process(sure, rms: 0.02))
        XCTAssertNil(tracker.process(sure, rms: 0.02))
        XCTAssertNil(tracker.process(unsure, rms: 0.3))
        XCTAssertNil(tracker.process(unsure, rms: 0.3))
    }

    // MARK: Chroma chords

    func testChromaMatchesTwoHandChord() {
        let sampleRate = 44_100.0
        let analyzer = ChromaAnalyzer(sampleRate: sampleRate, size: 8192)
        let weights = [1.0, 0.45, 0.25, 0.12]
        let chord = [48, 64, 67].map { Self.tone(Self.midiFrequency($0), sampleRate: sampleRate, count: 8192, weights: weights, amplitude: 0.2) }
        let mix = (0..<8192).map { index in chord.reduce(Float(0)) { $0 + $1[index] } }
        let chroma = analyzer.chroma(of: mix)

        XCTAssertTrue(ChromaAnalyzer.matches(chroma, expected: [0, 4, 7]))
        XCTAssertFalse(ChromaAnalyzer.matches(chroma, expected: [5, 9, 0]))
        XCTAssertFalse(ChromaAnalyzer.matches(chroma, expected: [2, 7, 11]))
        XCTAssertEqual(Set(ChromaAnalyzer.activePitchClasses(chroma, level: 0.3)), [0, 4, 7])
    }

    func testChromaDoesNotMistakeOneNoteForAChord() {
        let sampleRate = 48_000.0
        let analyzer = ChromaAnalyzer(sampleRate: sampleRate, size: 8192)
        let single = Self.tone(Self.midiFrequency(60), sampleRate: sampleRate, count: 8192, weights: [1, 0.5, 0.33, 0.25])
        let chroma = analyzer.chroma(of: single)
        XCTAssertEqual(chroma.firstIndex(of: 1), 0)
        XCTAssertFalse(ChromaAnalyzer.matches(chroma, expected: [0, 4]))
        XCTAssertFalse(ChromaAnalyzer.matches(chroma, expected: [0, 7]))
    }

    func testChromaOfSilenceIsEmpty() {
        let analyzer = ChromaAnalyzer(sampleRate: 44_100, size: 4096)
        XCTAssertEqual(analyzer.chroma(of: [Float](repeating: 0, count: 4096)), [Float](repeating: 0, count: 12))
        XCTAssertFalse(ChromaAnalyzer.matches([Float](repeating: 0, count: 12), expected: [0, 4]))
    }
}

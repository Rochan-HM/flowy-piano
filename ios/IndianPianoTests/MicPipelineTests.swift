import XCTest
@testable import IndianPiano

/// Runs synthesized "recordings" through the same analysis the microphone uses (YIN, onset
/// tracking, chroma) in 1024-sample chunks, as the audio tap delivers them.
final class MicPipelineTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let overtones = [1.0, 0.5, 0.3, 0.18, 0.1]

    private func performance(_ notes: [[Int]], seconds: Double = 0.7, gap: Double = 0.35) -> [Float] {
        var signal: [Float] = []
        for chord in notes {
            let voices = chord.map {
                PitchDetectionTests.tone(PitchDetectionTests.midiFrequency($0), sampleRate: sampleRate,
                                         count: Int(seconds * sampleRate), weights: overtones,
                                         amplitude: 0.22 / Double(chord.count), decay: 2.5)
            }
            signal += (0..<Int(seconds * sampleRate)).map { index in voices.reduce(Float(0)) { $0 + $1[index] } }
            signal += [Float](repeating: 0, count: Int(gap * sampleRate))
        }
        let hiss = PitchDetectionTests.noise(count: signal.count, amplitude: 0.002, seed: 7)
        return zip(signal, hiss).map { $0 + $1 }
    }

    private func analyze(_ signal: [Float]) -> [MicFrameResult] {
        let analyzer = MicAnalyzer(sampleRate: sampleRate)
        var results: [MicFrameResult] = []
        var start = 0
        while start < signal.count {
            let end = min(signal.count, start + 1024)
            results += analyzer.process(Array(signal[start..<end]))
            start = end
        }
        return results
    }

    func testDetectsEachNoteOfAPerformanceIncludingRepeats() {
        let notes = [60, 60, 67, 67, 62, 69, 69]
        let onsets = analyze(performance(notes.map { [$0] })).compactMap(\.noteOnset)
        XCTAssertEqual(onsets, notes)
    }

    func testRecognisesAChordShortlyAfterTheStrike() {
        let results = analyze(performance([[48, 64, 67]], seconds: 1.0))
        let firstAttack = try? XCTUnwrap(results.firstIndex { $0.isAttack })
        let window = results[(firstAttack ?? 0)...].prefix(6)
        XCTAssertTrue(window.contains { $0.chroma.map { ChromaAnalyzer.matches($0, expected: [0, 4, 7]) } ?? false })
        XCTAssertFalse(results.contains { $0.chroma.map { ChromaAnalyzer.matches($0, expected: [2, 5, 9]) } ?? false })
    }

    func testOnsetChromaIgnoresTheChordStillRinging() {
        // C3-E3-G3 struck and left ringing; F#3 struck 0.6 s later over it.
        let total = Int(1.6 * sampleRate)
        let chord = [48, 52, 55].map {
            PitchDetectionTests.tone(PitchDetectionTests.midiFrequency($0), sampleRate: sampleRate, count: total, weights: overtones, amplitude: 0.12, decay: 1.2)
        }
        let start = Int(0.6 * sampleRate)
        let wrong = PitchDetectionTests.tone(PitchDetectionTests.midiFrequency(54), sampleRate: sampleRate, count: total - start,
                                             weights: overtones, amplitude: 0.25, decay: 2)
        var signal = (0..<total).map { index in chord.reduce(Float(0)) { $0 + $1[index] } }
        for index in start..<total { signal[index] += wrong[index - start] }

        let results = analyze(signal)
        let secondStrike = try? XCTUnwrap(results.last { $0.isAttack }?.attackID)
        let afterStrike = results.filter { $0.attackID == secondStrike && $0.chroma != nil && $0.framesSinceAttack <= MicAnalyzer.onsetChromaFrames }
        XCTAssertFalse(afterStrike.isEmpty)
        XCTAssertFalse(afterStrike.contains { ChromaAnalyzer.matches($0.chroma!, expected: [0, 4]) }, "ringing C-E must not count as the next chord")
        XCTAssertTrue(afterStrike.contains { ($0.chroma![6]) >= 0.9 }, "the new F# should dominate the onset chroma")
    }

    func testSuppressionIgnoresTheAppsOwnSound() {
        let analyzer = MicAnalyzer(sampleRate: sampleRate)
        analyzer.suppress(seconds: 2)
        let signal = performance([[60]])
        var onsets: [Int] = []
        var start = 0
        while start < signal.count {
            let end = min(signal.count, start + 1024)
            onsets += analyzer.process(Array(signal[start..<end])).compactMap(\.noteOnset)
            start = end
        }
        XCTAssertEqual(onsets, [])
    }

    @MainActor
    func testMicrophonePerformanceDrivesTheTwinkleLesson() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "twinkle-twinkle", withExtension: "musicxml"))
        let lesson = LessonEngine()
        lesson.handMode = .right
        lesson.load(try await ScoreImportService.shared.importScore(at: url))

        // C C G G, a wrong D, then A A.
        let onsets = analyze(performance([[60], [60], [67], [67], [62], [69], [69]])).compactMap(\.noteOnset)
        var results: [LessonEngine.InputResult] = []
        for note in onsets {
            results.append(lesson.handle(midi: note, source: .microphone, octaveTolerant: true))
        }

        XCTAssertEqual(results, [
            .correct(completedStep: true), .correct(completedStep: true), .correct(completedStep: true),
            .correct(completedStep: true), .wrong, .correct(completedStep: true), .correct(completedStep: true),
        ])
        XCTAssertEqual(lesson.currentIndex, 6)
        XCTAssertEqual(lesson.wrongCount, 1)
        XCTAssertEqual(lesson.results[4], .withMistakes)
        XCTAssertEqual(lesson.currentStep?.notes.map(\.midi), [67])
    }
}

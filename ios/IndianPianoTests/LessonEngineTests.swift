import XCTest
@testable import IndianPiano

@MainActor
final class LessonEngineTests: XCTestCase {
    /// RH: C4 (beat 0, finger 1), D4 (beat 1), E4+G4 chord (beat 2). LH: C3 (beat 0), G2 (beat 2).
    /// Tempo 60, so beats equal seconds.
    private func makeScore() -> Score {
        func note(_ midi: Int, _ beat: Double, _ hand: Hand, finger: Int? = nil) -> ScoreNote {
            ScoreNote(id: 0, midi: midi, onsetBeats: beat, durationBeats: 1, hand: hand, finger: finger)
        }
        var score = Score(
            title: "Test",
            notes: [
                note(60, 0, .right, finger: 1), note(62, 1, .right, finger: 2),
                note(64, 2, .right, finger: 3), note(67, 2, .right, finger: 5),
                note(48, 0, .left, finger: 5), note(43, 2, .left),
            ],
            tempoMap: TempoMap([TempoChange(beat: 0, bpm: 60)]),
            sourceFormat: "Test"
        )
        score.finalize()
        return score
    }

    private func makeEngine(_ mode: LessonEngine.HandMode, practice: LessonEngine.PracticeMode = .wait) -> LessonEngine {
        let engine = LessonEngine()
        engine.handMode = mode
        engine.practiceMode = practice
        engine.load(makeScore())
        return engine
    }

    private func midis(_ engine: LessonEngine) -> [[Int]] { engine.steps.map { $0.notes.map(\.midi) } }

    func testHandModesFilterSteps() {
        XCTAssertEqual(midis(makeEngine(.right)), [[60], [62], [64, 67]])
        XCTAssertEqual(midis(makeEngine(.left)), [[48], [43]])
        XCTAssertEqual(midis(makeEngine(.both)), [[48, 60], [62], [43, 64, 67]])
    }

    func testSwitchingHandModeRebuildsAndRestarts() {
        let engine = makeEngine(.right)
        engine.handle(midi: 60, source: .touch)
        XCTAssertEqual(engine.currentIndex, 1)
        engine.handMode = .left
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(midis(engine), [[48], [43]])
    }

    func testWaitModeOnlyAdvancesOnTheRightNote() {
        let engine = makeEngine(.right)
        XCTAssertEqual(engine.handle(midi: 61, source: .touch), .wrong)
        XCTAssertEqual(engine.currentIndex, 0)
        guard case let .wrong(played, expected)? = engine.feedback else { return XCTFail("expected wrong-note feedback") }
        XCTAssertEqual(played, 61)
        XCTAssertEqual(expected.map(\.midi), [60])
        XCTAssertEqual(expected.first?.finger, 1)

        XCTAssertEqual(engine.handle(midi: 60, source: .touch), .correct(completedStep: true))
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertEqual(engine.results[0], .withMistakes)
        XCTAssertEqual(engine.wrongCount, 1)
    }

    func testChordStepNeedsEveryNote() {
        let engine = makeEngine(.right)
        engine.handle(midi: 60, source: .touch)
        engine.handle(midi: 62, source: .touch)
        XCTAssertEqual(engine.handle(midi: 64, source: .touch), .correct(completedStep: false))
        XCTAssertEqual(engine.remainingNotes.map(\.midi), [67])
        XCTAssertEqual(engine.handle(midi: 64, source: .touch), .ignored)
        XCTAssertEqual(engine.handle(midi: 67, source: .touch), .correct(completedStep: true))
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.feedback, .finished)
        XCTAssertEqual(engine.accuracy, 1)
    }

    func testBothHandsNeedBothHands() {
        let engine = makeEngine(.both)
        XCTAssertEqual(engine.handle(midi: 60, source: .touch), .correct(completedStep: false))
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.handle(midi: 48, source: .touch), .correct(completedStep: true))
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testMicrophoneOctaveTolerance() {
        let strict = makeEngine(.right)
        XCTAssertEqual(strict.handle(midi: 72, source: .microphone, octaveTolerant: false), .wrong)
        let tolerant = makeEngine(.right)
        XCTAssertEqual(tolerant.handle(midi: 72, source: .microphone, octaveTolerant: true), .correct(completedStep: true))
    }

    func testMicrophoneIgnoresSinglePitchReadingsOfChordsAndRingingNotes() {
        let engine = makeEngine(.right)
        engine.handle(midi: 60, source: .microphone)
        // C4 is still ringing while D4 is expected: not a mistake.
        XCTAssertEqual(engine.handle(midi: 60, source: .microphone), .ignored)
        engine.handle(midi: 62, source: .microphone)
        // Chord step: an unrelated single-pitch reading is ignored rather than flagged.
        XCTAssertEqual(engine.handle(midi: 71, source: .microphone), .ignored)
        XCTAssertEqual(engine.wrongCount, 0)
    }

    func testChromaCompletesChordSteps() {
        let engine = makeEngine(.both)
        engine.handle(midi: 48, source: .touch)
        engine.handle(midi: 60, source: .touch)
        XCTAssertFalse(engine.handleChroma([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "single-note step can't use chroma")
        engine.handle(midi: 62, source: .touch)

        var wrongChord = [Float](repeating: 0.05, count: 12)
        wrongChord[5] = 1; wrongChord[9] = 0.8; wrongChord[0] = 0.7
        XCTAssertFalse(engine.handleChroma(wrongChord))

        var rightChord = [Float](repeating: 0.05, count: 12)
        rightChord[7] = 1; rightChord[4] = 0.8; rightChord[11] = 0.2
        XCTAssertTrue(engine.handleChroma(rightChord))
        XCTAssertTrue(engine.isFinished)
    }

    func testWrongNoteDuringAChordNeedsChromaConfirmation() {
        let engine = makeEngine(.both)
        engine.handle(midi: 48, source: .touch)
        engine.handle(midi: 60, source: .touch)
        engine.handle(midi: 62, source: .touch)
        XCTAssertEqual(engine.currentStep?.notes.map(\.midi), [43, 64, 67])

        XCTAssertFalse(engine.isWrongCandidateInChord(55), "G is in the chord (another octave)")
        XCTAssertFalse(engine.isWrongCandidateInChord(74), "D is the previous step still ringing")
        XCTAssertTrue(engine.isWrongCandidateInChord(65))

        var chord = [Float](repeating: 0.05, count: 12)
        chord[7] = 1; chord[4] = 0.8
        XCTAssertFalse(engine.chromaConfirmsWrong(65, chroma: chord))
        var single = [Float](repeating: 0.05, count: 12)
        single[5] = 1; single[0] = 0.25
        XCTAssertTrue(engine.chromaConfirmsWrong(65, chroma: single))

        engine.registerWrong(played: 65)
        XCTAssertEqual(engine.wrongCount, 1)
        guard case let .wrong(played, expected)? = engine.feedback else { return XCTFail("expected wrong-note feedback") }
        XCTAssertEqual(played, 65)
        XCTAssertEqual(expected.map(\.midi), [43, 64, 67])
        XCTAssertEqual(engine.currentIndex, 2)
    }

    func testTempoModeMarksMissedStepsAndScoresHits() {
        let engine = makeEngine(.right, practice: .tempo)
        engine.tempoScale = 1
        XCTAssertEqual(engine.handle(midi: 60, source: .touch), .ignored, "nothing counts before pressing play")
        engine.play()
        defer { engine.stopPlayback() }

        engine.advancePlayhead(to: 0.5) // C4 was due at 0 s; the 0.4 s window has passed
        XCTAssertEqual(engine.results[0], .missed)
        XCTAssertEqual(engine.missedCount, 1)
        XCTAssertEqual(engine.currentIndex, 1)

        engine.advancePlayhead(to: 0.95)
        XCTAssertEqual(engine.handle(midi: 62, source: .touch), .correct(completedStep: true))
        XCTAssertEqual(engine.results[1], .perfect)
    }

    func testTempoModePlaysTheOtherHand() {
        let engine = makeEngine(.right, practice: .tempo)
        engine.tempoScale = 0.5
        var played: [(Int, TimeInterval)] = []
        engine.onAccompaniment = { note, duration in played.append((note.midi, duration)) }
        engine.play()
        defer { engine.stopPlayback() }

        engine.advancePlayhead(to: 0.1)
        XCTAssertEqual(played.map(\.0), [48])
        XCTAssertEqual(played.first?.1 ?? 0, 2, accuracy: 1e-9, "1 s note at half speed lasts 2 s")
        engine.advancePlayhead(to: 4.1)
        XCTAssertEqual(played.map(\.0), [48, 43])
    }

    func testLoadingARightHandOnlySongFromLeftHandModeFallsBack() {
        let engine = LessonEngine()
        engine.handMode = .left
        var score = makeScore()
        score.notes.removeAll { $0.hand == .left }
        engine.load(score)
        XCTAssertEqual(engine.handMode, .right)
        XCTAssertEqual(engine.steps.count, 3)
    }

    func testPreviousAndSkip() {
        let engine = makeEngine(.right)
        engine.skipStep()
        XCTAssertEqual(engine.currentIndex, 1)
        engine.previousStep()
        XCTAssertEqual(engine.currentIndex, 0)
        engine.previousStep()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    // MARK: - Listen mode

    private struct Handed: Equatable {
        var midi: Int
        var on: Bool
        var at: TimeInterval
        var soft = false
    }

    /// A listen-mode engine on a fake clock, recording the notes it hands to the synth.
    private func makeListener(_ mode: LessonEngine.HandMode, speed: Double = 1, otherHand: Bool = false,
                              now: @escaping () -> TimeInterval) -> (LessonEngine, () -> [Handed], () -> Int) {
        let engine = makeEngine(mode, practice: .listen)
        engine.tempoScale = speed
        engine.listenWithOtherHand = otherHand
        engine.clock = now
        var handed: [Handed] = []
        var stops = 0
        engine.onDemoEvent = { event, time in
            handed.append(Handed(midi: event.midi, on: event.kind == .noteOn, at: (time * 1000).rounded() / 1000,
                                 soft: event.kind == .noteOn && event.velocity < DemoSchedule.velocity))
        }
        engine.onDemoStop = { stops += 1 }
        addTeardownBlock { engine.stopPlayback() }
        return (engine, { handed }, { stops })
    }

    func testListenPlaysFromTheCurrentStepAndFollowsAlong() {
        var now = 100.0
        let (engine, handed, stops) = makeListener(.right, speed: 0.5) { now }
        engine.skipStep()
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.demoOrigin, 1)
        // D4 is at 2 s at half speed, after a one-second lead-in.
        XCTAssertEqual(engine.playhead, 2 - engine.demoLeadIn, accuracy: 1e-9)
        XCTAssertEqual(handed(), [])

        now = 100.9
        engine.advancePlayhead(to: 1.9)
        XCTAssertEqual(handed(), [Handed(midi: 62, on: true, at: 101)], "handed over ahead of time, at its exact clock time")
        XCTAssertEqual(engine.soundingNotes, [])

        engine.advancePlayhead(to: 2.01)
        XCTAssertEqual(engine.soundingNotes.map(\.midi), [62])
        XCTAssertEqual(engine.soundingNotes.first?.finger, 2)
        XCTAssertEqual(engine.currentIndex, 1)

        engine.advancePlayhead(to: 4.01)
        XCTAssertEqual(engine.soundingNotes.map(\.midi), [64, 67])
        XCTAssertEqual(engine.currentIndex, 2)

        now = 105.5
        engine.advancePlayhead(to: 6.5)
        XCTAssertEqual(handed(), [Handed(midi: 62, on: true, at: 101), Handed(midi: 62, on: false, at: 103),
                                  Handed(midi: 64, on: true, at: 103), Handed(midi: 67, on: true, at: 103),
                                  Handed(midi: 64, on: false, at: 105), Handed(midi: 67, on: false, at: 105)])
        XCTAssertFalse(engine.isPlaying, "stops at the end of the song")
        XCTAssertEqual(engine.currentIndex, 1, "and goes back to where the demo started")
        XCTAssertNil(engine.demoOrigin)
        XCTAssertEqual(engine.soundingNotes, [])
        XCTAssertEqual(stops(), 1)
    }

    func testListenPlaysTheOtherHandSofterWithoutLightingIt() {
        var now = 100.0
        let (engine, handed, _) = makeListener(.right, otherHand: true) { now }
        engine.play()
        now = 101
        engine.advancePlayhead(to: 0)
        XCTAssertEqual(handed(), [Handed(midi: 48, on: true, at: 101, soft: true), Handed(midi: 60, on: true, at: 101)])
        XCTAssertEqual(engine.soundingNotes.map(\.midi), [60])
    }

    func testListenWithBothHandsLightsBoth() {
        var now = 100.0
        let (engine, handed, _) = makeListener(.both, otherHand: true) { now }
        engine.play()
        now = 101
        engine.advancePlayhead(to: 0)
        XCTAssertEqual(handed(), [Handed(midi: 48, on: true, at: 101), Handed(midi: 60, on: true, at: 101)])
        XCTAssertEqual(engine.soundingNotes.map(\.midi), [48, 60])
        XCTAssertEqual(engine.soundingNotes.map(\.hand), [.left, .right])
    }

    func testPausingAndResumingNeitherRepeatsNorSkipsNotes() {
        var now = 100.0
        let (engine, handed, stops) = makeListener(.right) { now }
        engine.play()
        now = 101.9
        engine.advancePlayhead(to: 0.9)
        XCTAssertEqual(handed(), [Handed(midi: 60, on: true, at: 101), Handed(midi: 60, on: false, at: 102),
                                  Handed(midi: 62, on: true, at: 102)])

        engine.togglePlayback()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(stops(), 1, "notes handed over but not yet started are dropped")
        XCTAssertEqual(engine.playhead, 0.9, accuracy: 1e-9)
        XCTAssertEqual(engine.demoOrigin, 0)
        XCTAssertEqual(engine.soundingNotes, [])

        now = 200
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(handed().dropFirst(3), [Handed(midi: 62, on: true, at: 200.1)], "carries on where it paused")
        XCTAssertEqual(handed().filter { $0.midi == 60 && $0.on }.count, 1)

        engine.stopDemo()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertNil(engine.demoOrigin)
    }

    func testStopGoesBackToWhereTheDemoStartedAndPlayStartsThereAgain() {
        var now = 100.0
        let (engine, handed, _) = makeListener(.right) { now }
        engine.skipStep()
        engine.play()
        now = 103.1
        engine.advancePlayhead(to: 2.1)
        XCTAssertEqual(engine.currentIndex, 2)
        engine.stopDemo()
        XCTAssertEqual(engine.currentIndex, 1)

        now = 300
        engine.play()
        XCTAssertEqual(engine.playhead, 1 - engine.demoLeadIn, accuracy: 1e-9)
        engine.advancePlayhead(to: 0.9)
        XCTAssertEqual(handed().last, Handed(midi: 62, on: true, at: 301))
    }

    func testListenIgnoresInput() {
        var now = 100.0
        let (engine, _, _) = makeListener(.right) { now }
        XCTAssertEqual(engine.handle(midi: 60, source: .touch), .ignored)
        engine.play()
        now = 101
        engine.advancePlayhead(to: 0)
        XCTAssertEqual(engine.handle(midi: 60, source: .microphone), .ignored)
        XCTAssertEqual(engine.handle(midi: 61, source: .touch), .ignored)
        engine.registerWrong(played: 61)
        XCTAssertFalse(engine.handleChroma([1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(engine.correctCount + engine.wrongCount + engine.missedCount, 0)
        XCTAssertNil(engine.feedback)
    }

    func testSwitchingModesKeepsThePlaceOfTheDemo() {
        var now = 100.0
        let (engine, _, _) = makeListener(.right) { now }
        engine.skipStep()
        engine.play()
        now = 103.1
        engine.advancePlayhead(to: 2.1)
        engine.practiceMode = .wait
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.currentIndex, 1, "practise the passage just heard")
        XCTAssertEqual(engine.handle(midi: 62, source: .touch), .correct(completedStep: true))

        engine.practiceMode = .listen
        XCTAssertEqual(engine.currentIndex, 2)
        engine.practiceMode = .tempo
        XCTAssertEqual(engine.currentIndex, 2)
        engine.practiceMode = .wait
        XCTAssertEqual(engine.currentIndex, 0, "wait and tempo still restart")
    }

    func testChangingSpeedKeepsTheDemoGoing() {
        var now = 100.0
        let (engine, handed, _) = makeListener(.right) { now }
        engine.play()
        now = 102.5
        engine.advancePlayhead(to: 1.5)
        XCTAssertEqual(engine.currentIndex, 1)

        engine.changeTempoScale(to: 0.5)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.tempoScale, 0.5)
        XCTAssertEqual(engine.playhead, 3, accuracy: 1e-9, "the same place in the music at half speed")
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertEqual(engine.demoOrigin, 0)

        now = 103.4
        engine.advancePlayhead(to: 3.9)
        XCTAssertEqual(handed().suffix(2), [Handed(midi: 64, on: true, at: 103.5), Handed(midi: 67, on: true, at: 103.5)])
    }

    func testSkippingDuringADemoCarriesOnFromTheNewStep() {
        var now = 100.0
        let (engine, handed, _) = makeListener(.right) { now }
        engine.play()
        engine.skipStep()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertEqual(engine.demoOrigin, 1)
        now = 101
        engine.advancePlayhead(to: 1)
        XCTAssertEqual(handed().last, Handed(midi: 62, on: true, at: 101))
    }
}

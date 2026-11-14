import XCTest
@testable import IndianPiano

final class DemoScheduleTests: XCTestCase {
    private func note(_ midi: Int, _ beat: Double, _ hand: Hand, length: Double = 1) -> ScoreNote {
        ScoreNote(id: 0, midi: midi, onsetBeats: beat, durationBeats: length, hand: hand)
    }

    /// Tempo 60, so beats equal seconds at full speed.
    private func notes(_ notes: [ScoreNote], bpm: Double = 60) -> [ScoreNote] {
        var score = Score(title: "Test", notes: notes, tempoMap: TempoMap([TempoChange(beat: 0, bpm: bpm)]), sourceFormat: "Test")
        score.finalize()
        return score.notes
    }

    /// RH: C4, D4, E4+G4 on beats 0, 1, 2. LH: C3 on beat 0, G2 on beat 2.
    private var song: [ScoreNote] {
        notes([note(60, 0, .right), note(62, 1, .right), note(64, 2, .right), note(67, 2, .right),
               note(48, 0, .left), note(43, 2, .left)])
    }

    private struct Timed: Equatable {
        var time: TimeInterval
        var on: Bool
        var midi: Int
    }

    private func timed(_ events: [DemoEvent]) -> [Timed] {
        events.map { Timed(time: ($0.time * 1000).rounded() / 1000, on: $0.kind == .noteOn, midi: $0.midi) }
    }

    func testPlaysThePractisedHandAtThePlaybackSpeed() {
        let events = DemoSchedule.events(notes: song, hands: [.right], accompaniment: false, tempoScale: 0.5)
        XCTAssertEqual(timed(events), [
            Timed(time: 0, on: true, midi: 60),
            Timed(time: 2, on: false, midi: 60), Timed(time: 2, on: true, midi: 62),
            Timed(time: 4, on: false, midi: 62), Timed(time: 4, on: true, midi: 64), Timed(time: 4, on: true, midi: 67),
            Timed(time: 6, on: false, midi: 64), Timed(time: 6, on: false, midi: 67),
        ])
        XCTAssertTrue(events.allSatisfy { !$0.isAccompaniment })
        XCTAssertTrue(events.filter { $0.kind == .noteOn }.allSatisfy { $0.velocity == DemoSchedule.velocity })
    }

    func testHandModes() {
        let left = DemoSchedule.events(notes: song, hands: [.left], accompaniment: false, tempoScale: 1)
        XCTAssertEqual(Set(left.map(\.midi)), [48, 43])

        let both = DemoSchedule.events(notes: song, hands: [.left, .right], accompaniment: false, tempoScale: 1)
        XCTAssertEqual(both.filter { $0.kind == .noteOn }.map(\.midi), [48, 60, 62, 43, 64, 67])
        XCTAssertTrue(both.allSatisfy { !$0.isAccompaniment })
    }

    func testTheOtherHandIsPlayedSofterAsAccompaniment() {
        let events = DemoSchedule.events(notes: song, hands: [.right], accompaniment: true, tempoScale: 1)
        let strikes = events.filter { $0.kind == .noteOn }
        XCTAssertEqual(strikes.map(\.midi), [48, 60, 62, 43, 64, 67])
        for strike in strikes {
            let isLeft = [48, 43].contains(strike.midi)
            XCTAssertEqual(strike.isAccompaniment, isLeft)
            XCTAssertEqual(strike.velocity, isLeft ? DemoSchedule.accompanimentVelocity : DemoSchedule.velocity)
        }
        XCTAssertLessThan(DemoSchedule.accompanimentVelocity, DemoSchedule.velocity)
    }

    func testStartsAtTheGivenTime() {
        let events = DemoSchedule.events(notes: song, hands: [.right], accompaniment: true, tempoScale: 0.5, from: 2)
        XCTAssertEqual(events.filter { $0.kind == .noteOn }.map(\.midi), [62, 43, 64, 67])
        XCTAssertEqual(events.first?.time ?? 0, 2, accuracy: 1e-9)
    }

    func testRepeatedKeysAreReleasedBeforeTheNextStrike() {
        // Legato repeats, an overlapping one, then two very quick ones.
        let repeated = notes([note(60, 0, .right), note(60, 1, .right, length: 1.5), note(60, 2, .right),
                              note(60, 3, .right, length: 0.25), note(60, 3.25, .right, length: 0.01)], bpm: 60)
        let events = DemoSchedule.events(notes: repeated, hands: [.right], accompaniment: false, tempoScale: 1)
        let offs = events.filter { $0.kind == .noteOff }.map(\.time)
        XCTAssertEqual(offs.count, 5)
        XCTAssertEqual(offs[0], 1 - DemoSchedule.repeatGap, accuracy: 1e-9)
        XCTAssertEqual(offs[1], 2 - DemoSchedule.repeatGap, accuracy: 1e-9, "an overlapping note is cut short")
        XCTAssertEqual(offs[3], 3.25 - DemoSchedule.repeatGap, accuracy: 1e-9)
        XCTAssertEqual(offs[4], 3.25 + DemoSchedule.minimumLength, accuracy: 1e-9, "very short notes still sound")

        let quick = notes([note(72, 0, .right, length: 0.1), note(72, 0.04, .right, length: 0.1)], bpm: 60)
        let quickOffs = DemoSchedule.events(notes: quick, hands: [.right], accompaniment: false, tempoScale: 1)
            .filter { $0.kind == .noteOff }.map(\.time)
        XCTAssertEqual(quickOffs.first ?? 0, 0.02, accuracy: 1e-9, "released halfway when repeats are closer than the gap")

        for (index, event) in events.enumerated() where event.kind == .noteOn && index > 0 {
            XCTAssertEqual(events[index - 1].kind, .noteOff, "each strike follows the previous release")
        }
    }

    func testUnisonBetweenHandsIsOneStrike() {
        let unison = notes([note(60, 0, .right), note(60, 0, .left, length: 2), note(64, 1, .right)])
        let events = DemoSchedule.events(notes: unison, hands: [.right], accompaniment: true, tempoScale: 1)
        let strikes = events.filter { $0.kind == .noteOn && $0.midi == 60 }
        XCTAssertEqual(strikes.count, 1)
        XCTAssertEqual(strikes.first?.isAccompaniment, false, "credited to the practised hand")
        XCTAssertEqual(events.filter { $0.kind == .noteOff && $0.midi == 60 }.count, 1)
    }
}

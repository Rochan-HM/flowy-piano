import XCTest
@testable import IndianPiano

final class BeatGridTests: XCTestCase {
    private func grid(_ beats: Int, _ beatType: Int, bpm: Double, pickup: Double = 0) -> BeatGrid {
        BeatGrid(timeSignature: TimeSignature(beats: beats, beatType: beatType),
                 tempoMap: TempoMap([TempoChange(beat: 0, bpm: bpm)]), pickupBeats: pickup)
    }

    private func times(_ beats: [BeatGrid.Beat]) -> [Double] { beats.map { ($0.time * 1000).rounded() / 1000 } }

    func testFourFourAccentsTheFirstBeatOfEachBar() {
        let beats = grid(4, 4, bpm: 120).beats(from: 0, to: 4, tempoScale: 1)
        XCTAssertEqual(times(beats), [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, false, false, true, false, false, false])
    }

    func testThreeFour() {
        let beats = grid(3, 4, bpm: 90).beats(from: 0, to: 4, tempoScale: 1)
        XCTAssertEqual(times(beats), [0, 0.667, 1.333, 2, 2.667, 3.333])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, false, true, false, false])
    }

    func testTempoScaleSlowsTheBeat() {
        let grid = grid(4, 4, bpm: 120)
        XCTAssertEqual(times(grid.beats(from: 0, to: 4, tempoScale: 0.5)), [0, 1, 2, 3])
        XCTAssertEqual(grid.interval(atQuarter: 0, tempoScale: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(grid.beatsPerMinute(atQuarter: 0, tempoScale: 0.7), 84, accuracy: 1e-9)
    }

    func testTheGridContinuesBeforeTheSongAsACountIn() {
        let beats = grid(4, 4, bpm: 60).beats(from: -4, to: 0.5, tempoScale: 1)
        XCTAssertEqual(times(beats), [-4, -3, -2, -1, 0])
        XCTAssertEqual(beats.map(\.index), [-4, -3, -2, -1, 0])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, false, false, true])
    }

    func testBarsAreCountedFromTheEndOfAPickup() {
        // 3/4 starting with one pickup beat: the first downbeat is the second note.
        let beats = grid(3, 4, bpm: 60, pickup: 1).beats(from: 0, to: 5, tempoScale: 1)
        XCTAssertEqual(times(beats), [0, 1, 2, 3, 4])
        XCTAssertEqual(beats.map(\.isDownbeat), [false, true, false, false, true])
    }

    func testTempoChangesMoveTheBeats() {
        let grid = BeatGrid(timeSignature: TimeSignature(beats: 4, beatType: 4),
                            tempoMap: TempoMap([TempoChange(beat: 0, bpm: 60), TempoChange(beat: 4, bpm: 120)]))
        let beats = grid.beats(from: 0, to: 6, tempoScale: 1)
        XCTAssertEqual(times(beats), [0, 1, 2, 3, 4, 4.5, 5, 5.5])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, false, false, true, false, false, false])
        XCTAssertEqual(grid.interval(atQuarter: 5, tempoScale: 1), 0.5, accuracy: 1e-9)
    }

    func testCompoundMetresCountDottedQuarters() {
        let beats = grid(6, 8, bpm: 60).beats(from: 0, to: 6, tempoScale: 1)
        XCTAssertEqual(times(beats), [0, 1.5, 3, 4.5])
        XCTAssertEqual(beats.map(\.isDownbeat), [true, false, true, false])
    }

    func testSteadyBeats() {
        let beats = BeatGrid.steadyBeats(interval: 0.5, beatsPerBar: 3, from: 0.4, to: 2.1)
        XCTAssertEqual(times(beats), [0.5, 1, 1.5, 2])
        XCTAssertEqual(beats.map(\.isDownbeat), [false, false, true, false])
    }
}

@MainActor
final class MetronomeTests: XCTestCase {
    private var now = 50.0
    private var clicks: [(click: Metronome.Click, handedAt: TimeInterval)] = []
    private var cancels = 0

    private func makeMetronome() -> Metronome {
        let metronome = Metronome()
        metronome.clock = { [unowned self] in now }
        metronome.grid = BeatGrid(timeSignature: TimeSignature(beats: 4, beatType: 4), tempoMap: TempoMap([TempoChange(beat: 0, bpm: 120)]))
        metronome.onClick = { [unowned self] click in clicks.append((click, now)) }
        metronome.onCancel = { [unowned self] in cancels += 1 }
        addTeardownBlock { metronome.setMode(.off) }
        return metronome
    }

    /// Advances the clock as the metronome's timer would, ticking 30 times a second.
    private func run(_ metronome: Metronome, until end: TimeInterval) {
        while now < end - 1e-9 {
            now = min(end, now + 1.0 / 30)
            metronome.tick()
        }
    }

    func testSyncedClicksFollowTheSongsBeatsIncludingTheCountIn() {
        let metronome = makeMetronome()
        metronome.setMode(.synced(songStart: 51, tempoScale: 1))
        run(metronome, until: 52.6)

        XCTAssertEqual(clicks.map(\.click.time), [50, 50.5, 51, 51.5, 52, 52.5])
        XCTAssertEqual(clicks.map(\.click.isDownbeat), [false, false, true, false, false, false])
        for (click, handedAt) in clicks {
            XCTAssertGreaterThanOrEqual(click.time, handedAt, "handed over before it sounds")
            XCTAssertLessThanOrEqual(click.time - handedAt, Metronome.lookahead + 1e-9)
        }
        XCTAssertEqual(metronome.beatCount, 6, "clicks up to 52.5 have sounded")
        XCTAssertEqual(cancels, 0)
    }

    func testTempoScaleStretchesSyncedClicks() {
        let metronome = makeMetronome()
        metronome.setMode(.synced(songStart: 50, tempoScale: 0.5))
        run(metronome, until: 53)
        XCTAssertEqual(clicks.map(\.click.time), [50, 51, 52, 53])
    }

    func testSteadyClicksAccentTheFirstBeatOfEachBar() {
        let metronome = makeMetronome()
        metronome.setMode(.steady(interval: 0.5, beatsPerBar: 3))
        run(metronome, until: 52)
        let start = clicks.first?.click.time ?? 0
        XCTAssertEqual(start, 50.05, accuracy: 1e-9)
        XCTAssertEqual(clicks.map { ($0.click.time - start) * 2 }.map { $0.rounded() }, [0, 1, 2, 3, 4])
        XCTAssertEqual(clicks.map(\.click.isDownbeat), [true, false, false, true, false])
    }

    func testChangingModeCancelsClicksNotYetSounded() {
        let metronome = makeMetronome()
        metronome.setMode(.steady(interval: 0.5, beatsPerBar: 4))
        run(metronome, until: 51)
        let before = clicks.count

        metronome.setMode(.steady(interval: 0.5, beatsPerBar: 4))
        XCTAssertEqual(cancels, 0, "setting the same mode changes nothing")
        XCTAssertEqual(clicks.count, before)

        metronome.setMode(.synced(songStart: 52, tempoScale: 1))
        XCTAssertEqual(cancels, 1)
        run(metronome, until: 52)
        XCTAssertEqual(clicks.dropFirst(before).map(\.click.time), [51, 51.5, 52])

        metronome.setMode(.off)
        XCTAssertEqual(cancels, 2)
        let count = clicks.count
        run(metronome, until: 54)
        XCTAssertEqual(clicks.count, count)
    }
}

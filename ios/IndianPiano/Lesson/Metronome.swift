import Foundation
import Observation
import QuartzCore

/// Where a score's beats fall: every pulse of the time signature, timed by the tempo map, with
/// the first beat of each bar (counted from the end of any pickup bar) as the downbeat.
struct BeatGrid {
    struct Beat: Equatable {
        /// Pulse number from the first downbeat; negative before it (pickup bar and count-in).
        var index: Int
        /// Seconds from the reference point (the start of the song) at the playback speed.
        var time: TimeInterval
        var isDownbeat: Bool
    }

    var tempoMap: TempoMap
    var beatsPerBar: Int
    /// Pulse length in quarter notes.
    var beatLength: Double
    /// Quarter-note position of the first downbeat.
    var firstDownbeat: Double

    init(timeSignature: TimeSignature, tempoMap: TempoMap, pickupBeats: Double = 0) {
        let pulse = timeSignature.pulse
        self.tempoMap = tempoMap
        beatsPerBar = pulse.perBar
        beatLength = pulse.length
        firstDownbeat = pickupBeats
    }

    init(score: Score) {
        self.init(timeSignature: score.timeSignature, tempoMap: score.tempoMap, pickupBeats: score.pickupBeats)
    }

    /// Beats with `from <= time < to`; negative times continue the grid before the music (a count-in).
    func beats(from: TimeInterval, to: TimeInterval, tempoScale: Double) -> [Beat] {
        guard to > from, tempoScale > 0, beatLength > 0 else { return [] }
        let firstQuarter = tempoMap.beat(atSeconds: from * tempoScale)
        var index = Int(((firstQuarter - firstDownbeat) / beatLength).rounded(.down)) - 1
        var beats: [Beat] = []
        while true {
            let time = tempoMap.seconds(atBeat: firstDownbeat + Double(index) * beatLength) / tempoScale
            if time >= to { break }
            if time >= from { beats.append(Beat(index: index, time: time, isDownbeat: Self.isDownbeat(index, beatsPerBar))) }
            index += 1
        }
        return beats
    }

    /// Seconds per beat at a quarter-note position, at the playback speed.
    func interval(atQuarter position: Double, tempoScale: Double) -> TimeInterval {
        60 / tempoMap.bpm(atBeat: position) * beatLength / max(tempoScale, 0.05)
    }

    func beatsPerMinute(atQuarter position: Double, tempoScale: Double) -> Double {
        60 / interval(atQuarter: position, tempoScale: tempoScale)
    }

    /// A steady pulse starting at time 0 with a downbeat: the beats with `from <= time < to`.
    static func steadyBeats(interval: TimeInterval, beatsPerBar: Int, from: TimeInterval, to: TimeInterval) -> [Beat] {
        guard interval > 0, to > from else { return [] }
        var index = max(0, Int((from / interval).rounded(.down)))
        var beats: [Beat] = []
        while Double(index) * interval < to {
            let time = Double(index) * interval
            if time >= from { beats.append(Beat(index: index, time: time, isDownbeat: isDownbeat(index, beatsPerBar))) }
            index += 1
        }
        return beats
    }

    static func isDownbeat(_ index: Int, _ beatsPerBar: Int) -> Bool {
        let bar = max(1, beatsPerBar)
        return (index % bar + bar) % bar == 0
    }
}

/// Hands metronome clicks to the synth a little ahead of time, so each one lands on its exact sample.
@MainActor
@Observable
final class Metronome {
    enum Mode: Equatable {
        case off
        /// On the score's beats; `songStart` is the clock time of the start of the song.
        case synced(songStart: TimeInterval, tempoScale: Double)
        /// A steady pulse, starting when the mode is set.
        case steady(interval: TimeInterval, beatsPerBar: Int)
    }

    struct Click: Equatable {
        var time: TimeInterval
        var isDownbeat: Bool
    }

    static let lookahead: TimeInterval = 0.2

    private(set) var mode: Mode = .off
    /// Counts the clicks as they sound, for a visual beat.
    private(set) var beatCount = 0
    private(set) var lastBeatWasDownbeat = false

    @ObservationIgnored var grid: BeatGrid?
    @ObservationIgnored var clock: () -> TimeInterval = { CACurrentMediaTime() }
    /// Called up to `lookahead` seconds before each click with its clock time.
    @ObservationIgnored var onClick: ((Click) -> Void)?
    /// Drops clicks handed to `onClick` that haven't sounded yet.
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private var steadyStart: TimeInterval = 0
    @ObservationIgnored private var scheduledUntil: TimeInterval = 0
    @ObservationIgnored private var upcoming: [Click] = []
    @ObservationIgnored private var timer: Timer?

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if mode != .off { onCancel?() }
        mode = newMode
        upcoming = []
        timer?.invalidate()
        timer = nil
        let now = clock()
        scheduledUntil = now
        steadyStart = now + 0.05
        guard newMode != .off else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func tick() {
        let now = clock()
        while let next = upcoming.first, next.time <= now {
            upcoming.removeFirst()
            beatCount += 1
            lastBeatWasDownbeat = next.isDownbeat
        }
        let horizon = now + Self.lookahead
        guard horizon > scheduledUntil else { return }
        for click in clicks(from: scheduledUntil, to: horizon) {
            onClick?(click)
            upcoming.append(click)
        }
        scheduledUntil = horizon
    }

    /// The current mode's clicks with `from <= time < to` (clock times).
    func clicks(from: TimeInterval, to: TimeInterval) -> [Click] {
        switch mode {
        case .off:
            return []
        case let .synced(songStart, tempoScale):
            guard let grid else { return [] }
            return grid.beats(from: from - songStart, to: to - songStart, tempoScale: tempoScale)
                .map { Click(time: songStart + $0.time, isDownbeat: $0.isDownbeat) }
        case let .steady(interval, beatsPerBar):
            return BeatGrid.steadyBeats(interval: interval, beatsPerBar: beatsPerBar, from: from - steadyStart, to: to - steadyStart)
                .map { Click(time: steadyStart + $0.time, isDownbeat: $0.isDownbeat) }
        }
    }
}

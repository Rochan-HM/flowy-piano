import Foundation

/// A note starting or ending while the app plays the song to the learner (Listen mode).
struct DemoEvent: Equatable {
    enum Kind: Equatable { case noteOn, noteOff }

    /// Seconds from the start of the song at the playback speed.
    var time: TimeInterval
    var kind: Kind
    var midi: Int
    var velocity: Float
    var noteID: Int
    /// A note of the hand that isn't being practised, played softer.
    var isAccompaniment: Bool
}

enum DemoSchedule {
    static let velocity: Float = 0.75
    static let accompanimentVelocity: Float = 0.45
    static let minimumLength: TimeInterval = 0.06
    /// Silence left before a key is struck again, so the repeat is heard.
    static let repeatGap: TimeInterval = 0.03
    /// Notes on the same key closer than this (score seconds) are one strike, e.g. both hands in unison.
    static let unisonTolerance: TimeInterval = 0.035

    /// Note on/off events for the notes starting at or after `start` (seconds at playback speed):
    /// the practised hands, plus the other hand softer when `accompaniment` is set. Events are
    /// sorted by time, with note-offs before note-ons at the same time.
    static func events(notes: [ScoreNote], hands: Set<Hand>, accompaniment: Bool, tempoScale: Double,
                       from start: TimeInterval = 0) -> [DemoEvent] {
        let scale = max(tempoScale, 0.05)
        let selected = notes.filter { (hands.contains($0.hand) || accompaniment) && $0.onsetSeconds / scale >= start - 1e-9 }
        var events: [DemoEvent] = []
        for (midi, sameKey) in Dictionary(grouping: selected, by: \.midi) {
            let ordered = sameKey.sorted {
                $0.onsetSeconds != $1.onsetSeconds ? $0.onsetSeconds < $1.onsetSeconds : hands.contains($0.hand) && !hands.contains($1.hand)
            }
            var strikes: [ScoreNote] = []
            for note in ordered where strikes.last.map({ note.onsetSeconds - $0.onsetSeconds >= unisonTolerance }) ?? true {
                strikes.append(note)
            }
            for (index, note) in strikes.enumerated() {
                let on = note.onsetSeconds / scale
                var off = on + max(note.durationSeconds / scale, minimumLength)
                if index + 1 < strikes.count {
                    let next = strikes[index + 1].onsetSeconds / scale
                    off = min(off, next - min(repeatGap, (next - on) / 2))
                }
                let isAccompaniment = !hands.contains(note.hand)
                let velocity = isAccompaniment ? accompanimentVelocity : Self.velocity
                events.append(DemoEvent(time: on, kind: .noteOn, midi: midi, velocity: velocity, noteID: note.id, isAccompaniment: isAccompaniment))
                events.append(DemoEvent(time: off, kind: .noteOff, midi: midi, velocity: 0, noteID: note.id, isAccompaniment: isAccompaniment))
            }
        }
        return events.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.kind != $1.kind { return $0.kind == .noteOff }
            return $0.midi < $1.midi
        }
    }
}

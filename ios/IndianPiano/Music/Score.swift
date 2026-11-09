import Foundation

enum Hand: String, Codable, CaseIterable, Sendable {
    case right
    case left
}

struct ScoreNote: Identifiable, Hashable, Sendable {
    var id: Int
    var midi: Int
    /// Onset and duration in quarter-note beats from the start of the piece.
    var onsetBeats: Double
    var durationBeats: Double
    /// Onset and duration in seconds at the written tempo.
    var onsetSeconds: Double = 0
    var durationSeconds: Double = 0
    var hand: Hand
    /// Piano fingering 1 (thumb) ... 5 (little finger), if the score provides it.
    var finger: Int?
    var spelling: NoteSpelling?
    var staff: Int = 1
    var voice: Int = 1
    var measure: Int = 1
    var partID: String = "P1"
}

struct TempoChange: Hashable, Sendable {
    var beat: Double
    /// Quarter notes per minute.
    var bpm: Double
}

/// Converts quarter-note beats to seconds using a piecewise-constant tempo map.
struct TempoMap: Sendable {
    private(set) var changes: [TempoChange]

    init(_ changes: [TempoChange], defaultBPM: Double = 100) {
        var sorted = changes.filter { $0.bpm > 0 }.sorted { $0.beat < $1.beat }
        if sorted.first.map({ $0.beat > 0 }) ?? true {
            sorted.insert(TempoChange(beat: 0, bpm: sorted.first?.bpm ?? defaultBPM), at: 0)
        }
        var deduped: [TempoChange] = []
        for change in sorted {
            if let last = deduped.last, abs(last.beat - change.beat) < 1e-9 {
                deduped[deduped.count - 1] = change
            } else {
                deduped.append(change)
            }
        }
        self.changes = deduped
    }

    func seconds(atBeat beat: Double) -> Double {
        var seconds = 0.0
        for (index, change) in changes.enumerated() {
            let end = index + 1 < changes.count ? changes[index + 1].beat : .infinity
            if beat <= change.beat { break }
            let span = min(beat, end) - change.beat
            seconds += span * 60 / change.bpm
            if beat <= end { break }
        }
        return seconds
    }

    var initialBPM: Double { changes.first?.bpm ?? 100 }
}

struct Score: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var composer: String?
    /// All notes sorted by onset, then pitch.
    var notes: [ScoreNote]
    var tempoMap: TempoMap
    var timeSignature = TimeSignature(beats: 4, beatType: 4)
    var keyFifths: Int?
    /// Human-readable source format, e.g. "MusicXML" or "MIDI".
    var sourceFormat: String

    var hands: Set<Hand> { Set(notes.map(\.hand)) }
    var hasFingerings: Bool { notes.contains { $0.finger != nil } }
    var durationSeconds: Double { notes.map { $0.onsetSeconds + $0.durationSeconds }.max() ?? 0 }
    var initialBPM: Double { tempoMap.initialBPM }

    /// Sorts notes, assigns stable ids and fills in seconds from the tempo map.
    mutating func finalize() {
        notes.sort {
            if abs($0.onsetBeats - $1.onsetBeats) > 1e-9 { return $0.onsetBeats < $1.onsetBeats }
            return $0.midi < $1.midi
        }
        for index in notes.indices {
            notes[index].id = index
            let start = tempoMap.seconds(atBeat: notes[index].onsetBeats)
            let end = tempoMap.seconds(atBeat: notes[index].onsetBeats + notes[index].durationBeats)
            notes[index].onsetSeconds = start
            notes[index].durationSeconds = end - start
        }
    }
}

struct TimeSignature: Hashable, Sendable {
    var beats: Int
    var beatType: Int
}

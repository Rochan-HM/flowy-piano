import Foundation

/// Helpers for MIDI note numbers (60 = middle C = C4).
enum MIDINote {
    static let pianoRange: ClosedRange<Int> = 21...108

    static func pitchClass(_ midi: Int) -> Int { ((midi % 12) + 12) % 12 }

    /// Scientific-pitch octave (C4 = 60).
    static func octave(_ midi: Int) -> Int { Int((Double(midi) / 12).rounded(.down)) - 1 }

    static func isBlack(_ midi: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitchClass(midi)) }

    static func frequency(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    static func midi(forFrequency hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Name used for a pitch class when the user picks a key (e.g. the movable Sa).
    static let keyNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
}

/// How a note is written in a score: letter + accidental + octave.
struct NoteSpelling: Hashable, Codable, Sendable {
    enum Letter: Int, CaseIterable, Codable, Sendable {
        case c, d, e, f, g, a, b

        var semitone: Int { [0, 2, 4, 5, 7, 9, 11][rawValue] }
        var name: String { ["C", "D", "E", "F", "G", "A", "B"][rawValue] }

        init?(name: String) {
            guard let index = ["C", "D", "E", "F", "G", "A", "B"].firstIndex(of: name.uppercased()) else { return nil }
            self.init(rawValue: index)
        }
    }

    var letter: Letter
    var alter: Int
    var octave: Int

    var midi: Int { (octave + 1) * 12 + letter.semitone + alter }

    var accidentalSymbol: String {
        switch alter {
        case ..<(-1): return "𝄫"
        case -1: return "♭"
        case 1: return "♯"
        case 2...: return "𝄪"
        default: return ""
        }
    }
}

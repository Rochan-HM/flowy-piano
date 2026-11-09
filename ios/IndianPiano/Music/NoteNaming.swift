import Foundation

/// A display name for one note, in whichever notation system is active.
struct NoteLabel: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        /// Hindustani komal (flattened) swara, drawn with an underline.
        case komal
        /// Hindustani tivra (sharpened) Ma, drawn with a vertical stroke above.
        case tivra
    }

    /// Base syllable or letter, e.g. "Ri", "C♯", "Dha".
    var name: String
    /// Carnatic variant number (Ri1, Ri2, ...). Nil when the swara has a single form.
    var variant: Int?
    var mark: Mark?
    /// Sargam register relative to madhya sthayi: +1 = tara (dot above), -1 = mandra (dot below).
    var octaveShift: Int = 0
    /// Western octave number (C4 = middle C). Nil for sargam labels.
    var westernOctave: Int?

    /// Compact text without octave information, e.g. "Ri2", "C♯", "Dha".
    var text: String { name + (variant.map(String.init) ?? "") }

    /// Plain-text form that keeps all information (useful for accessibility and tests).
    var fullText: String {
        var result = text
        switch mark {
        case .komal?: result = "komal " + result
        case .tivra?: result = "tivra " + result
        case nil: break
        }
        if let westernOctave { result += String(westernOctave) }
        if octaveShift > 0 { result += String(repeating: "'", count: octaveShift) }
        if octaveShift < 0 { result += String(repeating: ",", count: -octaveShift) }
        return result
    }
}

/// A way of naming the 12 semitones. Add a new system by conforming to this protocol
/// and adding a case to `NotationSystem`.
protocol NoteNamingScheme: Sendable {
    var system: NotationSystem { get }
    /// - Parameters:
    ///   - midi: the sounding pitch.
    ///   - spelling: how the score writes the note, if known. Lets schemes choose between
    ///     enharmonic names (e.g. Carnatic Ri3 vs Ga2).
    func label(forMIDI midi: Int, spelling: NoteSpelling?) -> NoteLabel
}

extension NoteNamingScheme {
    func label(forMIDI midi: Int) -> NoteLabel { label(forMIDI: midi, spelling: nil) }
}

enum NotationSystem: String, CaseIterable, Identifiable, Codable, Sendable {
    case western
    case carnatic
    case hindustani

    var id: String { rawValue }

    var title: String {
        switch self {
        case .western: return "Western"
        case .carnatic: return "Carnatic"
        case .hindustani: return "Hindustani"
        }
    }

    var sample: String {
        switch self {
        case .western: return "C D E"
        case .carnatic: return "Sa Ri Ga"
        case .hindustani: return "Sa Re Ga"
        }
    }

    var isSargam: Bool { self != .western }

    func makeScheme(saPitchClass: Int) -> NoteNamingScheme {
        switch self {
        case .western: return WesternNaming()
        case .carnatic: return CarnaticNaming(saPitchClass: saPitchClass)
        case .hindustani: return HindustaniNaming(saPitchClass: saPitchClass)
        }
    }
}

// MARK: - Western

struct WesternNaming: NoteNamingScheme {
    var preferFlats = false
    var system: NotationSystem { .western }

    func label(forMIDI midi: Int, spelling: NoteSpelling?) -> NoteLabel {
        if let spelling, spelling.midi == midi {
            return NoteLabel(name: spelling.letter.name + spelling.accidentalSymbol, westernOctave: spelling.octave)
        }
        let pc = MIDINote.pitchClass(midi)
        let name = preferFlats ? MIDINote.flatNames[pc] : MIDINote.sharpNames[pc]
        return NoteLabel(name: name, westernOctave: MIDINote.octave(midi))
    }
}

// MARK: - Sargam shared logic

/// Movable-Sa helpers shared by the Indian schemes.
enum Sargam {
    /// MIDI number of the madhya-sthayi Sa: the Sa closest to middle C (G3...F♯4).
    static func middleSa(saPitchClass: Int) -> Int {
        let pc = MIDINote.pitchClass(saPitchClass)
        return pc <= 6 ? 60 + pc : 48 + pc
    }

    /// Semitones above Sa (0...11) and the register (sthayi) offset of a pitch.
    static func degree(of midi: Int, saPitchClass: Int) -> (semitone: Int, octaveShift: Int) {
        let sa = middleSa(saPitchClass: saPitchClass)
        let distance = midi - sa
        let shift = Int((Double(distance) / 12).rounded(.down))
        return (distance - shift * 12, shift)
    }

    /// The written letter that Sa is spelled with for each pitch class. Black-key tonics use
    /// the spelling most common for that key (C♯, E♭, F♯, A♭, B♭).
    static let saLetter: [NoteSpelling.Letter] = [.c, .c, .d, .e, .e, .f, .f, .g, .a, .a, .b, .b]
}

// MARK: - Carnatic

/// Carnatic swara names with variant numbers:
/// Sa, Ri1, Ri2, Ga2, Ga3, Ma1, Ma2, Pa, Da1, Da2, Ni2, Ni3 by default. The enharmonic
/// alternatives Ga1 (= Ri2), Ri3 (= Ga2), Ni1 (= Da2) and Da3 (= Ni2) are used when the
/// score spells the note that way (e.g. D♯ with Sa = C reads as Ri3, E♭ as Ga2).
struct CarnaticNaming: NoteNamingScheme {
    var saPitchClass: Int
    var system: NotationSystem { .carnatic }

    static let defaultNames: [(String, Int?)] = [
        ("Sa", nil), ("Ri", 1), ("Ri", 2), ("Ga", 2), ("Ga", 3), ("Ma", 1),
        ("Ma", 2), ("Pa", nil), ("Da", 1), ("Da", 2), ("Ni", 2), ("Ni", 3),
    ]

    /// For each of the seven swaras (in letter order Sa..Ni): semitone above Sa -> variant number.
    static let families: [(name: String, variants: [Int: Int?])] = [
        ("Sa", [0: nil]),
        ("Ri", [1: 1, 2: 2, 3: 3]),
        ("Ga", [2: 1, 3: 2, 4: 3]),
        ("Ma", [5: 1, 6: 2]),
        ("Pa", [7: nil]),
        ("Da", [8: 1, 9: 2, 10: 3]),
        ("Ni", [9: 1, 10: 2, 11: 3]),
    ]

    func label(forMIDI midi: Int, spelling: NoteSpelling?) -> NoteLabel {
        let (semitone, shift) = Sargam.degree(of: midi, saPitchClass: saPitchClass)
        var (name, variant) = Self.defaultNames[semitone]

        if let spelling, spelling.midi == midi {
            let saLetter = Sargam.saLetter[MIDINote.pitchClass(saPitchClass)]
            let swara = (spelling.letter.rawValue - saLetter.rawValue + 7) % 7
            let family = Self.families[swara]
            if let spelledVariant = family.variants[semitone] {
                name = family.name
                variant = spelledVariant
            }
        }
        return NoteLabel(name: name, variant: variant, octaveShift: shift)
    }
}

// MARK: - Hindustani

/// Hindustani (Bhatkhande-style) names: komal Re/Ga/Dha/Ni and tivra Ma.
struct HindustaniNaming: NoteNamingScheme {
    var saPitchClass: Int
    var system: NotationSystem { .hindustani }

    static let names: [(String, NoteLabel.Mark?)] = [
        ("Sa", nil), ("Re", .komal), ("Re", nil), ("Ga", .komal), ("Ga", nil), ("Ma", nil),
        ("Ma", .tivra), ("Pa", nil), ("Dha", .komal), ("Dha", nil), ("Ni", .komal), ("Ni", nil),
    ]

    func label(forMIDI midi: Int, spelling: NoteSpelling?) -> NoteLabel {
        let (semitone, shift) = Sargam.degree(of: midi, saPitchClass: saPitchClass)
        let (name, mark) = Self.names[semitone]
        return NoteLabel(name: name, mark: mark, octaveShift: shift)
    }
}

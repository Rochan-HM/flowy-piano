import CoreGraphics

/// Geometry of the on-screen keyboard: which keys are visible, where they are, and hit testing.
struct KeyboardLayout: Equatable {
    var lowestWhite: Int
    var whiteCount: Int
    var size: CGSize

    static let whiteSemitones = [0, 2, 4, 5, 7, 9, 11]
    /// For each pitch class, the index (0...6) of the white key at or just below it.
    static let whiteStep = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    /// Real pianos offset black keys slightly within their gap.
    static let blackOffset: [Int: CGFloat] = [1: -0.12, 3: 0.12, 6: -0.14, 8: 0, 10: 0.14]

    static let lowestPianoWhite = whiteIndex(of: MIDINote.pianoRange.lowerBound)
    static let highestPianoWhite = whiteIndex(of: MIDINote.pianoRange.upperBound)

    static func whiteIndex(of midi: Int) -> Int {
        let octave = Int((Double(midi) / 12).rounded(.down))
        return octave * 7 + whiteStep[MIDINote.pitchClass(midi)]
    }

    static func midi(forWhiteIndex index: Int) -> Int {
        let octave = Int((Double(index) / 7).rounded(.down))
        let step = ((index % 7) + 7) % 7
        return octave * 12 + whiteSemitones[step]
    }

    var whiteWidth: CGFloat { size.width / CGFloat(max(whiteCount, 1)) }
    var blackWidth: CGFloat { whiteWidth * 0.62 }
    var blackHeight: CGFloat { size.height * 0.6 }

    var visibleRange: ClosedRange<Int> {
        Self.midi(forWhiteIndex: lowestWhite)...Self.midi(forWhiteIndex: lowestWhite + whiteCount - 1)
    }

    /// Keys to draw, including a margin off-screen so scrolling animates smoothly.
    func renderedKeys(margin: Int) -> [Int] {
        let low = max(MIDINote.pianoRange.lowerBound, Self.midi(forWhiteIndex: lowestWhite - margin))
        let high = min(MIDINote.pianoRange.upperBound, Self.midi(forWhiteIndex: lowestWhite + whiteCount - 1 + margin) + 1)
        return low <= high ? Array(low...high) : []
    }

    func frame(for midi: Int) -> CGRect {
        let column = CGFloat(Self.whiteIndex(of: midi) - lowestWhite)
        if !MIDINote.isBlack(midi) {
            return CGRect(x: column * whiteWidth, y: 0, width: whiteWidth, height: size.height)
        }
        let boundary = (column + 1) * whiteWidth
        let x = boundary - blackWidth / 2 + (Self.blackOffset[MIDINote.pitchClass(midi)] ?? 0) * blackWidth
        return CGRect(x: x, y: 0, width: blackWidth, height: blackHeight)
    }

    func key(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.x < size.width, point.y >= 0, point.y <= size.height else { return nil }
        let column = Int(point.x / whiteWidth) + lowestWhite
        if point.y <= blackHeight {
            for whiteColumn in [column - 1, column] {
                let black = Self.midi(forWhiteIndex: whiteColumn) + 1
                if MIDINote.isBlack(black), MIDINote.pianoRange.contains(black), frame(for: black).contains(point) {
                    return black
                }
            }
        }
        let white = Self.midi(forWhiteIndex: column)
        return MIDINote.pianoRange.contains(white) ? white : nil
    }
}

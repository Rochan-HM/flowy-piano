import Foundation
import UniformTypeIdentifiers

struct MIDIImporter: ScoreImporter {
    var name: String { "MIDI" }
    var contentTypes: [UTType] { [.midi] }
    var fileExtensions: Set<String> { ["mid", "midi", "smf", "kar"] }

    func importScore(from input: ScoreImportInput) async throws -> Score {
        try MIDIFileParser.parse(try input.readData(), fallbackTitle: input.displayName)
    }
}

/// Standard MIDI File (format 0 and 1) parser.
///
/// Hands: when the notes are spread over several tracks/channels, track names win
/// ("left", "LH", "bass" ...); otherwise the group with the higher average pitch is the right
/// hand. A single track/channel is split at middle C. Channel 10 (drums) is ignored.
enum MIDIFileParser {
    struct RawNote: Equatable {
        var track: Int
        var channel: Int
        var key: Int
        var velocity: Int
        var startTick: Int
        var endTick: Int
    }

    private struct GroupKey: Hashable {
        var track: Int
        var channel: Int
    }

    static func parse(_ data: Data, fallbackTitle: String = "Untitled") throws -> Score {
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.ascii(4) == "MThd" else { throw ScoreImportError.invalidFormat("missing MIDI header") }
        let headerLength = Int(reader.u32())
        let headerStart = reader.offset
        _ = reader.u16() // format
        _ = reader.u16() // declared track count
        let division = reader.u16()
        reader.offset = headerStart + headerLength

        let isSMPTE = division & 0x8000 != 0
        let ticksPerQuarter: Double
        if isSMPTE {
            let framesPerSecond = Double(256 - Int(division >> 8))
            let ticksPerFrame = Double(division & 0xFF)
            ticksPerQuarter = framesPerSecond * ticksPerFrame / 2 // treat as 120 bpm
        } else {
            ticksPerQuarter = Double(max(division, 1))
        }

        var notes: [RawNote] = []
        var tempoEvents: [(tick: Int, microsecondsPerQuarter: Int)] = []
        var trackNames: [Int: String] = [:]
        var timeSignature: TimeSignature?
        var trackIndex = 0

        while reader.remaining >= 8 {
            let chunkID = reader.ascii(4)
            let length = min(Int(reader.u32()), reader.remaining)
            let end = reader.offset + length
            if chunkID == "MTrk" {
                try parseTrack(&reader, end: end, track: trackIndex, notes: &notes, tempos: &tempoEvents,
                               names: &trackNames, timeSignature: &timeSignature)
                trackIndex += 1
            }
            reader.offset = end
        }

        let pitched = notes.filter { $0.channel != 9 }
        let usable = pitched.isEmpty ? notes : pitched
        guard !usable.isEmpty else { throw ScoreImportError.noNotes }

        let hands = assignHands(usable, trackNames: trackNames)
        let tempos = isSMPTE ? [] : tempoEvents.map {
            TempoChange(beat: Double($0.tick) / ticksPerQuarter, bpm: 60_000_000 / Double(max($0.microsecondsPerQuarter, 1)))
        }
        let signature = timeSignature ?? TimeSignature(beats: 4, beatType: 4)
        let beatsPerMeasure = Double(signature.beats) * 4 / Double(signature.beatType)

        let scoreNotes = zip(usable, hands).map { raw, hand in
            let onset = Double(raw.startTick) / ticksPerQuarter
            return ScoreNote(
                id: 0,
                midi: raw.key,
                onsetBeats: onset,
                durationBeats: max(Double(raw.endTick - raw.startTick) / ticksPerQuarter, 1.0 / 32),
                hand: hand,
                finger: nil,
                spelling: nil,
                staff: hand == .right ? 1 : 2,
                voice: raw.channel + 1,
                measure: Int(onset / beatsPerMeasure) + 1,
                partID: "T\(raw.track)"
            )
        }

        let title = trackNames.keys.sorted().compactMap { trackNames[$0] }.first { !$0.isEmpty } ?? fallbackTitle
        var score = Score(
            title: title,
            composer: nil,
            notes: scoreNotes,
            tempoMap: TempoMap(tempos, defaultBPM: 120),
            timeSignature: signature,
            keyFifths: nil,
            sourceFormat: "MIDI"
        )
        score.finalize()
        return score
    }

    private static func parseTrack(_ reader: inout ByteReader, end: Int, track: Int, notes: inout [RawNote],
                                   tempos: inout [(tick: Int, microsecondsPerQuarter: Int)],
                                   names: inout [Int: String], timeSignature: inout TimeSignature?) throws {
        var tick = 0
        var runningStatus: UInt8 = 0
        var open: [Int: [(tick: Int, velocity: Int)]] = [:]

        func close(channel: Int, key: Int, at endTick: Int) {
            let slot = channel * 128 + key
            guard var pending = open[slot], !pending.isEmpty else { return }
            let start = pending.removeFirst()
            open[slot] = pending
            notes.append(RawNote(track: track, channel: channel, key: key, velocity: start.velocity, startTick: start.tick, endTick: endTick))
        }

        trackLoop: while reader.offset < end {
            tick += reader.vlq()
            guard reader.offset < end else { break }
            var status = reader.peek()
            if status < 0x80 {
                guard runningStatus != 0 else { throw ScoreImportError.invalidFormat("running status without a prior status byte") }
                status = runningStatus
            } else {
                reader.offset += 1
            }

            switch status {
            case 0xFF:
                runningStatus = 0
                let type = reader.u8()
                let length = reader.vlq()
                let payload = reader.take(length)
                switch type {
                case 0x51 where payload.count == 3:
                    let value = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                    tempos.append((tick, value))
                case 0x03:
                    if names[track] == nil {
                        names[track] = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case 0x58 where payload.count >= 2:
                    if timeSignature == nil {
                        timeSignature = TimeSignature(beats: Int(payload[0]), beatType: 1 << Int(payload[1]))
                    }
                case 0x2F:
                    break trackLoop
                default:
                    break
                }
            case 0xF0, 0xF7:
                runningStatus = 0
                reader.offset += reader.vlq()
            case 0x80..<0xF0:
                runningStatus = status
                let kind = status & 0xF0
                let channel = Int(status & 0x0F)
                let first = Int(reader.u8())
                let second = (kind == 0xC0 || kind == 0xD0) ? 0 : Int(reader.u8())
                if kind == 0x90 && second > 0 {
                    open[channel * 128 + first, default: []].append((tick, second))
                } else if kind == 0x80 || kind == 0x90 {
                    close(channel: channel, key: first, at: tick)
                }
            default:
                break trackLoop
            }
        }

        for (slot, pending) in open {
            for _ in pending { close(channel: slot / 128, key: slot % 128, at: tick) }
        }
    }

    private static func assignHands(_ notes: [RawNote], trackNames: [Int: String]) -> [Hand] {
        let groups = Dictionary(grouping: notes.indices) { GroupKey(track: notes[$0].track, channel: notes[$0].channel) }
        if groups.count <= 1 {
            return notes.map { $0.key < 60 ? .left : .right }
        }

        func hint(_ key: GroupKey) -> Hand? {
            let name = (trackNames[key.track] ?? "").lowercased()
            if ["left", "l.h", "lh", "bass"].contains(where: name.contains) { return .left }
            if ["right", "r.h", "rh", "treble", "melody"].contains(where: name.contains) { return .right }
            return nil
        }

        let averages = groups.mapValues { indices in Double(indices.map { notes[$0].key }.reduce(0, +)) / Double(indices.count) }
        let highest = averages.values.max() ?? 60
        let lowest = averages.values.min() ?? 60
        let split = (highest + lowest) / 2

        var groupHands: [GroupKey: Hand] = [:]
        for key in groups.keys { groupHands[key] = hint(key) ?? ((averages[key] ?? 60) >= split ? .right : .left) }
        if Set(groupHands.values).count == 1 {
            for key in groups.keys { groupHands[key] = (averages[key] ?? 60) >= split ? .right : .left }
        }

        return notes.map { groupHands[GroupKey(track: $0.track, channel: $0.channel)] ?? .right }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    var remaining: Int { max(0, bytes.count - offset) }

    func peek() -> UInt8 { offset < bytes.count ? bytes[offset] : 0 }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return peek()
    }

    mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }

    mutating func u32() -> UInt32 { UInt32(u16()) << 16 | UInt32(u16()) }

    mutating func ascii(_ count: Int) -> String { String(decoding: take(count), as: UTF8.self) }

    mutating func take(_ count: Int) -> [UInt8] {
        let end = min(bytes.count, offset + max(count, 0))
        defer { offset = end }
        return offset < end ? Array(bytes[offset..<end]) : []
    }

    /// MIDI variable-length quantity.
    mutating func vlq() -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = u8()
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { break }
        }
        return value
    }
}

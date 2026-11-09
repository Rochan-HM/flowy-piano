import AudioToolbox
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

/// Standard MIDI File import on top of AudioToolbox's `MusicSequence`, which parses the file,
/// pairs note-on/off messages and expresses all timing in quarter-note beats.
///
/// Hands: when the notes are spread over several tracks/channels, track names win
/// ("left", "LH", "bass" ...); otherwise the group with the higher average pitch is the right
/// hand. A single track/channel is split at middle C. Channel 10 (drums) is ignored.
enum MIDIFileParser {
    struct RawNote: Equatable {
        var track: Int
        var channel: Int
        var key: Int
        var beat: Double
        var duration: Double
    }

    private struct GroupKey: Hashable {
        var track: Int
        var channel: Int
    }

    /// Track index used for notes that `MusicSequence` keeps in its tempo (conductor) track.
    private static let tempoTrackIndex = -1

    static func parse(_ data: Data, fallbackTitle: String = "Untitled") throws -> Score {
        var sequenceRef: MusicSequence?
        guard NewMusicSequence(&sequenceRef) == noErr, let sequence = sequenceRef else {
            throw ScoreImportError.unreadable("couldn't create a MIDI sequence")
        }
        defer { DisposeMusicSequence(sequence) }
        let status = MusicSequenceFileLoadData(sequence, data as CFData, .midiType, MusicSequenceLoadFlags())
        guard status == noErr else {
            throw ScoreImportError.invalidFormat("not a Standard MIDI File (error \(status))")
        }

        var notes: [RawNote] = []
        var trackNames: [Int: String] = [:]
        var tempos: [TempoChange] = []
        var signature: TimeSignature?

        func collect(_ track: MusicTrack, index: Int) {
            forEachEvent(in: track) { time, type, payload in
                switch type {
                case kMusicEventType_MIDINoteMessage:
                    let message = payload.load(as: MIDINoteMessage.self)
                    notes.append(RawNote(track: index, channel: Int(message.channel), key: Int(message.note),
                                         beat: time, duration: Double(message.duration)))
                case kMusicEventType_ExtendedTempo:
                    tempos.append(TempoChange(beat: time, bpm: payload.load(as: ExtendedTempoEvent.self).bpm))
                case kMusicEventType_Meta:
                    let (metaType, bytes) = metaEvent(payload)
                    if metaType == 0x03, trackNames[index] == nil {
                        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { trackNames[index] = name }
                    } else if metaType == 0x58, bytes.count >= 2, signature == nil {
                        signature = TimeSignature(beats: Int(bytes[0]), beatType: 1 << Int(bytes[1]))
                    }
                default:
                    break
                }
            }
        }

        var tempoTrack: MusicTrack?
        if MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack {
            collect(tempoTrack, index: tempoTrackIndex)
        }
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &trackCount)
        for index in 0..<Int(trackCount) {
            var track: MusicTrack?
            if MusicSequenceGetIndTrack(sequence, UInt32(index), &track) == noErr, let track {
                collect(track, index: index)
            }
        }

        let pitched = notes.filter { $0.channel != 9 }
        let usable = (pitched.isEmpty ? notes : pitched).sorted { ($0.beat, $0.key) < ($1.beat, $1.key) }
        guard !usable.isEmpty else { throw ScoreImportError.noNotes }

        let hands = assignHands(usable, trackNames: trackNames)
        let timeSignature = signature ?? TimeSignature(beats: 4, beatType: 4)
        let beatsPerMeasure = Double(timeSignature.beats) * 4 / Double(timeSignature.beatType)
        let scoreNotes = zip(usable, hands).map { raw, hand in
            ScoreNote(
                id: 0,
                midi: raw.key,
                onsetBeats: raw.beat,
                durationBeats: max(raw.duration, 1.0 / 32),
                hand: hand,
                finger: nil,
                spelling: nil,
                staff: hand == .right ? 1 : 2,
                voice: raw.channel + 1,
                measure: Int(raw.beat / beatsPerMeasure + 1e-9) + 1,
                partID: "T\(raw.track)"
            )
        }

        let title = trackNames[tempoTrackIndex]
            ?? trackNames.keys.sorted().compactMap { trackNames[$0] }.first
            ?? fallbackTitle
        var score = Score(
            title: title,
            composer: nil,
            notes: scoreNotes,
            tempoMap: TempoMap(tempos, defaultBPM: 120),
            timeSignature: timeSignature,
            keyFifths: nil,
            sourceFormat: "MIDI"
        )
        score.finalize()
        return score
    }

    private static func forEachEvent(in track: MusicTrack, _ body: (MusicTimeStamp, MusicEventType, UnsafeRawPointer) -> Void) {
        var iteratorRef: MusicEventIterator?
        guard NewMusicEventIterator(track, &iteratorRef) == noErr, let iterator = iteratorRef else { return }
        defer { DisposeMusicEventIterator(iterator) }
        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        while hasEvent.boolValue {
            var time: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var payload: UnsafeRawPointer?
            var size: UInt32 = 0
            if MusicEventIteratorGetEventInfo(iterator, &time, &type, &payload, &size) == noErr, let payload {
                body(time, type, payload)
            }
            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }
    }

    /// `MIDIMetaEvent` ends in a variable-length byte array that Swift only sees as one byte.
    private static func metaEvent(_ payload: UnsafeRawPointer) -> (type: UInt8, bytes: [UInt8]) {
        let event = payload.load(as: MIDIMetaEvent.self)
        guard let offset = MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data) else { return (event.metaEventType, []) }
        let start = (payload + offset).assumingMemoryBound(to: UInt8.self)
        return (event.metaEventType, Array(UnsafeBufferPointer(start: start, count: Int(event.dataLength))))
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

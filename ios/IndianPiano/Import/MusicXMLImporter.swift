import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

struct MusicXMLImporter: ScoreImporter {
    var name: String { "MusicXML" }
    var contentTypes: [UTType] { [.musicXML, .compressedMusicXML, .xml] }
    var fileExtensions: Set<String> { ["musicxml", "xml", "mxl"] }

    func importScore(from input: ScoreImportInput) async throws -> Score {
        let data = try input.readData()
        let xmlData = Self.isZip(data) ? try MXLContainer.scoreData(fromArchive: data) : data
        return try MusicXMLParser.parse(xmlData, fallbackTitle: input.displayName)
    }

    static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) }
}

/// Reads `.mxl` (zipped MusicXML) containers with ZIPFoundation.
enum MXLContainer {
    static func scoreData(fromArchive data: Data) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw ScoreImportError.invalidFormat("the .mxl archive can't be opened")
        }
        if let container = archive["META-INF/container.xml"],
           let xml = try? XMLTreeElement.parse(contents(of: container, in: archive)) {
            let rootfiles = xml.descendants("rootfile")
            let scoreFile = rootfiles.first { ($0.attributes["media-type"] ?? "application/vnd.recordare.musicxml+xml").contains("musicxml") }
            if let path = scoreFile?.attributes["full-path"], let entry = archive[path] {
                return try contents(of: entry, in: archive)
            }
        }
        let fallback = archive.first { entry in
            let ext = (entry.path as NSString).pathExtension.lowercased()
            return entry.type == .file && !entry.path.hasPrefix("META-INF/") && (ext == "xml" || ext == "musicxml")
        }
        guard let fallback else { throw ScoreImportError.invalidFormat("no MusicXML score inside the .mxl archive") }
        return try contents(of: fallback, in: archive)
    }

    private static func contents(of entry: Entry, in archive: Archive) throws -> Data {
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            throw ScoreImportError.invalidFormat("couldn't decompress \(entry.path) from the .mxl archive")
        }
        return data
    }
}

/// Converts MusicXML (partwise or timewise) into a `Score`.
///
/// Hands: a part with two or more staves maps staff 1 to the right hand and the rest to the
/// left hand. Single-staff parts use the clef (F clef = left), then the part name, then pitch.
/// Fingerings come from `<notations><technical><fingering>`. Tied notes are merged.
/// Repeats are not expanded.
enum MusicXMLParser {
    private struct MeasureContent {
        var number: Int
        var element: XMLTreeElement
    }

    private struct PartInfo {
        var id: String
        var name: String
        var staves = 1
        var clefSigns: [Int: String] = [:]
        var notes: [ScoreNote] = []
    }

    static func parse(_ data: Data, fallbackTitle: String = "Untitled") throws -> Score {
        let root = try XMLTreeElement.parse(data)
        let parts = try measuresByPart(root)

        var partNames: [String: String] = [:]
        for scorePart in root["part-list"]?.children("score-part") ?? [] {
            if let id = scorePart.attributes["id"] { partNames[id] = scorePart["part-name"]?.trimmedText ?? "" }
        }

        var tempos: [TempoChange] = []
        var timeSignature: TimeSignature?
        var pickupBeats = 0.0
        var keyFifths: Int?
        var infos: [PartInfo] = []

        for (partIndex, part) in parts.enumerated() {
            var info = PartInfo(id: part.id, name: partNames[part.id] ?? "")
            var divisions = 1.0
            var measureStart = 0.0
            var openTies: [String: Int] = [:]

            for measure in part.measures {
                var position = 0.0
                var maxPosition = 0.0
                var lastOnset = 0.0

                func duration(of element: XMLTreeElement) -> Double {
                    (element["duration"]?.doubleValue ?? 0) / divisions
                }

                for element in measure.element.children {
                    switch element.name {
                    case "attributes":
                        if let value = element["divisions"]?.doubleValue, value > 0 { divisions = value }
                        if let value = element["staves"]?.intValue { info.staves = value }
                        for clef in element.children("clef") {
                            let number = Int(clef.attributes["number"] ?? "1") ?? 1
                            info.clefSigns[number] = clef["sign"]?.trimmedText
                        }
                        if partIndex == 0 {
                            if keyFifths == nil { keyFifths = element["key", "fifths"]?.intValue }
                            if timeSignature == nil, let beats = element["time", "beats"].flatMap({ Int($0.trimmedText) }),
                               let beatType = element["time", "beat-type"]?.intValue {
                                timeSignature = TimeSignature(beats: beats, beatType: beatType)
                            }
                        }
                    case "backup":
                        position = max(0, position - duration(of: element))
                    case "forward":
                        position += duration(of: element)
                        maxPosition = max(maxPosition, position)
                    case "direction":
                        if let bpm = tempo(fromDirection: element) {
                            tempos.append(TempoChange(beat: measureStart + position, bpm: bpm))
                        }
                    case "sound":
                        if let bpm = element.attributes["tempo"].flatMap(Double.init) {
                            tempos.append(TempoChange(beat: measureStart + position, bpm: bpm))
                        }
                    case "note":
                        if element.has("grace") { continue }
                        let noteDuration = duration(of: element)
                        let isChord = element.has("chord")
                        let onset = isChord ? lastOnset : position
                        if !isChord {
                            lastOnset = position
                            position += noteDuration
                            maxPosition = max(maxPosition, position)
                        }
                        if element.has("rest") || element.has("cue") { continue }
                        guard let pitch = element.child("pitch"),
                              let letter = pitch["step"].flatMap({ NoteSpelling.Letter(name: $0.trimmedText) }),
                              let octave = pitch["octave"]?.intValue else { continue }
                        let alter = pitch["alter"]?.doubleValue.map { Int($0.rounded()) } ?? 0
                        let spelling = NoteSpelling(letter: letter, alter: alter, octave: octave)
                        let staff = element["staff"]?.intValue ?? 1
                        let midi = spelling.midi
                        let ties = tieTypes(of: element)
                        let tieKey = "\(staff)-\(midi)"

                        if ties.contains("stop"), let tiedIndex = openTies[tieKey] {
                            let end = measureStart + onset + noteDuration
                            info.notes[tiedIndex].durationBeats = max(info.notes[tiedIndex].durationBeats, end - info.notes[tiedIndex].onsetBeats)
                            if !ties.contains("start") { openTies[tieKey] = nil }
                            continue
                        }

                        info.notes.append(ScoreNote(
                            id: 0,
                            midi: midi,
                            onsetBeats: measureStart + onset,
                            durationBeats: noteDuration,
                            hand: .right,
                            finger: fingering(of: element),
                            spelling: spelling,
                            staff: staff,
                            voice: element["voice"]?.intValue ?? 1,
                            measure: measure.number,
                            partID: part.id
                        ))
                        if ties.contains("start") { openTies[tieKey] = info.notes.count - 1 }
                    default:
                        break
                    }
                }

                if maxPosition <= 0, let timeSignature {
                    maxPosition = timeSignature.barLength
                }
                if partIndex == 0, measureStart == 0, let timeSignature, maxPosition < timeSignature.barLength - 1e-6 {
                    pickupBeats = maxPosition
                }
                measureStart += maxPosition
            }
            infos.append(info)
        }

        assignHands(&infos)
        // In a song (voice + piano) only the two-staff piano part is practised.
        let pianoParts = infos.filter { $0.staves >= 2 && !$0.notes.isEmpty }
        let practiced = pianoParts.isEmpty ? infos : pianoParts

        var score = Score(
            title: title(of: root) ?? fallbackTitle,
            composer: composer(of: root),
            notes: practiced.flatMap(\.notes),
            tempoMap: TempoMap(tempos),
            timeSignature: timeSignature ?? TimeSignature(beats: 4, beatType: 4),
            pickupBeats: pickupBeats,
            keyFifths: keyFifths,
            sourceFormat: "MusicXML"
        )
        guard !score.notes.isEmpty else { throw ScoreImportError.noNotes }
        score.finalize()
        return score
    }

    // MARK: - Helpers

    private static func measuresByPart(_ root: XMLTreeElement) throws -> [(id: String, measures: [MeasureContent])] {
        func number(_ element: XMLTreeElement, index: Int) -> Int {
            Int(element.attributes["number"] ?? "") ?? index + 1
        }
        switch root.name {
        case "score-partwise":
            return root.children("part").map { part in
                let measures = part.children("measure").enumerated().map { MeasureContent(number: number($1, index: $0), element: $1) }
                return (part.attributes["id"] ?? "P1", measures)
            }
        case "score-timewise":
            var order: [String] = []
            var byPart: [String: [MeasureContent]] = [:]
            for (index, measure) in root.children("measure").enumerated() {
                for part in measure.children("part") {
                    let id = part.attributes["id"] ?? "P1"
                    if byPart[id] == nil { order.append(id) }
                    byPart[id, default: []].append(MeasureContent(number: number(measure, index: index), element: part))
                }
            }
            return order.map { ($0, byPart[$0] ?? []) }
        default:
            throw ScoreImportError.invalidFormat("<\(root.name)> isn't a MusicXML score")
        }
    }

    static func fingering(of note: XMLTreeElement) -> Int? {
        let candidates = note.descendants("fingering").filter {
            $0.attributes["substitution"] != "yes" && $0.attributes["alternate"] != "yes"
        }
        for candidate in candidates {
            if let digit = candidate.trimmedText.first(where: { ("1"..."5").contains($0) }) {
                return Int(String(digit))
            }
        }
        return nil
    }

    private static func tieTypes(of note: XMLTreeElement) -> Set<String> {
        var types = Set(note.children("tie").compactMap { $0.attributes["type"] })
        for tied in note.descendants("tied") {
            if let type = tied.attributes["type"] { types.insert(type == "continue" ? "start" : type) }
            if tied.attributes["type"] == "continue" { types.insert("stop") }
        }
        return types
    }

    private static func tempo(fromDirection direction: XMLTreeElement) -> Double? {
        if let tempo = direction.child("sound")?.attributes["tempo"].flatMap(Double.init) { return tempo }
        guard let metronome = direction.descendants("metronome").first,
              let perMinute = metronome["per-minute"]?.doubleValue else { return nil }
        let unitLengths = ["whole": 4.0, "half": 2.0, "quarter": 1.0, "eighth": 0.5, "16th": 0.25]
        var unit = unitLengths[metronome["beat-unit"]?.trimmedText ?? "quarter"] ?? 1
        if metronome.has("beat-unit-dot") { unit *= 1.5 }
        return perMinute * unit
    }

    private static func title(of root: XMLTreeElement) -> String? {
        let candidates = [root["work", "work-title"]?.trimmedText, root["movement-title"]?.trimmedText]
        if let title = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) { return title }
        return root.children("credit").compactMap { $0["credit-words"]?.trimmedText }.first { !$0.isEmpty }
    }

    private static func composer(of root: XMLTreeElement) -> String? {
        root["identification"]?.children("creator").first { $0.attributes["type"] == "composer" }?.trimmedText
    }

    private static func assignHands(_ parts: inout [PartInfo]) {
        func nameHint(_ name: String) -> Hand? {
            let lower = name.lowercased()
            if ["left", "l.h", "lh", "bass"].contains(where: lower.contains) { return .left }
            if ["right", "r.h", "rh", "treble"].contains(where: lower.contains) { return .right }
            return nil
        }

        var anyMultiStaff = false
        for index in parts.indices {
            let part = parts[index]
            if part.staves >= 2 {
                anyMultiStaff = true
                for n in part.notes.indices { parts[index].notes[n].hand = part.notes[n].staff <= 1 ? .right : .left }
            } else {
                let hand: Hand = part.clefSigns[1] == "F" ? .left : (nameHint(part.name) ?? .right)
                for n in part.notes.indices { parts[index].notes[n].hand = hand }
            }
        }

        let nonEmpty = parts.indices.filter { !parts[$0].notes.isEmpty }
        let allRight = parts.allSatisfy { $0.notes.allSatisfy { $0.hand == .right } }
        if !anyMultiStaff, allRight, nonEmpty.count >= 2 {
            let lowest = nonEmpty.min { averagePitch(parts[$0].notes) < averagePitch(parts[$1].notes) }!
            for n in parts[lowest].notes.indices { parts[lowest].notes[n].hand = .left }
        }
    }

    private static func averagePitch(_ notes: [ScoreNote]) -> Double {
        notes.isEmpty ? 0 : Double(notes.map(\.midi).reduce(0, +)) / Double(notes.count)
    }
}

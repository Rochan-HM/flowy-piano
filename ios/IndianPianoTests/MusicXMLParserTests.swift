import XCTest
@testable import IndianPiano

final class MusicXMLParserTests: XCTestCase {
    /// Grand staff with a chord, accidentals, a rest, a tie across the barline, a grace note,
    /// backup/forward, and fingerings (including a substitution that must be ignored).
    static let grandStaff = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">
      <work><work-title>Test Piece</work-title></work>
      <identification><creator type="composer">Tester</creator></identification>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>2</divisions>
            <key><fifths>-1</fifths></key>
            <time><beats>4</beats><beat-type>4</beat-type></time>
            <staves>2</staves>
            <clef number="1"><sign>G</sign><line>2</line></clef>
            <clef number="2"><sign>F</sign><line>4</line></clef>
          </attributes>
          <direction><sound tempo="120"/></direction>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><staff>1</staff>
            <notations><technical><fingering>3</fingering></technical></notations></note>
          <note><chord/><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><staff>1</staff>
            <notations><technical><fingering>5</fingering></technical></notations></note>
          <note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>2</duration><voice>1</voice><staff>1</staff>
            <notations><technical><fingering>4</fingering><fingering substitution="yes">3</fingering></technical></notations></note>
          <note><rest/><duration>2</duration><voice>1</voice><staff>1</staff></note>
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><tie type="start"/><voice>1</voice><staff>1</staff>
            <notations><tied type="start"/><technical><fingering>1</fingering></technical></notations></note>
          <backup><duration>8</duration></backup>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><staff>2</staff>
            <notations><technical><fingering>5</fingering></technical></notations></note>
          <note><grace/><pitch><step>D</step><octave>3</octave></pitch><voice>5</voice><staff>2</staff></note>
          <note><pitch><step>G</step><octave>2</octave></pitch><duration>4</duration><voice>5</voice><staff>2</staff></note>
        </measure>
        <measure number="2">
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><tie type="stop"/><voice>1</voice><staff>1</staff>
            <notations><tied type="stop"/></notations></note>
          <note><pitch><step>B</step><alter>-1</alter><octave>4</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff>
            <notations><technical><fingering>2</fingering></technical></notations></note>
          <backup><duration>8</duration></backup>
          <forward><duration>4</duration></forward>
          <note><pitch><step>F</step><octave>3</octave></pitch><duration>4</duration><voice>5</voice><staff>2</staff></note>
        </measure>
      </part>
    </score-partwise>
    """

    private func parse(_ xml: String) throws -> Score {
        try MusicXMLParser.parse(Data(xml.utf8))
    }

    func testGrandStaffHandsTimingAndFingerings() throws {
        let score = try parse(Self.grandStaff)
        XCTAssertEqual(score.title, "Test Piece")
        XCTAssertEqual(score.composer, "Tester")
        XCTAssertEqual(score.keyFifths, -1)
        XCTAssertEqual(score.sourceFormat, "MusicXML")

        let summary = score.notes.map { "\($0.midi)@\($0.onsetBeats) \($0.hand.rawValue) f\($0.finger.map(String.init) ?? "-")" }
        XCTAssertEqual(summary, [
            "48@0.0 left f5", "64@0.0 right f3", "67@0.0 right f5",
            "66@1.0 right f4",
            "43@2.0 left f-",
            "72@3.0 right f1",
            "53@6.0 left f-", "70@6.0 right f2",
        ])
    }

    func testTiesMergeIntoOneNote() throws {
        let score = try parse(Self.grandStaff)
        let tied = try XCTUnwrap(score.notes.first { $0.midi == 72 })
        XCTAssertEqual(tied.durationBeats, 3, accuracy: 1e-9)
        XCTAssertEqual(tied.measure, 1)
        XCTAssertEqual(score.notes.filter { $0.midi == 72 }.count, 1)
    }

    func testSecondsFollowTempo() throws {
        let score = try parse(Self.grandStaff)
        let flat = try XCTUnwrap(score.notes.first { $0.midi == 70 })
        XCTAssertEqual(flat.onsetSeconds, 3.0, accuracy: 1e-9) // beat 6 at 120 bpm
        XCTAssertEqual(flat.durationSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(flat.spelling, NoteSpelling(letter: .b, alter: -1, octave: 4))
        XCTAssertEqual(score.initialBPM, 120)
    }

    func testSingleStaffBassClefPartIsLeftHand() throws {
        let xml = """
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Exercise</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><attributes><divisions>1</divisions><clef><sign>F</sign><line>4</line></clef></attributes>
        <note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration></note></measure></part></score-partwise>
        """
        XCTAssertEqual(try parse(xml).notes.map(\.hand), [.left])
    }

    func testTwoSingleStaffPartsUseLowerPartForLeftHand() throws {
        let xml = """
        <score-partwise version="4.0"><part-list>
          <score-part id="P1"><part-name>Piano</part-name></score-part><score-part id="P2"><part-name>Piano</part-name></score-part>
        </part-list>
        <part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
          <note><pitch><step>E</step><octave>5</octave></pitch><duration>1</duration></note></measure></part>
        <part id="P2"><measure number="1"><attributes><divisions>1</divisions></attributes>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration></note></measure></part>
        </score-partwise>
        """
        let notes = try parse(xml).notes
        XCTAssertEqual(notes.first { $0.midi == 76 }?.hand, .right)
        XCTAssertEqual(notes.first { $0.midi == 48 }?.hand, .left)
    }

    func testTimewiseScoresAreSupported() throws {
        let xml = """
        <score-timewise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <measure number="1"><part id="P1"><attributes><divisions>1</divisions></attributes>
            <note><pitch><step>C</step><octave>4</octave></pitch><duration>2</duration></note></part></measure>
          <measure number="2"><part id="P1">
            <note><pitch><step>D</step><octave>4</octave></pitch><duration>2</duration></note></part></measure>
        </score-timewise>
        """
        let notes = try parse(xml).notes
        XCTAssertEqual(notes.map(\.midi), [60, 62])
        XCTAssertEqual(notes.map(\.onsetBeats), [0, 2])
        XCTAssertEqual(notes.map(\.measure), [1, 2])
    }

    func testRejectsNonScores() {
        XCTAssertThrowsError(try parse("<html><body/></html>"))
        XCTAssertThrowsError(try parse("not xml at all <"))
        XCTAssertThrowsError(try parse("<score-partwise version=\"4.0\"><part id=\"P1\"/></score-partwise>")) { error in
            XCTAssertEqual(error as? ScoreImportError, .noNotes)
        }
    }

    // MARK: Bundled songs

    private func bundled(_ name: String) async throws -> Score {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "musicxml"), "\(name) isn't in the app bundle")
        return try await ScoreImportService.shared.importScore(at: url)
    }

    func testBundledTwinkleHasBothHandsAndFingeringEverywhere() async throws {
        let score = try await bundled("twinkle-twinkle")
        XCTAssertEqual(score.hands, [.right, .left])
        XCTAssertEqual(score.notes.filter { $0.hand == .right }.count, 42)
        XCTAssertEqual(score.notes.filter { $0.hand == .left }.count, 22)
        XCTAssertTrue(score.notes.allSatisfy { $0.finger != nil })
        XCTAssertEqual(score.notes.filter { $0.hand == .right }.prefix(4).map(\.midi), [60, 60, 67, 67])
        XCTAssertEqual(score.initialBPM, 92)
    }

    func testBundledOdeToJoyIsRightHandOnly() async throws {
        let score = try await bundled("ode-to-joy")
        XCTAssertEqual(score.hands, [.right])
        XCTAssertEqual(score.notes.count, 30)
        XCTAssertTrue(score.hasFingerings)
        XCTAssertEqual(score.notes.prefix(4).map(\.finger), [3, 3, 4, 5])
    }

    func testBundledMinuetHasTwoHandChordsAndSharps() async throws {
        let score = try await bundled("minuet-in-g")
        XCTAssertEqual(score.timeSignature, TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(score.keyFifths, 1)
        let firstBeat = score.notes.filter { $0.onsetBeats == 0 }
        XCTAssertEqual(firstBeat.map(\.midi), [55, 59, 74])
        XCTAssertEqual(firstBeat.map(\.hand), [.left, .left, .right])
        XCTAssertEqual(firstBeat.map(\.finger), [5, 3, 5])
        let fSharp = try XCTUnwrap(score.notes.first { $0.midi == 78 })
        XCTAssertEqual(fSharp.spelling, NoteSpelling(letter: .f, alter: 1, octave: 5))
        XCTAssertEqual(fSharp.finger, 4)
    }

    // MARK: Compressed MusicXML

    func testMXLMatchesUncompressedScore() async throws {
        let mxl = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "minuet-in-g", withExtension: "mxl"))
        let compressed = try await ScoreImportService.shared.importScore(at: mxl)
        let plain = try await bundled("minuet-in-g")
        XCTAssertEqual(compressed.title, "Minuet in G (simplified)")
        XCTAssertEqual(compressed.notes.map(\.midi), plain.notes.map(\.midi))
        XCTAssertEqual(compressed.notes.map(\.onsetBeats), plain.notes.map(\.onsetBeats))
        XCTAssertEqual(compressed.notes.map(\.finger), plain.notes.map(\.finger))
    }

    func testMXLContainerFollowsRootfileAndInflates() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "minuet-in-g", withExtension: "mxl"))
        let xml = try MXLContainer.scoreData(fromArchive: Data(contentsOf: url))
        let plain = try Data(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "minuet-in-g", withExtension: "musicxml")))
        XCTAssertEqual(xml, plain)
    }

    func testMXLWithoutContainerFallsBackToTheFirstScore() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ode-no-container", withExtension: "mxl"))
        let score = try MusicXMLParser.parse(try MXLContainer.scoreData(fromArchive: Data(contentsOf: url)))
        XCTAssertEqual(score.title, "Ode to Joy")
        XCTAssertEqual(score.notes.count, 30)
    }

    func testCorruptArchiveIsRejected() {
        var bytes = Data([0x50, 0x4B, 0x03, 0x04])
        bytes.append(Data(repeating: 0x41, count: 64))
        XCTAssertThrowsError(try MXLContainer.scoreData(fromArchive: bytes))
    }

    func testSongWithVoiceKeepsOnlyThePianoPart() throws {
        let xml = """
        <score-partwise version="4.0"><part-list>
          <score-part id="P1"><part-name>Voice</part-name></score-part><score-part id="P2"><part-name>Piano</part-name></score-part>
        </part-list>
        <part id="P1"><measure number="1"><attributes><divisions>1</divisions><clef><sign>G</sign><line>2</line></clef></attributes>
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration></note></measure></part>
        <part id="P2"><measure number="1"><attributes><divisions>1</divisions><staves>2</staves></attributes>
          <note><pitch><step>E</step><octave>5</octave></pitch><duration>1</duration><staff>1</staff></note>
          <backup><duration>1</duration></backup>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note></measure></part>
        </score-partwise>
        """
        let notes = try parse(xml).notes
        XCTAssertEqual(notes.map(\.midi), [48, 76])
        XCTAssertEqual(notes.map(\.hand), [.left, .right])
    }

    func testImportServiceRoutesByExtension() {
        let service = ScoreImportService.shared
        XCTAssertEqual(service.importer(for: .file(URL(fileURLWithPath: "/tmp/a.mxl")))?.name, "MusicXML")
        XCTAssertEqual(service.importer(for: .file(URL(fileURLWithPath: "/tmp/a.MusicXML")))?.name, "MusicXML")
        XCTAssertEqual(service.importer(for: .file(URL(fileURLWithPath: "/tmp/a.mid")))?.name, "MIDI")
        XCTAssertNil(service.importer(for: .file(URL(fileURLWithPath: "/tmp/a.pdf"))))
        XCTAssertTrue(service.allowedContentTypes.contains(.midi))
        XCTAssertTrue(service.allowedContentTypes.contains(.musicXML))
        XCTAssertTrue(service.allowedContentTypes.contains(.compressedMusicXML))
    }
}

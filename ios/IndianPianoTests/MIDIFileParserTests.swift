import XCTest
@testable import IndianPiano

final class MIDIFileParserTests: XCTestCase {
    func testFixtureUsesTrackNamesForHands() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "two-hands", withExtension: "mid"))
        let score = try await ScoreImportService.shared.importScore(at: url)
        XCTAssertEqual(score.title, "Two Hands Test")
        XCTAssertEqual(score.sourceFormat, "MIDI")
        XCTAssertEqual(score.notes.filter { $0.hand == .right }.map(\.midi), [60, 62, 64, 65])
        XCTAssertEqual(score.notes.filter { $0.hand == .left }.map(\.midi), [48, 43])
        let e4 = try XCTUnwrap(score.notes.first { $0.midi == 64 })
        XCTAssertEqual(e4.onsetBeats, 2, accuracy: 1e-9)
        XCTAssertEqual(e4.onsetSeconds, 1.0, accuracy: 1e-9) // 120 bpm
        let c3 = try XCTUnwrap(score.notes.first { $0.midi == 48 })
        XCTAssertEqual(c3.durationBeats, 2, accuracy: 1e-9) // ended by note-on with velocity 0
        XCTAssertTrue(score.notes.allSatisfy { $0.finger == nil })
    }

    func testFormat0SingleChannelSplitsAtMiddleCWithRunningStatusAndTempoChange() throws {
        // 480 ticks per quarter. Tempo 120 bpm, then 60 bpm from tick 960.
        var track: [UInt8] = []
        track += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]          // 500000 µs/quarter
        track += [0x00, 0x90, 48, 80]                                  // C3 on
        track += [0x00, 72, 80]                                        // running status: C5 on
        track += [0x87, 0x40, 48, 0]                                   // +960: C3 off (velocity 0)
        track += [0x00, 72, 0]                                         // C5 off
        track += [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40]            // 1000000 µs/quarter at 960
        track += [0x83, 0x60, 0x99, 36, 100]                           // +480: drum hit (channel 10) — ignored
        track += [0x00, 0x90, 64, 90]                                  // E4 on at tick 1440
        track += [0x83, 0x60, 0x80, 64, 0]                             // E4 off at 1920
        track += [0x00, 0xFF, 0x2F, 0x00]
        let data = Self.smf(format: 0, tracks: [track])

        let score = try MIDIFileParser.parse(data, fallbackTitle: "Fallback")
        XCTAssertEqual(score.title, "Fallback")
        XCTAssertEqual(score.notes.map(\.midi), [48, 72, 64])
        XCTAssertEqual(score.notes.map(\.hand), [.left, .right, .right])
        let e4 = score.notes[2]
        XCTAssertEqual(e4.onsetBeats, 3, accuracy: 1e-9)
        XCTAssertEqual(e4.onsetSeconds, 2.0, accuracy: 1e-9) // 1 s for two beats at 120, then 1 s for one beat at 60
        XCTAssertEqual(e4.durationSeconds, 1.0, accuracy: 1e-9)
    }

    func testAveragePitchDecidesHandsWhenTracksAreUnnamed() throws {
        let high: [UInt8] = [0x00, 0x90, 76, 80, 0x83, 0x60, 0x80, 76, 0, 0x00, 0xFF, 0x2F, 0x00]
        let low: [UInt8] = [0x00, 0x90, 50, 80, 0x83, 0x60, 0x80, 50, 0, 0x00, 0xFF, 0x2F, 0x00]
        let score = try MIDIFileParser.parse(Self.smf(format: 1, tracks: [low, high]))
        XCTAssertEqual(score.notes.first { $0.midi == 76 }?.hand, .right)
        XCTAssertEqual(score.notes.first { $0.midi == 50 }?.hand, .left)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MIDIFileParser.parse(Data("hello".utf8)))
        XCTAssertThrowsError(try MIDIFileParser.parse(Self.smf(format: 0, tracks: [[0x00, 0xFF, 0x2F, 0x00]]))) { error in
            XCTAssertEqual(error as? ScoreImportError, .noNotes)
        }
    }

    static func smf(format: UInt16, tracks: [[UInt8]], division: UInt16 = 480) -> Data {
        func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
        func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        var bytes = Array("MThd".utf8) + be32(6) + be16(format) + be16(UInt16(tracks.count)) + be16(division)
        for track in tracks { bytes += Array("MTrk".utf8) + be32(track.count) + track }
        return Data(bytes)
    }
}

import XCTest
@testable import IndianPiano

final class NoteNamingTests: XCTestCase {
    private func spelled(_ letter: NoteSpelling.Letter, _ alter: Int, _ octave: Int) -> NoteSpelling {
        NoteSpelling(letter: letter, alter: alter, octave: octave)
    }

    func testCarnaticDefaultNamesAcrossTwelveSemitones() {
        let scheme = CarnaticNaming(saPitchClass: 0)
        let names = (60..<72).map { scheme.label(forMIDI: $0).text }
        XCTAssertEqual(names, ["Sa", "Ri1", "Ri2", "Ga2", "Ga3", "Ma1", "Ma2", "Pa", "Da1", "Da2", "Ni2", "Ni3"])
        XCTAssertTrue((60..<72).allSatisfy { scheme.label(forMIDI: $0).octaveShift == 0 })
        XCTAssertNil(scheme.label(forMIDI: 60).variant)
        XCTAssertNil(scheme.label(forMIDI: 67).variant)
    }

    func testCarnaticRegistersAroundMiddleSa() {
        let scheme = CarnaticNaming(saPitchClass: 0)
        XCTAssertEqual(scheme.label(forMIDI: 72).octaveShift, 1)
        XCTAssertEqual(scheme.label(forMIDI: 84).octaveShift, 2)
        XCTAssertEqual(scheme.label(forMIDI: 59).text, "Ni3")
        XCTAssertEqual(scheme.label(forMIDI: 59).octaveShift, -1)
        XCTAssertEqual(scheme.label(forMIDI: 48).octaveShift, -1)
        XCTAssertEqual(scheme.label(forMIDI: 72).fullText, "Sa'")
        XCTAssertEqual(scheme.label(forMIDI: 59).fullText, "Ni3,")
    }

    func testMovableSa() {
        let scheme = CarnaticNaming(saPitchClass: 2) // Sa = D
        XCTAssertEqual(scheme.label(forMIDI: 62).text, "Sa")
        XCTAssertEqual(scheme.label(forMIDI: 62).octaveShift, 0)
        XCTAssertEqual(scheme.label(forMIDI: 64).text, "Ri2")
        XCTAssertEqual(scheme.label(forMIDI: 66).text, "Ga3")
        XCTAssertEqual(scheme.label(forMIDI: 67).text, "Ma1")
        XCTAssertEqual(scheme.label(forMIDI: 69).text, "Pa")
        XCTAssertEqual(scheme.label(forMIDI: 60).text, "Ni2")
        XCTAssertEqual(scheme.label(forMIDI: 60).octaveShift, -1)
        XCTAssertEqual(scheme.label(forMIDI: 74).octaveShift, 1)
    }

    func testHighTonicAnchorsMiddleOctaveBelowMiddleC() {
        let scheme = CarnaticNaming(saPitchClass: 9) // Sa = A
        XCTAssertEqual(Sargam.middleSa(saPitchClass: 9), 57)
        XCTAssertEqual(scheme.label(forMIDI: 57).text, "Sa")
        XCTAssertEqual(scheme.label(forMIDI: 57).octaveShift, 0)
        XCTAssertEqual(scheme.label(forMIDI: 69).octaveShift, 1)
        XCTAssertEqual(scheme.label(forMIDI: 60).text, "Ga2")
        XCTAssertEqual(Sargam.middleSa(saPitchClass: 6), 66)
    }

    func testCarnaticEnharmonicsFollowScoreSpelling() {
        let scheme = CarnaticNaming(saPitchClass: 0)
        XCTAssertEqual(scheme.label(forMIDI: 63, spelling: spelled(.d, 1, 4)).text, "Ri3")
        XCTAssertEqual(scheme.label(forMIDI: 63, spelling: spelled(.e, -1, 4)).text, "Ga2")
        XCTAssertEqual(scheme.label(forMIDI: 62, spelling: spelled(.e, -2, 4)).text, "Ga1")
        XCTAssertEqual(scheme.label(forMIDI: 62, spelling: spelled(.d, 0, 4)).text, "Ri2")
        XCTAssertEqual(scheme.label(forMIDI: 70, spelling: spelled(.a, 1, 4)).text, "Da3")
        XCTAssertEqual(scheme.label(forMIDI: 70, spelling: spelled(.b, -1, 4)).text, "Ni2")
        XCTAssertEqual(scheme.label(forMIDI: 69, spelling: spelled(.b, -2, 4)).text, "Ni1")
        XCTAssertEqual(scheme.label(forMIDI: 66, spelling: spelled(.f, 1, 4)).text, "Ma2")
        // G♭ isn't a form of Pa, so the default name is kept.
        XCTAssertEqual(scheme.label(forMIDI: 66, spelling: spelled(.g, -1, 4)).text, "Ma2")
    }

    func testCarnaticEnharmonicsWithMovableSa() {
        let scheme = CarnaticNaming(saPitchClass: 2) // Sa = D, so E is the Ri letter and F the Ga letter
        XCTAssertEqual(scheme.label(forMIDI: 65, spelling: spelled(.e, 1, 4)).text, "Ri3")
        XCTAssertEqual(scheme.label(forMIDI: 65, spelling: spelled(.f, 0, 4)).text, "Ga2")
    }

    func testSpellingThatDoesNotMatchPitchIsIgnored() {
        let scheme = CarnaticNaming(saPitchClass: 0)
        XCTAssertEqual(scheme.label(forMIDI: 63, spelling: spelled(.d, 1, 5)).text, "Ga2")
    }

    func testHindustaniKomalAndTivra() {
        let scheme = HindustaniNaming(saPitchClass: 0)
        let komal = scheme.label(forMIDI: 61)
        XCTAssertEqual(komal.text, "Re")
        XCTAssertEqual(komal.mark, .komal)
        XCTAssertEqual(komal.fullText, "komal Re")
        XCTAssertNil(scheme.label(forMIDI: 62).mark)
        XCTAssertEqual(scheme.label(forMIDI: 66).mark, .tivra)
        XCTAssertEqual(scheme.label(forMIDI: 66).text, "Ma")
        XCTAssertEqual(scheme.label(forMIDI: 68).text, "Dha")
        XCTAssertEqual(scheme.label(forMIDI: 68).mark, .komal)
        XCTAssertEqual(scheme.label(forMIDI: 71).text, "Ni")
        XCTAssertNil(scheme.label(forMIDI: 71).mark)
    }

    func testWesternNames() {
        let scheme = WesternNaming()
        XCTAssertEqual(scheme.label(forMIDI: 60).text, "C")
        XCTAssertEqual(scheme.label(forMIDI: 60).westernOctave, 4)
        XCTAssertEqual(scheme.label(forMIDI: 61).text, "C♯")
        XCTAssertEqual(scheme.label(forMIDI: 61, spelling: spelled(.d, -1, 4)).text, "D♭")
        XCTAssertEqual(scheme.label(forMIDI: 21).fullText, "A0")
        XCTAssertEqual(scheme.label(forMIDI: 108).fullText, "C8")
        XCTAssertEqual(scheme.label(forMIDI: 71, spelling: spelled(.c, -1, 5)).fullText, "C♭5")
    }

    func testNotationSystemsAreRegistered() {
        for system in NotationSystem.allCases {
            XCTAssertEqual(system.makeScheme(saPitchClass: 0).system, system)
        }
        XCTAssertFalse(NotationSystem.western.isSargam)
        XCTAssertTrue(NotationSystem.carnatic.isSargam)
        XCTAssertTrue(NotationSystem.hindustani.isSargam)
    }

    @MainActor
    func testSaCanBeGivenAsNameOrNumber() {
        XCTAssertEqual(AppModel.pitchClass(from: "D"), 2)
        XCTAssertEqual(AppModel.pitchClass(from: "Eb"), 3)
        XCTAssertEqual(AppModel.pitchClass(from: "F#"), 6)
        XCTAssertEqual(AppModel.pitchClass(from: "11"), 11)
        XCTAssertNil(AppModel.pitchClass(from: "H"))
    }
}

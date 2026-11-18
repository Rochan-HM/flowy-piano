import XCTest

final class IndianPianoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func key(_ app: XCUIApplication, _ midi: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "key-\(midi)").firstMatch
    }

    private func waitFor(_ element: XCUIElement, label expected: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", expected)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "label is “\(element.label)”, expected “\(expected)”", file: file, line: line)
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "label is “\(element.label)”, expected it to contain “\(text)”", file: file, line: line)
    }

    func testTappingKeysDrivesTheWaitModeLesson() {
        let app = launch(["-song", "twinkle", "-handMode", "right", "-practiceMode", "wait",
                          "-notation", "western", "-visibleWhiteKeys", "15", "-showFingers", "YES"])
        let middleC = key(app, 60)
        XCTAssertTrue(middleC.waitForExistence(timeout: 20))
        let feedback = app.descendants(matching: .any).matching(identifier: "feedback").firstMatch
        waitFor(feedback, labelContaining: "C4")

        key(app, 61).tap()
        waitFor(feedback, labelContaining: "Played")

        middleC.tap()
        middleC.tap()
        key(app, 67).tap()
        key(app, 67).tap()
        // Twinkle continues with A4, played with finger 5.
        waitFor(feedback, labelContaining: "A4")
        waitFor(feedback, labelContaining: "finger 5")
    }

    func testNotationToggleAndMovableSa() {
        let app = launch(["-song", "twinkle", "-handMode", "right", "-notation", "western",
                          "-indianSystem", "carnatic", "-saPitchClass", "0", "-keyLabels", "all"])
        XCTAssertTrue(key(app, 60).waitForExistence(timeout: 20))
        waitFor(key(app, 60), label: "C4")
        waitFor(key(app, 62), label: "D4")

        app.buttons["Sa Ri Ga"].tap()
        waitFor(key(app, 60), label: "Sa")
        waitFor(key(app, 62), label: "Ri2")
        waitFor(key(app, 63), label: "Ga2")
        waitFor(key(app, 72), label: "Sa'")

        app.buttons["saPicker"].tap()
        app.buttons["Sa = D"].tap()
        waitFor(key(app, 62), label: "Sa")
        waitFor(key(app, 64), label: "Ri2")
        waitFor(key(app, 60), label: "Ni2,")

        app.buttons["C D E"].tap()
        waitFor(key(app, 62), label: "D4")
    }

    func testImportOpensTheFilesPicker() {
        let app = launch(["-song", "ode-to-joy", "-notation", "western"])
        let songButton = app.buttons["songButton"]
        XCTAssertTrue(songButton.waitForExistence(timeout: 20))
        songButton.tap()
        XCTAssertTrue(app.buttons["song-minuet-in-g"].waitForExistence(timeout: 5))
        let importButton = app.buttons["importToolbarButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()
        // The document picker offers Cancel plus its Browse/Recents tabs.
        let picker = app.navigationBars.buttons["Cancel"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Files picker didn't appear")
        picker.tap()
    }

    func testBothHandsChordNeedsBothKeysAndShowsFingers() {
        let app = launch(["-song", "twinkle", "-handMode", "both", "-notation", "carnatic", "-indianSystem", "carnatic",
                          "-saPitchClass", "0", "-practiceMode", "wait", "-showFingers", "YES"])
        let feedback = app.descendants(matching: .any).matching(identifier: "feedback").firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 20))
        // First step: C4 (RH finger 1) with C3 (LH finger 5), shown as Sa and mandra Sa.
        waitFor(feedback, labelContaining: "finger 1")
        waitFor(feedback, labelContaining: "finger 5")
        waitFor(feedback, labelContaining: "Sa,")

        key(app, 60).tap()
        let stats = app.descendants(matching: .any).matching(identifier: "stats").firstMatch
        waitFor(stats, labelContaining: "1 correct")
        // Still waiting for the left hand.
        waitFor(feedback, labelContaining: "Sa,")
        key(app, 48).tap()
        waitFor(stats, labelContaining: "2 correct")
        // Next step is C4 alone (RH, finger 1); a wrong G4 shows the correction.
        key(app, 67).tap()
        waitFor(feedback, labelContaining: "Played")
        waitFor(stats, labelContaining: "1 mistakes")
    }

    func testListenModeAndMetronome() {
        let app = launch(["-song", "twinkle", "-handMode", "right", "-practiceMode", "listen", "-notation", "western",
                          "-showFingers", "YES", "-tempoScale", "1", "-metronome", "NO"])
        let feedback = app.descendants(matching: .any).matching(identifier: "feedback").firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 20))
        waitFor(feedback, labelContaining: "Press play to hear it at 100%")

        let metronome = app.buttons["metronomeButton"]
        XCTAssertEqual(metronome.value as? String, "Off")
        // Leave the saved setting as it was.
        addTeardownBlock { if metronome.exists, metronome.value as? String != "Off" { metronome.tap() } }
        metronome.tap()
        let on = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "On, 92 beats per minute"),
                                                                  object: metronome)], timeout: 5)
        XCTAssertEqual(on, .completed, "metronome value is “\(metronome.value ?? "")”")

        let play = app.buttons["playButton"]
        play.tap()
        waitFor(feedback, labelContaining: "Playing")
        // The sounding notes are named with their fingers as the song plays.
        waitFor(feedback, labelContaining: "finger")
        play.tap()
        waitFor(feedback, labelContaining: "Paused")
        play.tap()
        waitFor(feedback, labelContaining: "Playing")
        app.buttons["stopButton"].tap()
        waitFor(feedback, labelContaining: "Press play")
        XCTAssertFalse(app.buttons["stopButton"].isEnabled)
    }

    func testHandModeSwitchShowsLeftHandNotes() {
        let app = launch(["-song", "twinkle", "-handMode", "right", "-notation", "western", "-practiceMode", "wait"])
        let feedback = app.descendants(matching: .any).matching(identifier: "feedback").firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 20))
        waitFor(feedback, labelContaining: "C4")
        app.buttons["LH"].tap()
        waitFor(feedback, labelContaining: "C3")
        app.buttons["Both"].tap()
        waitFor(feedback, labelContaining: "C4")
        waitFor(feedback, labelContaining: "C3")
    }
}

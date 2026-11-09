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

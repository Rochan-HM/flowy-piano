import Foundation
import Observation
import os
import SwiftUI

enum KeyLabelMode: String, CaseIterable, Identifiable {
    case all, white, off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All keys"
        case .white: return "White keys"
        case .off: return "Off"
        }
    }
}

struct KeyFlash: Equatable {
    enum Kind { case correct, wrong }
    var kind: Kind
    var token: Int
}

struct KeyVisualState: Equatable {
    var expectedHand: Hand?
    var finger: Int?
    var isSatisfied = false
    var isPressed = false
    var flash: KeyFlash.Kind?
    var isHeard = false
    var isTonic = false
}

/// App-wide state: settings, the loaded song, the lesson, and audio in/out.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let notation = "notation"
        static let indianSystem = "indianSystem"
        static let sa = "saPitchClass"
        static let keyLabels = "keyLabels"
        static let showFingers = "showFingers"
        static let sound = "sound"
        static let micOctaveTolerant = "micOctaveTolerant"
        static let visibleWhiteKeys = "visibleWhiteKeys"
        static let playOtherHand = "playOtherHand"
        static let song = "song"
        static let handMode = "handMode"
        static let practiceMode = "practiceMode"
        static let tempoScale = "tempoScale"
        static let autoZoom = "autoZoom"
        static let recognitionEnabled = "recognitionEnabled"
        static let recognitionURL = "recognitionURL"
        static let recognitionToken = "recognitionToken"
    }

    enum RecognitionStatus: Equatable {
        case idle
        case working(RecognitionProgress, name: String)
    }

    // MARK: Settings

    var notation: NotationSystem { didSet { defaults.set(notation.rawValue, forKey: Keys.notation) } }
    /// The Indian scheme used by the notation toggle (Carnatic by default).
    var indianSystem: NotationSystem {
        didSet {
            defaults.set(indianSystem.rawValue, forKey: Keys.indianSystem)
            if notation.isSargam { notation = indianSystem }
        }
    }
    var saPitchClass: Int { didSet { defaults.set(saPitchClass, forKey: Keys.sa) } }
    var keyLabelMode: KeyLabelMode { didSet { defaults.set(keyLabelMode.rawValue, forKey: Keys.keyLabels) } }
    var showFingerNumbers: Bool { didSet { defaults.set(showFingerNumbers, forKey: Keys.showFingers) } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.sound) } }
    var micOctaveTolerant: Bool { didSet { defaults.set(micOctaveTolerant, forKey: Keys.micOctaveTolerant) } }
    var playOtherHand: Bool { didSet { defaults.set(playOtherHand, forKey: Keys.playOtherHand) } }
    var visibleWhiteKeys: Int {
        didSet {
            defaults.set(visibleWhiteKeys, forKey: Keys.visibleWhiteKeys)
            fitKeyboardToSong()
        }
    }
    /// Zoom the keyboard out so the whole song fits, instead of scrolling between hands.
    var autoZoom: Bool {
        didSet {
            defaults.set(autoZoom, forKey: Keys.autoZoom)
            fitKeyboardToSong()
        }
    }
    static let maxAutoZoomKeys = 26
    /// Key count chosen for the current song by auto-zoom, if it needed more than `visibleWhiteKeys`.
    private(set) var songWhiteKeys: Int?
    var shownWhiteKeys: Int { songWhiteKeys ?? visibleWhiteKeys }
    /// Photo/PDF import through the recognition server (off until a server is set up).
    var recognitionEnabled: Bool { didSet { defaults.set(recognitionEnabled, forKey: Keys.recognitionEnabled) } }
    var recognitionServerURL: String { didSet { defaults.set(recognitionServerURL, forKey: Keys.recognitionURL) } }
    /// Kept in the Keychain, not UserDefaults.
    var recognitionToken: String { didSet { Keychain.write(recognitionToken, account: Keys.recognitionToken) } }

    var isRecognitionReady: Bool {
        recognitionEnabled && !recognitionServerURL.trimmingCharacters(in: .whitespaces).isEmpty && !recognitionToken.isEmpty
    }

    // MARK: Runtime state

    let library = SongLibrary()
    let lesson = LessonEngine()
    let mic = MicController()
    @ObservationIgnored let synth = PianoSynth()

    private(set) var currentSong: SongEntry?
    private(set) var isLoadingSong = false
    var errorMessage: String?
    private(set) var pressedKeys: Set<Int> = []
    private(set) var flashes: [Int: KeyFlash] = [:]
    var lowestWhiteKey: Int
    var isLibraryPresented = false
    var isSettingsPresented = false
    private(set) var recognitionStatus: RecognitionStatus = .idle
    /// Shown once after an import that came with warnings (e.g. no finger numbers from scans).
    var importNotes: [String] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var flashToken = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stickyFlashes = false
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    /// Key strike that completed the last chord step via chroma.
    @ObservationIgnored private var chordAttack: Int?
    /// Latest key strike heard, and the strike that was latest when the current step began:
    /// a step only accepts chords from strikes made after it became current.
    @ObservationIgnored private var latestAttack = 0
    @ObservationIgnored private var stepAttackFloor = 0
    /// A pitch reading in a chord step that may be a wrong note, waiting for chroma to confirm it.
    @ObservationIgnored private var pendingChordWrong: (midi: Int, attack: Int)?
    @ObservationIgnored private let log = Logger(subsystem: "com.rochan.indianpiano", category: "lesson")

    var naming: NoteNamingScheme { notation.makeScheme(saPitchClass: saPitchClass) }

    var isIndianNotation: Bool {
        get { notation.isSargam }
        set { notation = newValue ? indianSystem : .western }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notation = NotationSystem(rawValue: defaults.string(forKey: Keys.notation) ?? "") ?? .western
        let indian = NotationSystem(rawValue: defaults.string(forKey: Keys.indianSystem) ?? "") ?? .carnatic
        indianSystem = indian.isSargam ? indian : .carnatic
        saPitchClass = Self.pitchClass(from: defaults.string(forKey: Keys.sa)) ?? 0
        keyLabelMode = KeyLabelMode(rawValue: defaults.string(forKey: Keys.keyLabels) ?? "") ?? .all
        showFingerNumbers = defaults.object(forKey: Keys.showFingers) == nil ? true : defaults.bool(forKey: Keys.showFingers)
        soundEnabled = defaults.object(forKey: Keys.sound) == nil ? true : defaults.bool(forKey: Keys.sound)
        micOctaveTolerant = defaults.object(forKey: Keys.micOctaveTolerant) == nil ? true : defaults.bool(forKey: Keys.micOctaveTolerant)
        playOtherHand = defaults.object(forKey: Keys.playOtherHand) == nil ? true : defaults.bool(forKey: Keys.playOtherHand)
        let storedVisible = defaults.integer(forKey: Keys.visibleWhiteKeys)
        visibleWhiteKeys = storedVisible >= 7 ? min(storedVisible, 36) : 15
        lowestWhiteKey = KeyboardLayout.whiteIndex(of: 53)
        autoZoom = defaults.object(forKey: Keys.autoZoom) == nil ? true : defaults.bool(forKey: Keys.autoZoom)
        recognitionEnabled = defaults.bool(forKey: Keys.recognitionEnabled)
        recognitionServerURL = defaults.string(forKey: Keys.recognitionURL) ?? ""
        // A launch argument can supply the token for automated runs; it isn't persisted.
        recognitionToken = defaults.string(forKey: Keys.recognitionToken) ?? Keychain.read(Keys.recognitionToken) ?? ""

        lesson.handMode = LessonEngine.HandMode(rawValue: defaults.string(forKey: Keys.handMode) ?? "") ?? .right
        lesson.practiceMode = LessonEngine.PracticeMode(rawValue: defaults.string(forKey: Keys.practiceMode) ?? "") ?? .wait
        let storedScale = defaults.double(forKey: Keys.tempoScale)
        lesson.tempoScale = storedScale > 0 ? min(max(storedScale, 0.25), 1.5) : 0.7
    }

    /// Accepts "2", "D", "D#", "Eb", "E♭" ...
    static func pitchClass(from text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let number = Int(text) { return MIDINote.pitchClass(number) }
        let normalized = text.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
        let upper = normalized.prefix(1).uppercased() + normalized.dropFirst()
        return MIDINote.sharpNames.firstIndex(of: upper) ?? MIDINote.flatNames.firstIndex(of: upper)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        AudioSessionConfigurator.configure(recording: false)
        synth.start()

        lesson.onStepChanged = { [weak self] in
            guard let self else { return }
            self.stepAttackFloor = self.latestAttack
            self.pendingChordWrong = nil
            self.revealExpectedKeys()
        }
        lesson.onAccompaniment = { [weak self] note, duration in
            guard let self, self.playOtherHand, self.soundEnabled else { return }
            self.synth.play(note.midi, duration: duration, velocity: 0.55)
            self.mic.suppress(for: min(duration, 1) + 0.3)
        }
        mic.onNote = { [weak self] midi, attack in self?.handleMicNote(midi, attack: attack) }
        mic.onChroma = { [weak self] chroma, attack, age in self?.handleMicChroma(chroma, attack: attack, framesSinceAttack: age) }

        Task {
            let initial = library.entry(id: defaults.string(forKey: Keys.song) ?? "") ?? SongLibrary.bundledSongs[0]
            await select(initial)
            await applyLaunchOptions()
        }
    }

    func select(_ entry: SongEntry) async {
        isLoadingSong = true
        defer { isLoadingSong = false }
        do {
            let score = try await library.loadScore(entry)
            currentSong = entry
            defaults.set(entry.id, forKey: Keys.song)
            lesson.load(score)
            fitKeyboardToSong()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(_ url: URL) async {
        do {
            let entry = try await library.importFile(at: url)
            await select(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sheet music recognition

    /// Uploads photos or a PDF to the recognition server and opens the returned score.
    func recognize(_ uploads: [RecognitionUpload], name: String) {
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in await self?.runRecognition(uploads, name: name) }
    }

    func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionStatus = .idle
    }

    func checkRecognitionServer() async -> String {
        do {
            let client = try RecognitionClient(serverURL: recognitionServerURL, token: recognitionToken)
            let health = try await client.health()
            return "Connected: \(health.engine.name) \(health.engine.version) (\(health.status))"
        } catch {
            return error.localizedDescription
        }
    }

    private func runRecognition(_ uploads: [RecognitionUpload], name: String) async {
        guard isRecognitionReady else {
            errorMessage = RecognitionError.notConfigured.errorDescription
            return
        }
        recognitionStatus = .working(RecognitionProgress(phase: .uploading), name: name)
        let started = Date()
        do {
            let client = try RecognitionClient(serverURL: recognitionServerURL, token: recognitionToken)
            let result = try await client.recognize(uploads) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .working = self.recognitionStatus else { return }
                    self.recognitionStatus = .working(progress, name: name)
                }
            }
            let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).musicxml")
            try result.musicXML.write(to: file, options: .atomic)
            var seen = Set<String>()
            let notes = result.warnings.map(\.userMessage).filter { seen.insert($0).inserted }
            let entry = try await library.importFile(at: file, sourceLabel: "Scanned", notes: notes)
            recognitionStatus = .idle
            await select(entry)
            if isLibraryPresented {
                isLibraryPresented = false
                try? await Task.sleep(for: .milliseconds(700))
            }
            importNotes = notes
            log.info("Recognized \(name, privacy: .public) in \(Int(Date().timeIntervalSince(started)), privacy: .public) s: \(self.lesson.score?.notes.count ?? 0, privacy: .public) notes, warnings=\(result.warnings.map(\.code).joined(separator: ","), privacy: .public)")
        } catch {
            recognitionStatus = .idle
            if Task.isCancelled || (error as? RecognitionError) == .canceled { return }
            log.error("Recognition failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func setHandMode(_ mode: LessonEngine.HandMode) {
        lesson.handMode = mode
        defaults.set(mode.rawValue, forKey: Keys.handMode)
        fitKeyboardToSong()
    }

    func setPracticeMode(_ mode: LessonEngine.PracticeMode) {
        lesson.practiceMode = mode
        defaults.set(mode.rawValue, forKey: Keys.practiceMode)
    }

    func setTempoScale(_ scale: Double) {
        lesson.stopPlayback()
        lesson.tempoScale = min(max(scale, 0.25), 1.5)
        defaults.set(lesson.tempoScale, forKey: Keys.tempoScale)
    }

    // MARK: Input

    func keyDown(_ midi: Int) {
        pressedKeys.insert(midi)
        if soundEnabled {
            synth.noteOn(midi)
            mic.suppress(for: 0.8)
        }
        process(midi, source: .touch)
    }

    func keyUp(_ midi: Int) {
        pressedKeys.remove(midi)
        synth.noteOff(midi)
    }

    /// Plays the notes the learner should play next.
    func playExpected() {
        let notes = lesson.remainingNotes
        guard !notes.isEmpty else { return }
        for note in notes { synth.play(note.midi, duration: 0.7) }
        mic.suppress(for: 1.2)
    }

    /// Keeps strike bookkeeping consistent when a new listening session restarts the strike count.
    private func noteAttack(_ attack: Int) {
        if attack < latestAttack {
            latestAttack = 0
            stepAttackFloor = 0
            chordAttack = nil
        }
        latestAttack = max(latestAttack, attack)
    }

    private func handleMicNote(_ midi: Int, attack: Int) {
        noteAttack(attack)
        // A strike that already completed a chord step can still produce a (often sub-octave)
        // pitch reading a moment later; it belongs to that chord, not to the next step.
        if attack == chordAttack {
            logInput("mic", played: "\(midi)", result: .ignored, stepBefore: lesson.currentIndex, expected: lesson.remainingNotes)
            return
        }
        let result = process(midi, source: .microphone)
        if result == .ignored, lesson.isWrongCandidateInChord(midi) {
            pendingChordWrong = (midi, attack)
        }
    }

    @discardableResult
    private func process(_ midi: Int, source: LessonEngine.InputSource) -> LessonEngine.InputResult {
        let completedBefore = lesson.currentStep?.notes ?? []
        let stepBefore = lesson.currentIndex
        let remainingBefore = lesson.remainingNotes
        let result = lesson.handle(midi: midi, source: source, octaveTolerant: source == .microphone && micOctaveTolerant)
        switch result {
        case .correct:
            let target = completedBefore.first { LessonEngine.matches(midi, $0.midi, octaveTolerant: source == .microphone && micOctaveTolerant) }
            flash(target?.midi ?? midi, .correct)
        case .wrong:
            flash(midi, .wrong)
        case .ignored:
            break
        }
        logInput(source == .touch ? "touch" : "mic", played: "\(midi)", result: result, stepBefore: stepBefore, expected: remainingBefore)
        return result
    }

    private func handleMicChroma(_ chroma: [Float], attack: Int, framesSinceAttack: Int) {
        noteAttack(attack)
        let notes = lesson.currentStep?.notes ?? []
        let stepBefore = lesson.currentIndex
        guard attack > stepAttackFloor else { return }
        if lesson.handleChroma(chroma) {
            chordAttack = attack
            pendingChordWrong = nil
            for note in notes { flash(note.midi, .correct) }
            let heard = ChromaAnalyzer.activePitchClasses(chroma, level: 0.3).map(String.init).joined(separator: "+")
            logInput("mic-chord", played: "pc\(heard)", result: .correct(completedStep: true), stepBefore: stepBefore, expected: notes)
            return
        }
        guard let pending = pendingChordWrong else { return }
        if pending.attack != attack || framesSinceAttack > MicController.chromaWindowFrames {
            pendingChordWrong = nil
        } else if framesSinceAttack >= 4, lesson.chromaConfirmsWrong(pending.midi, chroma: chroma) {
            // ~90 ms after the strike the new sound dominates the chroma window.
            pendingChordWrong = nil
            let remaining = lesson.remainingNotes
            lesson.registerWrong(played: pending.midi)
            flash(pending.midi, .wrong)
            logInput("mic-chord", played: "\(pending.midi)", result: .wrong, stepBefore: stepBefore, expected: remaining)
        }
    }

    /// One parseable line per input, used by the end-to-end test harness (`tools/e2e`).
    private func logInput(_ source: String, played: String, result: LessonEngine.InputResult, stepBefore: Int, expected: [ScoreNote]) {
        let outcome: String
        switch result {
        case .correct(let completed): outcome = completed ? "advance" : "partial"
        case .wrong: outcome = "wrong"
        case .ignored: outcome = "ignored"
        }
        let expectedText = expected.map { "\($0.midi)\($0.hand == .right ? "R" : "L")\($0.finger.map { "f\($0)" } ?? "")" }.joined(separator: ",")
        let label = expected.map { naming.label(forMIDI: $0.midi, spelling: $0.spelling).fullText }.joined(separator: "+")
        log.info("LESSON source=\(source, privacy: .public) played=\(played, privacy: .public) result=\(outcome, privacy: .public) step=\(stepBefore, privacy: .public)->\(self.lesson.currentIndex, privacy: .public)/\(self.lesson.steps.count, privacy: .public) expected=\(expectedText, privacy: .public) labels=\(label, privacy: .public)")
    }

    private func flash(_ midi: Int, _ kind: KeyFlash.Kind) {
        flashToken += 1
        let token = flashToken
        flashes[midi] = KeyFlash(kind: kind, token: token)
        guard !stickyFlashes else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(kind == .wrong ? 900 : 450))
            if self?.flashes[midi]?.token == token { self?.flashes[midi] = nil }
        }
    }

    // MARK: Keyboard

    func keyState(for midi: Int) -> KeyVisualState {
        var state = KeyVisualState()
        if let step = lesson.currentStep, let note = step.notes.first(where: { $0.midi == midi }) {
            if lesson.satisfiedNoteIDs.contains(note.id) {
                state.isSatisfied = true
            } else {
                state.expectedHand = note.hand
                state.finger = showFingerNumbers ? note.finger : nil
            }
        }
        state.isPressed = pressedKeys.contains(midi)
        state.flash = flashes[midi]?.kind
        state.isHeard = mic.heardNote == midi
        state.isTonic = notation.isSargam && MIDINote.pitchClass(midi) == saPitchClass
        return state
    }

    func keyLabel(for midi: Int) -> NoteLabel? {
        switch keyLabelMode {
        case .off: return nil
        case .white where MIDINote.isBlack(midi): return nil
        default: return naming.label(forMIDI: midi)
        }
    }

    func clampedLowestWhite(_ value: Int) -> Int {
        let highest = KeyboardLayout.highestPianoWhite - shownWhiteKeys + 1
        return min(max(value, KeyboardLayout.lowestPianoWhite), max(highest, KeyboardLayout.lowestPianoWhite))
    }

    func shiftKeyboard(by whiteKeys: Int) {
        lowestWhiteKey = clampedLowestWhite(lowestWhiteKey + whiteKeys)
    }

    /// White-key columns a key occupies; a black key straddles the white keys on both sides.
    static func whiteColumns(of midi: Int) -> ClosedRange<Int> {
        let column = KeyboardLayout.whiteIndex(of: midi)
        return MIDINote.isBlack(midi) ? column...(column + 1) : column...column
    }

    /// Leftmost white key that centres `columns` in the visible window.
    private func centeredStart(_ columns: ClosedRange<Int>) -> Int {
        columns.lowerBound - (shownWhiteKeys - columns.count) / 2
    }

    /// Centres the keyboard on the notes the current hand mode needs, zooming out (up to
    /// `maxAutoZoomKeys`) when the song is wider than the preferred number of keys.
    func fitKeyboardToSong() {
        let columns = lesson.steps.flatMap { $0.notes.map { Self.whiteColumns(of: $0.midi) } }
        guard let lowWhite = columns.map(\.lowerBound).min(), let highWhite = columns.map(\.upperBound).max() else {
            songWhiteKeys = nil
            return
        }
        let span = highWhite - lowWhite + 1
        songWhiteKeys = autoZoom && span > visibleWhiteKeys ? min(span + 1, Self.maxAutoZoomKeys) : nil
        lowestWhiteKey = clampedLowestWhite(lowestWhiteKey)
        if span <= shownWhiteKeys {
            lowestWhiteKey = clampedLowestWhite(centeredStart(lowWhite...highWhite))
        } else {
            revealExpectedKeys()
        }
    }

    /// Scrolls the keyboard if the next notes are off-screen. The views animate the change.
    func revealExpectedKeys() {
        let current = lesson.remainingNotes.map { Self.whiteColumns(of: $0.midi) }
        guard let lowWhite = current.map(\.lowerBound).min(), let highWhite = current.map(\.upperBound).max() else { return }
        let visibleHigh = lowestWhiteKey + shownWhiteKeys - 1
        guard lowWhite < lowestWhiteKey || highWhite > visibleHigh else { return }

        var rangeLow = lowWhite
        var rangeHigh = highWhite
        for step in lesson.upcomingSteps(6) {
            for note in step.notes {
                let columns = Self.whiteColumns(of: note.midi)
                if max(rangeHigh, columns.upperBound) - min(rangeLow, columns.lowerBound) + 1 <= shownWhiteKeys {
                    rangeLow = min(rangeLow, columns.lowerBound)
                    rangeHigh = max(rangeHigh, columns.upperBound)
                }
            }
        }
        lowestWhiteKey = clampedLowestWhite(centeredStart(rangeLow...rangeHigh))
    }

    // MARK: Launch options (used for screenshots and automated checks)

    /// Supported launch arguments, besides any settings key (e.g. `-notation carnatic -saPitchClass D`):
    /// `-importPath <file>`, `-recognizeFile <pdf or image>`, `-exportLessonSteps <json path>`,
    /// `-micFile <audio file>` (feeds the file through the microphone pipeline in real time),
    /// `-demoSteps <n>`, `-demoWrongNote <midi>`, `-demoPressNote <midi>`, `-autoPlay YES` (tempo mode),
    /// `-openLibrary YES`, `-openSettings YES`, `-startMic YES`.
    private func applyLaunchOptions() async {
        if let path = defaults.string(forKey: "importPath") {
            await importFile(URL(fileURLWithPath: path))
        }
        if let path = defaults.string(forKey: "recognizeFile") {
            do {
                let url = URL(fileURLWithPath: path)
                recognize(try RecognitionPages.uploads(fromFile: url), name: url.deletingPathExtension().lastPathComponent)
                await recognitionTask?.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if let path = defaults.string(forKey: "exportLessonSteps") {
            exportLessonSteps(to: URL(fileURLWithPath: path))
        }
        let steps = defaults.integer(forKey: "demoSteps")
        if steps > 0 {
            try? await Task.sleep(for: .milliseconds(800))
            for _ in 0..<steps {
                for note in lesson.remainingNotes { process(note.midi, source: .touch) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let wrong = defaults.integer(forKey: "demoWrongNote")
        if wrong > 0 {
            stickyFlashes = true
            process(wrong, source: .touch)
        }
        let pressed = defaults.integer(forKey: "demoPressNote")
        if pressed > 0 {
            stickyFlashes = true
            pressedKeys.insert(pressed)
            process(pressed, source: .touch)
        }
        if defaults.bool(forKey: "autoPlay") { lesson.play() }
        if defaults.bool(forKey: "openLibrary") { isLibraryPresented = true }
        if defaults.bool(forKey: "openSettings") { isSettingsPresented = true }
        if defaults.bool(forKey: "startMic") { await mic.start() }
        if let path = defaults.string(forKey: "micFile") {
            try? await Task.sleep(for: .milliseconds(defaults.integer(forKey: "micFileDelayMs")))
            await mic.startFile(URL(fileURLWithPath: path))
        }
    }

    /// Writes the current lesson's steps as JSON so test tools can build a matching performance.
    private func exportLessonSteps(to url: URL) {
        struct ExportedNote: Encodable { var midi: Int; var hand: String; var finger: Int?; var label: String }
        struct ExportedStep: Encodable { var index: Int; var time: Double; var measure: Int; var notes: [ExportedNote] }
        struct Export: Encodable { var title: String; var handMode: String; var notation: String; var sa: Int; var steps: [ExportedStep] }
        let export = Export(
            title: lesson.score?.title ?? "",
            handMode: lesson.handMode.rawValue,
            notation: notation.rawValue,
            sa: saPitchClass,
            steps: lesson.steps.map { step in
                ExportedStep(index: step.id, time: step.time, measure: step.measure, notes: step.notes.map {
                    ExportedNote(midi: $0.midi, hand: $0.hand.rawValue, finger: $0.finger,
                                 label: naming.label(forMIDI: $0.midi, spelling: $0.spelling).fullText)
                })
            }
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: url, options: .atomic)
            log.info("Exported \(self.lesson.steps.count, privacy: .public) lesson steps to \(url.path, privacy: .public)")
        } catch {
            log.error("Couldn't export lesson steps: \(error.localizedDescription, privacy: .public)")
        }
    }
}

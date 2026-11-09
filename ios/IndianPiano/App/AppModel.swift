import Foundation
import Observation
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
            lowestWhiteKey = clampedLowestWhite(lowestWhiteKey)
        }
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var flashToken = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stickyFlashes = false

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

        lesson.onStepChanged = { [weak self] in self?.revealExpectedKeys() }
        lesson.onAccompaniment = { [weak self] note, duration in
            guard let self, self.playOtherHand, self.soundEnabled else { return }
            self.synth.play(note.midi, duration: duration, velocity: 0.55)
            self.mic.suppress(for: min(duration, 1) + 0.3)
        }
        mic.onNote = { [weak self] midi in self?.process(midi, source: .microphone) }
        mic.onChroma = { [weak self] chroma in self?.handleMicChroma(chroma) }

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

    private func process(_ midi: Int, source: LessonEngine.InputSource) {
        let completedBefore = lesson.currentStep?.notes ?? []
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
    }

    private func handleMicChroma(_ chroma: [Float]) {
        let notes = lesson.currentStep?.notes ?? []
        if lesson.handleChroma(chroma) {
            for note in notes { flash(note.midi, .correct) }
        }
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
        let highest = KeyboardLayout.highestPianoWhite - visibleWhiteKeys + 1
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
        columns.lowerBound - (visibleWhiteKeys - columns.count) / 2
    }

    /// Centres the keyboard on the notes the current hand mode needs, if they fit.
    func fitKeyboardToSong() {
        let columns = lesson.steps.flatMap { $0.notes.map { Self.whiteColumns(of: $0.midi) } }
        guard let lowWhite = columns.map(\.lowerBound).min(), let highWhite = columns.map(\.upperBound).max() else { return }
        if highWhite - lowWhite + 1 <= visibleWhiteKeys {
            lowestWhiteKey = clampedLowestWhite(centeredStart(lowWhite...highWhite))
        } else {
            revealExpectedKeys()
        }
    }

    /// Scrolls the keyboard if the next notes are off-screen. The views animate the change.
    func revealExpectedKeys() {
        let current = lesson.remainingNotes.map { Self.whiteColumns(of: $0.midi) }
        guard let lowWhite = current.map(\.lowerBound).min(), let highWhite = current.map(\.upperBound).max() else { return }
        let visibleHigh = lowestWhiteKey + visibleWhiteKeys - 1
        guard lowWhite < lowestWhiteKey || highWhite > visibleHigh else { return }

        var rangeLow = lowWhite
        var rangeHigh = highWhite
        for step in lesson.upcomingSteps(6) {
            for note in step.notes {
                let columns = Self.whiteColumns(of: note.midi)
                if max(rangeHigh, columns.upperBound) - min(rangeLow, columns.lowerBound) + 1 <= visibleWhiteKeys {
                    rangeLow = min(rangeLow, columns.lowerBound)
                    rangeHigh = max(rangeHigh, columns.upperBound)
                }
            }
        }
        lowestWhiteKey = clampedLowestWhite(centeredStart(rangeLow...rangeHigh))
    }

    // MARK: Launch options (used for screenshots and automated checks)

    /// Supported launch arguments, besides any settings key (e.g. `-notation carnatic -saPitchClass D`):
    /// `-importPath <file>`, `-demoSteps <n>`, `-demoWrongNote <midi>`, `-demoPressNote <midi>`,
    /// `-autoPlay YES` (tempo mode), `-openLibrary YES`, `-openSettings YES`, `-startMic YES`.
    private func applyLaunchOptions() async {
        if let path = defaults.string(forKey: "importPath") {
            await importFile(URL(fileURLWithPath: path))
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
    }
}

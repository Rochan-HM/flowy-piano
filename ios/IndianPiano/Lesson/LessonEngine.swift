import Foundation
import Observation
import QuartzCore

/// Drives a practice session over a score.
///
/// * Wait mode: the next note(s) are highlighted and the lesson only advances once they're played.
/// * Tempo mode: a playhead runs at a fraction of the written tempo; notes played within the hit
///   window count, notes the playhead passes count as missed. The hand you're not practising can
///   be played by the app as accompaniment.
/// * Listen mode: the app plays the song from the current step at the same speed, lighting the
///   keys as they sound. Input isn't graded; stopping returns to the step the demo started from.
@MainActor
@Observable
final class LessonEngine {
    enum HandMode: String, CaseIterable, Identifiable {
        case right, left, both

        var id: String { rawValue }
        var title: String {
            switch self {
            case .right: return "Right hand"
            case .left: return "Left hand"
            case .both: return "Both hands"
            }
        }
        var shortTitle: String {
            switch self {
            case .right: return "RH"
            case .left: return "LH"
            case .both: return "Both"
            }
        }
        var hands: Set<Hand> {
            switch self {
            case .right: return [.right]
            case .left: return [.left]
            case .both: return [.right, .left]
            }
        }
    }

    enum PracticeMode: String, CaseIterable, Identifiable {
        case wait, tempo, listen

        var id: String { rawValue }
        var title: String {
            switch self {
            case .wait: return "Wait"
            case .tempo: return "Tempo"
            case .listen: return "Listen"
            }
        }
    }

    enum InputSource: Equatable {
        case touch
        case microphone
    }

    enum InputResult: Equatable {
        case correct(completedStep: Bool)
        case wrong
        case ignored
    }

    enum StepResult: Equatable {
        case perfect
        case withMistakes
        case missed
    }

    enum Feedback: Equatable {
        case correct(played: Int)
        case wrong(played: Int, expected: [ScoreNote])
        case missed(expected: [ScoreNote])
        case finished
    }

    /// Notes that start together and must all be played before moving on.
    struct Step: Identifiable, Equatable {
        let id: Int
        let notes: [ScoreNote]
        /// Onset in seconds at the written tempo.
        let time: TimeInterval
        let measure: Int
    }

    static let chordTolerance: TimeInterval = 0.035

    private(set) var score: Score?
    var handMode: HandMode = .right {
        didSet { if handMode != oldValue { rebuildSteps() } }
    }
    var practiceMode: PracticeMode = .wait {
        didSet {
            guard practiceMode != oldValue else { return }
            if practiceMode == .listen || oldValue == .listen { keepPlaceAfterSwitchingMode() } else { restart() }
        }
    }
    /// Playback speed in tempo and listen mode as a fraction of the written tempo.
    var tempoScale: Double = 0.7
    /// Whether Listen mode also plays the hand that isn't being practised (softer).
    var listenWithOtherHand = true

    private(set) var steps: [Step] = []
    private(set) var currentIndex = 0
    private(set) var satisfiedNoteIDs: Set<Int> = []
    private(set) var results: [Int: StepResult] = [:]
    private(set) var feedback: Feedback?
    private(set) var feedbackCount = 0
    private(set) var correctCount = 0
    private(set) var wrongCount = 0
    private(set) var missedCount = 0
    private(set) var isPlaying = false
    private(set) var playhead: TimeInterval = 0
    /// Listen mode: the step the demo started from, while it plays or is paused.
    private(set) var demoOrigin: Int?
    /// Listen mode: notes of the practised hands sounding at the playhead.
    private(set) var soundingNotes: [ScoreNote] = []

    let leadIn: TimeInterval = 2
    let demoLeadIn: TimeInterval = 1
    let hitWindow: TimeInterval = 0.4
    /// How far ahead demo notes go to the synth, which starts them on their exact sample.
    static let scheduleAhead: TimeInterval = 0.15

    @ObservationIgnored var clock: () -> TimeInterval = { CACurrentMediaTime() }
    /// Called in tempo mode for notes of the hand that isn't being practised: (note, duration).
    @ObservationIgnored var onAccompaniment: ((ScoreNote, TimeInterval) -> Void)?
    /// Called in listen mode, up to `scheduleAhead` early, with each note on/off and its clock time.
    @ObservationIgnored var onDemoEvent: ((DemoEvent, TimeInterval) -> Void)?
    /// Called when a demo stops or pauses: notes handed over but not yet started must be dropped.
    @ObservationIgnored var onDemoStop: (() -> Void)?
    @ObservationIgnored var onStepChanged: (() -> Void)?
    @ObservationIgnored var onPlaybackChanged: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playStart: TimeInterval = 0
    @ObservationIgnored private var accompaniment: [ScoreNote] = []
    @ObservationIgnored private var accompanimentCursor = 0
    @ObservationIgnored private var stepHadMistake = false
    @ObservationIgnored private var notesByID: [Int: ScoreNote] = [:]
    @ObservationIgnored private var demoEvents: [DemoEvent] = []
    @ObservationIgnored private var demoScheduleCursor = 0
    @ObservationIgnored private var demoVisualCursor = 0
    @ObservationIgnored private var soundingIDs: Set<Int> = []

    /// Clock time of the start of the song while playing, e.g. for the metronome.
    var songStartTime: TimeInterval? { isPlaying ? playStart : nil }

    var currentStep: Step? { steps.indices.contains(currentIndex) ? steps[currentIndex] : nil }
    var isFinished: Bool { !steps.isEmpty && currentIndex >= steps.count }
    var remainingNotes: [ScoreNote] { currentStep?.notes.filter { !satisfiedNoteIDs.contains($0.id) } ?? [] }
    var availableHands: Set<Hand> { score?.hands ?? [] }
    var progress: Double { steps.isEmpty ? 0 : Double(min(currentIndex, steps.count)) / Double(steps.count) }

    var accuracy: Double? {
        let attempts = correctCount + wrongCount + missedCount
        return attempts == 0 ? nil : Double(correctCount) / Double(attempts)
    }

    func upcomingSteps(_ count: Int) -> ArraySlice<Step> {
        guard currentIndex < steps.count else { return [] }
        return steps[currentIndex..<min(steps.count, currentIndex + count)]
    }

    // MARK: - Loading

    func load(_ score: Score?) {
        stopPlayback()
        self.score = score
        notesByID = Dictionary((score?.notes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let score, handMode.hands.isDisjoint(with: score.hands) {
            handMode = score.hands.contains(.right) ? .right : .left
        }
        rebuildSteps()
    }

    func rebuildSteps() {
        if let score {
            steps = Self.makeSteps(from: score.notes, hands: handMode.hands)
            accompaniment = score.notes.filter { !handMode.hands.contains($0.hand) }
        } else {
            steps = []
            accompaniment = []
        }
        restart()
    }

    static func makeSteps(from notes: [ScoreNote], hands: Set<Hand>) -> [Step] {
        let selected = notes.filter { hands.contains($0.hand) }.sorted {
            $0.onsetSeconds == $1.onsetSeconds ? $0.midi < $1.midi : $0.onsetSeconds < $1.onsetSeconds
        }
        var steps: [Step] = []
        var group: [ScoreNote] = []

        func flush() {
            guard let first = group.first else { return }
            var seen = Set<Int>()
            let unique = group.filter { seen.insert($0.midi).inserted }.sorted { $0.midi < $1.midi }
            steps.append(Step(id: steps.count, notes: unique, time: first.onsetSeconds, measure: first.measure))
            group = []
        }

        for note in selected {
            if let first = group.first, note.onsetSeconds - first.onsetSeconds > chordTolerance { flush() }
            group.append(note)
        }
        flush()
        return steps
    }

    func restart() {
        stopPlayback()
        demoOrigin = nil
        currentIndex = 0
        satisfiedNoteIDs = []
        results = [:]
        feedback = nil
        correctCount = 0
        wrongCount = 0
        missedCount = 0
        stepHadMistake = false
        playhead = -leadIn
        accompanimentCursor = 0
        onStepChanged?()
    }

    /// Switching to or from Listen keeps the step (where the demo started), so the learner can
    /// practise the passage they just heard.
    private func keepPlaceAfterSwitchingMode() {
        stopPlayback()
        if let origin = demoOrigin, steps.indices.contains(origin) { currentIndex = origin }
        demoOrigin = nil
        if isFinished {
            restart()
            return
        }
        satisfiedNoteIDs = []
        stepHadMistake = false
        feedback = nil
        playhead = (currentStep.map(stepTime) ?? 0) - leadIn
        syncAccompanimentCursor()
        onStepChanged?()
    }

    // MARK: - Input

    @discardableResult
    func handle(midi: Int, source: InputSource, octaveTolerant: Bool = false) -> InputResult {
        guard let step = currentStep, practiceMode != .listen else { return .ignored }
        if practiceMode == .tempo && !isPlaying { return .ignored }

        let remaining = remainingNotes
        let pitchClasses = Set(step.notes.map { MIDINote.pitchClass($0.midi) })

        // Octave doublings (e.g. C3 + C4) can't be told apart by a single microphone reading.
        if source == .microphone, step.notes.count > 1, pitchClasses == [MIDINote.pitchClass(midi)] {
            satisfiedNoteIDs.formUnion(remaining.map(\.id))
            correctCount += max(1, remaining.count)
            setFeedback(.correct(played: midi))
            completeStep()
            return .correct(completedStep: true)
        }

        if let match = remaining.first(where: { Self.matches(midi, $0.midi, octaveTolerant: octaveTolerant) }) {
            satisfiedNoteIDs.insert(match.id)
            correctCount += 1
            setFeedback(.correct(played: midi))
            if step.notes.allSatisfy({ satisfiedNoteIDs.contains($0.id) }) {
                completeStep()
                return .correct(completedStep: true)
            }
            return .correct(completedStep: false)
        }

        if step.notes.contains(where: { Self.matches(midi, $0.midi, octaveTolerant: octaveTolerant) }) {
            return .ignored
        }
        if source == .microphone {
            // A single pitch reading of a chord is unreliable, and the previous note may still be ringing.
            if step.notes.count > 1 { return .ignored }
            if currentIndex > 0, steps[currentIndex - 1].notes.contains(where: { Self.matches(midi, $0.midi, octaveTolerant: true) }) {
                return .ignored
            }
        }

        wrongCount += 1
        stepHadMistake = true
        setFeedback(.wrong(played: midi, expected: remaining))
        return .wrong
    }

    /// Microphone chord recognition for steps with several pitch classes.
    @discardableResult
    func handleChroma(_ chroma: [Float]) -> Bool {
        guard let step = currentStep, practiceMode != .listen, !(practiceMode == .tempo && !isPlaying) else { return false }
        let expected = Set(step.notes.map { MIDINote.pitchClass($0.midi) })
        guard expected.count > 1, ChromaAnalyzer.matches(chroma, expected: expected) else { return false }
        let remaining = remainingNotes
        satisfiedNoteIDs.formUnion(remaining.map(\.id))
        correctCount += remaining.count
        setFeedback(.correct(played: step.notes.last?.midi ?? 60))
        completeStep()
        return true
    }

    /// Whether a single-pitch microphone reading during a chord step may be a wrong note, rather than
    /// a chord member heard at another octave or the previous step still ringing. Confirm it with
    /// `chromaConfirmsWrong` before calling `registerWrong`.
    func isWrongCandidateInChord(_ midi: Int) -> Bool {
        guard let step = currentStep, step.notes.count > 1 else { return false }
        let pitchClass = MIDINote.pitchClass(midi)
        if step.notes.contains(where: { MIDINote.pitchClass($0.midi) == pitchClass }) { return false }
        if currentIndex > 0, steps[currentIndex - 1].notes.contains(where: { MIDINote.pitchClass($0.midi) == pitchClass }) {
            return false
        }
        return true
    }

    /// The chroma of a key strike is dominated by `midi`'s pitch class and doesn't contain the chord.
    func chromaConfirmsWrong(_ midi: Int, chroma: [Float]) -> Bool {
        guard let step = currentStep, chroma.count == 12 else { return false }
        let expected = Set(step.notes.map { MIDINote.pitchClass($0.midi) })
        return chroma[MIDINote.pitchClass(midi)] >= 0.6 && !ChromaAnalyzer.matches(chroma, expected: expected)
    }

    func registerWrong(played midi: Int) {
        guard currentStep != nil, practiceMode != .listen, !(practiceMode == .tempo && !isPlaying) else { return }
        wrongCount += 1
        stepHadMistake = true
        setFeedback(.wrong(played: midi, expected: remainingNotes))
    }

    static func matches(_ played: Int, _ expected: Int, octaveTolerant: Bool) -> Bool {
        played == expected || (octaveTolerant && MIDINote.pitchClass(played) == MIDINote.pitchClass(expected))
    }

    // MARK: - Navigation

    func skipStep() {
        guard currentStep != nil else { return }
        if practiceMode == .listen {
            if currentIndex + 1 < steps.count { seekDemo { currentIndex += 1 } }
        } else {
            moveToNextStep()
        }
    }

    func previousStep() {
        guard currentIndex > 0 else { return }
        if practiceMode == .listen {
            seekDemo { currentIndex -= 1 }
            return
        }
        stopPlayback()
        currentIndex -= 1
        results[currentIndex] = nil
        satisfiedNoteIDs = []
        stepHadMistake = false
        feedback = nil
        playhead = (steps[currentIndex].time / tempoScale) - leadIn
        syncAccompanimentCursor()
        onStepChanged?()
    }

    /// Moves to another step in listen mode; a playing demo carries on from there.
    private func seekDemo(_ move: () -> Void) {
        let resume = isPlaying
        stopPlayback()
        demoOrigin = nil
        move()
        onStepChanged?()
        if resume { play() }
    }

    private func completeStep() {
        results[currentIndex] = stepHadMistake ? .withMistakes : .perfect
        moveToNextStep()
    }

    private func moveToNextStep() {
        currentIndex += 1
        satisfiedNoteIDs = []
        stepHadMistake = false
        if currentIndex >= steps.count {
            setFeedback(.finished)
            stopPlayback()
        }
        onStepChanged?()
    }

    private func setFeedback(_ value: Feedback) {
        feedback = value
        feedbackCount += 1
    }

    // MARK: - Tempo and listen mode

    func stepTime(_ step: Step) -> TimeInterval { step.time / tempoScale }

    func togglePlayback() { isPlaying ? stopPlayback() : play() }

    /// Starts tempo mode, or the demo in listen mode: from the current step, or from where it was paused.
    func play() {
        guard practiceMode != .wait, !steps.isEmpty, !isPlaying else { return }
        if practiceMode == .listen {
            prepareDemo()
        } else if isFinished {
            restart()
        }
        isPlaying = true
        playStart = clock() - playhead
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onPlaybackChanged?()
        if practiceMode == .listen { advancePlayhead(to: playhead) }
    }

    /// Stops the playhead where it is (a pause in listen mode: `play()` resumes the demo).
    func stopPlayback() {
        timer?.invalidate()
        timer = nil
        soundingIDs = []
        if !soundingNotes.isEmpty { soundingNotes = [] }
        guard isPlaying else { return }
        if !demoEvents.isEmpty {
            playhead = clock() - playStart
            demoEvents = []
            onDemoStop?()
        }
        isPlaying = false
        onPlaybackChanged?()
    }

    /// Ends the demo and goes back to the step it started from.
    func stopDemo() {
        stopPlayback()
        guard let origin = demoOrigin else { return }
        demoOrigin = nil
        if steps.indices.contains(origin) { currentIndex = origin }
        onStepChanged?()
    }

    /// Changes the speed, keeping the musical position; a playing demo carries on at the new speed.
    func changeTempoScale(to scale: Double) {
        let resume = practiceMode == .listen && isPlaying
        stopPlayback()
        if playhead > 0 { playhead *= tempoScale / scale }
        tempoScale = scale
        syncAccompanimentCursor()
        if resume { play() }
    }

    private func prepareDemo() {
        if isFinished {
            currentIndex = 0
            demoOrigin = nil
        }
        let start: TimeInterval
        if let origin = demoOrigin {
            start = max(playhead, stepTime(steps[origin]))
        } else {
            demoOrigin = currentIndex
            start = stepTime(steps[currentIndex])
            playhead = start - demoLeadIn
        }
        demoEvents = DemoSchedule.events(notes: score?.notes ?? [], hands: handMode.hands, accompaniment: listenWithOtherHand,
                                         tempoScale: tempoScale, from: start)
        demoScheduleCursor = 0
        demoVisualCursor = 0
        soundingIDs = []
    }

    private func syncAccompanimentCursor() {
        accompanimentCursor = accompaniment.firstIndex { $0.onsetSeconds / tempoScale >= playhead } ?? accompaniment.count
    }

    private func tick() { advancePlayhead(to: clock() - playStart) }

    /// Moves the playhead. Tempo mode marks passed steps as missed and fires accompaniment;
    /// listen mode hands upcoming notes to the synth and follows along.
    func advancePlayhead(to time: TimeInterval) {
        playhead = time
        if practiceMode == .listen { return advanceDemo(to: time) }
        while let step = currentStep, time > stepTime(step) + hitWindow {
            results[currentIndex] = satisfiedNoteIDs.isEmpty ? .missed : .withMistakes
            missedCount += 1
            setFeedback(.missed(expected: remainingNotes))
            moveToNextStep()
        }
        while accompanimentCursor < accompaniment.count,
              accompaniment[accompanimentCursor].onsetSeconds / tempoScale <= time {
            let note = accompaniment[accompanimentCursor]
            onAccompaniment?(note, note.durationSeconds / tempoScale)
            accompanimentCursor += 1
        }
    }

    private func advanceDemo(to time: TimeInterval) {
        guard isPlaying else { return }
        while demoScheduleCursor < demoEvents.count, demoEvents[demoScheduleCursor].time <= time + Self.scheduleAhead {
            let event = demoEvents[demoScheduleCursor]
            onDemoEvent?(event, playStart + event.time)
            demoScheduleCursor += 1
        }

        var soundingChanged = false
        while demoVisualCursor < demoEvents.count, demoEvents[demoVisualCursor].time <= time {
            let event = demoEvents[demoVisualCursor]
            if !event.isAccompaniment {
                if event.kind == .noteOn { soundingIDs.insert(event.noteID) } else { soundingIDs.remove(event.noteID) }
                soundingChanged = true
            }
            demoVisualCursor += 1
        }
        if soundingChanged {
            soundingNotes = soundingIDs.compactMap { notesByID[$0] }.sorted { $0.midi < $1.midi }
        }

        var stepChanged = false
        while currentIndex + 1 < steps.count, stepTime(steps[currentIndex + 1]) <= time {
            currentIndex += 1
            stepChanged = true
        }
        if stepChanged { onStepChanged?() }

        if demoVisualCursor >= demoEvents.count { stopDemo() }
    }
}

import Foundation
import Observation
import QuartzCore

/// Drives a practice session over a score.
///
/// * Wait mode: the next note(s) are highlighted and the lesson only advances once they're played.
/// * Tempo mode: a playhead runs at a fraction of the written tempo; notes played within the hit
///   window count, notes the playhead passes count as missed. The hand you're not practising can
///   be played by the app as accompaniment.
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
        case wait, tempo

        var id: String { rawValue }
        var title: String { self == .wait ? "Wait" : "Tempo" }
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
        didSet { if practiceMode != oldValue { restart() } }
    }
    /// Playback speed in tempo mode as a fraction of the written tempo.
    var tempoScale: Double = 0.7

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

    let leadIn: TimeInterval = 2
    let hitWindow: TimeInterval = 0.4

    @ObservationIgnored var clock: () -> TimeInterval = { CACurrentMediaTime() }
    /// Called in tempo mode for notes of the hand that isn't being practised: (note, duration).
    @ObservationIgnored var onAccompaniment: ((ScoreNote, TimeInterval) -> Void)?
    @ObservationIgnored var onStepChanged: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playStart: TimeInterval = 0
    @ObservationIgnored private var accompaniment: [ScoreNote] = []
    @ObservationIgnored private var accompanimentCursor = 0
    @ObservationIgnored private var stepHadMistake = false

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

    // MARK: - Input

    @discardableResult
    func handle(midi: Int, source: InputSource, octaveTolerant: Bool = false) -> InputResult {
        guard let step = currentStep else { return .ignored }
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
        guard let step = currentStep, !(practiceMode == .tempo && !isPlaying) else { return false }
        let expected = Set(step.notes.map { MIDINote.pitchClass($0.midi) })
        guard expected.count > 1, ChromaAnalyzer.matches(chroma, expected: expected) else { return false }
        let remaining = remainingNotes
        satisfiedNoteIDs.formUnion(remaining.map(\.id))
        correctCount += remaining.count
        setFeedback(.correct(played: step.notes.last?.midi ?? 60))
        completeStep()
        return true
    }

    static func matches(_ played: Int, _ expected: Int, octaveTolerant: Bool) -> Bool {
        played == expected || (octaveTolerant && MIDINote.pitchClass(played) == MIDINote.pitchClass(expected))
    }

    // MARK: - Navigation

    func skipStep() {
        guard currentStep != nil else { return }
        moveToNextStep()
    }

    func previousStep() {
        guard currentIndex > 0 else { return }
        stopPlayback()
        currentIndex -= 1
        results[currentIndex] = nil
        satisfiedNoteIDs = []
        stepHadMistake = false
        feedback = nil
        playhead = (steps[currentIndex].time / tempoScale) - leadIn
        onStepChanged?()
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

    // MARK: - Tempo mode

    func stepTime(_ step: Step) -> TimeInterval { step.time / tempoScale }

    func togglePlayback() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard practiceMode == .tempo, !steps.isEmpty else { return }
        if isFinished { restart() }
        isPlaying = true
        playStart = clock() - playhead
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func tick() { advancePlayhead(to: clock() - playStart) }

    /// Moves the tempo-mode playhead, marking passed steps as missed and firing accompaniment.
    func advancePlayhead(to time: TimeInterval) {
        playhead = time
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
}

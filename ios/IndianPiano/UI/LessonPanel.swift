import SwiftUI

struct LessonPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lesson = model.lesson
        let isListening = lesson.practiceMode == .listen
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Practice mode", selection: Binding(get: { lesson.practiceMode }, set: { model.setPracticeMode($0) })) {
                    ForEach(LessonEngine.PracticeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityIdentifier("practiceMode")

                // Wait mode has no playhead, but the speed still sets the metronome's pulse.
                if lesson.practiceMode != .wait || model.metronomeEnabled {
                    TempoControls(showsTransport: lesson.practiceMode != .wait)
                }

                FeedbackBanner()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                if !isListening { StatsView() }
                MetronomeButton()
                if !isListening {
                    IconButton(systemName: "speaker.wave.2.fill", label: "Hear the next notes") { model.playExpected() }
                }
                IconButton(systemName: "backward.fill", label: "Previous step") { lesson.previousStep() }
                IconButton(systemName: "forward.fill", label: "Skip step") { lesson.skipStep() }
                IconButton(systemName: "arrow.counterclockwise", label: "Restart") { model.restartLesson() }
            }
            .frame(height: 30)

            NoteStripView()
                .frame(maxHeight: .infinity)

            ProgressBar(progress: lesson.progress)
                .frame(height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelBackground()
    }
}

private struct TempoControls: View {
    @Environment(AppModel.self) private var model
    var showsTransport: Bool

    var body: some View {
        let lesson = model.lesson
        HStack(spacing: 4) {
            if showsTransport {
                Button { lesson.togglePlayback() } label: {
                    Image(systemName: lesson.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 28)
                        .background(Capsule().fill(Theme.saffron))
                        .foregroundStyle(.black)
                }
                .accessibilityLabel(lesson.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("playButton")
                if lesson.practiceMode == .listen {
                    Button { lesson.stopDemo() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Capsule().fill(Color.white.opacity(lesson.demoOrigin == nil ? 0.04 : 0.12)))
                            .foregroundStyle(lesson.demoOrigin == nil ? .secondary : .primary)
                    }
                    .disabled(lesson.demoOrigin == nil)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("stopButton")
                }
            }
            Button { model.setTempoScale(lesson.tempoScale - 0.1) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Slower")
            Text("\(Int((lesson.tempoScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 38)
            Button { model.setTempoScale(lesson.tempoScale + 0.1) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Faster")
        }
        .font(.system(size: 12, weight: .bold))
        .buttonStyle(.plain)
    }
}

private struct MetronomeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = model.metronomeEnabled
        let bpm = model.metronomeBeatsPerMinute
        Button { model.metronomeEnabled.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "metronome.fill" : "metronome")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.bounce, value: model.metronome.beatCount)
                if isOn, let bpm {
                    Text("\(bpm)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                }
            }
            .foregroundStyle(isOn ? .black : .primary)
            .padding(.horizontal, isOn ? 7 : 0)
            .frame(minWidth: 30, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.saffron : Color.white.opacity(0.08)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metronome")
        .accessibilityValue(isOn ? "On, \(bpm ?? 0) beats per minute" : "Off")
        .accessibilityIdentifier("metronomeButton")
    }
}

private struct StatsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lesson = model.lesson
        HStack(spacing: 8) {
            counter(lesson.correctCount, symbol: "checkmark", color: Theme.correct)
            counter(lesson.wrongCount + lesson.missedCount, symbol: "xmark", color: Theme.wrong)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lesson.correctCount) correct, \(lesson.wrongCount + lesson.missedCount) mistakes")
        .accessibilityIdentifier("stats")
    }

    private func counter(_ value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
            Text("\(value)").font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(color)
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.saffron).frame(width: proxy.size.width * progress)
            }
        }
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}

// MARK: - Feedback

private struct FeedbackBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lesson = model.lesson
        HStack(spacing: 6) {
            content(lesson)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(background(lesson)))
        .animation(.easeOut(duration: 0.2), value: lesson.feedbackCount)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback")
    }

    @ViewBuilder
    private func content(_ lesson: LessonEngine) -> some View {
        if lesson.score == nil {
            Text(model.isLoadingSong ? "Loading…" : "Pick a song to start")
        } else if lesson.practiceMode == .listen {
            listenContent(lesson)
        } else if lesson.isFinished {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.correct)
            Text("Song complete")
            if let accuracy = lesson.accuracy {
                Text("· \(Int((accuracy * 100).rounded()))% accuracy").foregroundStyle(.secondary)
            }
            Button("Again") { lesson.restart() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.saffron)
                .controlSize(.mini)
        } else if lesson.practiceMode == .tempo && !lesson.isPlaying && lesson.currentIndex == 0 {
            Image(systemName: "metronome.fill").foregroundStyle(Theme.saffron)
            Text("Press play — notes scroll at \(Int((lesson.tempoScale * 100).rounded()))% tempo")
        } else {
            switch lesson.feedback {
            case let .wrong(played, expected)?:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.wrong)
                Text("Played")
                NoteChip(midi: played, spelling: nil, hand: nil, finger: nil, style: .wrong)
                Text("— play")
                chips(expected.isEmpty ? lesson.remainingNotes : expected)
                Text("instead").foregroundStyle(.secondary)
            case let .missed(expected)?:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.saffron)
                Text("Missed")
                chips(expected)
                nextPrompt(lesson)
            case .correct?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.correct)
                nextPrompt(lesson)
            default:
                Image(systemName: "hand.point.down.fill").foregroundStyle(Theme.saffron)
                nextPrompt(lesson)
            }
        }
    }

    @ViewBuilder
    private func listenContent(_ lesson: LessonEngine) -> some View {
        let speed = Int((lesson.tempoScale * 100).rounded())
        if lesson.isPlaying {
            Image(systemName: "ear.fill").foregroundStyle(Theme.saffron)
            Text("Playing")
            chips(lesson.soundingNotes)
        } else if let origin = lesson.demoOrigin, lesson.steps.indices.contains(origin) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.saffron)
            Text("Paused — stop goes back to bar \(lesson.steps[origin].measure)")
        } else {
            Image(systemName: "play.circle.fill").foregroundStyle(Theme.saffron)
            Text("Press play to hear it at \(speed)%")
            Text("· keys light up with fingers").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nextPrompt(_ lesson: LessonEngine) -> some View {
        Text("Play")
        chips(lesson.remainingNotes)
    }

    private func chips(_ notes: [ScoreNote]) -> some View {
        HStack(spacing: 4) {
            ForEach(notes.sorted { $0.midi > $1.midi }.prefix(4)) { note in
                NoteChip(midi: note.midi, spelling: note.spelling, hand: note.hand,
                         finger: model.showFingerNumbers ? note.finger : nil, style: .expected)
            }
        }
    }

    private func background(_ lesson: LessonEngine) -> Color {
        switch lesson.feedback {
        case .wrong?: return Theme.wrong.opacity(0.18)
        case .missed?: return Theme.saffron.opacity(0.15)
        case .correct?, .finished?: return Theme.correct.opacity(0.14)
        case nil: return Color.white.opacity(0.06)
        }
    }
}

// MARK: - Note chips and strip

struct NoteChip: View {
    enum Style { case expected, satisfied, done, missed, wrong }

    @Environment(AppModel.self) private var model
    let midi: Int
    let spelling: NoteSpelling?
    let hand: Hand?
    let finger: Int?
    var style: Style = .expected
    var fontSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 3) {
            NoteLabelView(label: model.naming.label(forMIDI: midi, spelling: spelling), fontSize: fontSize, color: .white)
            if let finger {
                FingerBadge(finger: finger, color: .black.opacity(0.35), size: fontSize + 3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minHeight: fontSize + 9)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(style == .expected ? 0.25 : 0)))
    }

    private var fill: Color {
        switch style {
        case .wrong: return Theme.wrong
        case .satisfied: return Theme.correct
        case .missed: return Theme.wrong.opacity(0.45)
        case .done: return (hand.map(Theme.color(for:)) ?? .gray).opacity(0.35)
        case .expected: return hand.map(Theme.color(for:)) ?? .gray
        }
    }
}

struct NoteStripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lesson = model.lesson
        let lanes: [Hand] = lesson.handMode == .both ? [.right, .left] : [lesson.handMode == .left ? .left : .right]
        let steps = lesson.steps
        let currentIndex = lesson.currentIndex
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: 4) {
                        ForEach(steps) { step in
                            StepColumn(step: step, lanes: lanes,
                                       showsBarline: step.id == 0 || steps[step.id - 1].measure != step.measure)
                                .id(step.id)
                        }
                    }
                    .padding(.horizontal, proxy.size.width * 0.3)
                    .frame(height: proxy.size.height)
                }
                .onChange(of: currentIndex, initial: true) { _, index in
                    guard !steps.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scroller.scrollTo(min(index, steps.count - 1), anchor: UnitPoint(x: 0.35, y: 0.5))
                    }
                }
                .onChange(of: lesson.steps) { _, steps in
                    if !steps.isEmpty { scroller.scrollTo(0, anchor: UnitPoint(x: 0.35, y: 0.5)) }
                }
            }
        }
        .overlay(alignment: .leading) {
            if lanes.count == 2 {
                VStack {
                    laneTag("RH", Theme.rightHand)
                    Spacer()
                    laneTag("LH", Theme.leftHand)
                }
                .padding(.vertical, 6)
                .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("noteStrip")
    }

    private func laneTag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.backgroundTop.opacity(0.85)))
    }
}

private struct StepColumn: View {
    @Environment(AppModel.self) private var model
    let step: LessonEngine.Step
    let lanes: [Hand]
    let showsBarline: Bool

    var body: some View {
        let lesson = model.lesson
        let isCurrent = step.id == lesson.currentIndex
        let result = lesson.results[step.id]
        HStack(spacing: 4) {
            if showsBarline {
                VStack(spacing: 2) {
                    Text("\(step.measure)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1)
                }
            }
            VStack(spacing: 3) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, hand in
                    let notes = step.notes.filter { $0.hand == hand }.sorted { $0.midi > $1.midi }
                    // Dense chords wrap into columns (highest note top-left) instead of being clipped.
                    let rowsPerColumn = lanes.count == 2 ? 2 : 3
                    let columns = stride(from: 0, to: notes.count, by: rowsPerColumn).map { Array(notes[$0..<min(notes.count, $0 + rowsPerColumn)]) }
                    let fontSize: CGFloat = (lanes.count == 2 ? 13 : 16) - (notes.count > rowsPerColumn ? 2 : 0)
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 2) {
                                ForEach(column) { note in
                                    NoteChip(midi: note.midi, spelling: note.spelling, hand: note.hand,
                                             finger: model.showFingerNumbers ? note.finger : nil,
                                             style: style(for: note, isCurrent: isCurrent, result: result),
                                             fontSize: fontSize)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: lanes.count == 2 ? (index == 0 ? .bottom : .top) : .center)
                    if lanes.count == 2 && index == 0 {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isCurrent ? Color.white.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isCurrent ? Theme.saffron : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if let result, result != .missed {
                    Image(systemName: result == .perfect ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(result == .perfect ? Theme.correct : Theme.saffron)
                        .offset(x: 3, y: -3)
                }
            }
            .scaleEffect(isCurrent ? 1.04 : 1)
            .opacity(step.id < lesson.currentIndex ? 0.55 : 1)
        }
    }

    private func style(for note: ScoreNote, isCurrent: Bool, result: LessonEngine.StepResult?) -> NoteChip.Style {
        if result == .missed { return .missed }
        if result != nil { return .done }
        if isCurrent && model.lesson.satisfiedNoteIDs.contains(note.id) { return .satisfied }
        return .expected
    }
}

import SwiftUI

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Button { model.isLibraryPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.saffron)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.lesson.score?.title ?? model.currentSong?.title ?? "Choose a song")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(model.currentSong?.subtitle ?? "Songs & import")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .panelBackground(cornerRadius: 10)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityIdentifier("songButton")

            Spacer(minLength: 4)

            Picker("Hands", selection: Binding(get: { model.lesson.handMode }, set: { model.setHandMode($0) })) {
                ForEach(LessonEngine.HandMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityIdentifier("handMode")

            Picker("Notation", selection: $model.isIndianNotation) {
                Text("C D E").tag(false)
                Text(model.indianSystem == .hindustani ? "Sa Re Ga" : "Sa Ri Ga").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityIdentifier("notationToggle")

            if model.notation.isSargam {
                Menu {
                    Picker("Sa", selection: $model.saPitchClass) {
                        ForEach(0..<12, id: \.self) { pc in
                            Text("Sa = \(MIDINote.keyNames[pc])").tag(pc)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Sa")
                            .foregroundStyle(.secondary)
                        Text(MIDINote.keyNames[model.saPitchClass])
                            .foregroundStyle(Theme.saffron)
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .panelBackground(cornerRadius: 8)
                }
                .accessibilityIdentifier("saPicker")
            }

            MicButton()

            Button { model.isSettingsPresented = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .panelBackground(cornerRadius: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
        }
    }
}

struct MicButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mic = model.mic
        Button { Task { await mic.toggle() } } label: {
            ZStack {
                Circle()
                    .fill(mic.isListening ? Theme.saffron.opacity(0.22) : Color.white.opacity(0.06))
                Circle()
                    .trim(from: 0, to: CGFloat(mic.isListening ? mic.level : 0))
                    .stroke(Theme.saffron, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: icon(mic.status))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(mic.isListening ? Theme.saffron : .primary)
            }
            .frame(width: 34, height: 34)
            .overlay(alignment: .bottom) {
                if mic.isListening, let heard = mic.heardNote {
                    NoteLabelView(label: model.naming.label(forMIDI: heard), fontSize: 9, color: .white, showWesternOctave: false)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Theme.saffron))
                        .offset(y: 10)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mic.isListening ? "Stop listening" : "Listen with microphone")
        .accessibilityIdentifier("micButton")
    }

    private func icon(_ status: MicController.Status) -> String {
        switch status {
        case .listening: return "mic.fill"
        case .requesting: return "ellipsis"
        case .denied, .failed: return "mic.slash.fill"
        case .off: return "mic"
        }
    }
}

struct KeyboardNavigator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let window = model.lowestWhiteKey
        let visible = model.visibleWhiteKeys
        let expected = model.lesson.remainingNotes
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left.2", label: "Octave down") { model.shiftKeyboard(by: -7) }
            GeometryReader { proxy in
                overview(size: proxy.size, window: window, visible: visible, expected: expected)
            }
            IconButton(systemName: "chevron.right.2", label: "Octave up") { model.shiftKeyboard(by: 7) }
        }
    }

    private func overview(size: CGSize, window: Int, visible: Int, expected: [ScoreNote]) -> some View {
        let lowest = KeyboardLayout.lowestPianoWhite
        let total = KeyboardLayout.highestPianoWhite - lowest + 1
        let keyWidth = size.width / CGFloat(total)
        return ZStack(alignment: .topLeading) {
            Canvas { context, canvasSize in
                for index in 0..<total {
                    let rect = CGRect(x: CGFloat(index) * keyWidth + 0.5, y: 0, width: keyWidth - 1, height: canvasSize.height)
                    context.fill(Path(rect), with: .color(Color.white.opacity(0.75)))
                }
                for midi in MIDINote.pianoRange where MIDINote.isBlack(midi) {
                    let column = CGFloat(KeyboardLayout.whiteIndex(of: midi) - lowest + 1)
                    let rect = CGRect(x: column * keyWidth - keyWidth * 0.3, y: 0, width: keyWidth * 0.6, height: canvasSize.height * 0.6)
                    context.fill(Path(rect), with: .color(.black))
                }
                for note in expected {
                    let column = CGFloat(KeyboardLayout.whiteIndex(of: note.midi) - lowest) + 0.5
                    let dot = CGRect(x: column * keyWidth - 2.5, y: canvasSize.height - 7, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(Theme.color(for: note.hand)))
                }
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.saffron, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.saffron.opacity(0.12)))
                .frame(width: keyWidth * CGFloat(visible), height: size.height)
                .offset(x: CGFloat(window - lowest) * keyWidth)
                .animation(.easeInOut(duration: 0.3), value: window)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let column = Int(value.location.x / keyWidth) + lowest - visible / 2
            model.lowestWhiteKey = model.clampedLowestWhite(column)
        })
        .accessibilityElement()
        .accessibilityLabel("Keyboard position")
        .accessibilityAdjustableAction { direction in
            model.shiftKeyboard(by: direction == .increment ? 7 : -7)
        }
    }
}

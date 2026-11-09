import SwiftUI
import UIKit

struct PianoKeyboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Read all model state here rather than inside the GeometryReader closure, where
        // Observation tracking is unreliable and animated changes can be missed.
        let lowestWhite = model.lowestWhiteKey
        let whiteCount = model.visibleWhiteKeys
        let keys = KeyboardLayout(lowestWhite: lowestWhite, whiteCount: whiteCount, size: .zero).renderedKeys(margin: 7)
        let states = Dictionary(uniqueKeysWithValues: keys.map { ($0, model.keyState(for: $0)) })
        let labels = Dictionary(uniqueKeysWithValues: keys.map { ($0, model.keyLabel(for: $0)) })
        let namingKey = "\(model.notation.rawValue)-\(model.saPitchClass)"
        let naming = model.naming

        GeometryReader { proxy in
            let layout = KeyboardLayout(lowestWhite: lowestWhite, whiteCount: whiteCount, size: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(keys.filter { !MIDINote.isBlack($0) }, id: \.self) { midi in
                    let frame = layout.frame(for: midi)
                    WhiteKeyView(
                        state: states[midi] ?? KeyVisualState(),
                        label: labels[midi] ?? nil,
                        showWesternOctave: MIDINote.pitchClass(midi) == 0,
                        width: frame.width
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX)
                }
                ForEach(keys.filter { MIDINote.isBlack($0) }, id: \.self) { midi in
                    let frame = layout.frame(for: midi)
                    BlackKeyView(state: states[midi] ?? KeyVisualState(), label: labels[midi] ?? nil, width: frame.width)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                }
                KeyboardTouchSurface(
                    layout: layout,
                    namingKey: namingKey,
                    accessibilityName: { naming.label(forMIDI: $0).fullText },
                    onDown: { model.keyDown($0) },
                    onUp: { model.keyUp($0) }
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.3), value: lowestWhite)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 6))
        }
    }
}

private struct WhiteKeyView: View {
    let state: KeyVisualState
    let label: NoteLabel?
    let showWesternOctave: Bool
    let width: CGFloat

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(
                colors: state.isPressed ? [Color(white: 0.78), Color(white: 0.86)] : [Color(white: 0.98), Color(white: 0.9)],
                startPoint: .top, endPoint: .bottom))
            if let tint = state.tint {
                shape.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.9)], startPoint: .top, endPoint: .bottom))
            }
            shape.stroke(Color.black.opacity(0.35), lineWidth: 1)

            VStack(spacing: 5) {
                if state.isHeard {
                    Image(systemName: "waveform")
                        .font(.system(size: min(14, width * 0.3), weight: .bold))
                        .foregroundStyle(Theme.saffron)
                }
                if let finger = state.finger, let hand = state.expectedHand {
                    FingerBadge(finger: finger, color: Theme.color(for: hand), size: min(26, width * 0.56))
                }
                if let label {
                    NoteLabelView(label: label, fontSize: min(15, width * 0.3),
                                  color: state.tint == nil ? Color(white: 0.28) : .white,
                                  showWesternOctave: showWesternOctave)
                }
                Capsule()
                    .fill(state.isTonic ? Theme.saffron : .clear)
                    .frame(width: width * 0.42, height: 3)
            }
            .padding(.bottom, 7)
        }
        .padding(.horizontal, 0.5)
    }
}

private struct BlackKeyView: View {
    let state: KeyVisualState
    let label: NoteLabel?
    let width: CGFloat

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(
                colors: state.isPressed ? [Color(white: 0.28), Color(white: 0.2)] : [Color(white: 0.2), Color(white: 0.06)],
                startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 2)
            if let tint = state.tint {
                shape.fill(LinearGradient(colors: [tint.opacity(0.5), tint], startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 3) {
                if state.isHeard {
                    Image(systemName: "waveform")
                        .font(.system(size: min(11, width * 0.4), weight: .bold))
                        .foregroundStyle(Theme.saffron)
                }
                if let finger = state.finger, let hand = state.expectedHand {
                    FingerBadge(finger: finger, color: Theme.color(for: hand), size: min(22, width * 0.78))
                }
                if let label {
                    NoteLabelView(label: label, fontSize: min(11, width * 0.36), color: .white.opacity(0.92), showWesternOctave: false)
                        .minimumScaleFactor(0.6)
                }
                Capsule()
                    .fill(state.isTonic ? Theme.saffron : .clear)
                    .frame(width: width * 0.5, height: 2.5)
            }
            .padding(.bottom, 5)
        }
    }
}

/// Multi-touch input for the keyboard (SwiftUI gestures only track one finger). Also exposes one
/// accessibility element per visible key so VoiceOver and UI tests can press keys.
struct KeyboardTouchSurface: UIViewRepresentable {
    var layout: KeyboardLayout
    /// Changes whenever key names change, so accessibility labels are rebuilt.
    var namingKey: String
    var accessibilityName: (Int) -> String
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void

    func makeUIView(context: Context) -> KeyboardTouchView {
        let view = KeyboardTouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: KeyboardTouchView, context: Context) {
        view.onDown = onDown
        view.onUp = onUp
        view.accessibilityName = accessibilityName
        if view.layout != layout || view.namingKey != namingKey {
            view.layout = layout
            view.namingKey = namingKey
            view.rebuildAccessibilityElements()
        }
    }
}

final class KeyboardTouchView: UIView {
    var layout: KeyboardLayout?
    var namingKey = ""
    var onDown: ((Int) -> Void)?
    var onUp: ((Int) -> Void)?
    var accessibilityName: ((Int) -> String)?
    private var activeTouches: [ObjectIdentifier: Int] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let midi = layout?.key(at: touch.location(in: self)) else { continue }
            activeTouches[ObjectIdentifier(touch)] = midi
            onDown?(midi)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let midi = layout?.key(at: touch.location(in: self))
            guard midi != activeTouches[id] else { continue }
            if let previous = activeTouches[id] { onUp?(previous) }
            activeTouches[id] = midi
            if let midi { onDown?(midi) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            if let midi = activeTouches.removeValue(forKey: ObjectIdentifier(touch)) { onUp?(midi) }
        }
    }

    func rebuildAccessibilityElements() {
        guard let layout else { accessibilityElements = []; return }
        accessibilityElements = layout.visibleRange.compactMap { midi -> UIAccessibilityElement? in
            let frame = layout.frame(for: midi)
            guard frame.maxX > 0, frame.minX < layout.size.width else { return nil }
            let element = KeyAccessibilityElement(accessibilityContainer: self)
            element.midi = midi
            element.owner = self
            element.accessibilityIdentifier = "key-\(midi)"
            element.accessibilityLabel = accessibilityName?(midi) ?? "\(midi)"
            element.accessibilityTraits = [.button, .playsSound]
            // White keys expose only the part below the black keys, so a tap on the frame's centre hits them.
            element.accessibilityFrameInContainerSpace = MIDINote.isBlack(midi)
                ? frame
                : CGRect(x: frame.minX, y: layout.blackHeight, width: frame.width, height: frame.height - layout.blackHeight)
            return element
        }
    }

    fileprivate func activate(_ midi: Int) {
        onDown?(midi)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.onUp?(midi) }
    }
}

private final class KeyAccessibilityElement: UIAccessibilityElement {
    var midi = 60
    weak var owner: KeyboardTouchView?

    override func accessibilityActivate() -> Bool {
        owner?.activate(midi)
        return true
    }
}

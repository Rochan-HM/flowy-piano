import SwiftUI

/// Renders a `NoteLabel`: sargam octave dots above/below, Carnatic variant numbers, komal underline,
/// tivra stroke, and the Western octave number.
struct NoteLabelView: View {
    let label: NoteLabel
    var fontSize: CGFloat = 14
    var color: Color = .primary
    var showWesternOctave = true

    var body: some View {
        VStack(spacing: fontSize * 0.08) {
            dots(max(0, label.octaveShift))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label.name)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .underline(label.mark == .komal)
                    .overlay(alignment: .top) {
                        if label.mark == .tivra {
                            Capsule().frame(width: max(1.5, fontSize * 0.1), height: fontSize * 0.38)
                                .offset(y: -fontSize * 0.36)
                        }
                    }
                if let variant = label.variant {
                    Text("\(variant)")
                        .font(.system(size: fontSize * 0.7, weight: .bold, design: .rounded))
                }
                if showWesternOctave, let octave = label.westernOctave {
                    Text("\(octave)")
                        .font(.system(size: fontSize * 0.62, weight: .medium, design: .rounded))
                        .opacity(0.65)
                }
            }
            .lineLimit(1)
            .fixedSize()
            dots(max(0, -label.octaveShift))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.fullText)
    }

    @ViewBuilder
    private func dots(_ count: Int) -> some View {
        let size = max(2.5, fontSize * 0.2)
        if count > 0 {
            HStack(spacing: size * 0.6) {
                ForEach(0..<count, id: \.self) { _ in Circle().frame(width: size, height: size) }
            }
            .frame(height: size)
        }
    }
}

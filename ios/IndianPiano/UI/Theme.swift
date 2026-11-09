import SwiftUI

enum Theme {
    static let backgroundTop = Color(red: 0.07, green: 0.07, blue: 0.11)
    static let backgroundBottom = Color(red: 0.11, green: 0.09, blue: 0.16)
    static let background = LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    static let panel = Color.white.opacity(0.055)
    static let panelStroke = Color.white.opacity(0.09)

    static let saffron = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let rightHand = Color(red: 0.26, green: 0.6, blue: 1.0)
    static let leftHand = Color(red: 0.76, green: 0.42, blue: 1.0)
    static let correct = Color(red: 0.2, green: 0.78, blue: 0.45)
    static let wrong = Color(red: 1.0, green: 0.32, blue: 0.32)

    static func color(for hand: Hand) -> Color { hand == .right ? rightHand : leftHand }
}

extension KeyVisualState {
    /// Colour overlay for the key, if any; flashes win over lesson highlights.
    var tint: Color? {
        switch flash {
        case .wrong?: return Theme.wrong
        case .correct?: return Theme.correct
        case nil: break
        }
        if isSatisfied { return Theme.correct }
        if let expectedHand { return Theme.color(for: expectedHand) }
        return nil
    }
}

struct PanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.panelStroke))
    }
}

extension View {
    func panelBackground(cornerRadius: CGFloat = 16) -> some View { modifier(PanelBackground(cornerRadius: cornerRadius)) }
}

struct FingerBadge: View {
    let finger: Int
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Text("\(finger)")
            .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: max(1, size * 0.07)))
            .accessibilityLabel("finger \(finger)")
    }
}

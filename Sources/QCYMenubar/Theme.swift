import SwiftUI

/// Shared visual language for the panel (inspired by LGwebOS-menubar).
enum Theme {
    /// QCY-ish accent blue.
    static let accent = Color(red: 0.30, green: 0.56, blue: 0.98)
    static let mutedInk = Color.white.opacity(0.49)
    static let ink = Color.white.opacity(0.88)

    static let panelTop = Color(red: 0.085, green: 0.095, blue: 0.105)
    static let panelBottom = Color(white: 0.045)
    static let gradient = LinearGradient(colors: [panelTop, panelBottom],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing)
}

/// Rounded, subtly-filled card used for every block of controls.
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.068)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.7))
    }
}

/// Selectable tile / button style with an accent "on" state.
struct TileButtonStyle: ButtonStyle {
    var selected = false
    var accent: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? accent.opacity(0.18) : Color.white.opacity(configuration.isPressed ? 0.13 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Uppercase section label used between cards.
struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.mutedInk)
            .padding(.horizontal, 1)
    }
}

/// The tail that points from the panel up to the menu bar item.
struct PanelArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 11, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX - 3, y: rect.minY + 2),
                          control: CGPoint(x: rect.midX - 6, y: rect.maxY - 6))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 3, y: rect.minY + 2),
                          control: CGPoint(x: rect.midX, y: rect.minY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 11, y: rect.maxY),
                          control: CGPoint(x: rect.midX + 6, y: rect.maxY - 6))
        path.closeSubpath()
        return path
    }
}

/// Wraps the panel content with the arrow and the rounded shell.
struct PanelShell: View {
    @ObservedObject var model: HeadsetModel
    let height: CGFloat
    let arrowX: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            PanelArrow()
                .fill(Theme.panelTop)
                .frame(width: 24, height: 11)
                .frame(width: AppDelegate.panelWidth, alignment: .leading)
                .offset(x: arrowX - 12)
            QCYPanel(model: model)
                .frame(width: AppDelegate.panelWidth, height: height - 11)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7))
        }
        .frame(width: AppDelegate.panelWidth, height: height)
        .preferredColorScheme(.dark)
    }
}

import SwiftUI

/// Compact vertical slider for the 10-band EQ editor.
/// Native `Slider` is horizontal-only, so this draws its own track and thumb.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 112

    private let thumb: CGFloat = 12
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let raw = span > 0 ? (value - range.lowerBound) / span : 0
            let frac = min(max(raw, 0), 1)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: track / 2)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: track)

                RoundedRectangle(cornerRadius: track / 2)
                    .fill(Theme.accent)
                    .frame(width: track, height: frac * h)

                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: thumb, height: thumb)
                    .offset(y: -(frac * (h - thumb)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let y = min(max(0, g.location.y), h)
                    let f = 1 - (y / h)
                    value = range.lowerBound + f * span
                }
            )
        }
        .frame(width: 18, height: height)
    }
}

/// Small connection status indicator for the header / footer.
struct StatusDot: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .connected: return .green
        case .scanning, .connecting: return .yellow
        case .poweredOff, .unauthorized, .failed: return .red
        default: return Color.white.opacity(0.35)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
    }
}

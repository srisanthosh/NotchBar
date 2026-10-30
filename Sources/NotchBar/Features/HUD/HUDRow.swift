import SwiftUI

/// Volume or brightness level, shown below the notch. The bar can be dragged.
struct HUDRow: View {
    let state: HUDState
    let onSet: (Float) -> Void
    @State private var dragging = false

    var body: some View {
        let value = state.muted ? 0 : state.value
        HStack(spacing: 12) {
            icon
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 24, height: 20)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white)
                        .frame(width: value <= 0 ? 0 : max(dragging ? 8 : 6, g.size.width * CGFloat(value)))
                }
                .frame(height: dragging ? 8 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        onSet(Float(min(1, max(0, v.location.x / g.size.width))))
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 20)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: value)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
            Text(state.muted ? "Off" : "\(Int((value * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, alignment: .trailing)
                .contentTransition(.numericText(value: Double(value)))
        }
        .foregroundStyle(.white)
    }

    /// Drawn as text so the glyph shares the row's layer and never drops out mid-transition.
    private var icon: some View {
        let image: Image
        switch state.kind {
        case .volume:
            image = state.muted || state.value <= 0.001
                ? Image(systemName: "speaker.slash.fill")
                : Image(systemName: "speaker.wave.3.fill", variableValue: Double(state.value))
        case .brightness:
            image = Image(systemName: state.value < 0.5 ? "sun.min.fill" : "sun.max.fill")
        }
        return Text(image)
    }
}

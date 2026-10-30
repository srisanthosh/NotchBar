import SwiftUI

/// Equalizer bars that bounce while audio plays.
///
/// Each bar runs one repeating Core Animation-style animation at its own speed, so the
/// view's body is evaluated once instead of every frame. The bars rest when playback stops
/// or nobody can see the screen.
struct AudioWaves: View {
    var isPlaying: Bool
    var color: Color = .white
    var height: CGFloat = 14

    @ObservedObject private var system = SystemActivity.shared
    @State private var raised = false

    private static let bars: [(low: CGFloat, high: CGFloat, duration: Double)] = [
        (0.30, 1.00, 0.42), (0.45, 0.78, 0.31), (0.25, 0.95, 0.53), (0.35, 0.70, 0.37),
    ]

    var body: some View {
        let animating = isPlaying && system.isAwake
        HStack(alignment: .center, spacing: height * 0.16) {
            ForEach(Self.bars.indices, id: \.self) { i in
                let bar = Self.bars[i]
                Capsule()
                    .fill(color.gradient)
                    .frame(width: height * 0.19, height: height)
                    .scaleEffect(x: 1, y: animating ? (raised ? bar.high : bar.low) : 0.2, anchor: .center)
                    .animation(animating ? .easeInOut(duration: bar.duration).repeatForever(autoreverses: true)
                                         : .spring(response: 0.4, dampingFraction: 0.7), value: raised)
            }
        }
        .frame(height: height)
        .onAppear { raised = animating }
        .onChange(of: animating) { _, now in raised = now }
    }
}

import SwiftUI

/// Shown beside the notch while a dictation app listens: its icon with a red pulse, and
/// red waves, like the recording indicator on iPhone.
struct DictationWing: View {
    let source: MediaSource
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .scaleEffect(pulse ? 1.45 : 0.9)
                    .opacity(pulse ? 0 : 0.9)
                if let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                }
            }
            .frame(width: 20, height: 20)
            AudioWaves(isPlaying: true, color: .red, height: 12)
        }
        .help("\(source.appName) is listening")
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

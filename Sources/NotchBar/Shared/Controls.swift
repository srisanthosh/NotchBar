import SwiftUI

extension Color {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let claudeWaiting = Color(red: 1, green: 0.76, blue: 0.28)
    static let timerOrange = Color(red: 1, green: 0.624, blue: 0.039)
    static let linkBlue = Color(red: 0.45, green: 0.7, blue: 1)
    static let cpuBlue = Color(red: 0.36, green: 0.66, blue: 1)
    static let memoryGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
}

/// Shrinks a little while pressed, like system buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A round icon button with a soft hover highlight.
struct CircleIconButton: View {
    var systemName: String
    var size: CGFloat = 26
    var iconSize: CGFloat = 12
    var help: String = ""
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.8))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(help)
    }
}

/// Content blurs in and out as the notch changes shape, the way system UI morphs.
struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(radius: 12, opacity: 0, scale: 0.94),
                                 identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.05)),
            removal: .modifier(active: BlurFade(radius: 10, opacity: 0, scale: 0.96),
                               identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeOut(duration: 0.16))
        )
    }
}

/// Small grey section label, such as "UP NEXT".
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.white.opacity(0.4))
    }
}

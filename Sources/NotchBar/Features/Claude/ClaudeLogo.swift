import SwiftUI

/// A Claude-style spark: rounded rays of slightly uneven length around a center.
struct ClaudeSpark: Shape {
    func path(in r: CGRect) -> Path {
        let center = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let lengths: [CGFloat] = [1.0, 0.80, 0.94, 0.76, 0.98, 0.84, 0.92, 0.78, 1.0, 0.82, 0.9, 0.77]
        var p = Path()
        for (i, length) in lengths.enumerated() {
            let angle = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi - .pi / 2 + 0.07 * sin(CGFloat(i) * 1.7)
            p.move(to: center)
            p.addLine(to: CGPoint(x: center.x + cos(angle) * radius * length, y: center.y + sin(angle) * radius * length))
        }
        return p
    }
}

struct ClaudeLogo: View {
    var size: CGFloat = 16
    var color: Color = .claude

    var body: some View {
        ClaudeSpark()
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            .padding(size * 0.08)
            .frame(width: size, height: size)
    }
}

/// The logo beside the notch. A thin ring shows session usage. The spark spins while
/// Claude Code is working and pulses amber while it waits for you.
///
/// The spark is a Core Animation layer with repeating animations, so the window server runs
/// them on its own: a Claude session that works for an hour costs NotchBar no CPU. (SwiftUI
/// would redraw a rotating shape on every frame.) When idle the logo is static.
struct LiveClaudeLogo: View {
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject private var system = SystemActivity.shared
    var size: CGFloat = 13

    var body: some View {
        let activity = usage.activity
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.001, usage.sessionFraction))
                .stroke(usageColor(usage.sessionFraction), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if Snapshotter.isRendering {
                // Image renders can't draw AppKit layers, so snapshots get the still shape.
                ClaudeLogo(size: size, color: activity == .waiting ? .claudeWaiting : .claude)
            } else {
                AnimatedSpark(size: size, activity: system.isAwake ? activity : .idle)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + 9, height: size + 9)
    }
}

/// The Claude spark as a `CAShapeLayer`, spinning or pulsing with Core Animation.
private struct AnimatedSpark: NSViewRepresentable {
    let size: CGFloat
    let activity: ClaudeActivity

    func makeNSView(context: Context) -> SparkView { SparkView(size: size) }

    func updateNSView(_ view: SparkView, context: Context) { view.show(activity) }

    final class SparkView: NSView {
        private let spark = CAShapeLayer()
        private var shown: ClaudeActivity?

        init(size: CGFloat) {
            super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
            wantsLayer = true
            let inset = size * 0.08
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
            spark.frame = CGRect(x: 0, y: 0, width: size, height: size)
            spark.path = ClaudeSpark().path(in: rect).cgPath
            spark.fillColor = nil
            spark.lineWidth = size * 0.15
            spark.lineCap = .round
            spark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(spark)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        func show(_ activity: ClaudeActivity) {
            guard activity != shown else { return }
            shown = activity
            spark.strokeColor = NSColor(activity == .waiting ? Color.claudeWaiting : Color.claude).cgColor
            spark.removeAllAnimations()
            switch activity {
            case .working:
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 5
                spin.repeatCount = .infinity
                spark.add(spin, forKey: "spin")
            case .waiting:
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 1
                pulse.toValue = 1.14
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                spark.add(pulse, forKey: "pulse")
            case .idle:
                break
            }
        }
    }
}

/// Claude orange, turning amber then red as a limit gets close.
func usageColor(_ fraction: Double) -> Color {
    if fraction >= 0.9 { return Color(red: 1, green: 0.36, blue: 0.32) }
    if fraction >= 0.75 { return Color(red: 1, green: 0.62, blue: 0.24) }
    return .claude
}

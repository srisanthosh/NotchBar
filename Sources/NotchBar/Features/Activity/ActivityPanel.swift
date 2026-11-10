import SwiftUI
import UniformTypeIdentifiers

/// CPU, memory, network and disk at a glance, and the processes working hardest.
struct ActivityPanel: View {
    @ObservedObject var monitor: ActivityMonitor

    var body: some View {
        let s = monitor.sample
        HStack(alignment: .top, spacing: 20) {
            cpu(s).frame(width: 170, alignment: .topLeading)
            memory(s).frame(width: 188, alignment: .topLeading)
            processes(s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 184, alignment: .top)
    }

    private func cpu(_ s: ActivitySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "CPU")
            HStack(spacing: 10) {
                GaugeRing(fraction: s.cpu, color: .cpuBlue, size: 60, lineWidth: 6.5) {
                    Text(percent(s.cpu))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 5) {
                    share("User", s.cpuUser, color: .cpuBlue)
                    share("System", s.cpuSystem, color: .cpuBlue.opacity(0.55))
                    share("Idle", max(0, 1 - s.cpu), color: .white.opacity(0.25))
                }
            }
            Sparkline(values: monitor.cpuHistory, maximum: 1, capacity: ActivityMonitor.historyLength, color: .cpuBlue)
                .frame(height: 30)
            Text("\(s.cores) cores · Load \(s.loadAverage, specifier: "%.1f") · \(s.thermalLabel)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }

    private func share(_ title: String, _ fraction: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 4)
            Text(percent(fraction)).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .frame(width: 98)
    }

    private func memory(_ s: ActivitySample) -> some View {
        let color = memoryColor(s.pressure)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Memory")
            HStack(spacing: 14) {
                GaugeRing(fraction: s.memoryFraction, color: color, size: 60, lineWidth: 6.5) {
                    Text(percent(s.memoryFraction))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(formatMemory(s.memoryUsed)) of \(formatMemory(s.memoryTotal))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1)
                    Text("Pressure \(s.pressure.label.lowercased())")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(s.pressure == .nominal ? .white.opacity(0.55) : color)
                    Text(s.swapUsed == 0 ? "No swap used" : "Swap \(formatMemory(s.swapUsed))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                }
            }
            SectionLabel(text: "Network & Disk").padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                rates("network", down: s.networkIn, up: s.networkOut)
                rates("internaldrive", down: s.diskRead, up: s.diskWrite)
            }
        }
    }

    private func rates(_ symbol: String, down: Double, up: Double) -> some View {
        HStack(spacing: 8) {
            Text(Image(systemName: symbol)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).frame(width: 16)
            rate("arrow.down", down)
            rate("arrow.up", up)
        }
    }

    private func rate(_ arrow: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(Image(systemName: arrow)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(value > 0 ? 0.8 : 0.3))
            Text(formatRate(value)).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(value > 0 ? 1 : 0.5))
        }
        .frame(width: 76, alignment: .leading)
    }

    private func processes(_ s: ActivitySample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Top Processes")
            if s.processes.isEmpty {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.processes.prefix(5)) { ProcessRow(process: $0) }
                }
            }
            Spacer(minLength: 0)
            Button(action: ActivityMonitor.openActivityMonitor) {
                HStack(spacing: 5) {
                    Text(Image(systemName: "arrow.up.forward.app")).font(.system(size: 10, weight: .semibold))
                    Text("Open Activity Monitor").font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.95))
        }
    }
}

private struct ProcessRow: View {
    let process: ActivityProcess

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIcons.icon(for: process))
                .resizable().frame(width: 16, height: 16)
            Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            Text(formatMemory(process.memory))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                .frame(width: 52, alignment: .trailing)
            Text(String(format: "%.1f%%", process.cpu * 100))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(process.cpu >= 0.5 ? Color.cpuBlue : .white)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 20)
    }
}

/// App icons for the process list, looked up once per app.
@MainActor
private enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]
    private static let generic: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .unixExecutable)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    static func icon(for process: ActivityProcess) -> NSImage {
        guard let bundle = process.bundlePath else { return generic }
        if let cached = cache[bundle] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        icon.size = NSSize(width: 16, height: 16)
        cache[bundle] = icon
        return icon
    }
}

/// The compact version for Home: CPU and memory gauges and the network rate.
struct HomeActivityWidget: View {
    @ObservedObject var monitor: ActivityMonitor
    let open: () -> Void

    var body: some View {
        let s = monitor.sample
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Activity", action: open) { Image(systemName: "gauge.with.dots.needle.33percent") }
            VStack(alignment: .leading, spacing: 4) {
                gauge(s.cpu, color: .cpuBlue, title: "CPU")
                gauge(s.memoryFraction, color: memoryColor(s.pressure), title: "Memory")
                HStack(spacing: 8) {
                    rate("arrow.down", s.networkIn)
                    rate("arrow.up", s.networkOut)
                }
                .frame(height: 16)
            }
        }
    }

    private func gauge(_ fraction: Double, color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            GaugeRing(fraction: fraction, color: color, size: 16, lineWidth: 2.5) { EmptyView() }
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 4)
            Text(percent(fraction)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        }
        .frame(height: 16)
    }

    private func rate(_ arrow: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(Image(systemName: arrow)).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(value > 0 ? 0.8 : 0.3))
            Text(formatRate(value)).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(value > 0 ? 0.9 : 0.5))
        }
    }
}

// MARK: - Pieces

/// A ring that fills clockwise to `fraction`.
///
/// The ring is a `CAShapeLayer`, so the window server animates each change and NotchBar
/// draws nothing in between. A SwiftUI shape would be redrawn on the CPU for every frame of
/// every change, which at one sample every two seconds added up to a sixth of a core.
struct GaugeRing<Label: View>: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 60
    var lineWidth: CGFloat = 6
    @ViewBuilder let label: Label

    var body: some View {
        ZStack {
            if Snapshotter.isRendering {
                // ImageRenderer leaves out AppKit views, so stills draw the ring in SwiftUI.
                Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.003, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                RingLayer(fraction: fraction, color: color, lineWidth: lineWidth)
            }
            label
        }
        .frame(width: size, height: size)
    }
}

private struct RingLayer: NSViewRepresentable {
    let fraction: Double
    let color: Color
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.set(fraction: fraction, color: NSColor(color), lineWidth: lineWidth)
    }
}

private final class RingView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var lineWidth: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(fraction: Double, color: NSColor, lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fill.strokeColor = color.cgColor
        fill.strokeEnd = max(0.003, min(1, fraction))
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        // From the top, clockwise. Layers aren't flipped, so clockwise on screen is clockwise here.
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
            ring.lineWidth = lineWidth
        }
        CATransaction.commit()
    }
}

/// Recent values as a line with a soft fill, newest at the right. A short history grows in
/// from the right edge.
struct Sparkline: View {
    let values: [Double]
    let maximum: Double
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let top = max(maximum, values.max() ?? 0, 0.0001)
            let step = size.width / CGFloat(max(1, capacity - 1))
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width - CGFloat(values.count - 1 - index) * step,
                        y: size.height - CGFloat(min(1, value / top)) * (size.height - 2) - 1)
            }
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

func memoryColor(_ pressure: ActivitySample.Pressure) -> Color {
    switch pressure {
    case .nominal: return .memoryGreen
    case .warning: return .claudeWaiting
    case .critical: return .red
    }
}

private func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

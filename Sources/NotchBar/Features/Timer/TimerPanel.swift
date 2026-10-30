import SwiftUI

struct TimerPanel: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            HStack(alignment: .center, spacing: 22) {
                TimerRing(timer: timer, now: ctx.date, size: 104, lineWidth: 8)
                switch timer.phase {
                case .idle:
                    idle
                case .running, .paused:
                    running(now: ctx.date)
                case .finished:
                    finished
                }
            }
            .frame(height: 112)
        }
    }

    // MARK: Idle

    private var idle: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK START").font(.system(size: 9.5, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.white.opacity(0.4))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 8), count: 3), spacing: 8) {
                    ForEach(TimerModel.presets, id: \.self) { m in
                        Button { timer.start(minutes: m) } label: {
                            Text("\(m) min")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 62, height: 30)
                                .background(Capsule().fill(.white.opacity(0.09)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    CircleIconButton(systemName: "minus", size: 28, iconSize: 11, help: "One minute less") {
                        timer.pickerMinutes = max(1, timer.pickerMinutes - 1)
                    }
                    Text("\(timer.pickerMinutes) min")
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(timer.pickerMinutes)))
                        .frame(width: 58)
                        .animation(.snappy, value: timer.pickerMinutes)
                    CircleIconButton(systemName: "plus", size: 28, iconSize: 11, help: "One minute more") {
                        timer.pickerMinutes = min(180, timer.pickerMinutes + 1)
                    }
                }
                Button { timer.start(minutes: timer.pickerMinutes) } label: {
                    Text("Start")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 128, height: 32)
                        .background(Capsule().fill(Color.timerOrange))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
            }
        }
    }

    // MARK: Running

    private func running(now: Date) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(timer.isRunning ? "Timer" : "Paused")
                    .font(.system(size: 13.5, weight: .semibold))
                if let end = timer.endDate {
                    Label("Ends at \(end.formatted(date: .omitted, time: .shortened))", systemImage: "bell.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text("\(formatClock(timer.remaining(at: now))) left")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                }
                Button { timer.addMinute() } label: {
                    Text("+1 min").font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.09)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                RoundAction(symbol: "xmark", fill: .white.opacity(0.14), tint: .white, size: 46, help: "Cancel") {
                    timer.cancel()
                }
                RoundAction(symbol: timer.isRunning ? "pause.fill" : "play.fill",
                            fill: Color.timerOrange.opacity(0.22), tint: .timerOrange, size: 56,
                            help: timer.isRunning ? "Pause" : "Resume") {
                    timer.isRunning ? timer.pause() : timer.resume()
                }
            }
        }
    }

    // MARK: Finished

    private var finished: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Time's up").font(.system(size: 15, weight: .semibold))
                Text("\(durationLabel(timer.duration)) timer").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                RoundAction(symbol: "arrow.counterclockwise", fill: .white.opacity(0.14), tint: .white, size: 46, help: "Repeat") {
                    timer.start(seconds: timer.duration)
                }
                RoundAction(symbol: "stop.fill", fill: Color.timerOrange, tint: .black, size: 56, help: "Stop") {
                    timer.dismissAlert()
                }
            }
        }
    }
}

struct TimerRing: View {
    @ObservedObject var timer: TimerModel
    let now: Date
    var size: CGFloat
    var lineWidth: CGFloat
    var showsText = true

    var body: some View {
        let progress = timer.progress(at: now)
        let dim = timer.phase == .idle
        ZStack {
            Circle().stroke(Color.timerOrange.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, progress))
                .stroke(Color.timerOrange.opacity(dim ? 0.6 : 1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            if showsText {
                VStack(spacing: 1) {
                    Text(formatClock(timer.remaining(at: now)))
                        .font(.system(size: size * 0.2, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                    Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var caption: String {
        switch timer.phase {
        case .idle: return "ready"
        case .paused: return "paused"
        case .finished: return "done"
        case .running: return durationLabel(timer.duration)
        }
    }
}

/// Compact ring and time shown beside the notch while a timer runs.
struct TimerWing: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            HStack(spacing: 5) {
                TimerRing(timer: timer, now: ctx.date, size: 13, lineWidth: 2.2, showsText: false)
                Text(formatClock(timer.remaining(at: ctx.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isRunning ? Color.timerOrange : .white.opacity(0.6))
                    .contentTransition(.numericText(countsDown: true))
            }
        }
    }
}

struct RoundAction: View {
    let symbol: String
    let fill: Color
    let tint: Color
    var size: CGFloat
    var help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size, height: size)
                .background(Circle().fill(fill).brightness(hover ? 0.08 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(help)
    }
}

/// The banner that drops from the notch when a timer ends.
struct TimerAlertRow: View {
    @ObservedObject var timer: TimerModel
    let onDismiss: () -> Void
    @State private var ring = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.timerOrange))
                .rotationEffect(.degrees(ring ? 12 : -12))
            VStack(alignment: .leading, spacing: 1) {
                Text("Timer Done").font(.system(size: 12.5, weight: .semibold))
                Text(durationLabel(timer.duration)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text("Stop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(Color.timerOrange))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.92))
        }
        .foregroundStyle(.white)
        .onAppear { withAnimation(.easeInOut(duration: 0.12).repeatCount(9, autoreverses: true)) { ring = true } }
    }
}

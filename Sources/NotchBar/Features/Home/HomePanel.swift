import SwiftUI

/// The master page: a glance at everything, in three columns. Each widget's title opens
/// its full tab.
struct HomePanel: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var timer: TimerModel
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var weather: WeatherStore

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 18) {
                HomeMediaWidget(media: media) { vm.select(.media) }
                MonthGrid(calendar: calendar)
            }
            .frame(width: 252)

            VStack(alignment: .leading, spacing: 18) {
                HomeWeatherWidget(weather: weather)
                upNext
            }
            .frame(width: 214, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 18) {
                HomeClaudeWidget(usage: usage) { vm.select(.claude) }
                HomeTimerWidget(timer: timer) { vm.select(.timer) }
                if vm.isEnabled(.activity) {
                    HomeActivityWidget(monitor: vm.activity) { vm.select(.activity) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 304, alignment: .top)
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Up Next", action: { vm.select(.calendar) }) {
                Image(systemName: "calendar")
            }
            switch calendar.access {
            case .granted:
                if calendar.upcoming.isEmpty {
                    Text("Nothing coming up").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                } else {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(calendar.upcoming.prefix(3)) {
                                EventRow(event: $0, now: context.date, compact: true, actions: .init(store: calendar))
                            }
                        }
                    }
                }
            case .notDetermined:
                WidgetButton(title: "Allow Calendar Access") { calendar.requestAccess() }
            case .denied:
                WidgetButton(title: "Open Settings") { calendar.openPrivacySettings() }
            }
        }
    }
}

/// An icon and title that open the widget's full tab.
struct WidgetHeader<Icon: View>: View {
    let title: String
    var action: (() -> Void)?
    @ViewBuilder var icon: Icon
    @State private var hover = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 6) {
                icon.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Text(title).font(.system(size: 13, weight: .semibold))
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(hover ? 0.6 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct WidgetButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(PressableStyle(scale: 0.95))
    }
}

// MARK: - Widgets

struct HomeMediaWidget: View {
    @ObservedObject var media: MediaController
    let open: () -> Void

    var body: some View {
        let accent = Color(nsColor: media.accent)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ArtworkView(image: media.artwork, size: 46, radius: 11, accent: accent, isAppIcon: media.artworkIsAppIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.nowPlaying?.title ?? "Nothing Playing").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(media.nowPlaying?.artist ?? "Music, Spotify, VLC or a browser")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let entry = media.nowPlaying { AudioWaves(isPlaying: entry.isPlaying, color: accent, height: 15) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)

            if let entry = media.nowPlaying, entry.source.usesMediaKeys, !media.hasAccessibility {
                AccessibilityHint(app: entry.source.appName) { media.requestAccessibility() }
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
            HStack(spacing: 28) {
                if media.nowPlaying?.source.canSkip != false {
                    TransportButton(symbol: "backward.fill", size: 14, diameter: 30) { media.previous() }
                }
                TransportButton(symbol: media.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill", size: 18, big: true, diameter: 38) {
                    media.togglePlayPause()
                }
                if media.nowPlaying?.source.canSkip != false {
                    TransportButton(symbol: "forward.fill", size: 14, diameter: 30) { media.next() }
                }
            }
            .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HomeWeatherWidget: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Weather") { Image(systemName: "cloud.sun") }
            switch weather.access {
            case .on:
                if let w = weather.weather {
                    HStack(spacing: 8) {
                        Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 22))
                        Text("\(w.temperature)°").font(.system(size: 28, weight: .semibold, design: .rounded))
                    }
                    Text(w.condition).font(.system(size: 13, weight: .semibold))
                    Text([w.place, "H \(w.high)° L \(w.low)°"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                } else {
                    Text("Getting the weather…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            case .off:
                Text("Uses your approximate location.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                WidgetButton(title: "Show Weather") { weather.turnOn() }
            case .waiting:
                Text("Waiting for location access…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 8) {
                    WidgetButton(title: "Ask Again") { weather.turnOn() }
                    Button("Cancel") { weather.turnOff() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            case .denied:
                Text("Location access is off for NotchBar.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                WidgetButton(title: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            }
        }
    }
}

struct HomeClaudeWidget: View {
    @ObservedObject var usage: ClaudeUsageStore
    let open: () -> Void

    var body: some View {
        let fraction = usage.sessionFraction
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Claude", action: open) { ClaudeLogo(size: 13) }
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 5)
                    Circle().trim(from: 0, to: max(0.002, fraction))
                        .stroke(usageColor(fraction), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusText).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(usage.activity == .idle ? .white : (usage.activity == .waiting ? Color.claudeWaiting : .claude))
                    TimelineView(.everyMinute) { context in
                        Text(formatCountdown(to: usage.sessionResetsAt, now: context.date).map { "\($0) left" } ?? "No session")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            if let week = usage.weeklyWindows.first {
                Text("\(week.label) \(Int(week.percent.rounded()))%").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            } else {
                Text("\(formatTokens(usage.snapshot.weekTokens)) this week").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var statusText: String {
        switch usage.activity {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .idle: return usage.sessionIsReal ? "Session" : "Est. session"
        }
    }
}

struct HomeTimerWidget: View {
    @ObservedObject var timer: TimerModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Timer", action: open) { Image(systemName: "timer") }
            if timer.isActive || timer.phase == .finished {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        TimerRing(timer: timer, now: context.date, size: 22, lineWidth: 3, showsText: false)
                        Text(formatClock(timer.remaining(at: context.date)))
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(timer.isRunning ? Color.timerOrange : .white)
                    }
                }
                HStack(spacing: 8) {
                    if timer.phase == .finished {
                        RoundAction(symbol: "stop.fill", fill: Color.timerOrange, tint: .black, size: 30, help: "Stop") { timer.dismissAlert() }
                    } else {
                        RoundAction(symbol: timer.isRunning ? "pause.fill" : "play.fill", fill: Color.timerOrange.opacity(0.22),
                                    tint: .timerOrange, size: 30, help: timer.isRunning ? "Pause" : "Resume") {
                            timer.isRunning ? timer.pause() : timer.resume()
                        }
                        RoundAction(symbol: "xmark", fill: .white.opacity(0.14), tint: .white, size: 30, help: "Cancel") { timer.cancel() }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach([5, 15, 25], id: \.self) { minutes in
                        Button { timer.start(minutes: minutes) } label: {
                            Text("\(minutes)m").font(.system(size: 11.5, weight: .semibold))
                                .frame(width: 38, height: 26)
                                .background(Capsule().fill(.white.opacity(0.09)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                    }
                }
            }
        }
    }
}

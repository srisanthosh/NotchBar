import SwiftUI

struct ClaudePanel: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var usage: ClaudeUsageStore
    @State private var shownFraction = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            HStack(alignment: .center, spacing: 20) {
                ring
                details(now: now)
                    .frame(width: 236, alignment: .leading)
                activity
            }
            .frame(height: 112)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.1)) { shownFraction = usage.sessionFraction }
        }
        .onChange(of: usage.sessionFraction) { _, f in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shownFraction = f }
        }
    }

    private var ring: some View {
        let color = usageColor(usage.sessionFraction)
        return ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.002, shownFraction))
                .stroke(AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, shownFraction))),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 6)
            VStack(spacing: 1) {
                Text("\(Int((usage.sessionFraction * 100).rounded()))%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(value: usage.sessionFraction))
                Text(usage.sessionIsReal ? "session" : "est. session")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 104, height: 104)
    }

    private func details(now: Date) -> some View {
        let snap = usage.snapshot
        let reset = formatCountdown(to: usage.sessionResetsAt, now: now)
        return VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Current session").font(.system(size: 13.5, weight: .semibold))
                    if usage.activity != .idle { ActivityBadge(activity: usage.activity) }
                }
                Text(reset.map { "Resets in \($0)" } ?? "No active session")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            weekly(now: now)
            if usage.weeklyWindows.count < 2 {
            HStack(spacing: 16) {
                stat("Session", formatTokens(snap.sessionTokens))
                stat("Today", formatTokens(snap.todayTokens))
                stat("Replies", "\(snap.sessionMessages)")
            }
            }
        }
    }

    @ViewBuilder private func weekly(now: Date) -> some View {
        let windows = usage.weeklyWindows
        if windows.isEmpty {
            // Without Claude Code's numbers there is no honest weekly percentage, so show the volume.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("This week").font(.system(size: 11, weight: .semibold))
                    Text(formatTokens(usage.snapshot.weekTokens) + " tokens")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Color.claude)
                }
                Text(weeklyHint)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(windows.prefix(2)) { w in
                    LimitBar(title: w.label, fraction: w.percent / 100,
                             trailing: formatCountdown(to: w.resetsAt, now: now).map { "resets in \($0)" } ?? "")
                }
            }
        }
    }

    private var weeklyHint: String {
        if usage.sessionIsReal { return "Weekly limit isn't shared with Claude Code" }
        if usage.isConnected { return "Weekly % comes from claude in Terminal" }
        return "Connect to see your real limits"
    }

    private var activity: some View {
        let snap = usage.snapshot
        let peak = max(1, snap.buckets.max() ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Activity")
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(Array(snap.buckets.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(v > 0 ? Color.claude.opacity(0.35 + 0.65 * Double(v) / Double(peak)) : .white.opacity(0.08))
                        .frame(width: 4, height: max(3, 34 * CGFloat(v) / CGFloat(peak)))
                }
            }
            .frame(height: 34, alignment: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(snap.models.prefix(2)) { m in
                    HStack(spacing: 5) {
                        Circle().fill(m.id == snap.models.first?.id ? Color.claude : .white.opacity(0.4)).frame(width: 5, height: 5)
                        Text(m.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(formatTokens(m.tokens)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            Spacer(minLength: 0)
            sourceLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sourceLine: some View {
        if !usage.hasHooks {
            Button(action: connect) {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(.system(size: 9.5, weight: .bold))
                    Text(usage.isConnected ? "Turn on instant activity" : "Connect Claude Code")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(Color.claude))
            }
            .buttonStyle(PressableStyle(scale: 0.95))
        } else if usage.usesRealLimits, let updated = usage.limits?.updatedAt {
            Label("Live from Claude Code · \(updated.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                .labelStyle(.titleAndIcon)
        } else {
            // Only the terminal app reports plan limits. Anyone else can type in what Claude shows.
            Button { UsageMatchPrompt.run(usage: usage, vm: vm) } label: {
                HStack(spacing: 4) {
                    Text(estimateNote).foregroundStyle(.white.opacity(0.4))
                    Text(usage.calibration?.manual == true ? "Rematch" : "Match Claude").foregroundStyle(Color.claude)
                }
                .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Type in the session numbers from Claude's usage page")
        }
    }

    private var estimateNote: String {
        guard let calibration = usage.calibration else { return "Estimated ·" }
        let when = calibration.at.formatted(.relative(presentation: .named))
        return calibration.manual ? "Estimated, matched \(when) ·" : "Estimated from Terminal \(when) ·"
    }

    private func connect() {
        switch usage.connect() {
        case .connected:
            vm.showToast("Connected. Claude's activity now shows the moment it starts and stops.")
        case .connectedKeepingStatusLine:
            vm.showToast("Connected. Your own status line was kept, so limits stay estimated.")
        case .failed(let reason):
            vm.showToast("Couldn't connect: \(reason)")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

struct LimitBar: View {
    let title: String
    let fraction: Double
    let trailing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usageColor(fraction))
                Spacer(minLength: 4)
                Text(trailing).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule().fill(usageColor(fraction).gradient)
                        .frame(width: max(5, g.size.width * min(1, fraction)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// "Working" while Claude Code writes, "Needs you" while it waits for an approval.
struct ActivityBadge: View {
    let activity: ClaudeActivity
    @State private var pulse = false

    var body: some View {
        let color = activity == .waiting ? Color.claudeWaiting : .claude
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
                .scaleEffect(pulse ? 1.35 : 0.8).opacity(pulse ? 1 : 0.5)
            Text(activity == .waiting ? "Needs you" : "Working").font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

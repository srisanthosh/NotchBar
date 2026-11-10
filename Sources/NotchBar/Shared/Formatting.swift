import Foundation

/// 1234 -> "1.2K", 15_400_000 -> "15M".
func formatTokens(_ n: Int) -> String {
    let d = Double(n)
    switch d {
    case 1_000_000_000...: return String(format: "%.1fB", d / 1e9)
    case 10_000_000...: return String(format: "%.0fM", d / 1e6)
    case 1_000_000...: return String(format: "%.1fM", d / 1e6)
    case 10_000...: return String(format: "%.0fK", d / 1e3)
    case 1_000...: return String(format: "%.1fK", d / 1e3)
    default: return "\(n)"
    }
}

/// Time left until `date`, such as "2h 14m" or "3d 4h". Nil once it has passed.
func formatCountdown(to date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let s = Int(date.timeIntervalSince(now))
    guard s > 0 else { return nil }
    let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(1, m))m"
}

/// Playback position, such as "3:07" or "1:02:45".
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

/// A countdown clock that rounds up, so "0:01" shows until the very end.
func formatClock(_ t: TimeInterval) -> String {
    formatTime(t.rounded(.up))
}

/// "45 sec" or "25 min".
func durationLabel(_ t: TimeInterval) -> String {
    t < 60 ? "\(Int(t.rounded())) sec" : "\(Int((t / 60).rounded())) min"
}

/// Memory the way Activity Monitor shows it: "15.2 GB", "412 MB".
func formatMemory(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}

/// A transfer rate, such as "1.2 MB/s" or "0 KB/s".
func formatRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0 KB/s" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.zeroPadsFractionDigits = false
    return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}

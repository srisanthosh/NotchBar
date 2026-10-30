import Foundation

/// What Claude Code is doing right now, across all sessions.
enum ClaudeActivity: Equatable {
    case idle
    case working
    /// Waiting for you, for example to approve a tool.
    case waiting
}

/// One rate-limit window reported by Claude Code.
struct LimitWindow: Equatable, Identifiable {
    var key: String
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { key }
}

/// Real limits reported by Claude Code to its status line.
struct RealLimits: Equatable {
    var session: LimitWindow?
    /// The overall weekly window first, then any per-model weekly windows.
    var weekly: [LimitWindow]
    var updatedAt: Date
}

struct ModelShare: Equatable, Identifiable {
    var name: String
    var tokens: Int
    var id: String { name }
}

/// A real session reading matched against what the transcripts cost at that moment.
struct UsageCalibration: Codable, Equatable {
    var costPerPercent: Double
    var windowStart: Date
    var percent: Double
    var at: Date
    /// Typed in from Claude's usage page rather than read from the terminal.
    var manual: Bool
}

/// Usage reconstructed from Claude Code's local transcripts.
struct UsageSnapshot: Equatable {
    var sessionTokens = 0
    /// Tokens weighted by what they cost, which is what plan limits count.
    var sessionCost = 0.0
    var sessionMessages = 0
    var sessionStart: Date?
    var sessionEnd: Date?
    var todayTokens = 0
    var weekTokens = 0
    var peakSessionTokens = 0
    var models: [ModelShare] = []
    /// Twenty 15-minute buckets spanning the current five-hour window.
    var buckets: [Int] = Array(repeating: 0, count: 20)
}

/// The token budget used to estimate session usage when real limits aren't available.
enum SessionLimit: String, CaseIterable, Identifiable {
    case peak, k500, m1, m2, m5, m10
    var id: String { rawValue }

    var tokens: Int? {
        switch self {
        case .peak: return nil
        case .k500: return 500_000
        case .m1: return 1_000_000
        case .m2: return 2_000_000
        case .m5: return 5_000_000
        case .m10: return 10_000_000
        }
    }

    var label: String { self == .peak ? "Your busiest session" : formatTokens(tokens ?? 0) + " tokens" }
}

/// "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5".
func prettyModelName(_ id: String) -> String {
    var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
    parts.removeAll { $0.count >= 6 && $0.allSatisfy(\.isNumber) }
    guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return id }
    let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
    return family.capitalized + (version.isEmpty ? "" : " " + version)
}

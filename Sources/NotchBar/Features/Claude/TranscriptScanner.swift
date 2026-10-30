import Foundation

/// Reads Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`) to estimate usage.
///
/// Files are append-only, so it remembers how far it has read each one and only reads new
/// lines. It is not thread-safe: use it from one serial queue.
final class TranscriptScanner: @unchecked Sendable {
    struct Result {
        var snapshot: UsageSnapshot
        /// Sessions whose new lines include "[Request interrupted by user]".
        var interrupted: Set<String>
    }

    private struct Event { let date: Date; let model: String; let tokens: Int; let cost: Double }

    private let root = ClaudeCodeIntegration.projectsFolder
    private let lookback: TimeInterval = 8 * 86_400
    private var offsets: [String: UInt64] = [:]
    private var events: [String: Event] = [:]
    private var interrupted: Set<String> = []
    /// Most writes are progress lines with no token usage. Then the totals can't have
    /// changed, and the last snapshot is reused instead of recomputing a week of events.
    private var eventsChanged = true
    private var lastSnapshot: UsageSnapshot?
    private var lastSnapshotDay = Date.distantPast
    private var anchor: Date?

    private static let usageNeedle = Data("\"output_tokens\"".utf8)
    private static let interruptNeedle = Data("[Request interrupted by user".utf8)
    private let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    /// Reads new lines and recomputes the snapshot.
    /// - Parameter files: Transcripts that changed, or nil to look at every recent transcript.
    /// - Parameter anchor: The start of a five-hour window Claude reported, which beats the guess.
    func update(files: [String]?, now: Date, anchor: Date? = nil) -> Result {
        interrupted = []
        if anchor != self.anchor { self.anchor = anchor; eventsChanged = true }
        let cutoff = now.addingTimeInterval(-lookback)
        for url in files.map({ $0.map(URL.init(fileURLWithPath:)) }) ?? recentTranscripts(since: cutoff) {
            read(url)
        }
        let before = events.count
        events = events.filter { $0.value.date > cutoff }
        if events.count != before { eventsChanged = true }
        // Recompute anyway every few minutes, so the five-hour window and chart roll forward.
        if eventsChanged || lastSnapshot == nil || now.timeIntervalSince(lastSnapshotDay) > 240 {
            lastSnapshot = snapshot(now: now)
            lastSnapshotDay = now
            eventsChanged = false
        }
        return Result(snapshot: lastSnapshot!, interrupted: interrupted)
    }

    /// The session a transcript belongs to: `<project>/<session>.jsonl`, or a subagent's
    /// `<project>/<session>/subagents/<agent>.jsonl`.
    static func sessionID(forTranscript path: String) -> String? {
        let parts = path.components(separatedBy: "/.claude/projects/")
        guard parts.count == 2 else { return nil }
        let components = parts[1].split(separator: "/")
        guard components.count >= 2 else { return nil }
        return String(components[1]).replacingOccurrences(of: ".jsonl", with: "")
    }

    // MARK: Reading

    private func recentTranscripts(since cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified > cutoff else { return nil }
            return url
        }
    }

    private func read(_ url: URL) {
        guard url.pathExtension == "jsonl",
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { return }
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }  // the file was replaced
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)

        let session = Self.sessionID(forTranscript: url.path)
        var consumed: UInt64 = 0
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            // Only whole lines: a line still being written is read next time.
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = buffer[start..<newline]
                if line.range(of: Self.usageNeedle) != nil { parseUsage(Data(line)) }
                if let session, line.range(of: Self.interruptNeedle) != nil, isInterrupt(Data(line)) { interrupted.insert(session) }
                consumed += UInt64(newline - start + 1)
                start = buffer.index(after: newline)
            }
            buffer = Data(buffer[start...])
        }
        offsets[url.path] = offset + consumed
    }

    private func parseUsage(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = isoWithFraction.date(from: stamp) ?? iso.date(from: stamp) else { return }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        // Cache reads are cheap and would swamp everything else, so they are left out.
        let tokens = count("input_tokens") + count("output_tokens") + count("cache_creation_input_tokens")
        // Plan limits follow what a reply costs, so weigh tokens like the API prices them:
        // output 5x input, cache writes 1.25x, cache reads 0.1x, and smaller models less.
        let weight = model.contains("haiku") ? 0.2 : model.contains("sonnet") ? 0.6 : 1
        let cost = weight * (Double(count("input_tokens")) + 5 * Double(count("output_tokens"))
            + 1.25 * Double(count("cache_creation_input_tokens")) + 0.1 * Double(count("cache_read_input_tokens")))
        // Streaming writes the same response more than once. Keep one per message and request.
        let id = message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let key = "\(id)|\(object["requestId"] as? String ?? "")"
        let event = Event(date: date, model: model, tokens: tokens, cost: cost)
        if events[key]?.tokens != tokens || events[key] == nil { eventsChanged = true }
        events[key] = event
    }

    /// Only Claude Code's own interrupt message counts, not the same words inside a command
    /// or a tool's output.
    private func isInterrupt(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "user",
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }
    }

    // MARK: Totals

    /// The weighted cost of replies between two moments, for calibrating against a real reading.
    func cost(from start: Date, to end: Date) -> Double {
        events.values.reduce(0) { $0 + ($1.date >= start && $1.date < end ? $1.cost : 0) }
    }

    /// Claude's windows start on a ten-minute mark: the one before the first message.
    private static func windowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 600).rounded(.down) * 600)
    }

    private func snapshot(now: Date) -> UsageSnapshot {
        let sorted = events.values.sorted { $0.date < $1.date }
        let window: TimeInterval = 5 * 3600
        let calendar = Calendar.current
        var snap = UsageSnapshot()

        // A five-hour block starts with the first message after the last one ended. Use on
        // claude.ai or another Mac can start a window earlier than this Mac sees, so a window
        // Claude reported wins over the guess while it lasts.
        struct Block { var start: Date; var tokens: Int; var cost: Double; var messages: Int }
        var blocks: [Block] = []
        for e in sorted {
            let anchored = anchor.map { e.date >= $0 && e.date < $0.addingTimeInterval(window) } ?? false
            if var b = blocks.last, e.date < b.start.addingTimeInterval(window), !anchored || b.start == anchor {
                b.tokens += e.tokens; b.cost += e.cost; b.messages += 1
                blocks[blocks.count - 1] = b
            } else {
                let start = anchored ? anchor! : Self.windowStart(for: e.date)
                blocks.append(Block(start: start, tokens: e.tokens, cost: e.cost, messages: 1))
            }
        }
        snap.peakSessionTokens = blocks.map(\.tokens).max() ?? 0
        let active = blocks.last.flatMap { now < $0.start.addingTimeInterval(window) ? $0 : nil }
        if let a = active {
            snap.sessionTokens = a.tokens
            snap.sessionCost = a.cost
            snap.sessionMessages = a.messages
            snap.sessionStart = a.start
            snap.sessionEnd = a.start.addingTimeInterval(window)
        }

        let dayStart = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        let bucketStart = active?.start ?? now.addingTimeInterval(-window)
        let modelsSince = active?.start ?? weekStart
        var models: [String: Int] = [:]
        for e in sorted {
            if e.date >= dayStart { snap.todayTokens += e.tokens }
            if e.date >= weekStart { snap.weekTokens += e.tokens }
            let bucket = Int(e.date.timeIntervalSince(bucketStart) / 900)
            if (0..<20).contains(bucket) { snap.buckets[bucket] += e.tokens }
            if e.date >= modelsSince { models[prettyModelName(e.model), default: 0] += e.tokens }
        }
        snap.models = models.map { ModelShare(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        return snap
    }
}

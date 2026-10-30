import Foundation
import Combine

/// Claude usage and activity for the notch.
///
/// It never polls. FSEvents reports when a transcript, the limits file or an activity marker
/// changes, and only then does the store read anything.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    /// The last limits Claude Code reported, which may be from a window that has since reset.
    @Published private(set) var limits: RealLimits? { didSet { scheduleExpiry(); calibrateFromLimits() } }
    /// What a percent of the session limit costs, learned from a real reading. Without it the
    /// estimate has no scale to go on.
    @Published private(set) var calibration: UsageCalibration? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(calibration), forKey: "usageCalibration") }
    }
    private var pendingCalibration: UsageCalibration?
    private var pendingMatchDone: ((Bool) -> Void)?
    private var isStarted = false
    private var needsFullScan = false
    private var expiryTimer: Timer?
    @Published private(set) var activity: ClaudeActivity = .idle
    @Published private(set) var isConnected = false
    /// The activity hooks are what make the working indicator instant.
    @Published private(set) var hasHooks = false
    @Published var sessionLimit: SessionLimit {
        didSet { UserDefaults.standard.set(sessionLimit.rawValue, forKey: "sessionLimit") }
    }

    private let scanner = TranscriptScanner()
    private let queue = DispatchQueue(label: "notchbar.usage", qos: .utility)
    private var watcher: FileWatcher?
    private var changedTranscripts = Set<String>()
    private var scanScheduled = false
    private var isScanning = false

    private var markers: [String: ClaudeCodeIntegration.SessionMarker] = [:]
    /// Sessions the hooks have reported on. Their stops are exact, so they skip the fallback.
    private var hookedSessions = Set<String>()
    /// Last transcript write per session, for sessions without hooks.
    private var lastWrite: [String: Date] = [:]
    private var idleCheck: DispatchWorkItem?
    /// Without hooks, a session counts as working this long after it last wrote.
    private let fallbackWindow: TimeInterval = 8

    /// Rolls the five-hour window and chart forward even when nothing is written.
    private lazy var periodicRescan = EfficientTimer(interval: 300, tolerance: 60) { [weak self] in self?.scan(files: nil) }

    init() {
        sessionLimit = SessionLimit(rawValue: UserDefaults.standard.string(forKey: "sessionLimit") ?? "") ?? .peak
        calibration = UserDefaults.standard.data(forKey: "usageCalibration")
            .flatMap { try? JSONDecoder().decode(UsageCalibration.self, from: $0) }
    }

    /// Sample data for snapshot rendering.
    init(preview snapshot: UsageSnapshot, limits: RealLimits?, activity: ClaudeActivity = .idle) {
        sessionLimit = .peak
        self.snapshot = snapshot
        self.limits = limits
        self.activity = activity
        isConnected = limits != nil
    }

    func start() {
        ClaudeCodeIntegration.upgradeScriptsIfInstalled()
        try? FileManager.default.createDirectory(at: ClaudeCodeIntegration.folder, withIntermediateDirectories: true)
        reloadIntegration()
        let watched = [ClaudeCodeIntegration.projectsFolder, ClaudeCodeIntegration.folder].map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        watcher = FileWatcher(paths: watched) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        watcher?.start()
        isStarted = true
        scan(files: nil)
        periodicRescan.start()
    }

    // MARK: Derived values

    /// The session window Claude Code reported, while it is still the current one. Once its
    /// reset time passes, the reading says nothing about the new window, so NotchBar goes back
    /// to its own estimate instead of showing a stale or made-up 0%.
    var currentSession: LimitWindow? { limits?.session.flatMap { Self.isCurrent($0) ? $0 : nil } }
    var sessionIsReal: Bool { currentSession != nil }
    var weeklyWindows: [LimitWindow] { limits?.weekly.filter(Self.isCurrent) ?? [] }
    var usesRealLimits: Bool { sessionIsReal || !weeklyWindows.isEmpty }
    /// A reading exists but every window in it has reset since.
    var limitsAreStale: Bool { limits != nil && !usesRealLimits }
    var sessionResetsAt: Date? { currentSession?.resetsAt ?? snapshot.sessionEnd }

    private static func isCurrent(_ window: LimitWindow) -> Bool { window.resetsAt.map { $0 > Date() } ?? true }

    /// Refreshes the views the moment a reported window resets.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        let resets = ([limits?.session].compactMap { $0 } + (limits?.weekly ?? [])).compactMap(\.resetsAt).filter { $0 > Date() }
        guard let next = resets.min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send(); self?.scheduleExpiry() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    var sessionFraction: Double {
        if let percent = currentSession?.percent { return percent / 100 }
        if let calibration, calibration.costPerPercent > 0 {
            return min(1, snapshot.sessionCost / (calibration.costPerPercent * 100))
        }
        let budget = Double(sessionLimit.tokens ?? snapshot.peakSessionTokens)
        return budget > 0 ? min(1, Double(snapshot.sessionTokens) / budget) : 0
    }

    // MARK: Connecting

    func connect() -> ClaudeCodeIntegration.Result {
        let result = ClaudeCodeIntegration.connect()
        reloadIntegration()
        return result
    }

    func disconnect() {
        try? ClaudeCodeIntegration.disconnect()
        hookedSessions = []
        reloadIntegration()
    }

    func refresh() { reloadIntegration(); scan(files: nil) }

    // MARK: Calibrating

    /// Takes the numbers Claude's own usage page shows, for people who don't use the terminal.
    /// - Parameter done: Called with false when there's nothing on this Mac to scale against.
    func match(percent: Double, resetsAt: Date, done: ((Bool) -> Void)? = nil) {
        pendingMatchDone = done
        calibrate(UsageCalibration(costPerPercent: 0, windowStart: resetsAt.addingTimeInterval(-Self.window),
                                   percent: percent, at: Date(), manual: true))
    }

    /// A reading the status line saved. A newer one replaces the calibration unless it is too
    /// small to be precise (percentages are whole numbers) and the old one was bigger.
    private func calibrateFromLimits() {
        guard let session = limits?.session, let reset = session.resetsAt, let updated = limits?.updatedAt,
              session.percent >= 1 else { return }
        if let old = calibration, updated <= old.at || (session.percent < 3 && session.percent < old.percent) { return }
        calibrate(UsageCalibration(costPerPercent: 0, windowStart: reset.addingTimeInterval(-Self.window),
                                   percent: session.percent, at: updated, manual: false))
    }

    /// The cost needs the transcripts read, so it is worked out in the next scan. Before the
    /// first scan, that is the full one start() runs.
    private func calibrate(_ request: UsageCalibration) {
        pendingCalibration = request
        if isStarted { scan(files: []) }
    }

    private static let window: TimeInterval = 5 * 3600

    /// The start of a window Claude reported, so the estimate counts the same five hours.
    private var anchor: Date? {
        [limits?.session?.resetsAt?.addingTimeInterval(-Self.window), calibration?.windowStart].compactMap { $0 }.max()
    }

    private func reloadIntegration() {
        hasHooks = ClaudeCodeIntegration.areHooksInstalled
        isConnected = ClaudeCodeIntegration.isStatusLineInstalled || hasHooks
        limits = ClaudeCodeIntegration.readLimits()
        reloadMarkers()
    }

    // MARK: File changes

    private func filesChanged(_ paths: [String]) {
        var markersChanged = false
        for path in paths {
            if path.hasPrefix(ClaudeCodeIntegration.activityFolder.path) {
                markersChanged = true
            } else if path == ClaudeCodeIntegration.limitsFile.path {
                limits = ClaudeCodeIntegration.readLimits()
            } else if path.hasSuffix(".jsonl"), let session = TranscriptScanner.sessionID(forTranscript: path) {
                changedTranscripts.insert(path)
                transcriptWritten(by: session)
            }
        }
        if markersChanged { reloadMarkers() }
        if !changedTranscripts.isEmpty { scheduleScan() }
    }

    private func transcriptWritten(by session: String) {
        lastWrite[session] = Date()
        // Writing after asking for approval means the approval came: back to working.
        if let marker = markers[session], marker.state == .waiting, Date().timeIntervalSince(marker.since) > 1.5 {
            ClaudeCodeIntegration.setActivity(.working, session: session)
        }
        updateActivity()
    }

    /// Batches a burst of writes into one read. Usage totals don't need to be up to the
    /// second, and a busy session writes several times a second.
    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scanScheduled = false
                let files = Array(self.changedTranscripts)
                let full = self.needsFullScan
                self.changedTranscripts = []
                self.needsFullScan = false
                self.scan(files: full ? nil : files)
            }
        }
    }

    private func scan(files: [String]?) {
        guard !isScanning else {
            if let files { changedTranscripts.formUnion(files) } else { needsFullScan = true }
            scheduleScan()
            return
        }
        isScanning = true
        let request = pendingCalibration
        let matchDone = request == nil ? nil : pendingMatchDone
        pendingCalibration = nil
        if request != nil { pendingMatchDone = nil }
        let anchor = anchor
        let oldScale = calibration?.costPerPercent ?? 0
        queue.async { [scanner] in
            var result = scanner.update(files: files, now: Date(), anchor: anchor)
            var learned: UsageCalibration?
            if var request {
                let cost = scanner.cost(from: request.windowStart, to: request.at)
                // 0% only says when the window started, so the old scale stays.
                if request.percent == 0, oldScale > 0 { request.costPerPercent = oldScale }
                else if request.percent > 0, cost > 0 { request.costPerPercent = cost / request.percent }
                if request.costPerPercent > 0 {
                    learned = request
                    if request.windowStart > anchor ?? .distantPast {
                        result = scanner.update(files: [], now: Date(), anchor: request.windowStart)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isScanning = false
                    if let learned { self.calibration = learned }
                    matchDone?(learned != nil)
                    if result.snapshot != self.snapshot { self.snapshot = result.snapshot }
                    // Esc in Claude Code skips the Stop hook, but the transcript records it.
                    for session in result.interrupted where self.markers[session] != nil {
                        ClaudeCodeIntegration.setActivity(.idle, session: session)
                    }
                }
            }
        }
    }

    // MARK: Activity

    private func reloadMarkers() {
        markers = ClaudeCodeIntegration.readActivity()
        hookedSessions.formUnion(markers.keys)
        updateActivity()
    }

    private func updateActivity() {
        let now = Date()
        lastWrite = lastWrite.filter { now.timeIntervalSince($0.value) < 60 }
        let unhookedWrites = lastWrite.filter { !hookedSessions.contains($0.key) }.values
        let newestFallback = unhookedWrites.filter { now.timeIntervalSince($0) < fallbackWindow }.max()

        let next: ClaudeActivity
        if markers.values.contains(where: { $0.state == .waiting }) { next = .waiting }
        else if !markers.isEmpty || newestFallback != nil { next = .working }
        else { next = .idle }
        if next != activity { activity = next }

        // Re-check once the fallback window runs out, instead of polling.
        idleCheck?.cancel()
        if let newestFallback {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updateActivity() } }
            idleCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fallbackWindow - now.timeIntervalSince(newestFallback) + 0.05, execute: work)
        }
    }
}

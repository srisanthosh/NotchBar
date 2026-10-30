import AppKit
import SwiftUI

/// A countdown timer that survives relaunches.
@MainActor
final class TimerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var duration: TimeInterval = 300
    @Published var pickerMinutes: Int { didSet { UserDefaults.standard.set(pickerMinutes, forKey: "timerMinutes") } }
    var onFinish: (() -> Void)?

    static let presets = [1, 3, 5, 10, 25, 45]
    private var fireTimer: Timer?
    private var chimes = 0
    private var chimeTimer: Timer?
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        let d = UserDefaults.standard
        pickerMinutes = max(1, d.integer(forKey: "timerMinutes") == 0 ? 5 : d.integer(forKey: "timerMinutes"))
        guard persist else { return }
        duration = d.double(forKey: "timerDuration") > 0 ? d.double(forKey: "timerDuration") : 300
        if let end = d.object(forKey: "timerEnd") as? Date {
            phase = end > Date() ? .running(end: end) : .idle
            if case .running = phase { schedule(end) }
        } else if d.double(forKey: "timerPaused") > 0 {
            phase = .paused(remaining: d.double(forKey: "timerPaused"))
        }
    }

    var isActive: Bool {
        switch phase { case .running, .paused: return true; default: return false }
    }
    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func remaining(at date: Date) -> TimeInterval {
        switch phase {
        case .idle: return TimeInterval(pickerMinutes * 60)
        case .running(let end): return max(0, end.timeIntervalSince(date))
        case .paused(let r): return r
        case .finished: return 0
        }
    }

    func progress(at date: Date) -> Double {
        switch phase {
        case .idle: return 1
        case .finished: return 0
        default: return duration > 0 ? remaining(at: date) / duration : 0
        }
    }

    var endDate: Date? { if case .running(let end) = phase { return end } else { return nil } }

    // MARK: Actions

    func start(minutes: Int) { start(seconds: TimeInterval(minutes * 60)) }

    func start(seconds: TimeInterval) {
        stopChimes()
        duration = seconds
        let end = Date().addingTimeInterval(seconds)
        update(.running(end: end))
        schedule(end)
    }

    func pause() {
        guard case .running(let end) = phase else { return }
        fireTimer?.invalidate()
        update(.paused(remaining: max(0, end.timeIntervalSinceNow)))
    }

    func resume() {
        guard case .paused(let r) = phase else { return }
        let end = Date().addingTimeInterval(r)
        update(.running(end: end))
        schedule(end)
    }

    func addMinute() {
        switch phase {
        case .running(let end):
            duration += 60
            let newEnd = end.addingTimeInterval(60)
            update(.running(end: newEnd))
            schedule(newEnd)
        case .paused(let r):
            duration += 60
            update(.paused(remaining: r + 60))
        case .finished:
            start(seconds: 60)
        case .idle:
            pickerMinutes = min(180, pickerMinutes + 1)
        }
    }

    func cancel() {
        fireTimer?.invalidate()
        stopChimes()
        update(.idle)
    }

    /// Test hook for snapshots.
    func setPreview(_ phase: Phase, duration: TimeInterval) {
        self.duration = duration
        self.phase = phase
    }

    private func update(_ p: Phase) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { phase = p }
        guard persist else { return }
        let d = UserDefaults.standard
        d.set(duration, forKey: "timerDuration")
        if case .running(let end) = p { d.set(end, forKey: "timerEnd") } else { d.removeObject(forKey: "timerEnd") }
        if case .paused(let r) = p { d.set(r, forKey: "timerPaused") } else { d.removeObject(forKey: "timerPaused") }
    }

    private func schedule(_ end: Date) {
        fireTimer?.invalidate()
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(t, forMode: .common)
        fireTimer = t
    }

    private func finish() {
        update(.finished)
        chimes = 0
        chime()
        chimeTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.chime() }
        }
        onFinish?()
    }

    private func chime() {
        chimes += 1
        if chimes > 4 { stopChimes(); return }
        NSSound(named: "Glass")?.play()
    }

    private func stopChimes() {
        chimeTimer?.invalidate()
        chimeTimer = nil
    }

    func dismissAlert() {
        stopChimes()
        if phase == .finished { update(.idle) }
    }
}

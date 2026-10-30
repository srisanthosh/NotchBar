import AppKit
import Combine

/// Tracks whether anyone can see the notch.
///
/// Everything in NotchBar that polls or animates pauses while the displays sleep or the
/// session is locked, which is most of a laptop's idle time.
@MainActor
final class SystemActivity: ObservableObject {
    static let shared = SystemActivity()

    @Published private(set) var isAwake = true

    private var displaysAsleep = false
    private var locked = false

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.locked = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.locked = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (SystemActivity) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                let awake = !self.displaysAsleep && !self.locked
                if awake != self.isAwake { self.isAwake = awake }
            }
        }
    }
}

/// A repeating timer that only runs while the Mac is awake.
///
/// It also sets a generous tolerance, so macOS can batch its wakeups with other work.
@MainActor
final class EfficientTimer {
    private let interval: TimeInterval
    private let tolerance: TimeInterval
    private let action: () -> Void
    private var timer: Timer?
    private var wanted = false
    private var awakeObserver: AnyCancellable?

    init(interval: TimeInterval, tolerance: TimeInterval? = nil, action: @escaping () -> Void) {
        self.interval = interval
        self.tolerance = tolerance ?? interval * 0.25
        self.action = action
        awakeObserver = SystemActivity.shared.$isAwake.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    var isRunning: Bool { wanted }

    func start() { wanted = true; update() }
    func stop() { wanted = false; update() }

    private func update() {
        let shouldRun = wanted && SystemActivity.shared.isAwake
        if shouldRun, timer == nil {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.action() }
            }
            t.tolerance = tolerance
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !shouldRun, let t = timer {
            t.invalidate()
            timer = nil
        }
    }
}

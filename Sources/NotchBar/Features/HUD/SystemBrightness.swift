import AppKit

/// Built-in display brightness, through the DisplayServices framework that the brightness
/// keys and Control Center use.
///
/// It listens for DisplayServices' change notification rather than sampling the value.
@MainActor
final class SystemBrightness {
    var onChange: ((Float) -> Void)?

    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias RegisterFunction = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32

    private let getBrightness: GetFunction?
    private let setBrightness: SetFunction?
    private let register: RegisterFunction?
    private var last: Float?
    /// Ignore the jump that comes with waking, which isn't the user pressing a key.
    private var quietUntil = Date.distantPast

    /// The notification callback is a C function, so it finds the instance through this.
    private static weak var current: SystemBrightness?

    init() {
        let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getBrightness = dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFunction.self) }
        setBrightness = dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFunction.self) }
        register = dlsym(framework, "DisplayServicesRegisterForBrightnessChangeNotifications").map { unsafeBitCast($0, to: RegisterFunction.self) }
    }

    var brightness: Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(builtInDisplay, &value) == 0 ? value : nil
    }

    func start() {
        last = brightness
        Self.current = self
        _ = register?(builtInDisplay, nil) { _, _, _, _, userInfo in
            let info = userInfo as NSDictionary?
            let value = (info?["value"] as? NSNumber)?.floatValue ?? Float(info?["value"] as? String ?? "")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SystemBrightness.current?.changed(to: value) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.quietUntil = Date().addingTimeInterval(3) }
            }
        }
    }

    /// Keyboard steps are 1/16. Auto-brightness moves in much smaller steps, so it never
    /// shows the HUD.
    private func changed(to reported: Float?) {
        guard let value = reported ?? brightness else { return }
        defer { last = value }
        guard let last, Date() > quietUntil, abs(value - last) >= 0.025 else { return }
        onChange?(value)
    }

    func set(_ value: Float) {
        let clamped = min(1, max(0, value))
        _ = setBrightness?(builtInDisplay, clamped)
    }

    private var builtInDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
}

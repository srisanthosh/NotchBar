import AppKit
import Combine

enum HUDKind: Equatable { case volume, brightness }

struct HUDState: Equatable {
    var kind: HUDKind
    var value: Float
    var muted: Bool
}

/// Shows a notch HUD whenever volume or brightness changes, from any source.
///
/// Optionally it also takes over the volume and brightness keys (Replace System HUD), so the
/// system's own indicator never appears. That part needs Accessibility access.
@MainActor
final class HUDService: ObservableObject {
    @Published var showHUDs: Bool { didSet { UserDefaults.standard.set(showHUDs, forKey: "showHUDs") } }
    @Published private(set) var replaceSystemHUD: Bool
    @Published private(set) var waitingForAccess = false

    let audio = SystemAudio()
    let brightness = SystemBrightness()
    private let keyTap = MediaKeyTap()
    private var trustObserver: NSObjectProtocol?
    var present: ((HUDState) -> Void)?
    /// Called when headphones or speakers connect or disconnect, and again with battery levels.
    var presentDevice: ((DeviceEvent) -> Void)?
    @Published var showDevices: Bool { didSet { UserDefaults.standard.set(showDevices, forKey: "showDevices") } }

    init() {
        let d = UserDefaults.standard
        showHUDs = d.object(forKey: "showHUDs") as? Bool ?? true
        showDevices = d.object(forKey: "showDevices") as? Bool ?? true
        replaceSystemHUD = d.bool(forKey: "replaceSystemHUD")
    }

    func start() {
        audio.onChange = { [weak self] v, muted in self?.emit(HUDState(kind: .volume, value: v, muted: muted)) }
        brightness.onChange = { [weak self] b in self?.emit(HUDState(kind: .brightness, value: b, muted: false)) }
        audio.onOutputChange = { [weak self] previous, current in self?.outputChanged(from: previous, to: current) }
        audio.start()
        brightness.start()
        keyTap.handler = { [weak self] key, fine in self?.handleKey(key, fine: fine) ?? false }
        if replaceSystemHUD { if !keyTap.start() { waitForTrust() } }
    }

    /// Battery levels seen at the last connection, shown again when the device disconnects.
    private var lastBattery: [String: [DeviceEvent.Battery]] = [:]

    private func outputChanged(from previous: AudioOutput?, to current: AudioOutput) {
        guard showDevices else { return }
        if current.isWireless {
            let event = DeviceEvent(name: current.name, symbol: current.symbol, connected: true,
                                    connection: current.isBluetooth ? "Bluetooth" : "AirPlay",
                                    volume: audio.isMuted ? 0 : audio.volume)
            presentDevice?(event)
            guard current.isBluetooth else { return }
            // Battery levels show up a moment after connecting.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) { [weak self] in
                let battery = BluetoothBattery.levels(forDeviceNamed: current.name)
                guard !battery.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.lastBattery[current.name] = battery
                        var updated = event
                        updated.battery = battery
                        self?.presentDevice?(updated)
                    }
                }
            }
        } else if let previous, previous.isWireless {
            presentDevice?(DeviceEvent(name: previous.name, symbol: previous.symbol, connected: false,
                                       battery: lastBattery[previous.name] ?? [],
                                       connection: previous.isBluetooth ? "Bluetooth" : "AirPlay",
                                       soundNowOn: current.name))
        }
    }

    private func emit(_ state: HUDState) {
        guard showHUDs else { return }
        present?(state)
    }

    func setReplaceSystemHUD(_ on: Bool) {
        replaceSystemHUD = on
        UserDefaults.standard.set(on, forKey: "replaceSystemHUD")
        if on {
            if !keyTap.start() {
                MediaKeyTap.requestTrust()
                waitForTrust()
            }
        } else {
            keyTap.stop()
            waitingForAccess = false
        }
    }

    /// macOS posts this distributed notification whenever the Accessibility list changes.
    private func waitForTrust() {
        waitingForAccess = true
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            // The new state lands a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, MediaKeyTap.isTrusted else { return }
                    self.waitingForAccess = false
                    if self.replaceSystemHUD { self.keyTap.start() }
                }
            }
        }
    }

    private func handleKey(_ key: MediaKeyTap.Key, fine: Bool) -> Bool {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard audio.canSetVolume else { return false }
            if key == .mute {
                audio.setMuted(!audio.isMuted)
            } else {
                let current = audio.isMuted && key == .volumeUp ? 0 : audio.volume
                audio.setVolume(snap(current + (key == .volumeUp ? step : -step), step))
                if key == .volumeDown && audio.volume <= 0.001 { audio.setMuted(true) }
            }
            return true
        case .brightnessUp, .brightnessDown:
            guard let b = brightness.brightness else { return false }
            brightness.set(snap(b + (key == .brightnessUp ? step : -step), step))
            return true
        }
    }

    private func snap(_ v: Float, _ step: Float) -> Float { min(1, max(0, (v / step).rounded() * step)) }

    /// Used by the draggable HUD bar.
    func set(_ kind: HUDKind, to value: Float) {
        switch kind {
        case .volume: audio.setVolume(value)
        case .brightness: brightness.set(value)
        }
    }
}

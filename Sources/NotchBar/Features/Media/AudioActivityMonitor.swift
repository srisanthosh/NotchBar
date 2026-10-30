import AppKit
import CoreAudio

/// An app that is currently sending sound to an output device.
struct AudioApp: Equatable {
    let bundleID: String
    let name: String
}

/// Knows which apps are making sound, and which are using the microphone, from CoreAudio's
/// process list (macOS 14.4+).
///
/// It needs no permission. This is how NotchBar notices playback in apps without a scripting
/// interface, and dictation apps like Handy listening.
///
/// Which notifications fire matters. On current macOS, CoreAudio never announces changes to a
/// process's "running output" or "running input" flags, even though their values change. It
/// does announce a process's general "running" flag, each device starting or stopping, and
/// processes coming and going. NotchBar listens to those and then reads the flags it needs.
/// A process's input flag can lag its microphone by about a second, so after each change NotchBar
/// looks again a little later. Nothing polls.
@MainActor
final class AudioActivityMonitor {
    static let shared = AudioActivityMonitor()

    private(set) var playing: [AudioApp] = []
    /// Apps currently recording from a microphone.
    private(set) var recording: [AudioApp] = []
    var onChange: (() -> Void)?
    var onRecordingChange: (() -> Void)?
    private var started = false
    private var watchedDevices: Set<AudioObjectID> = []
    private var inputFollowUps: [DispatchWorkItem] = []

    private var watched: Set<AudioObjectID> = []
    private var pendingEvaluation: DispatchWorkItem?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// Maps a helper process, such as "Google Chrome Helper", to the app it belongs to.
    private let responsiblePID: ResponsibleFunction? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFunction.self) }

    /// Call and chat apps keep their audio open while idle, ready for a ringtone or a call, so
    /// that isn't media. macOS already shows calls with the microphone indicator.
    private static let alwaysOpenApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap", "us.zoom.xos",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.microsoft.Outlook",
    ]

    /// Apple's own processes make sound for alerts and system UI. Only these count as media.
    private static let mediaApps: Set<String> = ["com.apple.Safari", "com.apple.Music", "com.apple.TV", "com.apple.podcasts",
                                                 "com.apple.QuickTimePlayerX", "com.apple.FaceTime"]

    private static var processListAddress = address(kAudioHardwarePropertyProcessObjectList)
    private static var isRunningOutputAddress = address(kAudioProcessPropertyIsRunningOutput)
    private static var isRunningInputAddress = address(kAudioProcessPropertyIsRunningInput)
    private static var processRunningAddress = address(kAudioProcessPropertyIsRunning)
    private static var deviceListAddress = address(kAudioHardwarePropertyDevices)
    private static var deviceRunningAddress = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private static var inputStreamsAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)

    /// Something started or stopped: a process, a device, or the list of processes.
    private lazy var activityChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.scheduleBothEvaluations() }
    }

    func start() {
        guard !started else { return }
        started = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &Self.processListAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchNewProcesses()
                self?.scheduleBothEvaluations()
            }
        }
        AudioObjectAddPropertyListenerBlock(system, &Self.deviceListAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchNewDevices() }
        }
        watchNewProcesses()
        watchNewDevices()
        evaluate()
        evaluateInput()
    }

    private func watchNewProcesses() {
        let current = Set(processObjects())
        for process in current.subtracting(watched) {
            AudioObjectAddPropertyListenerBlock(process, &Self.processRunningAddress, .main, activityChanged)
        }
        // Listeners on processes that exited go away with their objects.
        watched = current
    }

    /// Listens for each speaker and microphone starting or stopping, including ones plugged in later.
    private func watchNewDevices() {
        let current = Set(devices())
        for device in current.subtracting(watchedDevices) {
            AudioObjectAddPropertyListenerBlock(device, &Self.deviceRunningAddress, .main, activityChanged)
        }
        watchedDevices = current
    }

    private func scheduleBothEvaluations() {
        scheduleEvaluation()
        scheduleInputEvaluation()
    }

    private var microphoneOn: Bool {
        watchedDevices.contains { hasInput($0) && isRunning($0, &Self.deviceRunningAddress) }
    }

    /// Sound has to last a moment before it counts, which ignores alert blips, and the same
    /// delay lets the short gap between two tracks pass without a flicker.
    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Recording should show the moment you press the dictation key, so the first look is quick.
    /// The follow-ups catch a recording flag that changes after the notification.
    private func scheduleInputEvaluation() {
        inputFollowUps.forEach { $0.cancel() }
        inputFollowUps = [0.15, 1.2, 2.5].map { delay in
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateInput() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func evaluateInput() {
        var apps: [AudioApp] = []
        for process in watched where isRunning(process, &Self.isRunningInputAddress) {
            guard let app = owningApp(of: process, includeMenuBarApps: true), !apps.contains(app) else { continue }
            apps.append(app)
        }
        guard apps != recording else { return }
        recording = apps
        onRecordingChange?()
    }

    private func evaluate() {
        var apps: [AudioApp] = []
        for process in watched where isRunning(process, &Self.isRunningOutputAddress) {
            guard let app = owningApp(of: process), !apps.contains(app), !Self.alwaysOpenApps.contains(app.bundleID) else { continue }
            apps.append(app)
        }
        // Keep the order things started in, so the newest player is last.
        let ordered = playing.filter(apps.contains) + apps.filter { !playing.contains($0) }
        guard ordered != playing else { return }
        playing = ordered
        onChange?()
    }

    /// For the debug state: whether a microphone is on, whether NotchBar is checking, and every
    /// process recording before filtering.
    var debugRecordingSummary: String {
        let raw = watched.filter { isRunning($0, &Self.isRunningInputAddress) }.map { bundleID(of: $0) ?? "pid \(processID(of: $0))" }
        return "microphoneOn=\(microphoneOn) raw=\(raw.sorted())"
    }

    /// For the debug state: every process sending sound, before filtering, and what NotchBar keeps.
    var debugPlaybackSummary: String {
        let raw = watched.filter { isRunning($0, &Self.isRunningOutputAddress) }.map { process -> String in
            let pid = processID(of: process)
            let policy = NSRunningApplication(processIdentifier: pid).map { "\($0.activationPolicy.rawValue)" } ?? "-"
            return "\(bundleID(of: process) ?? "?")(pid \(pid), policy \(policy))"
        }
        return "raw=\(raw.sorted()) kept=\(playing.map(\.bundleID)) watched=\(watched.count) live=\(processObjects().count)"
    }

    /// The app a CoreAudio process belongs to. Playback counts only apps with a Dock icon, which
    /// skips background sound such as alerts. Recording also counts menu-bar apps, because
    /// dictation apps like Handy live in the menu bar.
    private func owningApp(of process: AudioObjectID, includeMenuBarApps: Bool = false) -> AudioApp? {
        let pid = processID(of: process)
        guard pid != ownPID else { return nil }
        if bundleID(of: process) == "com.apple.WebKit.GPU" {
            // Safari plays media in a shared WebKit process that can't be traced to its app.
            guard let safari = MediaSource.forBundle("com.apple.Safari").runningApp else { return nil }
            return AudioApp(bundleID: "com.apple.Safari", name: safari.localizedName ?? "Safari")
        }
        let accepted: Set<NSApplication.ActivationPolicy> = includeMenuBarApps ? [.regular, .accessory] : [.regular]
        var app = NSRunningApplication(processIdentifier: pid)
        if !(app.map { accepted.contains($0.activationPolicy) } ?? false), let owner = responsiblePID?(pid), owner > 0 {
            app = NSRunningApplication(processIdentifier: owner)
        }
        guard let app, accepted.contains(app.activationPolicy), let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              !id.hasPrefix("com.apple.") || Self.mediaApps.contains(id) else { return nil }
        return AudioApp(bundleID: id, name: app.localizedName ?? id)
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func processObjects() -> [AudioObjectID] { objectList(&Self.processListAddress) }
    private func devices() -> [AudioObjectID] { objectList(&Self.deviceListAddress) }

    private func objectList(_ address: inout AudioObjectPropertyAddress) -> [AudioObjectID] {
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func hasInput(_ device: AudioObjectID) -> Bool {
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &Self.inputStreamsAddress, 0, nil, &size) == noErr && size > 0
    }

    private func isRunning(_ process: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private func processID(of process: AudioObjectID) -> pid_t {
        var address = Self.address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        return value
    }

    private func bundleID(of process: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

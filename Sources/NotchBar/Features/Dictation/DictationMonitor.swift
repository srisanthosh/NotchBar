import AppKit
import Combine

/// Notices when a dictation app, such as Handy, is listening, so the notch can show it.
///
/// It relies on CoreAudio reporting which apps are recording (`AudioActivityMonitor`), so it
/// needs no permission and no polling, and knows nothing about what is said.
@MainActor
final class DictationMonitor: ObservableObject {
    /// The dictation app recording right now, if any.
    @Published private(set) var listening: MediaSource?
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: "showDictation"); update() } }

    /// Speech-to-text apps. Calls and voice notes aren't shown: macOS already marks those
    /// with the orange microphone dot.
    private static let knownApps: Set<String> = [
        "com.pais.handy", "com.superduper.superwhisper", "com.electron.wispr-flow", "com.goodsnooze.MacWhisper",
        "com.prakashjoshipax.VoiceInk", "com.aquavoice.app",
    ]

    private let audio: AudioActivityMonitor

    init(audio: AudioActivityMonitor? = nil) {
        self.audio = audio ?? .shared
        isEnabled = UserDefaults.standard.object(forKey: "showDictation") as? Bool ?? true
    }

    func start() {
        audio.onRecordingChange = { [weak self] in self?.update() }
        audio.start()
        update()
    }

    /// Test hook for snapshots.
    func setPreview(_ source: MediaSource?) { listening = source }

    static func isDictationApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return knownApps.contains(bundleID) || id.contains("whisper") || id.contains("dictat")
    }

    private func update() {
        let app = isEnabled ? audio.recording.last(where: { Self.isDictationApp($0.bundleID) }) : nil
        let source = app.map { MediaSource.forBundle($0.bundleID) }
        if source != listening { listening = source }
    }
}

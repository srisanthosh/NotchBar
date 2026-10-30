import AppKit
import CoreAudio
import AudioToolbox

/// Default output device volume via CoreAudio. Listens for changes from any source, and
/// reports when the output switches to another device, such as headphones connecting.
@MainActor
final class SystemAudio {
    var onChange: ((Float, Bool) -> Void)?
    /// Called with the previous and the new output device.
    var onOutputChange: ((AudioOutput?, AudioOutput) -> Void)?
    private var device = AudioDeviceID(0)
    private var listening: AudioDeviceID?
    private var output: AudioOutput?

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private lazy var changeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.emit() } }
    }

    func start() {
        bind()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bind() }
        }
    }

    private func bind() {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &id)
        if let old = listening {
            AudioObjectRemovePropertyListenerBlock(old, &Self.volumeAddress, .main, changeBlock)
            AudioObjectRemovePropertyListenerBlock(old, &Self.muteAddress, .main, changeBlock)
        }
        device = id
        AudioObjectAddPropertyListenerBlock(id, &Self.volumeAddress, .main, changeBlock)
        AudioObjectAddPropertyListenerBlock(id, &Self.muteAddress, .main, changeBlock)
        listening = id

        let previous = output
        let current = AudioOutput(device: id)
        output = current
        // The first reading happens at launch, which isn't a change.
        if let previous, previous.id != current.id { onOutputChange?(previous, current) }
    }

    private func emit() { onChange?(volume, isMuted) }

    var volume: Float {
        var v = Float32(0)
        var size = UInt32(4)
        AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &v)
        return v
    }

    var isMuted: Bool {
        guard AudioObjectHasProperty(device, &Self.muteAddress) else { return false }
        var m = UInt32(0)
        var size = UInt32(4)
        AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &m)
        return m != 0
    }

    var canSetVolume: Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &Self.volumeAddress, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ value: Float) {
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &Self.volumeAddress, 0, nil, 4, &v)
        if v > 0 && isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard AudioObjectHasProperty(device, &Self.muteAddress) else { return }
        var m = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &Self.muteAddress, 0, nil, 4, &m)
    }
}


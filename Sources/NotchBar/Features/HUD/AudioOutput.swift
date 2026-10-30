import CoreAudio
import Foundation

/// An audio output device, such as the built-in speakers or a pair of AirPods.
struct AudioOutput: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    init(device id: AudioDeviceID) {
        self.id = id
        name = Self.string(id, kAudioObjectPropertyName) ?? "Speakers"
        transport = Self.number(id, kAudioDevicePropertyTransportType) ?? 0
    }

    init(id: AudioDeviceID, name: String, transport: UInt32) {
        self.id = id
        self.name = name
        self.transport = transport
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Headphones and speakers that come and go: Bluetooth and AirPlay.
    var isWireless: Bool { isBluetooth || transport == kAudioDeviceTransportTypeAirPlay }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("powerbeats") {
            if lower.contains("studio buds") { return "beats.studiobuds" }
            if lower.contains("fit pro") { return "beats.fitpro" }
            if lower.contains("powerbeats") { return "beats.powerbeatspro" }
            return "beats.headphones"
        }
        if Self.earbudWords.contains(where: lower.contains) { return "earbuds" }
        if lower.contains("homepod") { return "homepod.fill" }
        if transport == kAudioDeviceTransportTypeAirPlay { return "airplayaudio" }
        if lower.contains("speaker") || lower.contains("soundbar") { return "hifispeaker.fill" }
        return isBluetooth ? "headphones" : "speaker.wave.2.fill"
    }

    /// Words in the names of in-ear headphones from other makers: Galaxy Buds, Pixel Buds,
    /// FreeBuds, Sony WF-1000XM5, Jabra Elite, Nothing Ear (2), Soundcore Liberty and others.
    private static let earbudWords = ["buds", "earbud", "pods", "earphone", "in-ear", "wf-", "elite", "nothing ear",
                                      "ear (", "liberty", "tws", "freeclip"]

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func number(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// The icons for one kind of in-ear headphones: each bud and the charging case.
struct EarbudIcons: Equatable {
    let left: String
    let right: String
    let chargingCase: String

    /// Nil for devices that aren't in-ear, such as over-ear headphones and speakers.
    init?(deviceSymbol: String) {
        switch deviceSymbol {
        case "airpodspro": (left, right, chargingCase) = ("airpodpro.left", "airpodpro.right", "airpodspro.chargingcase.wireless.fill")
        case "airpods": (left, right, chargingCase) = ("airpod.left", "airpod.right", "airpods.chargingcase.fill")
        case "beats.studiobuds": (left, right, chargingCase) = ("beats.studiobuds.left", "beats.studiobuds.right", "beats.studiobuds.chargingcase.fill")
        case "beats.fitpro": (left, right, chargingCase) = ("beats.fitpro.left", "beats.fitpro.right", "beats.fitpro.chargingcase.fill")
        case "beats.powerbeatspro": (left, right, chargingCase) = ("beats.powerbeatspro.left", "beats.powerbeatspro.right", "beats.powerbeatspro.chargingcase.fill")
        case "earbuds": (left, right, chargingCase) = ("earbud.left", "earbud.right", "earbuds.case.fill")
        default: return nil
        }
    }
}

/// A headphone or speaker connecting or disconnecting, for the notch banner.
struct DeviceEvent: Equatable {
    struct Battery: Equatable, Identifiable {
        /// "L", "R", "Case", or "" for a device with one battery.
        let label: String
        let percent: Int
        var id: String { label }
        var isLow: Bool { percent <= 20 }

        var title: String {
            switch label {
            case "L": return "Left"
            case "R": return "Right"
            case "": return "Battery"
            default: return label
            }
        }
    }

    let name: String
    let symbol: String
    let connected: Bool
    var battery: [Battery] = []
    /// How it's connected: "Bluetooth" or "AirPlay".
    var connection: String = "Bluetooth"
    /// Output volume from 0 to 1, when connected.
    var volume: Float?
    /// Where sound plays now, after a device disconnects.
    var soundNowOn: String?
}

/// Battery levels of a connected Bluetooth device, from the system's Bluetooth report.
///
/// AirPods and Beats report left, right and case. Other headphones report one level, or none.
enum BluetoothBattery {
    /// Runs `system_profiler`, which takes a fraction of a second. Call it off the main thread.
    static func levels(forDeviceNamed name: String) -> [DeviceEvent.Battery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = controller["device_connected"] as? [[String: Any]],
              let info = connected.lazy.compactMap({ $0[name] as? [String: Any] }).first else { return [] }
        let labels = [("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"),
                      ("device_batteryLevelCase", "Case"), ("device_batteryLevelMain", "")]
        return labels.compactMap { key, label in
            guard let text = info[key] as? String, let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
            return DeviceEvent.Battery(label: label, percent: percent)
        }
    }
}

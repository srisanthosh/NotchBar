import AppKit
import ApplicationServices

/// Optional: intercepts volume and brightness keys so the system HUD never appears
/// and NotchBar applies the change itself. Needs Accessibility permission.
@MainActor
final class MediaKeyTap {
    enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }
    /// Return true to consume the event.
    var handler: ((Key, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }
    private static var askedThisLaunch = false

    /// Shows the system's Accessibility prompt, at most once per launch.
    static func requestTrust() {
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, Self.isTrusted else { return tap != nil }
        let mask = (CGEventMask(1) << 14) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: me) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        if type == .keyDown {
            // Some keyboards send brightness as plain key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: return handler?(.brightnessUp, fine) ?? false
            case 145: return handler?(.brightnessDown, fine) ?? false
            default: return false
            }
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        default: return false
        }
        // Swallow key-up too, or the system shows its HUD on release.
        return isDown ? (handler?(key, fine) ?? false) : true
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return Unmanaged.passUnretained(event)
        }
        return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}


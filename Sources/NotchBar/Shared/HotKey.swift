import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        Self.installHandler()
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E424152), id: id) // "NBAR"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

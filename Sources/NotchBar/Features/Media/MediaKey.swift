import AppKit

/// The system media keys, the same events F7 to F9 send. macOS routes them to whichever app
/// is playing. Posting them needs Accessibility access.
enum MediaKey: Int32 {
    case play = 16, next = 17, previous = 18

    static func post(_ key: MediaKey) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

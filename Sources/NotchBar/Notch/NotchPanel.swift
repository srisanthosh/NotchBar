import AppKit
import SwiftUI

/// A borderless panel pinned over the notch. It never takes focus, so clicking the notch
/// doesn't pull you out of the app you're in.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click act on a control instead of only activating the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

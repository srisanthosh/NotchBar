import AppKit

/// A nearly invisible window over the closed notch that tells NotchBar when the pointer arrives.
///
/// Watching every pointer move on the screen wakes the app dozens of times a second while you
/// use the mouse. This window gets one event when the pointer enters it and nothing otherwise,
/// so the notch costs nothing while you work elsewhere.
@MainActor
final class PointerSensor {
    var onEnter: (() -> Void)?
    private let window: NSPanel

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        // Fully clear pixels let the pointer pass straight through a window, so the sensor is
        // drawn at the faintest possible alpha. Over the black notch it can't be seen.
        window.backgroundColor = NSColor.black.withAlphaComponent(1 / 255)
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = TrackingView()
        view.onEnter = { [weak self] in self?.onEnter?() }
        window.contentView = view
    }

    /// Covers `rect`, in screen coordinates. Does nothing when it's already there.
    func cover(_ rect: NSRect) {
        let rect = rect.integral
        if window.frame != rect { window.setFrame(rect, display: false) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    var debugSummary: String { "visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))" }

    func setHiddenFromCapture(_ hidden: Bool) { window.sharingType = hidden ? .none : .readOnly }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }

    private final class TrackingView: NSView {
        var onEnter: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // A click that lands before the hand-off still opens the notch.
        override func mouseDown(with event: NSEvent) { onEnter?() }
    }
}

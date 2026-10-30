import AppKit

/// Physical notch measurements for a screen, in points.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let fallback = NotchGeometry(notchWidth: 185, notchHeight: 32, hasNotch: true)

    static func of(_ screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchWidth: width, notchHeight: screen.safeAreaInsets.top, hasNotch: true)
        }
        // Screens without a notch get a pill that hugs the menu bar.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(notchWidth: 180, notchHeight: max(24, menuBar), hasNotch: false)
    }

    /// Prefer the built-in display that has the notch.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}

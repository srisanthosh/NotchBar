import AppKit

/// Tidies the menu bar, like Hidden Bar or Bartender.
///
/// It adds two items: a chevron and, just left of it, a thin divider. When tidy, the
/// divider grows to 10,000 points wide, which pushes every icon to its left off the screen.
/// Clicking the chevron shrinks it again. ⌘-drag an icon to the right of the divider to keep
/// it visible.
///
/// This matters most on notched Macs: when icons don't fit beside the notch, macOS silently
/// hides the extra ones.
@MainActor
final class MenuBarOrganizer: NSObject, ObservableObject {
    static let shared = MenuBarOrganizer()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isShowingAll = false

    private var chevron: NSStatusItem?
    private var divider: NSStatusItem?
    private var autoTidy: DispatchWorkItem?

    private static let enabledKey = "menuBarOrganizer"
    private static let hiddenLength: CGFloat = 10_000
    private static let dividerLength: CGFloat = 13
    /// How long hidden icons stay out after you reveal them.
    private static let revealDuration: TimeInterval = 15

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
    }

    func start() {
        if isEnabled { install() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? install() : uninstall()
    }

    func toggle() { isShowingAll ? tidy() : showAll() }

    /// Debug only: where the chevron and divider sit on screen.
    var debugSummary: String {
        func frame(_ item: NSStatusItem?) -> String { item?.button?.window.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" } ?? "none" }
        return "enabled=\(isEnabled) showingAll=\(isShowingAll) chevron=\(frame(chevron)) divider=\(frame(divider))"
    }

    // MARK: Status items

    private func install() {
        guard chevron == nil else { return }
        // First run: start beside the system icons, so everything else is tidied away.
        // macOS remembers where you drag them after that. Higher numbers sit further left.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSStatusItem Preferred Position NotchBarChevron") == nil {
            defaults.set(0, forKey: "NSStatusItem Preferred Position NotchBarChevron")
            defaults.set(1, forKey: "NSStatusItem Preferred Position NotchBarDivider")
        }

        let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = "NotchBarChevron"
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        chevron.button?.toolTip = "Show or hide menu bar icons. ⌘-drag icons right of the divider to keep them visible."
        self.chevron = chevron

        let divider = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "NotchBarDivider"
        divider.button?.image = Self.dividerImage
        divider.button?.appearsDisabled = true
        self.divider = divider

        tidy()
    }

    private func uninstall() {
        autoTidy?.cancel()
        [chevron, divider].compactMap { $0 }.forEach(NSStatusBar.system.removeStatusItem)
        chevron = nil
        divider = nil
        isShowingAll = false
    }

    private func showAll() {
        divider?.length = Self.dividerLength
        isShowingAll = true
        updateChevron()
        autoTidy?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.tidy() } }
        autoTidy = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDuration, execute: work)
    }

    private func tidy() {
        autoTidy?.cancel()
        divider?.length = Self.hiddenLength
        isShowingAll = false
        updateChevron()
    }

    private func updateChevron() {
        let name = isShowingAll ? "chevron.compact.right" : "chevron.compact.left"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: isShowingAll ? "Hide icons" : "Show hidden icons")
        image?.isTemplate = true
        chevron?.button?.image = image
    }

    @objc private func chevronClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { toggle(); return }
        let menu = NSMenu()
        let show = NSMenuItem(title: isShowingAll ? "Hide Icons" : "Show Hidden Icons", action: #selector(menuToggle), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Stop Tidying the Menu Bar", action: #selector(menuTurnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        chevron?.menu = menu
        chevron?.button?.performClick(nil)
        chevron?.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuTurnOff() { setEnabled(false) }

    /// A thin rounded line marking the boundary between hidden and visible icons.
    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 3, height: 14), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

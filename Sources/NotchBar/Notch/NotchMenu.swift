import AppKit
import ServiceManagement

/// The "…" menu in the open notch.
@MainActor
enum NotchMenu {
    /// A menu item that runs a closure.
    private final class Item: NSMenuItem {
        private var handler: (() -> Void)?

        convenience init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
            self.init(title: title, action: #selector(fire), keyEquivalent: "")
            self.handler = handler
            target = self
            state = checked ? .on : .off
            isEnabled = enabled
        }

        @objc private func fire() { handler?() }
    }

    static func show(vm: NotchViewModel) {
        let organizer = MenuBarOrganizer.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(submenu("Show Tabs", items: NotchViewModel.Tab.allCases.map { tab in
            Item(tab.title, checked: vm.isEnabled(tab), enabled: !(vm.isEnabled(tab) && vm.enabledTabs.count == 1)) {
                vm.setEnabled(tab, !vm.isEnabled(tab))
            }
        }))
        menu.addItem(.separator())
        addClaudeItems(to: menu, vm: vm)
        menu.addItem(.separator())
        addSystemItems(to: menu, vm: vm)
        let tidy = Item("Tidy Menu Bar Icons", checked: organizer.isEnabled) {
            organizer.setEnabled(!organizer.isEnabled)
            if organizer.isEnabled {
                vm.showToast("Icons left of the divider are hidden. Click the chevron to show them, ⌘-drag to rearrange.")
            }
        }
        tidy.toolTip = "Hides menu bar icons you rarely use behind a chevron, so the ones you need fit beside the notch."
        menu.addItem(tidy)
        menu.addItem(.separator())
        menu.addItem(Item("Lock Screen") { vm.close(); ScreenLock.lock() })
        menu.addItem(Item("Quit NotchBar") { NSApp.terminate(nil) })

        vm.isMenuOpen = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        vm.isMenuOpen = false
    }

    private static func addClaudeItems(to menu: NSMenu, vm: NotchViewModel) {
        let usage = vm.usage
        menu.addItem(submenu("Estimated Session Limit", items: SessionLimit.allCases.map { option in
            Item(option.label, checked: usage.sessionLimit == option) { usage.sessionLimit = option }
        }))
        menu.addItem(Item("Match Claude's Usage…") { UsageMatchPrompt.run(usage: usage, vm: vm) })
        if usage.hasHooks {
            menu.addItem(Item("Disconnect Claude Code") { usage.disconnect() })
        } else {
            menu.addItem(Item("Connect Claude Code…") {
                switch usage.connect() {
                case .connected: vm.showToast("Connected. Claude's activity now shows the moment it starts and stops.")
                case .connectedKeepingStatusLine: vm.showToast("Connected. Your own status line was kept, so limits stay estimated.")
                case .failed(let reason): vm.showToast("Couldn't connect: \(reason)")
                }
            })
        }
    }

    private static func addSystemItems(to menu: NSMenu, vm: NotchViewModel) {
        let hud = vm.hudService
        menu.addItem(Item("Show Volume & Brightness", checked: hud.showHUDs) { hud.showHUDs.toggle() })
        menu.addItem(Item("Show Headphone Connections", checked: hud.showDevices) { hud.showDevices.toggle() })
        let dictation = vm.dictation
        menu.addItem(Item("Show Dictation (Handy and Others)", checked: dictation.isEnabled) { dictation.isEnabled.toggle() })
        let replace = Item(hud.waitingForAccess ? "Replace System HUD (waiting for Accessibility)" : "Replace System HUD",
                           checked: hud.replaceSystemHUD) {
            hud.setReplaceSystemHUD(!hud.replaceSystemHUD)
            if hud.replaceSystemHUD && !MediaKeyTap.isTrusted {
                vm.showToast("Allow NotchBar in Privacy & Security > Accessibility.")
            }
        }
        replace.toolTip = "Handles the volume and brightness keys so only the notch HUD appears. Needs Accessibility access."
        menu.addItem(replace)

        let screenshots = Item("Hide from Screenshots", checked: vm.hideFromScreenshots) { vm.hideFromScreenshots.toggle() }
        screenshots.toolTip = "Leaves the notch out of screenshots, screen recordings and shared screens."
        menu.addItem(screenshots)

        let clipboard = vm.clipboard
        if vm.isEnabled(.clipboard) {
            menu.addItem(Item("Pause Clipboard History", checked: clipboard.isPaused) { clipboard.isPaused.toggle() })
            menu.addItem(Item("Clear Clipboard History") { clipboard.clearUnpinned() })
        }

        let login = SMAppService.mainApp
        menu.addItem(Item("Launch at Login", checked: login.status == .enabled) {
            do {
                if login.status == .enabled { try login.unregister() } else { try login.register() }
            } catch {
                vm.showToast("Launch at Login needs the app in /Applications.")
            }
        })
    }

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }
}

import AppKit
import SwiftUI
import ApplicationServices

/// Lets you drive a running NotchBar from the command line while developing.
///
/// Only active when launched with `NOTCHBAR_DEBUG=1`. Post the distributed notification
/// `com.local.notchbar.debug` with one of these as its object:
/// `open:<tab>` (home, media, claude, timer, clipboard, calendar, activity), `media`, `claude`, `timer`,
/// `clipboard`, `calendar`, `activity`, `close`, `peek`, `volume`,
/// `brightness`, `timer5s`, `toggle` (play/pause), `dismiss`, `hover`, `shot:<path.png>` to save the window, or
/// `state:<path.json>` to save what the notch currently shows, or `axtabs:<path.txt>` to dump
/// how Chrome describes its YouTube tabs to Accessibility.
/// See `scripts/debug.sh`.
@MainActor
enum DebugCommands {
    static func install(vm: NotchViewModel, panel: NSPanel, controller: NotchController) {
        guard ProcessInfo.processInfo.environment["NOTCHBAR_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.notchbar.debug"),
                                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let command = note.object as? String else { return }
                run(command, vm: vm, panel: panel, controller: controller)
            }
        }
    }

    private static func run(_ command: String, vm: NotchViewModel, panel: NSPanel, controller: NotchController) {
        let audio = vm.hudService.audio
        switch command {
        case _ where command.hasPrefix("open:"):
            NotchViewModel.Tab(rawValue: String(command.dropFirst(5))).map(vm.open)
        case "media": vm.open(.media)
        case "claude": vm.open(.claude)
        case "timer": vm.open(.timer)
        case "clipboard": vm.toggleClipboard()
        case "calendar": vm.open(.calendar)
        case "activity": vm.open(.activity)
        case "close": vm.close()
        case "peek": vm.show(.nowPlaying)
        case "volume": vm.show(.hud(HUDState(kind: .volume, value: audio.volume, muted: audio.isMuted)))
        case "brightness": vm.show(.hud(HUDState(kind: .brightness, value: vm.hudService.brightness.brightness ?? 0.5, muted: false)))
        case "timer5s": vm.timer.start(seconds: 5)
        case "toggle": vm.media.togglePlayPause()
        case "menubar": MenuBarOrganizer.shared.toggle()
        case "airpods":
            vm.show(.device(DeviceEvent(name: "AirPods Pro", symbol: "airpodspro", connected: true,
                                        battery: [.init(label: "L", percent: 82), .init(label: "R", percent: 79), .init(label: "Case", percent: 45)], volume: 0.5)))
        case "meeting":
            let now = Date()
            vm.show(.meeting(CalendarEvent(id: "debug", title: "Design review", start: now.addingTimeInterval(4 * 60),
                                           end: now.addingTimeInterval(49 * 60), isAllDay: false, location: nil,
                                           color: .systemPurple, joinURL: URL(string: "https://example.com"))))
        case "buds":
            vm.show(.device(DeviceEvent(name: "Galaxy Buds2 Pro", symbol: "earbuds", connected: true, volume: 0.44)))
        case "dismiss": vm.dismissBanner()
        case "hover": withAnimation { vm.isHovering.toggle() }
        case "matchprompt": UsageMatchPrompt.run(usage: vm.usage, vm: vm)
        case _ where command.hasPrefix("match:"):
            // match:<percent>:<seconds until reset>, the same as typing them into Match Claude's Usage.
            let parts = command.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { vm.usage.match(percent: parts[0], resetsAt: Date().addingTimeInterval(parts[1])) }
        case _ where command.hasPrefix("state:"):
            let state: [String: Any] = [
                "media": vm.media.nowPlaying.map { "\($0.title) | \($0.source.appName)" } ?? "",
                "playing": vm.media.nowPlaying?.isPlaying ?? false,
                "pageScripted": vm.media.nowPlaying?.isPageScripted ?? false,
                "pageScriptingOff": vm.media.pageScriptingOff,
                "position": vm.media.nowPlaying.map { "\(Int($0.elapsed(at: Date())))/\(Int($0.duration))" } ?? "",
                "artist": vm.media.nowPlaying?.artist ?? "",
                "dictating": vm.dictation.listening?.appName ?? "",
                "recordingApps": AudioActivityMonitor.shared.recording.map(\.name),
                "recordingDebug": AudioActivityMonitor.shared.debugRecordingSummary,
                "playbackDebug": AudioActivityMonitor.shared.debugPlaybackSummary,
                "claude": "\(vm.usage.activity)",
                "claudeSession": "\(Int((vm.usage.sessionFraction * 100).rounded()))% real=\(vm.usage.sessionIsReal) "
                    + "resets=\(vm.usage.sessionResetsAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "-") "
                    + "cost=\(Int(vm.usage.snapshot.sessionCost)) cal=\(vm.usage.calibration.map { "\(Int($0.costPerPercent))/% manual=\($0.manual)" } ?? "none")",
                "hovering": vm.isHovering,
                "notch": "\(Int(vm.geometry.notchWidth))x\(Int(vm.geometry.notchHeight))",
                "activity": String(format: "cpu=%.0f%% mem=%.0f%% sample=%.1fms", vm.activity.sample.cpu * 100,
                                   vm.activity.sample.memoryFraction * 100, vm.activity.lastSampleDuration * 1000),
                "pointer": controller.debugPointer,
                "expanded": vm.isExpanded,
                "accessibility": AXIsProcessTrusted(),
                "menuBar": MenuBarOrganizer.shared.debugSummary,
                "chromeAudibleTabs": NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
                    .flatMap { AudibleTabs.titles(pid: $0.processIdentifier) } ?? ["unknown"],
            ]
            let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: String(command.dropFirst(6))))
        case _ where command.hasPrefix("browserdiag:"):
            let path = String(command.dropFirst(12))
            DispatchQueue.global().async {
                try? BrowserTabs.diagnose(.forBundle("com.google.Chrome")).write(toFile: path, atomically: true, encoding: .utf8)
            }
        case _ where command.hasPrefix("axtabs:"):
            // Every attribute of Chrome's YouTube tabs, to see how it marks audible ones.
            try? AudibleTabs.debugDump(titleContaining: "YouTube").write(toFile: String(command.dropFirst(7)), atomically: true, encoding: .utf8)
        case _ where command.hasPrefix("layers:"):
            // Live (presentation) transforms of every layer, to check animations are running.
            var lines: [String] = []
            func walk(_ layer: CALayer, _ depth: Int) {
                let t = (layer.presentation() ?? layer).transform
                if t.m22 != 1 || t.m11 != 1 { lines.append(String(format: "%d %.3f %.3f", depth, t.m11, t.m22)) }
                layer.sublayers?.forEach { walk($0, depth + 1) }
            }
            panel.contentView?.layer.map { walk($0, 0) }
            try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst(7)), atomically: true, encoding: .utf8)
        default:
            guard command.hasPrefix("shot:"), let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(command.dropFirst(5))))
        }
    }
}

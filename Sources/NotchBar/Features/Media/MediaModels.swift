import AppKit

/// An app that can play media, and how NotchBar talks to it.
struct MediaSource: Equatable, Hashable {
    enum Kind: Equatable {
        /// Read and controlled through AppleScript.
        case music, spotify, vlc
        /// A browser: the playing tab's title is read through AppleScript.
        case chromium, safari
        /// Any other app making sound. Only its name and icon are known.
        case generic
    }

    let bundleID: String
    let kind: Kind

    static let music = MediaSource(bundleID: "com.apple.Music", kind: .music)
    static let spotify = MediaSource(bundleID: "com.spotify.client", kind: .spotify)
    static let vlc = MediaSource(bundleID: "org.videolan.vlc", kind: .vlc)
    static let scriptable: [MediaSource] = [.music, .spotify, .vlc]

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static func forBundle(_ id: String) -> MediaSource {
        if let player = scriptable.first(where: { $0.bundleID == id }) { return player }
        if chromiumBrowsers.contains(id) { return MediaSource(bundleID: id, kind: .chromium) }
        if id == "com.apple.Safari" { return MediaSource(bundleID: id, kind: .safari) }
        return MediaSource(bundleID: id, kind: .generic)
    }

    var isScriptable: Bool { kind == .music || kind == .spotify || kind == .vlc }
    var isBrowser: Bool { kind == .chromium || kind == .safari }
    /// Controlled with the system media keys, which needs Accessibility access.
    var usesMediaKeys: Bool { !isScriptable }
    /// Browsers forward previous and next to the page. Other apps usually ignore them.
    var canSkip: Bool { kind != .generic }

    var runningApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
    var isRunning: Bool { runningApp != nil }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    var appName: String {
        if let name = runningApp?.localizedName { return name }
        if let url = appURL { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return bundleID
    }

    var icon: NSImage? {
        guard let url = appURL else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 256, height: 256)  // pick the sharp representation when drawn large
        return image
    }
}

/// What is playing right now.
struct NowPlaying: Equatable {
    var source: MediaSource
    var trackID: String
    var title: String
    var artist: String
    var album: String = ""
    /// Zero when the source has no timeline, such as a browser tab.
    var duration: Double = 0
    var elapsed: Double = 0
    var fetchedAt = Date()
    var isPlaying: Bool
    var artworkURL: URL?
    /// The browser tab this came from.
    var tab: TabRef?
    /// True when the page itself reported this, so position and controls are exact.
    var isPageScripted = false

    struct TabRef: Equatable { let window: Int; let index: Int }

    var hasTimeline: Bool { duration > 0 }

    /// Elapsed time, moved forward from the last reading so the scrubber stays smooth.
    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        return min(duration > 0 ? duration : .infinity, elapsed + date.timeIntervalSince(fetchedAt))
    }

    /// True when the two differ in anything a person would notice. Small differences in
    /// position are ignored, so a fresh reading doesn't redraw the notch for nothing.
    func differs(from other: NowPlaying?) -> Bool {
        guard let other else { return true }
        if source != other.source || trackID != other.trackID || title != other.title || artist != other.artist
            || isPlaying != other.isPlaying || duration != other.duration || artworkURL != other.artworkURL { return true }
        return abs(elapsed(at: Date()) - other.elapsed(at: Date())) > 1.5
    }
}

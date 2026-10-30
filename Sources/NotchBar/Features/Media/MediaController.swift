import AppKit
import ApplicationServices

/// Decides what is playing and controls it.
///
/// macOS 15.4+ no longer lets third-party apps read the system Now Playing info, so this
/// combines public sources, cheapest first:
/// - Music and Spotify announce every change with a distributed notification.
/// - CoreAudio reports any app that starts or stops making sound (`AudioActivityMonitor`).
/// - VLC and browser tabs are read with AppleScript, only while they are playing.
///
/// Nothing here polls while nothing is playing.
@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkIsAppIcon = false
    @Published private(set) var accent: NSColor = .white
    /// Accessibility is needed to control browsers and other apps, and to see the moment
    /// Chrome pauses.
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    /// The playing browser refuses page scripts, so progress and artist aren't available.
    @Published private(set) var pageScriptingOff = false

    /// Called with an app name when controlling it needs Accessibility access.
    var onNeedsAccessibility: ((String) -> Void)?

    private let queue = DispatchQueue(label: "notchbar.media", qos: .userInitiated)
    private let audio = AudioActivityMonitor.shared
    private lazy var browserCheck = EfficientTimer(interval: 1.5) { [weak self] in self?.checkBrowserTabs() }
    private lazy var vlcCheck = EfficientTimer(interval: 2) { [weak self] in self?.refresh() }

    private var lastPlayer: MediaSource?
    /// A browser or app that went quiet stays on screen, paused: a browser tab for as long as
    /// its page still has the media (up to 30 minutes), any other app for a minute.
    private var quietApp: (entry: NowPlaying, since: Date)?
    /// Audible tab titles per browser, from `AudibleTabs`. Missing when unknown.
    private var audibleTabs: [String: [String]] = [:]
    private var lastBrowserScript = Date.distantPast
    private var artworkKey: String?
    /// After you press play or pause, keep showing your choice for a moment. Players report
    /// the old state for a second or two (Chrome keeps its "Audio playing" label ~2.5 s).
    private var pendingToggle: (source: MediaSource, playing: Bool, until: Date)?
    private var isFetching = false
    private var needsAnotherFetch = false
    private var needsDiscovery = false

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // macOS posts this whenever the Accessibility list changes.
        distributed.addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self?.hasAccessibility = AXIsProcessTrusted()
                    self?.refresh()
                }
            }
        }
        audio.onChange = { [weak self] in self?.refresh() }
        audio.start()
        refresh()
    }

    // MARK: Reading state

    /// - Parameter discover: Also look in browser tabs for paused media. Used when the notch
    ///   opens with nothing known, never on a timer.
    func refresh(discover: Bool = false) {
        guard !isFetching else {
            needsAnotherFetch = true
            needsDiscovery = needsDiscovery || discover
            return
        }
        let discover = discover || needsDiscovery
        needsDiscovery = false
        let players = MediaSource.scriptable.filter(\.isRunning)
        let soundingApps = audio.playing.filter { !MediaSource.forBundle($0.bundleID).isScriptable }
        let browsers = discover && nowPlaying == nil && quietApp == nil
            ? NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.map(MediaSource.forBundle) }.filter(\.isBrowser)
            : []
        guard !players.isEmpty || !soundingApps.isEmpty || quietApp != nil || !browsers.isEmpty else {
            publish(nil)
            return
        }
        isFetching = true
        let preferred = lastPlayer
        // Browsers making sound, so their audible tabs can be read fresh for ranking.
        let soundingChromium = soundingApps.compactMap { app -> (String, pid_t)? in
            let source = MediaSource.forBundle(app.bundleID)
            guard source.kind == .chromium, let pid = source.runningApp?.processIdentifier else { return nil }
            return (app.bundleID, pid)
        }
        var tabs = audibleTabs
        let quiet = quietApp?.entry
        let current = nowPlaying
        queue.async {
            for (id, pid) in soundingChromium { tabs[id] = AudibleTabs.titles(pid: pid) }
            let states = players.compactMap(PlayerScripts.nowPlaying)
            var playing = states.first(where: \.isPlaying)
            if playing == nil, let app = Self.mostLikelyPlaying(soundingApps, audibleTabs: tabs) {
                let source = MediaSource.forBundle(app.bundleID)
                let audible = tabs[app.bundleID]
                let knownTab = current?.source == source ? current?.tab : nil
                var entry = BrowserTabs.nowPlaying(for: source, appName: app.name, audibleTitle: audible?.first, knownTab: knownTab)
                // The browser still holds its audio stream open, but no tab is audible: paused.
                if audible?.isEmpty == true && !entry.isPageScripted { entry.isPlaying = false }
                playing = entry
            }
            // A paused tab: ask the page where it stands, which also tells us it's still open.
            var reread: NowPlaying?? = nil
            if playing == nil, let quiet, quiet.isPageScripted { reread = .some(BrowserTabs.reread(quiet)) }
            var discovered: NowPlaying?
            if playing == nil, quiet == nil, states.isEmpty {
                discovered = browsers.lazy.compactMap(BrowserTabs.findPausedMedia).first
            }
            let scriptingOff = (playing ?? quiet).map { $0.source.isBrowser && BrowserTabs.isPageScriptingOff($0.source) }
                ?? browsers.contains(where: BrowserTabs.isPageScriptingOff)
            let paused = states.first(where: { $0.source == preferred }) ?? states.first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isFetching = false
                    for (id, _) in soundingChromium { self.audibleTabs[id] = tabs[id] }
                    self.pageScriptingOff = scriptingOff
                    if playing?.source.isBrowser == true { self.lastBrowserScript = Date() }
                    if let reread {
                        if let fresh = reread { self.quietApp = (fresh, self.quietApp?.since ?? Date()) } else { self.quietApp = nil }
                    }
                    if let discovered { self.quietApp = (discovered, Date()) }
                    if let entry = playing, entry.isPlaying == false, entry.isPageScripted {
                        // Paused in a page that still reports itself: show it, and keep it around.
                        self.quietApp = (entry, Date())
                        self.publish(entry)
                    } else {
                        self.resolve(playing: playing, pausedPlayer: paused)
                    }
                    if self.needsAnotherFetch { self.needsAnotherFetch = false; self.refresh() }
                }
            }
        }
    }

    /// Picks the app most likely playing media when several make sound: a browser with an audible
    /// tab, then any other app, then a browser that only holds its stream open. Ties go to the
    /// app that started most recently.
    nonisolated private static func mostLikelyPlaying(_ apps: [AudioApp], audibleTabs: [String: [String]]) -> AudioApp? {
        func rank(_ app: AudioApp) -> Int {
            guard MediaSource.forBundle(app.bundleID).isBrowser else { return 1 }
            return audibleTabs[app.bundleID]?.isEmpty == false ? 2 : 0
        }
        return apps.enumerated().max { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?.element
    }

    private func resolve(playing: NowPlaying?, pausedPlayer: NowPlaying?) {
        if let playing {
            if playing.source.isScriptable { lastPlayer = playing.source; quietApp = nil }
            else { quietApp = (playing, Date()) }
            publish(playing)
        } else if let quiet = quietApp, quiet.entry.source.isRunning,
                  Date().timeIntervalSince(quiet.since) < (quiet.entry.isPageScripted ? 1800 : 60) {
            var entry = quiet.entry
            entry.isPlaying = false
            publish(entry)
        } else {
            quietApp = nil
            publish(pausedPlayer)
        }
    }

    private func publish(_ reading: NowPlaying?) {
        var entry = reading
        if let pending = pendingToggle, var current = entry, current.source == pending.source {
            if current.isPlaying == pending.playing || Date() > pending.until {
                pendingToggle = nil
            } else {
                current.isPlaying = pending.playing
                entry = current
            }
        }
        if entry?.differs(from: nowPlaying) ?? (nowPlaying != nil) { nowPlaying = entry }
        updateChecks()
        guard let entry else {
            artwork = nil; artworkKey = nil; artworkIsAppIcon = false; accent = .white
            return
        }
        let key = entry.artworkURL?.absoluteString ?? "\(entry.source.bundleID)|\(entry.trackID)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(for: entry, key: key)
        }
    }

    /// Polls only what has no change notification, and only while it is the thing playing.
    private func updateChecks() {
        let source = nowPlaying?.source
        let soundingBrowser = source?.isBrowser == true && audio.playing.contains { $0.bundleID == source?.bundleID }
        soundingBrowser ? browserCheck.start() : browserCheck.stop()
        source == .vlc && source?.isRunning == true ? vlcCheck.start() : vlcCheck.stop()
    }

    /// Notices a paused or changed tab right away (with Accessibility access), and otherwise
    /// re-reads the tab title every few seconds so the next video shows up.
    private func checkBrowserTabs() {
        guard let entry = nowPlaying, entry.source.kind == .chromium, let pid = entry.source.runningApp?.processIdentifier else {
            if Date().timeIntervalSince(lastBrowserScript) > 5 { refresh() }
            return
        }
        let id = entry.source.bundleID
        queue.async {
            let titles = AudibleTabs.titles(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let before = self.audibleTabs[id]
                    self.audibleTabs[id] = titles
                    if titles != before || Date().timeIntervalSince(self.lastBrowserScript) > 5 { self.refresh() }
                }
            }
        }
    }

    // MARK: Artwork

    private func loadArtwork(for entry: NowPlaying, key: String) {
        if let url = entry.artworkURL {
            download(url, key: key, source: entry.source)
            return
        }
        switch entry.source.kind {
        case .music:
            queue.async {
                let image = PlayerScripts.musicArtwork()
                DispatchQueue.main.async { MainActor.assumeIsolated { self.setArtwork(image, key: key, source: entry.source) } }
            }
        case .spotify:
            queue.async {
                let url = PlayerScripts.spotifyArtworkURL()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let url { self.download(url, key: key, source: entry.source) }
                        else { self.setArtwork(nil, key: key, source: entry.source) }
                    }
                }
            }
        default:
            setArtwork(nil, key: key, source: entry.source)
        }
    }

    private func download(_ url: URL, key: String, source: MediaSource) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { MainActor.assumeIsolated { self.setArtwork(image, key: key, source: source) } }
        }.resume()
    }

    private func setArtwork(_ image: NSImage?, key: String, source: MediaSource) {
        guard key == artworkKey else { return }
        // Without cover art, show the app's own icon, the way the system player does.
        let icon = image == nil && !source.isScriptable ? source.icon : nil
        artwork = image ?? icon
        artworkIsAppIcon = icon != nil
        accent = artwork?.vibrantAverageColor ?? .white
    }

    // MARK: Controls

    func togglePlayPause() { control(.toggle) }
    func next() { control(.next) }
    func previous() { control(.previous) }

    func seek(to seconds: Double) {
        guard var entry = nowPlaying, entry.hasTimeline, entry.source.isScriptable || entry.isPageScripted else { return }
        entry.elapsed = seconds
        entry.fetchedAt = Date()
        nowPlaying = entry
        queue.async {
            if let tab = entry.tab, entry.isPageScripted { _ = BrowserTabs.seek(in: entry.source, tab: tab, to: seconds) }
            else { PlayerScripts.seek(entry.source, to: seconds) }
        }
    }

    /// Adds NotchBar to the Accessibility list and opens that page of System Settings.
    func requestAccessibility() {
        MediaKeyTap.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func open(_ source: MediaSource) {
        guard let url = source.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func control(_ command: PlayerScripts.Command) {
        // A page that reports its media is paused and played directly, without media keys.
        if command == .toggle, let entry = nowPlaying, entry.isPageScripted, let tab = entry.tab {
            flipPlayingOptimistically()
            queue.async {
                let done = BrowserTabs.togglePlayback(in: entry.source, tab: tab)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if done { self.refreshSoon() } else { self.postMediaKey(command, flip: false) }
                    }
                }
            }
            return
        }
        guard let entry = nowPlaying, entry.source.isScriptable, entry.source.isRunning else {
            postMediaKey(command)
            return
        }
        if command == .toggle { flipPlayingOptimistically() }
        queue.async {
            PlayerScripts.send(command, to: entry.source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func postMediaKey(_ command: PlayerScripts.Command, flip: Bool = true) {
        guard AXIsProcessTrusted() else {
            MediaKeyTap.requestTrust()
            onNeedsAccessibility?(nowPlaying?.source.appName ?? "this app")
            return
        }
        if command == .toggle && flip { flipPlayingOptimistically() }
        switch command {
        case .toggle: MediaKey.post(.play)
        case .next: MediaKey.post(.next)
        case .previous: MediaKey.post(.previous)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.checkBrowserTabs() }
        }
    }

    /// Flip the play/pause icon right away instead of waiting for the player to answer.
    private func flipPlayingOptimistically() {
        guard var entry = nowPlaying else { return }
        entry.elapsed = entry.elapsed(at: Date())
        entry.fetchedAt = Date()
        entry.isPlaying.toggle()
        nowPlaying = entry
        pendingToggle = (entry.source, entry.isPlaying, Date().addingTimeInterval(4))
    }

    /// Sample data for snapshot rendering.
    func setPreview(_ entry: NowPlaying?, artwork: NSImage?, isAppIcon: Bool = false) {
        nowPlaying = entry
        self.artwork = artwork
        artworkIsAppIcon = isAppIcon
        accent = artwork?.vibrantAverageColor ?? .white
    }
}

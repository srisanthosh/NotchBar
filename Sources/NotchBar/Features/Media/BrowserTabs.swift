import AppKit
import ApplicationServices

/// Works out which browser tab is playing and what it is.
///
/// Two levels of detail:
/// - **Tab titles**, always. Browsers don't tell AppleScript which tab is audible, so NotchBar
///   uses the tab Chrome marks as audible (see `AudibleTabs`), then media sites, then the
///   front tab.
/// - **The page's own media**, when the browser allows AppleScript to run JavaScript
///   (Chrome: View > Developer > Allow JavaScript from Apple Events; Safari: Develop menu).
///   A short read-only script reads the page's Media Session (title, artist, artwork, the
///   same data macOS shows) and the video's position and state. Play, pause and seeking then
///   act on that exact video.
enum BrowserTabs {
    struct Tab { let window: Int; let index: Int; let url: URL; let title: String; let active: Bool }

    /// What the page reports about its media.
    struct PageMedia: Decodable {
        let title: String
        let artist: String
        let album: String
        let artwork: String
        let playing: Bool
        let time: Double
        let duration: Double
    }

    /// Builds the now-playing entry for a browser or other app that is making sound.
    /// - Parameter audibleTitle: The tab the browser marks as audible, when known.
    /// - Parameter knownTab: The tab that was playing a moment ago, preferred when no tab is audible.
    static func nowPlaying(for source: MediaSource, appName: String, audibleTitle: String?, knownTab: NowPlaying.TabRef? = nil) -> NowPlaying {
        let entry = NowPlaying(source: source, trackID: source.bundleID, title: appName, artist: "Playing audio", isPlaying: true)
        guard source.isBrowser, let tab = playingTab(in: source, audibleTitle: audibleTitle, knownTab: knownTab) else { return entry }
        return describe(tab, in: source, appName: appName)
    }

    /// Re-reads a tab NotchBar already knows about, for example after it paused.
    /// Nil once the tab is gone or has no media.
    static func reread(_ entry: NowPlaying) -> NowPlaying? {
        guard let ref = entry.tab,
              let tab = allTabs(in: entry.source).first(where: { $0.window == ref.window && $0.index == ref.index }),
              tab.url.absoluteString == entry.trackID else { return nil }
        let fresh = describe(tab, in: entry.source, appName: entry.source.appName)
        return fresh.isPageScripted ? fresh : nil
    }

    /// Looks through media-site tabs for a paused video or song, for when NotchBar starts up
    /// or opens with nothing known. Needs page scripts, so it returns nil without them.
    static func findPausedMedia(in source: MediaSource) -> NowPlaying? {
        let candidates = allTabs(in: source).filter { MediaSiteInfo.isMedia($0.url) }
            .sorted { $0.active && !$1.active }
        for tab in candidates.prefix(6) {
            let entry = describe(tab, in: source, appName: source.appName)
            if entry.isPageScripted && (entry.elapsed > 0 || entry.duration > 0) { return entry }
            if isPageScriptingOff(source) { return nil }
        }
        return nil
    }

    /// Debug only: what each step returns for one browser.
    static func diagnose(_ source: MediaSource) -> String {
        let (list, listError) = PlayerScripts.runReportingError("tell application id \"\(source.bundleID)\" to count every tab of every window")
        var lines = ["tabs: \(list?.stringValue ?? "-") error: \(listError ?? "none")"]
        let tabs = allTabs(in: source)
        let media = tabs.filter { MediaSiteInfo.isMedia($0.url) }
        lines.append("parsed tabs: \(tabs.count), media-site tabs: \(media.count)")
        if let tab = media.first {
            let target = "tab \(tab.index) of window \(tab.window)"
            let (r, e) = PlayerScripts.runReportingError("tell application id \"\(source.bundleID)\" to execute \(target) javascript \"1+1\"")
            lines.append("js 1+1: \(r?.stringValue ?? "-") error: \(e ?? "none")")
            lines.append("page media: \(pageMedia(in: source, tab: NowPlaying.TabRef(window: tab.window, index: tab.index)).map { "\($0.title) playing=\($0.playing) \(Int($0.time))/\(Int($0.duration))" } ?? "none")")
        }
        // The setting is per Chrome profile, so check one tab in every window.
        for window in Set(tabs.map(\.window)).sorted() {
            let (r, e) = PlayerScripts.runReportingError("tell application id \"\(source.bundleID)\" to execute tab 1 of window \(window) javascript \"1+1\"")
            let media = tabs.filter { $0.window == window && MediaSiteInfo.isMedia($0.url) }.count
            lines.append("window \(window): js \(r?.stringValue ?? (e?.contains("turned off") == true ? "turned off" : (e ?? "-"))), media tabs \(media)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ tab: Tab, in source: MediaSource, appName: String) -> NowPlaying {
        let info = MediaSiteInfo(url: tab.url, title: tab.title)
        var entry = NowPlaying(source: source, trackID: tab.url.absoluteString, title: info.title,
                               artist: info.subtitle ?? appName, isPlaying: true, artworkURL: info.artworkURL)
        entry.tab = NowPlaying.TabRef(window: tab.window, index: tab.index)
        if let media = pageMedia(in: source, tab: entry.tab!) {
            if !media.title.isEmpty { entry.title = media.title }
            if !media.artist.isEmpty { entry.artist = media.artist }
            entry.album = media.album
            if let art = URL(string: media.artwork), art.scheme?.hasPrefix("http") == true { entry.artworkURL = art }
            entry.duration = media.duration
            entry.elapsed = media.time
            entry.isPlaying = media.playing
            entry.isPageScripted = true
        }
        return entry
    }

    // MARK: Page scripts

    /// Browsers where running JavaScript from AppleScript is turned off, and when that was seen.
    /// Only touched from the media queue.
    private static var scriptingOff: [String: Date] = [:]

    /// True when the browser has refused to run page scripts recently.
    static func isPageScriptingOff(_ source: MediaSource) -> Bool {
        guard let seen = scriptingOff[source.bundleID] else { return false }
        return Date().timeIntervalSince(seen) < 60
    }

    static func pageMedia(in source: MediaSource, tab: NowPlaying.TabRef) -> PageMedia? {
        guard let json = runInPage(Self.readScript, source: source, tab: tab), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageMedia.self, from: data)
    }

    static func togglePlayback(in source: MediaSource, tab: NowPlaying.TabRef) -> Bool {
        runInPage(Self.mediaScript("if(m.paused){m.play()}else{m.pause()}"), source: source, tab: tab) == "ok"
    }

    static func seek(in source: MediaSource, tab: NowPlaying.TabRef, to seconds: Double) -> Bool {
        runInPage(Self.mediaScript("m.currentTime=\(Int(seconds))"), source: source, tab: tab) == "ok"
    }

    /// Picks the page's media element: one that's playing, else one that has started, else the first.
    private static let findMedia = "var els=Array.prototype.slice.call(document.querySelectorAll('video,audio'));var m=els.find(function(e){return !e.paused})||els.find(function(e){return e.currentTime>0})||els[0];"

    private static let readScript = "(function(){" + findMedia + "if(!m){return ''};var s=navigator.mediaSession&&navigator.mediaSession.metadata;var a=s&&s.artwork&&s.artwork.length?s.artwork[s.artwork.length-1].src:'';return JSON.stringify({title:s&&s.title||'',artist:s&&s.artist||'',album:s&&s.album||'',artwork:a,playing:!m.paused,time:m.currentTime||0,duration:isFinite(m.duration)?m.duration:0})})()"

    private static func mediaScript(_ action: String) -> String {
        "(function(){" + findMedia + "if(!m){return 'none'};" + action + ";return 'ok'})()"
    }

    /// Runs a script (written without double quotes or backslashes) in one tab.
    private static func runInPage(_ js: String, source: MediaSource, tab: NowPlaying.TabRef) -> String? {
        guard !isPageScriptingOff(source) else { return nil }
        let target = "tab \(tab.index) of window \(tab.window)"
        let script = source.kind == .safari
            ? "tell application id \"\(source.bundleID)\" to do JavaScript \"\(js)\" in \(target)"
            : "tell application id \"\(source.bundleID)\" to execute \(target) javascript \"\(js)\""
        let (result, error) = PlayerScripts.runReportingError(script)
        if let error, error.localizedCaseInsensitiveContains("javascript") {
            scriptingOff[source.bundleID] = Date()
            return nil
        }
        let text = result?.stringValue
        return text?.isEmpty == false ? text : nil
    }

    // MARK: Tabs

    /// The audible tab when known, then the tab that was playing, then a media site in the
    /// front tab, then any media site, then the front tab.
    private static func playingTab(in source: MediaSource, audibleTitle: String?, knownTab: NowPlaying.TabRef?) -> Tab? {
        let tabs = allTabs(in: source)
        if let audibleTitle {
            // Sites put an unread count in front of the title, "(39) Video - YouTube", and it can
            // change between the two reads, so compare without it.
            let audible = withoutCount(audibleTitle)
            if let match = tabs.first(where: { let title = withoutCount($0.title); return title == audible || audible.hasPrefix(title) }) {
                return match
            }
        }
        if let knownTab, let match = tabs.first(where: { $0.window == knownTab.window && $0.index == knownTab.index }) {
            return match
        }
        return tabs.first(where: { $0.active && MediaSiteInfo.isMedia($0.url) })
            ?? tabs.first(where: { MediaSiteInfo.isMedia($0.url) })
            ?? tabs.first(where: \.active)
    }

    private static func withoutCount(_ title: String) -> String {
        title.replacingOccurrences(of: #"^\(\d+\+?\)\s"#, with: "", options: .regularExpression)
    }

    /// Every tab's URL and title in three Apple Events, however many tabs are open.
    private static func allTabs(in source: MediaSource) -> [Tab] {
        let (titleKey, activeKey) = source.kind == .safari
            ? ("name", "index of current tab")
            : ("title", "active tab index")
        let s = "\u{1F}"
        let script = """
        tell application id "\(source.bundleID)"
            set u to URL of every tab of every window
            set t to \(titleKey) of every tab of every window
            set a to \(activeKey) of every window
        end tell
        set out to ""
        repeat with wi from 1 to count of u
            set wu to item wi of u
            set wt to item wi of t
            set ai to item wi of a
            repeat with ti from 1 to count of wu
                set out to out & wi & "\(s)" & ti & "\(s)" & (item ti of wu) & "\(s)" & (item ti of wt) & "\(s)" & ((ti = ai) as string) & linefeed
            end repeat
        end repeat
        return out
        """
        guard let output = PlayerScripts.run(script)?.stringValue else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let p = line.components(separatedBy: s)
            guard p.count == 5, let window = Int(p[0]), let index = Int(p[1]),
                  let url = URL(string: p[2]), url.scheme?.hasPrefix("http") == true else { return nil }
            return Tab(window: window, index: index, url: url, title: p[3], active: p[4] == "true")
        }
    }
}

/// Reads which tabs a Chromium browser marks as playing audio, from its tab strip.
enum AudibleTabs {
    /// Chrome names each tab in its tab strip "<page title>" followed by status notes, each after
    /// a dash, in any order: "Title - YouTube – Audio playing - Memory usage - 462 MB".
    /// Any dash is accepted, in case other Chromium browsers differ.
    private static let audibleMarker = #"\s[-–—]\s(Audio playing|Playing audio)(?=\s[-–—]\s|$)"#
    private static let memoryNote = #"\s[-–—]\sMemory usage\s[-–—]\s[\d.,]+\s?[KMGT]?B(?=\s[-–—]\s|$)"#

    /// The page title of an audible tab, or nil when the tab isn't making sound.
    static func audibleTitle(fromTabName name: String) -> String? {
        guard let marker = name.range(of: audibleMarker, options: .regularExpression) else { return nil }
        let memory = name.range(of: memoryNote, options: .regularExpression)
        let end = min(marker.lowerBound, memory?.lowerBound ?? name.endIndex)
        return String(name[..<end])
    }

    /// Titles of the audible tabs, or nil when NotchBar can't tell (no Accessibility access,
    /// or no tab strip found). An empty array means the browser is silent.
    static func titles(pid: pid_t) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var found: [String] = []
        var sawTabStrip = false
        for window in windows { collect(window, depth: 0, into: &found, sawTabStrip: &sawTabStrip) }
        return sawTabStrip ? found : nil
    }

    private static func collect(_ element: AXUIElement, depth: Int, into found: inout [String], sawTabStrip: inout Bool) {
        guard depth < 10 else { return }
        let role = value(element, kAXRoleAttribute) as? String
        // Never walk into page content: it is huge, and touching it makes Chrome build its
        // accessibility tree for the page.
        if role == "AXWebArea" || role == kAXScrollAreaRole { return }
        let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if role == kAXTabGroupRole {
            sawTabStrip = true
            for tab in children {
                let name = (value(tab, kAXTitleAttribute) as? String) ?? (value(tab, kAXDescriptionAttribute) as? String) ?? ""
                if let title = audibleTitle(fromTabName: name) { found.append(title) }
            }
            return
        }
        for child in children { collect(child, depth: depth + 1, into: &found, sawTabStrip: &sawTabStrip) }
    }

    /// Debug only: all attributes of Chrome tabs whose title contains `needle`.
    static func debugDump(titleContaining needle: String) -> String {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.processIdentifier else { return "no chrome" }
        let app = AXUIElementCreateApplication(pid)
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            let role = value(e, kAXRoleAttribute) as? String ?? "?"
            if role == "AXWebArea" || role == kAXScrollAreaRole { return }
            let title = (value(e, kAXTitleAttribute) as? String) ?? ""
            let desc = (value(e, kAXDescriptionAttribute) as? String) ?? ""
            if (title + desc).contains(needle) {
                var names: CFArray?
                AXUIElementCopyAttributeNames(e, &names)
                out.append("ROLE \(role) depth \(depth)")
                for name in (names as? [String]) ?? [] {
                    if let v = value(e, name), let text = (v as? String) ?? (v as? NSNumber)?.stringValue { out.append("  \(name) = \(text)") }
                    else { out.append("  \(name)") }
                }
            }
            if role == kAXTabGroupRole { out.append("TABGROUP at depth \(depth) children \((value(e, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0)") }
            for c in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        for w in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(w, 0) }
        return out.joined(separator: "\n")
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
}

/// Turns a browser tab into a title, a source name and, for YouTube, a thumbnail.
struct MediaSiteInfo {
    let title: String
    let subtitle: String?
    let artworkURL: URL?

    private static let sites: [(host: String, name: String)] = [
        ("music.youtube.com", "YouTube Music"), ("youtube.com", "YouTube"), ("youtu.be", "YouTube"),
        ("open.spotify.com", "Spotify"), ("soundcloud.com", "SoundCloud"), ("music.apple.com", "Apple Music"),
        ("netflix.com", "Netflix"), ("primevideo.com", "Prime Video"), ("twitch.tv", "Twitch"), ("vimeo.com", "Vimeo"),
        ("disneyplus.com", "Disney+"), ("hotstar.com", "JioHotstar"), ("jiosaavn.com", "JioSaavn"), ("gaana.com", "Gaana"),
        ("wynk.in", "Wynk"), ("tidal.com", "TIDAL"), ("deezer.com", "Deezer"), ("pandora.com", "Pandora"),
        ("music.amazon", "Amazon Music"), ("bandcamp.com", "Bandcamp"), ("mixcloud.com", "Mixcloud"),
        ("dailymotion.com", "Dailymotion"), ("hulu.com", "Hulu"), ("max.com", "Max"), ("tv.apple.com", "Apple TV"),
        ("podcasts.apple.com", "Podcasts"), ("audible.", "Audible"), ("udemy.com", "Udemy"), ("coursera.org", "Coursera"),
    ]

    static func site(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return sites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) || host.contains($0.host) })?.name
    }

    static func isMedia(_ url: URL) -> Bool { site(for: url) != nil }

    init(url: URL, title raw: String) {
        let site = Self.site(for: url)
        // Drop unread counts like "(3) " and the trailing site name.
        var title = raw.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        var subtitle = site ?? url.host?.replacingOccurrences(of: "www.", with: "")
        for suffix in [" - YouTube Music", " - YouTube", " | Netflix", " - Twitch", " on Vimeo", " | Prime Video"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        // Spotify and YouTube Music put "Song • Artist" in the title.
        if site == "Spotify" || site == "YouTube Music",
           let separator = [" • ", " · "].first(where: title.contains) {
            let parts = title.components(separatedBy: separator)
            title = parts[0]
            subtitle = parts.dropFirst().joined(separator: separator)
        }
        self.title = title.isEmpty ? (site ?? "Playing") : title
        self.subtitle = subtitle
        artworkURL = site == "YouTube" ? Self.youTubeID(url).flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") } : nil
    }

    private static func youTubeID(_ url: URL) -> String? {
        if url.host?.contains("youtu.be") == true { return url.pathComponents.dropFirst().first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }
}

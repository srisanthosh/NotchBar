import AppKit
import SwiftUI

/// Developer tools.
/// - `NotchBar --snapshot <folder>` renders every notch state to PNG with sample data.
/// - `NotchBar --usage` prints the usage NotchBar reads from your Claude Code transcripts.
@MainActor
enum Snapshotter {
    static func printUsage() {
        let start = Date()
        let s = TranscriptScanner().update(files: nil, now: Date()).snapshot
        print(String(format: "Scanned in %.2fs", Date().timeIntervalSince(start)))
        print("Session:", formatTokens(s.sessionTokens), "in", s.sessionMessages, "replies, ends", s.sessionEnd.map { "\($0)" } ?? "-")
        print("Today:", formatTokens(s.todayTokens), " Week:", formatTokens(s.weekTokens), " Busiest session:", formatTokens(s.peakSessionTokens))
        print("Models:", s.models.prefix(4).map { "\($0.name) \(formatTokens($0.tokens))" }.joined(separator: ", "))
        print("Real limits:", ClaudeCodeIntegration.readLimits().map { "\($0)" } ?? "none")
    }

    /// True while rendering, for views that draw differently in a still image.
    static var isRendering = false

    static func run(outDir: String) {
        isRendering = true
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let art = sampleArtwork()

        // Media
        let music = MediaController()
        music.setPreview(NowPlaying(source: .music, trackID: "1", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                    duration: 243, elapsed: 87, isPlaying: true), artwork: art)
        let nothing = MediaController()
        let browser = MediaController()
        browser.setPreview(NowPlaying(source: .forBundle("com.google.Chrome"), trackID: "yt", title: "Lofi beats to code to",
                                      artist: "YouTube", isPlaying: true), artwork: art)
        let teamsSource = MediaSource.forBundle("com.microsoft.teams2")
        let app = MediaController()
        app.setPreview(NowPlaying(source: teamsSource, trackID: "t", title: "Microsoft Teams", artist: "Playing audio", isPlaying: true),
                       artwork: teamsSource.icon, isAppIcon: true)

        // Claude
        var usageSample = UsageSnapshot()
        usageSample.sessionTokens = 1_840_000
        usageSample.sessionMessages = 212
        usageSample.sessionEnd = now.addingTimeInterval(2.4 * 3600)
        usageSample.todayTokens = 3_200_000
        usageSample.weekTokens = 14_600_000
        usageSample.peakSessionTokens = 3_100_000
        usageSample.models = [ModelShare(name: "Opus 5.5", tokens: 1_500_000), ModelShare(name: "Haiku 5.5", tokens: 340_000)]
        usageSample.buckets = [0, 0, 120, 340, 80, 500, 900, 300, 0, 640, 1200, 700, 200, 0, 0, 0, 0, 0, 0, 0].map { $0 * 1000 }
        let limits = RealLimits(
            session: LimitWindow(key: "five_hour", label: "Session", percent: 58, resetsAt: now.addingTimeInterval(2.4 * 3600)),
            weekly: [LimitWindow(key: "seven_day", label: "Weekly", percent: 31, resetsAt: now.addingTimeInterval(3.2 * 86_400)),
                     LimitWindow(key: "seven_day_fable", label: "Weekly · Fable", percent: 8, resetsAt: now.addingTimeInterval(12.5 * 3600))],
            updatedAt: now)
        let live = ClaudeUsageStore(preview: usageSample, limits: limits)
        let working = ClaudeUsageStore(preview: usageSample, limits: limits, activity: .working)
        let waiting = ClaudeUsageStore(preview: usageSample, limits: limits, activity: .waiting)
        let estimate = ClaudeUsageStore(preview: usageSample, limits: nil)

        // Timer
        let idleTimer = TimerModel(persist: false)
        idleTimer.pickerMinutes = 10
        let runningTimer = TimerModel(persist: false)
        runningTimer.setPreview(.running(end: now.addingTimeInterval(14 * 60 + 32)), duration: 25 * 60)
        let doneTimer = TimerModel(persist: false)
        doneTimer.setPreview(.finished, duration: 25 * 60)

        // Clipboard
        let clips = ClipboardStore(persist: false)
        clips.previewImages["sample.png"] = art
        clips.setPreview([
            ClipItem(kind: .text, text: "Ship the notch build tonight, then polish the HUD animations tomorrow morning.",
                     date: now.addingTimeInterval(-40), sourceBundle: "com.apple.Notes", pinned: true),
            ClipItem(kind: .link, text: "https://developer.apple.com/design/human-interface-guidelines/",
                     date: now.addingTimeInterval(-600), sourceBundle: "com.google.Chrome"),
            ClipItem(kind: .image, imageFile: "sample.png", date: now.addingTimeInterval(-3600), sourceBundle: "com.apple.Preview"),
        ])

        // Calendar
        let calendar = CalendarStore()
        let review = CalendarEvent(id: "1", title: "Design review", start: now.addingTimeInterval(4 * 60), end: now.addingTimeInterval(49 * 60),
                                   isAllDay: false, location: "Studio 2", color: .systemPurple,
                                   joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/sample"))
        calendar.setPreview([
            review,
            CalendarEvent(id: "2", title: "Gym", start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(3.75 * 3600),
                          isAllDay: false, location: nil, color: .systemGreen, joinURL: nil),
            CalendarEvent(id: "3", title: "Sprint planning", start: now.addingTimeInterval(20 * 3600), end: now.addingTimeInterval(21 * 3600),
                          isAllDay: false, location: "Room 4B", color: .systemBlue, joinURL: nil),
        ], busyDays: [3, 12, 19, 24, Calendar.current.component(.day, from: now)])

        let weather = WeatherStore()
        weather.setPreview(Weather(temperature: 27, high: 31, low: 22, code: 2, isDay: true, place: "Cupertino"))

        let noDictation = DictationMonitor()
        let handy = DictationMonitor()
        handy.setPreview(.forBundle("com.pais.handy"))

        // Activity
        let activity = ActivityMonitor()
        var load = ActivitySample()
        load.cpu = 0.34
        load.cpuUser = 0.23
        load.cpuSystem = 0.11
        load.cores = 12
        load.memoryTotal = 24 << 30
        load.memoryUsed = UInt64(15.2 * Double(1 << 30))
        load.swapUsed = UInt64(1.1 * Double(1 << 30))
        load.networkIn = 1_240_000
        load.networkOut = 86_000
        load.diskRead = 0
        load.diskWrite = 2_100_000
        load.loadAverage = 3.4
        load.processes = [
            ActivityProcess(id: "/Applications/Google Chrome.app", name: "Google Chrome", cpu: 1.26, memory: 3_260 << 20),
            ActivityProcess(id: "swift-frontend", name: "swift-frontend", cpu: 0.61, memory: 840 << 20),
            ActivityProcess(id: "WindowServer", name: "WindowServer", cpu: 0.098, memory: 612 << 20),
            ActivityProcess(id: "/System/Applications/Music.app", name: "Music", cpu: 0.021, memory: 188 << 20),
            ActivityProcess(id: "/Applications/NotchBar.app", name: "NotchBar", cpu: 0.003, memory: 52 << 20),
        ]
        let cpuHistory = [0.08, 0.1, 0.09, 0.12, 0.18, 0.15, 0.11, 0.1, 0.13, 0.22, 0.19, 0.16, 0.14, 0.12, 0.1, 0.11, 0.15, 0.2, 0.17, 0.14,
                          0.12, 0.1, 0.14, 0.2, 0.31, 0.28, 0.22, 0.45, 0.62, 0.58, 0.4, 0.33, 0.3, 0.27, 0.35, 0.52, 0.48, 0.3, 0.26, 0.34]
        activity.setPreview(load, cpuHistory: cpuHistory, networkHistory: cpuHistory.map { $0 * 3_000_000 })

        let clearBackground = ProcessInfo.processInfo.environment["NOTCHBAR_SNAPSHOT_CLEAR"] == "1"
        func render(_ name: String, media: MediaController = music, usage: ClaudeUsageStore = live, timer: TimerModel = idleTimer,
                    clipboard: ClipboardStore = clips, dictation: DictationMonitor? = nil, configure: (NotchViewModel) -> Void = { _ in }) {
            let vm = NotchViewModel(media: media, usage: usage, timer: timer, hudService: HUDService(), clipboard: clipboard, calendar: calendar,
                                    weather: weather, dictation: dictation ?? noDictation, activity: activity)
            configure(vm)
            let view = ZStack(alignment: .top) {
                // NOTCHBAR_SNAPSHOT_CLEAR=1 leaves out the wallpaper, for compositing (the launch video).
                if !clearBackground {
                    LinearGradient(colors: [Color(red: 0.38, green: 0.2, blue: 0.62), Color(red: 0.16, green: 0.12, blue: 0.42)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                NotchRootView(vm: vm, media: media, usage: usage, timer: timer)
            }
            .frame(width: NotchController.canvas.width, height: NotchController.canvas.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = clearBackground ? 3 : 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("Couldn't render \(name)")
                return
            }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            print("Wrote \(name).png")
        }

        func expanded(_ tab: NotchViewModel.Tab) -> (NotchViewModel) -> Void { { $0.isExpanded = true; $0.tab = tab } }

        render("00-home", configure: expanded(.home))
        render("00-home-running-timer", usage: working, timer: runningTimer, configure: expanded(.home))
        render("01-collapsed-idle", media: nothing, usage: estimate)
        render("02-collapsed-playing")
        render("03-collapsed-claude-working", usage: working)
        render("03b-collapsed-dictation", dictation: handy)
        render("04-collapsed-hover") { $0.isHovering = true }
        render("05-banner-now-playing") { $0.show(.nowPlaying) }
        render("06-banner-volume") { $0.show(.hud(HUDState(kind: .volume, value: 0.62, muted: false))) }
        render("06b-banner-airpods") { $0.show(.device(DeviceEvent(name: "AirPods Pro", symbol: "airpodspro", connected: true,
            battery: [.init(label: "L", percent: 82), .init(label: "R", percent: 79), .init(label: "Case", percent: 15)], volume: 0.62))) }
        render("06c-banner-headphones-off") { $0.show(.device(DeviceEvent(name: "WH-1000XM5", symbol: "headphones", connected: false,
            battery: [.init(label: "", percent: 64)], soundNowOn: "MacBook Pro Speakers"))) }
        render("06e-banner-buds") { $0.show(.device(DeviceEvent(name: "Galaxy Buds2 Pro", symbol: "earbuds", connected: true,
            volume: 0.44))) }
        render("06f-banner-buds-battery") { $0.show(.device(DeviceEvent(name: "Pixel Buds Pro", symbol: "earbuds", connected: true,
            battery: [.init(label: "L", percent: 64), .init(label: "R", percent: 71), .init(label: "Case", percent: 90)], volume: 0.5))) }
        render("06d-banner-airplay") { $0.show(.device(DeviceEvent(name: "Living Room", symbol: "homepod.fill", connected: true,
            connection: "AirPlay", volume: 0.4))) }
        render("07-banner-meeting") { $0.show(.meeting(review)) }
        render("08-banner-timer-done", timer: doneTimer) { $0.show(.timerDone) }
        render("09-media", configure: expanded(.media))
        render("10-media-browser", media: browser, configure: expanded(.media))
        render("11-media-app", media: app, configure: expanded(.media))
        render("12-media-empty", media: nothing, configure: expanded(.media))
        render("13-claude-live", configure: expanded(.claude))
        render("14-claude-waiting", usage: waiting, configure: expanded(.claude))
        render("15-claude-estimate", usage: estimate, configure: expanded(.claude))
        render("16-timer-idle", configure: expanded(.timer))
        render("17-timer-running", timer: runningTimer, configure: expanded(.timer))
        render("18-timer-collapsed", timer: runningTimer)
        render("19-clipboard", configure: expanded(.clipboard))
        render("19b-clipboard-empty", clipboard: ClipboardStore(persist: false), configure: expanded(.clipboard))
        render("20-calendar", configure: expanded(.calendar))
        render("21-activity", configure: expanded(.activity))
    }

    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.95, green: 0.35, blue: 0.55, alpha: 1),
                                NSColor(srgbRed: 0.35, green: 0.2, blue: 0.85, alpha: 1)])?.draw(in: rect, angle: -45)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 90, y: 90, width: 120, height: 120)).fill()
            return true
        }
    }
}

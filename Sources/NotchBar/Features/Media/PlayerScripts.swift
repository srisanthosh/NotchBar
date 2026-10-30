import AppKit

/// AppleScript access to Music, Spotify and VLC.
///
/// Every call here blocks on an Apple Event, so call these off the main thread. Only call them
/// for apps that are already running: sending an event to a closed app launches it.
enum PlayerScripts {
    enum Command { case toggle, next, previous }

    private static let separator = "\u{1F}"

    static func nowPlaying(_ source: MediaSource) -> NowPlaying? {
        guard let script = stateScript(for: source),
              let output = run(script)?.stringValue, !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: separator)
        guard parts.count == 7 else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(source: source, trackID: parts[0], title: parts[1], artist: parts[2], album: parts[3],
                          duration: number(parts[4]), elapsed: number(parts[5]), isPlaying: parts[6] == "playing")
    }

    static func send(_ command: Command, to source: MediaSource) {
        let verb: String
        switch (source.kind, command) {
        case (.vlc, .toggle): verb = "play"
        case (.vlc, .next): verb = "next"
        case (.vlc, .previous): verb = "previous"
        case (_, .toggle): verb = "playpause"
        case (_, .next): verb = "next track"
        case (.music, .previous): verb = "back track"
        case (_, .previous): verb = "previous track"
        }
        run("tell application id \"\(source.bundleID)\" to \(verb)")
    }

    static func seek(_ source: MediaSource, to seconds: Double) {
        let command = source.kind == .vlc
            ? "set current time to \(Int(seconds))"
            : "set player position to \(String(format: "%.2f", seconds))"
        run("tell application id \"\(source.bundleID)\" to \(command)")
    }

    static func musicArtwork() -> NSImage? {
        let script = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            on error
                return data of artwork 1 of current track
            end try
        end tell
        """
        guard let data = run(script)?.data, let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    static func spotifyArtworkURL() -> URL? {
        run("tell application id \"com.spotify.client\" to return artwork url of current track")?.stringValue.flatMap(URL.init(string:))
    }

    /// Runs AppleScript with a short timeout. Returns nil on any error, including a denied
    /// Automation permission.
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 3 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    /// Like `run`, but also returns the error message, to tell "turned off" from "nothing there".
    static func runReportingError(_ source: String) -> (NSAppleEventDescriptor?, String?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 3 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        return error == nil ? (result, nil) : (nil, error?[NSAppleScript.errorMessage] as? String ?? "error")
    }

    private static func stateScript(for source: MediaSource) -> String? {
        let s = separator
        switch source.kind {
        case .music:
            return """
            tell application id "com.apple.Music"
                if player state is stopped then return ""
                set t to current track
                return (persistent ID of t) & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & ((duration of t) as string) & "\(s)" & ((player position) as string) & "\(s)" & ((player state) as string)
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                if player state is stopped then return ""
                set t to current track
                return (id of t) & "\(s)" & (name of t) & "\(s)" & (artist of t) & "\(s)" & (album of t) & "\(s)" & (((duration of t) / 1000) as string) & "\(s)" & ((player position) as string) & "\(s)" & ((player state) as string)
            end tell
            """
        case .vlc:
            return """
            tell application id "org.videolan.vlc"
                try
                    set n to name of current item
                on error
                    return ""
                end try
                if playing then
                    set state to "playing"
                else
                    set state to "paused"
                end if
                return n & "\(s)" & n & "\(s)" & "VLC" & "\(s)" & "" & "\(s)" & ((duration of current item) as string) & "\(s)" & ((current time) as string) & "\(s)" & state
            end tell
            """
        default:
            return nil
        }
    }
}

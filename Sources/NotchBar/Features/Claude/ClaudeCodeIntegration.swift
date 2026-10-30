import Foundation

/// What NotchBar adds to Claude Code. Nothing is installed until you click Connect, and
/// Disconnect removes all of it.
///
/// - A **status line** script. Claude Code passes it the real rate-limit percentages, the only
///   documented credential-free source of them. It runs in the terminal version of Claude Code.
/// - **Activity hooks.** Claude Code runs them when a prompt is sent, when it stops, and when it
///   needs you, so the notch reacts instantly. Hooks run in every version of Claude Code.
///
/// No credentials are read. A copy of `settings.json` is saved before the first change.
enum ClaudeCodeIntegration {
    enum Result: Equatable {
        case connected
        /// Hooks were added, but you already had a status line, which was left alone.
        case connectedKeepingStatusLine
        case failed(String)
    }

    static let folder = home.appendingPathComponent(".claude/notchbar", isDirectory: true)
    static let activityFolder = folder.appendingPathComponent("active", isDirectory: true)
    static let limitsFile = folder.appendingPathComponent("limits.json")
    static let projectsFolder = home.appendingPathComponent(".claude/projects", isDirectory: true)
    private static let statusLineScript = folder.appendingPathComponent("statusline.sh")
    private static let activityScript = folder.appendingPathComponent("activity.sh")
    private static let settingsFile = home.appendingPathComponent(".claude/settings.json")
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Hook events and the argument each passes to the activity script.
    private static let hookEvents = ["UserPromptSubmit": "start", "Stop": "stop", "SessionEnd": "stop", "Notification": "wait"]

    // MARK: State

    static var isStatusLineInstalled: Bool {
        guard let line = loadSettings()?["statusLine"] as? [String: Any], let command = line["command"] as? String else { return false }
        return command.contains(statusLineScript.path)
    }

    static var areHooksInstalled: Bool {
        guard let hooks = loadSettings()?["hooks"] as? [String: Any] else { return false }
        return hookEvents.keys.allSatisfy { event in groups(hooks[event]).contains(where: isOurs) }
    }

    // MARK: Connect and disconnect

    static func connect() -> Result {
        do {
            try FileManager.default.createDirectory(at: activityFolder, withIntermediateDirectories: true)
            try writeScripts()
            try backUpSettingsOnce()

            var settings = loadSettings() ?? [:]
            var keptOtherStatusLine = false
            if let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
               !command.contains(statusLineScript.path) {
                keptOtherStatusLine = true
            } else {
                settings["statusLine"] = ["type": "command", "command": statusLineScript.path, "padding": 0]
            }

            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for (event, argument) in hookEvents {
                var list = groups(hooks[event])
                if !list.contains(where: isOurs) {
                    list.append(["hooks": [["type": "command", "command": "\"\(activityScript.path)\" \(argument)"]]])
                }
                hooks[event] = list
            }
            settings["hooks"] = hooks
            try save(settings)
            return keptOtherStatusLine ? .connectedKeepingStatusLine : .connected
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func disconnect() throws {
        var settings = loadSettings() ?? [:]
        if let line = settings["statusLine"] as? [String: Any], (line["command"] as? String)?.contains(statusLineScript.path) == true {
            settings["statusLine"] = nil
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for event in hookEvents.keys {
                let remaining = groups(hooks[event]).filter { !isOurs($0) }
                hooks[event] = remaining.isEmpty ? nil : remaining
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        try save(settings)
        try? FileManager.default.removeItem(at: activityFolder)
    }

    /// Keeps installed scripts in step with this version of the app.
    static func upgradeScriptsIfInstalled() {
        guard isStatusLineInstalled || areHooksInstalled else { return }
        try? writeScripts()
    }

    // MARK: Reading what the scripts write

    static func readLimits() -> RealLimits? {
        guard let data = try? Data(contentsOf: limitsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Saves nest the windows under rate_limits; the first version saved them at the top.
        let windows = object["rate_limits"] as? [String: Any] ?? object
        var session: LimitWindow?
        var weekly: [LimitWindow] = []
        for (key, value) in windows {
            guard let w = value as? [String: Any], let percent = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let window = LimitWindow(key: key, label: label(forWindow: key), percent: percent, resetsAt: reset)
            if key == "five_hour" { session = window } else if key.hasPrefix("seven_day") { weekly.append(window) }
        }
        weekly.sort { ($0.key == "seven_day" ? "" : $0.key) < ($1.key == "seven_day" ? "" : $1.key) }
        guard session != nil || !weekly.isEmpty else { return nil }
        let updated = (object["updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        return RealLimits(session: session, weekly: weekly, updatedAt: updated)
    }

    struct SessionMarker { let state: ClaudeActivity; let since: Date }

    /// One marker per Claude Code session that the hooks say is busy, keyed by session ID.
    static func readActivity() -> [String: SessionMarker] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: activityFolder, includingPropertiesForKeys: keys) else { return [:] }
        var markers: [String: SessionMarker] = [:]
        for file in files {
            let since = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            // A session that crashed never says it stopped. Forget it after a day.
            if Date().timeIntervalSince(since) > 86_400 { try? FileManager.default.removeItem(at: file); continue }
            let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            markers[file.lastPathComponent] = SessionMarker(state: text == "waiting" ? .waiting : .working, since: since)
        }
        return markers
    }

    static func setActivity(_ state: ClaudeActivity, session id: String) {
        let file = activityFolder.appendingPathComponent(id)
        switch state {
        case .idle: try? FileManager.default.removeItem(at: file)
        case .working: try? "working".write(to: file, atomically: true, encoding: .utf8)
        case .waiting: try? "waiting".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Scripts

    private static let statusLineSource = #"""
    #!/bin/bash
    # Written by NotchBar. Claude Code runs this to draw its status line. It saves the
    # rate-limit info for the notch, then prints a compact status line.
    input=$(cat)
    dir="$HOME/.claude/notchbar"
    mkdir -p "$dir"
    # Note which fields arrived (names only), so NotchBar can tell "not run" from "no limits sent".
    printf '%s' "$input" | /usr/bin/jq -c '{ran_at: now, fields: keys, has_rate_limits: (.rate_limits != null), version: .version}' > "$dir/last-run.json" 2>/dev/null
    if printf '%s' "$input" | /usr/bin/jq -e '.rate_limits' >/dev/null 2>&1; then
      printf '%s' "$input" | /usr/bin/jq -c '{rate_limits: .rate_limits, updated_at: now}' > "$dir/limits.json.tmp" && mv "$dir/limits.json.tmp" "$dir/limits.json"
    fi
    printf '%s' "$input" | /usr/bin/jq -r '
      (.model.display_name // "Claude")
      + (if .rate_limits.five_hour.used_percentage != null then " · 5h \(.rate_limits.five_hour.used_percentage | floor)%" else "" end)
      + (if .rate_limits.seven_day.used_percentage != null then " · 7d \(.rate_limits.seven_day.used_percentage | floor)%" else "" end)'
    """#

    private static let activitySource = #"""
    #!/bin/bash
    # Written by NotchBar. Claude Code hooks call this with "start", "stop" or "wait".
    # It keeps one small file per busy session, so the notch knows when Claude is working.
    # It prints nothing: a UserPromptSubmit hook's output would be added to the prompt.
    dir="$HOME/.claude/notchbar/active"
    mkdir -p "$dir"
    id=$(/usr/bin/jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
    [ -z "$id" ] && exit 0
    case "$1" in
      start) echo working > "$dir/$id" ;;
      wait)  [ -f "$dir/$id" ] && echo waiting > "$dir/$id" ;;
      stop)  rm -f "$dir/$id" ;;
    esac
    exit 0
    """#

    private static func writeScripts() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (url, source) in [(statusLineScript, statusLineSource), (activityScript, activitySource)] {
            if (try? String(contentsOf: url, encoding: .utf8)) != source {
                try source.write(to: url, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: Settings file

    private static func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func save(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: settingsFile, options: .atomic)
    }

    /// Keeps the very first backup, so restoring it removes everything NotchBar ever added.
    private static func backUpSettingsOnce() throws {
        let backup = settingsFile.appendingPathExtension("notchbar-backup")
        guard FileManager.default.fileExists(atPath: settingsFile.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: settingsFile, to: backup)
    }

    private static func groups(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(activityScript.path) == true }
    }

    /// "seven_day" -> "Weekly", "seven_day_opus" -> "Weekly · Opus".
    private static func label(forWindow key: String) -> String {
        guard key.hasPrefix("seven_day") else { return "Session" }
        let model = key.dropFirst("seven_day".count).split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        return model.isEmpty ? "Weekly" : "Weekly · \(model)"
    }
}

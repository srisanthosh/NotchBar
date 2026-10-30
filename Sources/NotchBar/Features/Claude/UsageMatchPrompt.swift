import AppKit

/// Asks for the session numbers Claude's usage page shows, so the estimate can follow them.
///
/// Claude's own apps read your limits from Anthropic with your sign-in, which NotchBar doesn't
/// touch. Typing the two numbers in once gives the estimate a real scale and window.
@MainActor
enum UsageMatchPrompt {
    private static let help = "In Claude Code, open Account & Usage (in the Claude app, Settings › Usage) "
        + "and enter what Session (5hr) shows. Using claude in Terminal updates this on its own."

    static func run(usage: ClaudeUsageStore, vm: NotchViewModel) {
        vm.close()
        let percent = NSTextField(string: "")
        percent.placeholderString = "e.g. 29"
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let picker = NSDatePicker()
        picker.datePickerElements = .hourMinute
        picker.datePickerStyle = .textFieldAndStepper
        picker.dateValue = usage.sessionResetsAt ?? Date().addingTimeInterval(5 * 3600)
        let row = NSStackView(views: [NSTextField(labelWithString: "Session"), percent, NSTextField(labelWithString: "%"),
                                      NSTextField(labelWithString: "   Resets at"), picker])
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 330, height: 26)

        var problem: String?
        // The notch is closed while this is up, so problems are shown here, not as a toast.
        while true {
            let alert = NSAlert()
            alert.messageText = "Match Claude's usage"
            alert.informativeText = problem.map { "⚠️ \($0)\n\n\(help)" } ?? help
            alert.accessoryView = row
            alert.addButton(withTitle: "Match")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = percent
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let text = percent.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " %"))
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), (0...100).contains(value) else {
                problem = text.isEmpty ? "Type the Session percentage Claude shows, such as 29."
                                       : "“\(text)” isn't a percentage from 0 to 100."
                continue
            }
            guard let reset = nextOccurrence(of: picker.dateValue) else {
                problem = "Set Resets at to the time Claude shows. It should be within the next five hours."
                continue
            }
            usage.match(percent: value, resetsAt: reset) { matched in
                vm.open(.claude)
                vm.showToast(matched ? "Matched to Claude's numbers."
                    : "Couldn't match: none of this window's use came from Claude Code on this Mac yet.")
            }
            return
        }
    }

    /// The picker only shows a time of day. The reset is the next time it comes round.
    private static func nextOccurrence(of picked: Date, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: picked)
        guard let reset = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime),
              reset.timeIntervalSince(now) <= 5 * 3600 + 60 else { return nil }
        return reset
    }
}

import SwiftUI

/// A month at a glance beside the next few events, with a Join button for online meetings.
struct CalendarPanel: View {
    @ObservedObject var calendar: CalendarStore

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            MonthGrid(calendar: calendar)
                .frame(width: 252)
            upNext
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 184, alignment: .top)
    }

    @ViewBuilder private var upNext: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Up next")
            switch calendar.access {
            case .notDetermined:
                message("See your meetings here", detail: "NotchBar reads the accounts in the Calendar app.",
                        button: "Allow Calendar Access") { calendar.requestAccess() }
            case .denied:
                message("Calendar access is off", detail: "Turn it on for NotchBar in Privacy & Security.",
                        button: "Open Settings") { calendar.openPrivacySettings() }
            case .granted:
                if calendar.upcoming.isEmpty {
                    message("Nothing coming up", detail: "Your next seven days are clear.", button: nil, action: {})
                } else {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(calendar.upcoming.prefix(3)) { EventRow(event: $0, now: context.date, actions: .init(store: calendar)) }
                        }
                    }
                }
            }
        }
    }

    private func message(_ title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            if let button {
                Button(action: action) {
                    Text(button).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .padding(.top, 4)
            }
        }
    }
}

struct MonthGrid: View {
    @ObservedObject var calendar: CalendarStore
    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { calendar.showMonth(offset: 0) } label: {
                    Text(calendar.displayedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .help("Go to today")
                Spacer()
                CircleIconButton(systemName: "chevron.left", size: 24, iconSize: 10, help: "Previous month") { calendar.showMonth(offset: -1) }
                CircleIconButton(systemName: "chevron.right", size: 24, iconSize: 10, help: "Next month") { calendar.showMonth(offset: 1) }
            }
            let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i]).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                }
                ForEach(days, id: \.self) { day in DayCell(date: day, month: calendar.displayedMonth, busy: isBusy(day)) }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Six full weeks, starting on the week that contains the 1st.
    private var days: [Date] {
        guard let firstWeek = cal.dateInterval(of: .weekOfMonth, for: calendar.displayedMonth) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: firstWeek.start) }
    }

    private func isBusy(_ day: Date) -> Bool {
        cal.isDate(day, equalTo: calendar.displayedMonth, toGranularity: .month) && calendar.busyDays.contains(cal.component(.day, from: day))
    }
}

private struct DayCell: View {
    let date: Date
    let month: Date
    let busy: Bool
    private let cal = Calendar.current

    var body: some View {
        let today = cal.isDateInToday(date)
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        VStack(spacing: 1) {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 11.5, weight: today ? .bold : .medium).monospacedDigit())
                .foregroundStyle(today ? .white : .white.opacity(inMonth ? 0.9 : 0.25))
                .frame(width: 22, height: 19)
                .background(Circle().fill(today ? Color.accentColor : .clear).frame(width: 22, height: 22))
            Circle().fill(busy ? Color.accentColor : .clear).frame(width: 3.5, height: 3.5)
        }
        .frame(height: 24)
    }
}

/// What a row in Up Next can do, besides Join.
struct EventActions {
    let open: (CalendarEvent) -> Void
    let remind: (CalendarEvent, Date) -> Void
    let hide: (CalendarEvent) -> Void

    @MainActor init(store: CalendarStore) {
        open = { store.open($0) }
        remind = { store.remind($0, at: $1) }
        hide = { store.hide($0) }
    }
}

/// One upcoming event. Click it to see it in Calendar; right-click for a reminder, or to
/// hide it. `compact` shrinks Join to an icon, for the narrow Home column.
struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    var compact = false
    var actions: EventActions?
    @State private var hover = false

    var body: some View {
        let soon = event.isHappening(at: now) || event.start.timeIntervalSince(now) < 10 * 60
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(nsColor: event.color))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let url = event.joinURL { join(url, soon: soon) }
        }
        .background {
            if actions != nil {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(hover ? 0.07 : 0))
                    .padding(.horizontal, -7).padding(.vertical, -5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions?.open(event) }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(actions == nil ? "" : "Open in Calendar")
        .contextMenu { if let actions { menu(actions) } }
    }

    private func join(_ url: URL, soon: Bool) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Group {
                if compact {
                    Image(systemName: "video.fill").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 24)
                } else {
                    Label("Join", systemImage: "video.fill").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                }
            }
            .foregroundStyle(soon ? .black : .white)
            .background(Capsule().fill(soon ? Color.green : .white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .help("Join the meeting")
    }

    @ViewBuilder private func menu(_ actions: EventActions) -> some View {
        Button("Open in Calendar") { actions.open(event) }
        if let url = event.joinURL { Button("Join Meeting") { NSWorkspace.shared.open(url) } }
        let reminders = CalendarStore.reminderOptions(for: event, now: now)
        if !reminders.isEmpty {
            Divider()
            Menu("Remind Me") {
                ForEach(reminders, id: \.title) { option in Button(option.title) { actions.remind(event, option.date) } }
            }
        }
        Divider()
        Button("Hide from Up Next") { actions.hide(event) }
    }

    private var detail: String {
        let cal = Calendar.current
        let time = event.start.formatted(date: .omitted, time: .shortened)
        var when: String
        if event.isAllDay {
            when = cal.isDateInToday(event.start) || event.isHappening(at: now) ? "All day" : event.start.formatted(.dateTime.weekday(.abbreviated)) + ", all day"
        } else if event.isHappening(at: now) {
            when = "Now · until \(event.end.formatted(date: .omitted, time: .shortened))"
        } else if cal.isDateInToday(event.start) {
            let minutes = Int(event.start.timeIntervalSince(now) / 60)
            when = minutes < 60 ? "In \(max(1, minutes)) min · \(time)" : time
        } else if cal.isDateInTomorrow(event.start) {
            when = "Tomorrow, \(time)"
        } else {
            when = event.start.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        if let location = event.location { when += " · " + location }
        return when
    }
}

/// The banner that drops from the notch shortly before a meeting.
struct MeetingAlertRow: View {
    let event: CalendarEvent
    var onSnooze: ((Date) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.joinURL == nil ? "calendar" : "video.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(nsColor: event.color)))
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                TimelineView(.everyMinute) { context in
                    let minutes = Int(ceil(event.start.timeIntervalSince(context.date) / 60))
                    Text(minutes > 0 ? "Starts in \(minutes) min" : "Starting now")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            if let onSnooze { SnoozeButton(event: event, choose: onSnooze) }
            if let url = event.joinURL {
                Button { NSWorkspace.shared.open(url); onDismiss() } label: {
                    Text("Join").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(Capsule().fill(Color.green))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
            }
            // Always there, so a reminder can be put away without joining or snoozing.
            CircleIconButton(systemName: "xmark", size: 24, iconSize: 9.5, help: "Dismiss", action: onDismiss)
        }
        .foregroundStyle(.white)
    }
}

/// Opens the snooze choices for a meeting reminder.
private struct SnoozeButton: View {
    let event: CalendarEvent
    let choose: (Date) -> Void

    var body: some View {
        Button {
            SnoozeMenu.show(options: CalendarStore.snoozeOptions(for: event), choose: choose)
        } label: {
            HStack(spacing: 4) {
                Text(Image(systemName: "bell.badge")).font(.system(size: 10, weight: .semibold))
                Text("Snooze").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .help("Remind me again")
    }
}

/// The snooze choices, shown as a menu under the pointer.
@MainActor
private enum SnoozeMenu {
    private final class Target: NSObject {
        let choose: (Date) -> Void
        init(choose: @escaping (Date) -> Void) { self.choose = choose }
        @objc func pick(_ item: NSMenuItem) { (item.representedObject as? Date).map(choose) }
    }

    static func show(options: [(title: String, date: Date)], choose: @escaping (Date) -> Void) {
        let target = Target(choose: choose)
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(Target.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = option.date
            menu.addItem(item)
        }
        // The menu runs until a choice is made, which keeps `target` alive for that long.
        withExtendedLifetime(target) { _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

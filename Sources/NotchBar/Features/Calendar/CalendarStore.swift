import AppKit
import EventKit

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let color: NSColor
    /// A Teams, Zoom, Meet or Webex link found in the event.
    let joinURL: URL?

    func isHappening(at date: Date) -> Bool { start <= date && date < end }
}

/// Upcoming events from the Calendar app's accounts (iCloud, Exchange, Google and so on).
///
/// It reloads only when EventKit says the calendar changed, at midnight, or at the next
/// moment something starts or ends. Nothing polls.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access
    @Published private(set) var upcoming: [CalendarEvent] = []
    /// Days of `displayedMonth` that have at least one event.
    @Published private(set) var busyDays: Set<Int> = []
    @Published private(set) var displayedMonth: Date

    /// Called once per event, a few minutes before it starts, and again after each snooze.
    var onMeetingSoon: ((CalendarEvent) -> Void)?

    private let store = EKEventStore()
    private var boundary: Timer?
    private var announced = Set<String>()
    /// Snoozed reminders: event ID and when to remind again.
    private var snoozed: [String: Date] = [:]
    private let calendar = Calendar.current
    private static let headsUp: TimeInterval = 5 * 60

    init() {
        access = Self.currentAccess()
        displayedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.access = Self.currentAccess()
                    self?.reload()
                }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMonth(offset: Int) {
        let target = offset == 0 ? Date() : calendar.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth
        displayedMonth = calendar.dateInterval(of: .month, for: target)?.start ?? target
        loadBusyDays()
    }

    /// Test hook for snapshots.
    func setPreview(_ events: [CalendarEvent], busyDays: Set<Int>) {
        access = .granted
        upcoming = events
        self.busyDays = busyDays
    }

    // MARK: Loading

    private func reload() {
        guard access == .granted else { upcoming = []; busyDays = []; return }
        loadUpcoming()
        loadBusyDays()
        scheduleNextBoundary()
        announceMeetingsStartingSoon()
    }

    private func loadUpcoming() {
        let now = Date()
        guard let horizon = calendar.date(byAdding: .day, value: 7, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: calendar.startOfDay(for: now), end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.endDate > now && !isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map(Self.makeEvent)
        if events != upcoming { upcoming = Array(events) }
    }

    private func loadBusyDays() {
        guard access == .granted,
              let month = calendar.dateInterval(of: .month, for: displayedMonth) else { busyDays = []; return }
        let predicate = store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil)
        var days = Set<Int>()
        for event in store.events(matching: predicate) where !isDeclined(event) {
            var day = max(event.startDate, month.start)
            while day < min(event.endDate, month.end) {
                days.insert(calendar.component(.day, from: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { break }
                day = next
            }
        }
        if days != busyDays { busyDays = days }
    }

    /// Reminds about `event` again at `date`.
    func snooze(_ event: CalendarEvent, until date: Date) {
        snoozed[event.id] = date
        scheduleNextBoundary()
    }

    /// The snooze choices that make sense for `event` right now.
    static func snoozeOptions(for event: CalendarEvent, now: Date = Date()) -> [(title: String, date: Date)] {
        var options: [(String, Date)] = []
        let lead = event.start.timeIntervalSince(now)
        if lead > 90 { options.append(("1 minute before", event.start.addingTimeInterval(-60))) }
        if lead > 20 { options.append(("When it starts", event.start)) }
        options.append(("In 5 minutes", now.addingTimeInterval(5 * 60)))
        return options
    }

    /// One timer, set for the next moment the list, a heads-up or a snooze needs to change.
    private func scheduleNextBoundary() {
        boundary?.invalidate()
        let now = Date()
        let moments = (upcoming.flatMap { [$0.start.addingTimeInterval(-Self.headsUp), $0.start, $0.end] } + snoozed.values)
            .filter { $0 > now }
        guard let next = moments.min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        boundary = timer
    }

    private func announceMeetingsStartingSoon() {
        let now = Date()
        for (id, date) in snoozed where date <= now.addingTimeInterval(1) {
            snoozed[id] = nil
            if let event = upcoming.first(where: { $0.id == id }), now < event.end { onMeetingSoon?(event) }
        }
        for event in upcoming where !event.isAllDay && !announced.contains(event.id) {
            let lead = event.start.timeIntervalSince(now)
            if lead <= Self.headsUp && lead > -60 {
                announced.insert(event.id)
                onMeetingSoon?(event)
            }
        }
    }

    private func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title?.isEmpty == false ? event.title : "Untitled",
                      start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                      location: event.location.flatMap(readableLocation),
                      color: event.calendar?.color ?? .systemBlue,
                      joinURL: meetingLink(in: [event.url?.absoluteString, event.location, event.notes]))
    }

    /// Hides locations that are just a meeting link.
    private static func readableLocation(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("://") || trimmed.lowercased().contains("microsoft teams meeting") ? nil : trimmed
    }

    private static let meetingHosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com",
                                       "gotomeeting.com", "chime.aws", "whereby.com", "meet.jit.si", "facetime.apple.com"]
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func meetingLink(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkDetector?.matches(in: text, range: range) ?? [] {
                if let url = match.url, let host = url.host?.lowercased(), meetingHosts.contains(where: host.hasSuffix) {
                    return url
                }
            }
        }
        return nil
    }
}

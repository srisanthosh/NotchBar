import SwiftUI

/// The open notch: a tab bar on either side of the camera, and the selected tab below.
struct ExpandedNotch: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var timer: TimerModel
    @Namespace private var tabHighlight

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: vm.geometry.notchHeight)
            ZStack(alignment: .top) {
                content.transition(.notchContent).id(vm.tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, vm.topRadius + 16)
            .padding(.top, 12)
            .padding(.bottom, vm.toast == nil ? 18 : 48)
        }
        .overlay(alignment: .bottom) { toast }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch vm.tab {
        case .home:
            HomePanel(vm: vm, media: media, usage: usage, timer: timer, calendar: vm.calendar, weather: vm.weather)
        case .media: MediaPanel(media: media)
        case .claude: ClaudePanel(vm: vm, usage: usage)
        case .timer: TimerPanel(timer: timer)
        case .clipboard: ClipboardPanel(store: vm.clipboard) { vm.copyClip($0, paste: $1) }
        case .calendar: CalendarPanel(calendar: vm.calendar)
        case .activity: ActivityPanel(monitor: vm.activity)
        }
    }

    @ViewBuilder private var toast: some View {
        if let toast = vm.toast {
            Text(toast)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.16)))
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
        }
    }

    // MARK: Header

    /// The room on each side of the camera. Each group is held to it, so nothing ends up
    /// under the camera however many tabs are showing.
    private var sideWidth: CGFloat {
        max(0, (vm.expandedSize.width - vm.geometry.notchWidth - 16) / 2 - (vm.topRadius + 10))
    }

    /// Whether the selected tab's name fits beside the icons. With every tab showing it
    /// usually doesn't, and the highlighted icon and its tooltip have to do.
    private var showsTabLabel: Bool {
        let label = (vm.tab.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
        let others = CGFloat(vm.enabledTabs.count - 1)
        let estimate = others * 25 + others * 2 + 4 + (20 + 13 + 5 + label) + 6
        return estimate <= sideWidth
    }

    private var header: some View {
        let showsLabel = showsTabLabel
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(vm.enabledTabs) { tabButton($0, showsLabel: showsLabel) }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.06)))
            .frame(width: sideWidth, alignment: .leading)

            Spacer(minLength: vm.geometry.notchWidth + 16)

            HStack(spacing: 7) {
                BatteryIndicator()
                CircleIconButton(systemName: "lock.fill", size: 24, iconSize: 10.5, help: "Lock Screen") {
                    vm.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ScreenLock.lock() }
                }
                CircleIconButton(systemName: "ellipsis", size: 24, iconSize: 11, help: "More") {
                    NotchMenu.show(vm: vm)
                }
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, vm.topRadius + 10)
        .padding(.top, 3)
    }

    private func tabButton(_ tab: NotchViewModel.Tab, showsLabel: Bool) -> some View {
        let selected = vm.tab == tab
        return Button { vm.select(tab) } label: {
            HStack(spacing: 5) {
                icon(for: tab)
                if selected && showsLabel {
                    Text(tab.title).font(.system(size: 11.5, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            .padding(.horizontal, selected ? (showsLabel ? 10 : 7) : 6)
            .frame(height: 22)
            .background {
                if selected { Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "tab", in: tabHighlight) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .help(tab.title)
    }

    @ViewBuilder private func icon(for tab: NotchViewModel.Tab) -> some View {
        switch tab {
        case .home: Image(systemName: "house.fill").font(.system(size: 10.5, weight: .semibold))
        case .media: Image(systemName: "music.note").font(.system(size: 11, weight: .semibold))
        case .claude: ClaudeLogo(size: 13)
        case .timer:
            Image(systemName: "timer").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(timer.isActive ? Color.timerOrange : .white)
        case .clipboard: Image(systemName: "doc.on.clipboard").font(.system(size: 10.5, weight: .semibold))
        case .calendar: Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
        case .activity: Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 11, weight: .semibold))
        }
    }
}

import SwiftUI

/// The closed notch: a status on each side of the camera, and an optional banner below.
struct CollapsedNotch: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var timer: TimerModel

    var body: some View {
        let playing = media.nowPlaying?.isPlaying == true && vm.isEnabled(.media)
        // A banner is centered on the camera, so its top row needs equal sides to keep the
        // camera gap lined up with the camera.
        let balanced = vm.banner == nil ? nil : max(vm.leftWing, vm.rightWing)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The ZStack keeps the width even while the wing is empty, such as during the
                // now-playing banner.
                ZStack { leftWing(playing: playing) }
                    .frame(width: balanced ?? vm.leftWing)
                    .frame(maxWidth: vm.isHovering ? .infinity : nil, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.open(timer.isActive ? .timer : .media) }

                Color.black.opacity(0.001)
                    .frame(width: vm.geometry.notchWidth)
                    .onTapGesture { vm.open(vm.preferredTab) }

                ZStack {
                    if vm.isEnabled(.claude) { LiveClaudeLogo(usage: usage, size: 13) }
                }
                .frame(width: balanced ?? vm.rightWing)
                .frame(maxWidth: vm.isHovering ? .infinity : nil, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { vm.open(.claude) }
            }
            .padding(.horizontal, vm.topRadius)
            .frame(height: vm.geometry.notchHeight)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: playing)
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: vm.dictation.listening)

            if let banner = vm.banner {
                bannerView(banner)
                    .padding(.horizontal, vm.topRadius + (banner.isHUD ? 16 : 14))
                    .frame(maxHeight: .infinity)
                    .transition(.notchContent)
            }
        }
    }

    @ViewBuilder private func leftWing(playing: Bool) -> some View {
        if let source = vm.dictation.listening {
            DictationWing(source: source).transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if timer.isActive && vm.isEnabled(.timer) {
            TimerWing(timer: timer).transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if playing && vm.banner != .nowPlaying {
            AudioWaves(isPlaying: true, color: Color(nsColor: media.accent), height: 13)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    @ViewBuilder private func bannerView(_ banner: NotchViewModel.Banner) -> some View {
        switch banner {
        case .nowPlaying:
            if let entry = media.nowPlaying {
                NowPlayingBanner(entry: entry, artwork: media.artwork, accent: Color(nsColor: media.accent))
                    .onTapGesture { vm.open(.media) }
                    .dismissable { vm.dismissBanner() }
            }
        case .hud(let state):
            HUDRow(state: state) { vm.hudService.set(state.kind, to: $0) }
        case .timerDone:
            TimerAlertRow(timer: timer) { vm.dismissBanner() }
        case .meeting(let event):
            MeetingAlertRow(event: event, onSnooze: { date in
                vm.calendar.snooze(event, until: date)
                vm.dismissBanner()
            }) { vm.dismissBanner() }
        case .device(let event):
            DeviceBanner(event: event).id(event.name + (event.connected ? "+" : "-"))
                .dismissable { vm.dismissBanner() }
        }
    }
}

/// A close button that slides in from the right edge of a banner while the pointer is on it,
/// for banners that have no button of their own.
private struct Dismissable: ViewModifier {
    let action: () -> Void
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.trailing, hover ? 26 : 0)
            .overlay(alignment: .trailing) {
                if hover {
                    Button(action: action) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white.opacity(0.16)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Dismiss")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hover = h } }
    }
}

private extension View {
    func dismissable(_ action: @escaping () -> Void) -> some View { modifier(Dismissable(action: action)) }
}

/// The short "now playing" banner shown when a new track starts.
struct NowPlayingBanner: View {
    let entry: NowPlaying
    let artwork: NSImage?
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(image: artwork, size: 32, radius: 8, accent: accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(entry.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            AudioWaves(isPlaying: entry.isPlaying, color: accent, height: 16)
        }
        .foregroundStyle(.white)
    }
}

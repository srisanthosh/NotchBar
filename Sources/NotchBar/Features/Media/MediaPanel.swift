import SwiftUI

struct MediaPanel: View {
    @ObservedObject var media: MediaController

    var body: some View {
        if let np = media.nowPlaying {
            playing(np)
        } else {
            empty
        }
    }

    private var accent: Color { Color(nsColor: media.accent) }

    private func playing(_ np: NowPlaying) -> some View {
        HStack(alignment: .center, spacing: 18) {
            ArtworkView(image: media.artwork, size: 104, radius: 18, accent: accent,
                        badge: media.artworkIsAppIcon ? nil : np.source.icon, isAppIcon: media.artworkIsAppIcon)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(np.artist.isEmpty ? np.album : np.artist)
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    AudioWaves(isPlaying: np.isPlaying, color: accent, height: 18)
                        .padding(.top, 4)
                }
                Spacer(minLength: 8)
                if np.source.usesMediaKeys && !media.hasAccessibility {
                    AccessibilityHint(app: np.source.appName) { media.requestAccessibility() }
                } else if np.hasTimeline {
                    Scrubber(np: np) { media.seek(to: $0) }
                } else if np.source.isBrowser && media.pageScriptingOff {
                    PageScriptingHint(source: np.source)
                } else if np.title != np.source.appName {
                    HStack(spacing: 6) {
                        if let icon = np.source.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                        Text(np.isPlaying ? "Playing in \(np.source.appName)" : "Paused in \(np.source.appName)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 34) {
                    if np.source.canSkip { transport("backward.fill", size: 17) { media.previous() } }
                    transport(np.isPlaying ? "pause.fill" : "play.fill", size: 24, big: true) { media.togglePlayPause() }
                    if np.source.canSkip { transport("forward.fill", size: 17) { media.next() } }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 112)
    }

    private var empty: some View {
        HStack(spacing: 18) {
            ArtworkView(image: nil, size: 104, radius: 18, accent: .white)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing Playing").font(.system(size: 15, weight: .semibold))
                Text("Play anything, in Music, Spotify, VLC or a browser, and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if media.pageScriptingOff {
                    Text("Paused in Chrome? Turn on View › Developer › Allow JavaScript from Apple Events to see it here.")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.claudeWaiting.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach([MediaSource.music, .spotify].filter(\.isInstalled), id: \.bundleID) { src in
                        Button { media.open(src) } label: {
                            HStack(spacing: 6) {
                                if let icon = src.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                Text("Open \(src.appName)").font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableStyle(scale: 0.94))
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            transport("play.fill", size: 22, big: true) { media.togglePlayPause() }
                .help("Play/Pause (media key)")
        }
        .frame(height: 112)
    }

    private func transport(_ symbol: String, size: CGFloat, big: Bool = false, action: @escaping () -> Void) -> some View {
        TransportButton(symbol: symbol, size: size, big: big, action: action)
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var big = false
    /// Overrides the circle size, for compact layouts.
    var diameter: CGFloat?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: diameter ?? (big ? 44 : 34), height: diameter ?? (big ? 44 : 34))
                .background(Circle().fill(.white.opacity(hover ? 0.14 : (big ? 0.08 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.82))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var accent: Color
    var badge: NSImage? = nil
    var isAppIcon = false

    var body: some View {
        ZStack {
            if let image, isAppIcon {
                // App icons sit on a soft tile instead of filling the frame.
                LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(size * 0.16)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: image == nil ? .clear : accent.opacity(0.35), radius: size * 0.14)
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(nsImage: badge).resizable().frame(width: size * 0.26, height: size * 0.26)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: size * 0.07, y: size * 0.07)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: image)
    }
}

struct Scrubber: View {
    let np: NowPlaying
    let onSeek: (Double) -> Void
    @State private var drag: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = drag.map { $0 * np.duration } ?? np.elapsed(at: ctx.date)
            let fraction = np.duration > 0 ? min(1, max(0, elapsed / np.duration)) : 0
            let active = hover || drag != nil
            VStack(spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(.white.opacity(active ? 1 : 0.82))
                            .frame(width: max(active ? 7 : 4, g.size.width * fraction))
                    }
                    .frame(height: active ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(1, max(0, v.location.x / g.size.width)) }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / g.size.width))
                            onSeek(f * np.duration)
                            drag = nil
                        })
                }
                .frame(height: 12)
                HStack {
                    Text(formatTime(elapsed))
                    Spacer()
                    Text("-" + formatTime(max(0, np.duration - elapsed)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .onHover { hover = $0 }
    }
}

/// Shown when controlling the current app needs Accessibility access.
struct AccessibilityHint: View {
    let app: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold))
                Text("Allow Accessibility to control \(app)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.claudeWaiting)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.claudeWaiting.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .help("Opens Privacy & Security > Accessibility. Turn on NotchBar there.")
    }
}

/// Explains the browser setting that unlocks progress, artist and exact controls.
struct PageScriptingHint: View {
    let source: MediaSource

    var body: some View {
        let path = source.kind == .safari
            ? "Safari › Develop › Allow JavaScript from Apple Events"
            : "View › Developer › Allow JavaScript from Apple Events"
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").font(.system(size: 10, weight: .bold))
            Text("For progress and artist, turn on \(path) in \(source.appName)")
                .font(.system(size: 10.5, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(.white.opacity(0.5))
        .help("This lets apps you've allowed to control \(source.appName) run scripts in its tabs. NotchBar only reads the playing video and presses play or pause.")
    }
}

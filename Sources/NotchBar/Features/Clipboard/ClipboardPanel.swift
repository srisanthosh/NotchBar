import SwiftUI
import ApplicationServices

struct ClipboardPanel: View {
    @ObservedObject var store: ClipboardStore
    let onCopy: (ClipItem, _ paste: Bool) -> Void

    private var cards: some View {
        LazyHStack(spacing: 10) {
            ForEach(store.items) { item in
                ClipCard(item: item, store: store, onCopy: onCopy)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 1)
    }

    var body: some View {
        if store.items.isEmpty {
            HStack(spacing: 16) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 104, height: 104)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.isPaused ? "History Paused" : "Nothing Copied Yet").font(.system(size: 15, weight: .semibold))
                    Text(store.isPaused ? "Resume it from the … menu."
                                        : "Text, links, images and files you copy show up here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Text("Press ⌃⌘V anytime to open it.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 112)
        } else {
            Group {
                if Snapshotter.isRendering {
                    // Image renders leave scroll views empty, so snapshots get a plain row.
                    cards.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) { cards }
                }
            }
            .frame(height: 112)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93),
                                         .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let onCopy: (ClipItem, Bool) -> Void
    @State private var hover = false
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon = sourceIcon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                Text(item.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 2)
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.timerOrange)
                }
                Text(relative(item.date)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
            content
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 158, height: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.13 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(hover ? 0.12 : 0.05), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if hover && !showCopied {
                HStack(spacing: 4) {
                    mini(item.pinned ? "pin.slash.fill" : "pin.fill", help: item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
                    mini("trash.fill", help: "Delete") { store.delete(item) }
                    mini("arrow.turn.down.left", help: "Paste into the front app") { flash(); onCopy(item, true) }
                }
                .padding(7)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomTrailing)))
            }
        }
        .overlay {
            if showCopied {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55))
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .scaleEffect(showCopied ? 0.96 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { flash(); onCopy(item, false) }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help("Click to copy")
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
        case .link:
            let url = URL(string: item.text ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Label(url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link", systemImage: "link")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1))
                Text(url?.path.isEmpty == false ? url!.path : (item.text ?? ""))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 138, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .file:
            HStack(spacing: 8) {
                if let first = item.files?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().frame(width: 34, height: 34)
                }
                Text(item.files?.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") ?? "")
                    .font(.system(size: 11, weight: .medium)).lineLimit(3)
            }
        }
    }

    private var sourceIcon: NSImage? {
        guard let id = item.sourceBundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func mini(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(white: 0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .help(help)
    }

    private func flash() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.2)) { showCopied = false }
        }
    }

    private func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

/// Sends ⌘V to the front app. The notch panel never takes focus, so the paste lands where the user was.
enum PasteKey {
    static func post() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

import AppKit
import SwiftUI

/// The banner that drops from the notch when headphones or speakers connect, like AirPods on
/// iPhone. A ring draws closed into a checkmark, and in-ear headphones of any make have their
/// two buds slide in from each side. A card for each battery fills up to its level. When a device disconnects, the banner says where the
/// sound went and shows the battery it last reported.
struct DeviceBanner: View {
    let event: DeviceEvent
    @State private var drawn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DeviceGlyph(symbol: event.symbol, buds: EarbudIcons(deviceSymbol: event.symbol), connected: event.connected, drawn: drawn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let volume = event.volume, event.connected { VolumeBadge(level: volume) }
            }
            if !event.battery.isEmpty {
                HStack(spacing: 6) {
                    ForEach(event.battery) { battery in
                        BatteryCard(battery: battery, symbol: symbol(for: battery), connected: event.connected, drawn: drawn)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72).delay(0.1)) { drawn = true }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: event.battery)
    }

    private var lowBattery: DeviceEvent.Battery? { event.battery.filter(\.isLow).min { $0.percent < $1.percent } }

    private var status: String {
        guard event.connected else {
            return event.soundNowOn.map { "Disconnected · Sound on \($0)" } ?? "Disconnected"
        }
        if let low = lowBattery {
            return low.label.isEmpty || low.label == "Case" ? "\(low.title) low · \(low.percent)%" : "\(low.title) bud low · \(low.percent)%"
        }
        return "Connected · \(event.connection)"
    }

    private var statusColor: Color {
        guard event.connected else { return .white.opacity(0.5) }
        return lowBattery == nil ? .green : .red
    }

    /// The matching part of the device: each bud, the charging case, or the whole device.
    private func symbol(for battery: DeviceEvent.Battery) -> String {
        guard let buds = EarbudIcons(deviceSymbol: event.symbol) else { return event.symbol }
        switch battery.label {
        case "L": return buds.left
        case "R": return buds.right
        case "Case": return buds.chargingCase
        default: return event.symbol
        }
    }
}

/// The device's icon in a ring that draws itself closed, with a checkmark once connected.
/// In-ear headphones show their two buds, which slide in from each side and tilt into place.
private struct DeviceGlyph: View {
    let symbol: String
    let buds: EarbudIcons?
    let connected: Bool
    let drawn: Bool

    var body: some View {
        ZStack {
            Circle().fill(connected ? Color.green.opacity(0.12) : .white.opacity(0.06))
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(connected ? Color.green : .white.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Group {
                if let buds {
                    HStack(spacing: 1) {
                        bud(buds.left, side: -1)
                        bud(buds.right, side: 1)
                    }
                } else {
                    Text(Image(systemName: symbol))
                        .font(.system(size: 18, weight: .medium))
                        .scaleEffect(drawn ? 1 : 0.4)
                        .opacity(drawn ? 1 : 0)
                }
            }
            .foregroundStyle(.white.opacity(connected ? 1 : 0.5))
        }
        .frame(width: 42, height: 42)
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(connected ? Color.green : Color.gray)
                Text(Image(systemName: connected ? "checkmark" : "xmark")).font(.system(size: 7.5, weight: .heavy))
            }
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(.black, lineWidth: 2))
            .scaleEffect(drawn ? 1 : 0.01)
            .offset(x: 3, y: 3)
        }
    }

    /// One bud. On connect it starts outside the ring, tilted away, and springs into place.
    private func bud(_ name: String, side: CGFloat) -> some View {
        Text(Image(systemName: name))
            .font(.system(size: 15, weight: .medium))
            .offset(x: drawn ? 0 : side * 16, y: drawn ? 0 : -6)
            .rotationEffect(.degrees(drawn ? 0 : side * 28))
            .opacity(drawn ? 1 : 0)
    }
}

/// The device's volume when it connected, so a loud pair of headphones is no surprise.
private struct VolumeBadge: View {
    let level: Float

    var body: some View {
        let symbol = level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        HStack(spacing: 5) {
            Text(Image(systemName: symbol)).font(.system(size: 10, weight: .semibold))
            Text("\(Int((level * 100).rounded()))%").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

/// One battery: the part's icon, its name, its level, and a bar that fills to it.
private struct BatteryCard: View {
    let battery: DeviceEvent.Battery
    let symbol: String
    let connected: Bool
    let drawn: Bool

    var body: some View {
        let tint: Color = !connected ? .white.opacity(0.4) : battery.isLow ? .red : .green
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Image(systemName: symbol)).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(battery.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                Text("\(battery.percent)%").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(battery.isLow && connected ? Color.red : .white)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * (drawn ? CGFloat(battery.percent) / 100 : 0))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

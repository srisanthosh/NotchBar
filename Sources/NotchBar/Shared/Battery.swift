import SwiftUI
import IOKit.ps

/// Battery level and charging state, updated by IOKit power notifications instead of polling.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var percent: Int?
    @Published private(set) var charging = false

    private init() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { percent = nil; return }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
            charging = (d[kIOPSIsChargingKey] as? Bool) == true || d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return
        }
        percent = nil
    }
}

struct BatteryIndicator: View {
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        if let p = battery.percent {
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1)
                        .frame(width: 20, height: 10)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(fill(p))
                        .frame(width: max(2, 16 * CGFloat(p) / 100), height: 6)
                        .padding(.leading, 2)
                    if battery.charging {
                        Image(systemName: "bolt.fill").font(.system(size: 7, weight: .black))
                            .foregroundStyle(.black).frame(width: 20)
                    }
                }
                .overlay(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.45)).frame(width: 1.5, height: 4).offset(x: 2)
                }
                Text("\(p)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(.white.opacity(0.09)))
        }
    }

    private func fill(_ p: Int) -> Color {
        if battery.charging { return .green }
        return p <= 20 ? .red : .white
    }
}

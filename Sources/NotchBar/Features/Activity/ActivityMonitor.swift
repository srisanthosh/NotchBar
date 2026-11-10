import AppKit
import Combine
import Darwin
import IOKit

/// One reading of the Mac's load, like the top of Activity Monitor.
struct ActivitySample: Equatable {
    enum Pressure: Equatable {
        case nominal, warning, critical

        var label: String {
            switch self {
            case .nominal: return "Normal"
            case .warning: return "Warning"
            case .critical: return "Critical"
            }
        }
    }

    /// Busy share of all cores together, 0...1.
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cores = ProcessInfo.processInfo.activeProcessorCount
    /// App memory plus wired and compressed memory, the way Activity Monitor counts "Memory Used".
    var memoryUsed: UInt64 = 0
    var memoryTotal = ProcessInfo.processInfo.physicalMemory
    var pressure: Pressure = .nominal
    var swapUsed: UInt64 = 0
    /// Bytes per second since the previous sample.
    var networkIn: Double = 0
    var networkOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var loadAverage: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    /// The apps using the most CPU right now, each with its helper processes added in.
    var processes: [ActivityProcess] = []

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    var thermalLabel: String {
        switch thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

struct ActivityProcess: Identifiable, Equatable {
    /// The .app's path, or the executable name for a process outside any app.
    let id: String
    let name: String
    /// CPU use as a share of one core, so 2.0 reads as 200%, like Activity Monitor.
    let cpu: Double
    let memory: UInt64
    /// The .app the process belongs to, for its icon.
    var bundlePath: String? { id.hasSuffix(".app") ? id : nil }
}

/// CPU, memory, network, disk and the busiest processes.
///
/// Sampling costs a few milliseconds, so it only runs while the Activity tab or the Home
/// widget is on screen. Nothing is measured while the notch is closed.
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var sample = ActivitySample()
    /// The last `historyLength` CPU readings, oldest first.
    @Published private(set) var cpuHistory: [Double] = []
    /// Network in plus out, bytes per second, oldest first.
    @Published private(set) var networkHistory: [Double] = []
    /// How long the last reading took, for the debug state.
    private(set) var lastSampleDuration: TimeInterval = 0
    static let historyLength = 40
    static let interval: TimeInterval = 2

    private var timer: EfficientTimer?
    private let queue = DispatchQueue(label: "com.local.notchbar.activity", qos: .utility)
    private let sampler = ActivitySampler()
    private var isActive = false
    private var inFlight = false
    private var previewing = false

    init() {
        timer = EfficientTimer(interval: Self.interval, tolerance: 0.3) { [weak self] in self?.sampleNow() }
    }

    /// Starts or stops sampling. The first numbers arrive within a second of starting.
    func setActive(_ active: Bool) {
        guard active != isActive, !previewing else { return }
        isActive = active
        if active {
            sampleNow()  // a baseline, so the next sample has rates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { if self?.isActive == true { self?.sampleNow() } }
            }
            timer?.start()
        } else {
            timer?.stop()
        }
    }

    /// Opens Apple's Activity Monitor, for the full picture.
    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Test hook for snapshots.
    func setPreview(_ sample: ActivitySample, cpuHistory: [Double], networkHistory: [Double]) {
        previewing = true
        self.sample = sample
        self.cpuHistory = cpuHistory
        self.networkHistory = networkHistory
    }

    private func sampleNow() {
        guard !inFlight else { return }
        inFlight = true
        let sampler = self.sampler
        queue.async {
            let started = ProcessInfo.processInfo.systemUptime
            let result = sampler.sample()
            let duration = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.lastSampleDuration = duration
                    self.apply(result.sample, hasRates: result.hasRates)
                }
            }
        }
    }

    private func apply(_ new: ActivitySample, hasRates: Bool) {
        sample = new
        guard hasRates else { return }
        cpuHistory = Array((cpuHistory + [new.cpu]).suffix(Self.historyLength))
        networkHistory = Array((networkHistory + [new.networkIn + new.networkOut]).suffix(Self.historyLength))
    }
}

/// Reads the kernel's counters. Every rate is the difference since the previous call, so
/// the first call only has levels. Used from one background queue.
private final class ActivitySampler: @unchecked Sendable {
    private var lastTime: TimeInterval?
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64)?
    private var lastNetwork: (in: UInt64, out: UInt64)?
    private var lastDisk: (read: UInt64, write: UInt64)?
    /// CPU time per process in nanoseconds, from the previous call.
    private var lastProcessTime: [pid_t: UInt64] = [:]
    private var names: [pid_t: (name: String, bundle: String?)] = [:]
    /// Nanoseconds per unit of the task info clock.
    private let nanosecondsPerTick: Double

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        nanosecondsPerTick = info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }

    func sample() -> (sample: ActivitySample, hasRates: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTime.map { now - $0 }
        lastTime = now
        var s = ActivitySample()
        readCPU(into: &s)
        readMemory(into: &s)
        readNetwork(into: &s, elapsed: elapsed)
        readDisk(into: &s, elapsed: elapsed)
        readProcesses(into: &s, elapsed: elapsed)
        s.thermal = ProcessInfo.processInfo.thermalState
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { s.loadAverage = loads[0] }
        return (s, elapsed != nil)
    }

    private func readCPU(into s: inout ActivitySample) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // user, system, idle, nice
        let ticks = (user: UInt64(load.cpu_ticks.0) + UInt64(load.cpu_ticks.3), system: UInt64(load.cpu_ticks.1), idle: UInt64(load.cpu_ticks.2))
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }
        let user = Double(ticks.user &- last.user)
        let system = Double(ticks.system &- last.system)
        let idle = Double(ticks.idle &- last.idle)
        let total = user + system + idle
        guard total > 0 else { return }
        s.cpuUser = user / total
        s.cpuSystem = system / total
        s.cpu = (user + system) / total
    }

    private func readMemory(into s: inout ActivitySample) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let app = internalPages > purgeable ? internalPages - purgeable : 0
            s.memoryUsed = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { s.swapUsed = swap.xsu_used }
        // 1 normal, 2 warning, 4 critical.
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            s.pressure = level >= 4 ? .critical : (level >= 2 ? .warning : .nominal)
        }
    }

    private func readNetwork(into s: inout ActivitySample, elapsed: TimeInterval?) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return }
        defer { freeifaddrs(first) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Loopback and the tunnels and links that carry traffic already counted on a real interface.
            if ["lo", "utun", "awdl", "llw", "bridge", "ipsec", "gif", "stf", "ap"].contains(where: name.hasPrefix) { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes += UInt64(stats.ifi_ibytes)
            outBytes += UInt64(stats.ifi_obytes)
        }
        defer { lastNetwork = (inBytes, outBytes) }
        guard let last = lastNetwork, let elapsed, elapsed > 0 else { return }
        // The kernel's counters are 32-bit and wrap; a wrap shows up as a dip, which counts as zero.
        s.networkIn = inBytes >= last.in ? Double(inBytes - last.in) / elapsed : 0
        s.networkOut = outBytes >= last.out ? Double(outBytes - last.out) / elapsed : 0
    }

    private func readDisk(into s: inout ActivitySample, elapsed: TimeInterval?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        defer { lastDisk = (read, write) }
        guard let last = lastDisk, let elapsed, elapsed > 0 else { return }
        s.diskRead = read >= last.read ? Double(read - last.read) / elapsed : 0
        s.diskWrite = write >= last.write ? Double(write - last.write) / elapsed : 0
    }

    /// Every process this user may inspect, added up per app. Other users' and the system's
    /// own processes don't answer, which is also how Activity Monitor behaves without an
    /// administrator.
    private func readProcesses(into s: inout ActivitySample, elapsed: TimeInterval?) {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return }
        var current: [pid_t: UInt64] = [:]
        var busy: [(pid: pid_t, cpu: Double, memory: UInt64)] = []
        var info = proc_taskinfo()
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(found) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else { continue }
            let nanoseconds = UInt64(Double(info.pti_total_user &+ info.pti_total_system) * nanosecondsPerTick)
            current[pid] = nanoseconds
            guard let elapsed, elapsed > 0, let last = lastProcessTime[pid], nanoseconds >= last else { continue }
            busy.append((pid, Double(nanoseconds - last) / 1e9 / elapsed, info.pti_resident_size))
        }
        lastProcessTime = current
        names = names.filter { current[$0.key] != nil }
        guard !busy.isEmpty else { return }
        // Only the busiest processes are worth naming. Helpers are added to their app, so
        // a browser with twenty renderers shows as one row.
        var apps: [String: ActivityProcess] = [:]
        for process in busy.sorted(by: { $0.cpu > $1.cpu }).prefix(40) {
            let identity = name(of: process.pid)
            let key = identity.bundle ?? identity.name
            let title = identity.bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? identity.name
            let existing = apps[key]
            apps[key] = ActivityProcess(id: key, name: title, cpu: (existing?.cpu ?? 0) + process.cpu,
                                        memory: (existing?.memory ?? 0) + process.memory)
        }
        s.processes = Array(apps.values.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(6))
    }

    /// The executable name, from its path so it isn't cut short the way `proc_name` is, and
    /// the .app it lives in.
    private func name(of pid: pid_t) -> (name: String, bundle: String?) {
        if let known = names[pid] { return known }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        var name = ""
        var bundle: String?
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            name = (full as NSString).lastPathComponent
            if let range = full.range(of: ".app/") { bundle = String(full[..<range.lowerBound]) + ".app" }
        }
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            if proc_name(pid, &short, UInt32(short.count)) > 0 { name = String(cString: short) }
        }
        let known = (name.isEmpty ? "Process \(pid)" : name, bundle)
        names[pid] = known
        return known
    }
}

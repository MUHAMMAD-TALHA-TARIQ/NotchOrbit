import AppKit
import Combine
import IOKit
import IOKit.ps

/// One round of readings. Percent values are 0–100; `apps` is a count.
/// `nil` means the reading isn't available (no battery, first CPU sample, …).
struct StatSnapshot: Equatable {
    var cpu: Double?
    var memory: Double?
    var gpu: Double?
    var disk: Double?
    var battery: Double?
    var apps: Double?

    func value(for metric: StatMetric) -> Double? {
        switch metric {
        case .cpu:     return cpu
        case .memory:  return memory
        case .gpu:     return gpu
        case .disk:    return disk
        case .battery: return battery
        case .apps:    return apps
        }
    }
}

/// Periodically samples system stats on the main run loop.
/// Runs while stats mode is on, or while the settings window wants a live preview.
final class SystemStatsMonitor: ObservableObject {
    static let shared = SystemStatsMonitor()

    @Published private(set) var snapshot = StatSnapshot()
    /// Most recent samples, oldest first, one per tick (capped at `historyCapacity`).
    /// Published after `snapshot` on every tick, so subscribers see both up to date.
    @Published private(set) var history: [StatSnapshot] = []
    static let historyCapacity = 90

    /// Set from settings: stats mode is enabled.
    var wanted = false { didSet { reconcile() } }
    /// Settings window is open and showing live readings.
    var previewWanted = false { didSet { reconcile() } }
    var interval: TimeInterval = 2 {
        didSet { if interval != oldValue { history.removeAll(); restart() } }
    }

    private var timer: Timer?
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    /// Nothing is visible while the displays sleep, so sampling pauses.
    private var screensAsleep = false { didSet { reconcile() } }
    /// IOAccelerator services, matched once and kept (each is a retained io_object_t).
    private var gpuServices: [io_registry_entry_t] = []
    private static let gpuKeys = ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"]

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
        }
    }

    private var shouldRun: Bool { (wanted || previewWanted) && !screensAsleep }

    private func reconcile() {
        if shouldRun, timer == nil { restart() }
        if !shouldRun, timer != nil { stop() }
    }

    private func restart() {
        stop()
        guard shouldRun else { return }
        let interval = max(0.5, self.interval)
        sampleNow()
        // CPU usage is a delta between two readings; take a quick second one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.sampleNow()
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sampleNow() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        lastCPUTicks = nil
    }

    func sampleNow() {
        var s = StatSnapshot()
        s.cpu = sampleCPU()
        s.memory = sampleMemory()
        s.gpu = sampleGPU()
        s.disk = sampleDisk()
        s.battery = sampleBattery()
        s.apps = sampleApps()
        if Debug.enabled { debugLog("[debug] stats:", s) }
        if s != snapshot { snapshot = s }
        history.append(s)
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }

    // MARK: - Samplers

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastCPUTicks = (busy, total) }
        guard let last = lastCPUTicks, total > last.total, busy >= last.busy else { return snapshot.cpu }
        return min(100, Double(busy - last.busy) / Double(total - last.total) * 100)
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func sampleMemory() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let pages = app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = Double(pages) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(100, max(0, used / total * 100))
    }

    /// Reads the GPU driver's performance counters from the IO registry. The
    /// accelerator services are matched once, and only their `PerformanceStatistics`
    /// property is fetched; copying every property of every accelerator on each tick
    /// (as before) built large dictionaries just to throw them away.
    private func sampleGPU() -> Double? {
        if gpuServices.isEmpty { gpuServices = Self.accelerators() }
        var best: Double?
        for service in gpuServices {
            guard let perf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            for key in Self.gpuKeys {
                if let n = perf[key] as? NSNumber, (0...100).contains(n.doubleValue) {
                    best = max(best ?? 0, n.doubleValue)
                    break
                }
            }
        }
        if best == nil, !gpuServices.isEmpty {
            // A GPU went away (an eGPU unplugged, say): match again next time.
            gpuServices.forEach { IOObjectRelease($0) }
            gpuServices = []
        }
        return best
    }

    private static func accelerators() -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var found: [io_registry_entry_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 { found.append(service) }
        return found
    }

    private func sampleDisk() -> Double? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return min(100, max(0, (1 - Double(available) / Double(total)) * 100))
    }

    private func sampleBattery() -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? NSNumber,
                  let max = desc[kIOPSMaxCapacityKey] as? NSNumber, max.doubleValue > 0 else { continue }
            return min(100, Swift.max(0, current.doubleValue / max.doubleValue * 100))
        }
        return nil
    }

    /// Apps with a Dock presence (what the ⌘-Tab switcher shows).
    private func sampleApps() -> Double? {
        Double(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count)
    }
}

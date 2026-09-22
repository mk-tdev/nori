import Foundation
import AppKit
import Darwin
import PulseSystem
import UserNotifications

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double
    let memory: Double
    let gpu: Double?
    let temperature: Double?
}
struct Reading {
    var cpu: Double = 0
    var cores: [Double] = []
    var memory: Double = 0
    var usedMemory: UInt64 = 0
    var swap: UInt64 = 0
    var pressure: MemoryPressure = .unknown
    var compressed: UInt64 = 0
    var pageOutBytesPerSecond: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 1
    var temperature: Double = -1
    var gpu = GPUReading()
    var processes: [ProcessReading] = []
    var time = Date()
    var valid = false
}
final class Collector: @unchecked Sendable {
    private var oldTicks: [UInt64]?
    private var oldCoreTicks: [[UInt64]]?
    private var oldProcesses: [Int32: UInt64] = [:]
    private var oldGPUProcesses: [Int32: UInt64] = [:]
    private var oldPageouts: UInt64?
    private var oldVMTime: TimeInterval?
    private var oldTime = ProcessInfo.processInfo.systemUptime
    func collect() -> Reading {
        var r = Reading()
        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0) == 0 { r.pressure = MemoryPressure(raw: pressureRaw) }
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let ticks = [cpuInfo.cpu_ticks.0, cpuInfo.cpu_ticks.1, cpuInfo.cpu_ticks.2, cpuInfo.cpu_ticks.3].map(UInt64.init)
            if let old = oldTicks {
                let delta = zip(ticks, old).map { ($0 &- $1) & 0xffffffff }
                let total = delta.reduce(0, +)
                if total > 0 { r.cpu = 100 * Double(total - delta[2]) / Double(total); r.valid = true }
            }
            oldTicks = ticks
        }
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        if host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &processorInfoCount) == KERN_SUCCESS,
           let info = processorInfo {
            defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
            let states = Int(CPU_STATE_MAX)
            if Int(processorInfoCount) >= Int(processorCount) * states {
                let ticks = (0..<Int(processorCount)).map { core in
                    (0..<states).map { UInt64(UInt32(bitPattern: info[core * states + $0])) }
                }
                if let previous = oldCoreTicks, previous.count == ticks.count {
                    r.cores = zip(ticks, previous).map { current, old in
                        let delta = zip(current, old).map { ($0 &- $1) & 0xffffffff }
                        let total = delta.reduce(0, +)
                        return total > 0 ? 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) : 0
                    }
                }
                oldCoreTicks = ticks
            }
        } else {
            oldCoreTicks = nil
        }
        var vm = vm_statistics64()
        count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if vmResult == KERN_SUCCESS {
            r.compressed = UInt64(vm.compressor_page_count) * UInt64(vm_kernel_page_size)
            let now = ProcessInfo.processInfo.systemUptime
            let pageouts = UInt64(vm.pageouts)
            if let old = oldPageouts, let priorTime = oldVMTime, pageouts >= old, now > priorTime {
                r.pageOutBytesPerSecond = Double(pageouts - old) * Double(vm_kernel_page_size) / (now - priorTime)
            }
            oldPageouts = pageouts; oldVMTime = now
            let pages = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let reclaimable = UInt64(vm.purgeable_count) + UInt64(vm.external_page_count)
            r.usedMemory = (pages > reclaimable ? pages - reclaimable : 0) * UInt64(vm_kernel_page_size)
            r.memory = min(100, Double(r.usedMemory) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
        }
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { r.swap = swap.xsu_used }
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            r.diskFree = Int64(values.volumeAvailableCapacity ?? 0); r.diskTotal = Int64(values.volumeTotalCapacity ?? 1)
        }
        r.temperature = pulse_temperature()
        var buffer = [PulseProcess](repeating: PulseProcess(), count: 8192)
        let n = pulse_processes(&buffer, Int32(buffer.count))
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - oldTime)
        var next: [Int32: UInt64] = [:]
        for var p in buffer.prefix(Int(n)) {
            let name = withUnsafePointer(to: &p.name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            let path = withUnsafePointer(to: &p.path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            let cpu = oldProcesses[p.pid].map { p.cpu_ns >= $0 ? Double(p.cpu_ns - $0) / elapsed / 1_000_000_000 * 100 : 0 } ?? 0
            next[p.pid] = p.cpu_ns
            r.processes.append(ProcessReading(id: p.pid, name: name.isEmpty ? "Process \(p.pid)" : name, cpu: cpu, memory: p.resident, parent: p.parent, path: path))
        }
        oldProcesses = next
        r.processes = AppGrouping.assign(r.processes)
        r.processes.sort { $0.cpu > $1.cpu }
        var gpuStats = PulseGPUStats()
        var gpuProcesses = [PulseGPUProcess](repeating: PulseGPUProcess(), count: 4096)
        let gpuCount = pulse_gpu_stats(&gpuStats, &gpuProcesses, Int32(gpuProcesses.count))
        r.gpu.device = gpuStats.device
        r.gpu.renderer = gpuStats.renderer
        r.gpu.tiler = gpuStats.tiler
        r.gpu.allocatedMemory = gpuStats.allocated_memory
        r.gpu.inUseMemory = gpuStats.in_use_memory
        r.gpu.coreCount = Int(gpuStats.core_count)
        var nextGPU: [Int32: UInt64] = [:]
        var gpuNames: [Int32: String] = [:]
        for var process in gpuProcesses.prefix(Int(gpuCount)) {
            let name = withUnsafePointer(to: &process.name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            nextGPU[process.pid, default: 0] += process.gpu_ns
            if !name.isEmpty { gpuNames[process.pid] = name }
        }
        var gpuUsage: [GPUAttribution.ProcessUsage] = []
        for (pid, total) in nextGPU {
            let previous = oldGPUProcesses[pid]
            let usage = previous.map { total >= $0 ? Double(total - $0) / elapsed / 1_000_000_000 * 100 : 0 } ?? 0
            if usage > 0.01 { gpuUsage.append(.init(pid: pid, name: gpuNames[pid] ?? "GPU process", usage: usage)) }
        }
        oldGPUProcesses = nextGPU
        let owners = Dictionary(r.processes.map { ($0.id, $0.app.isEmpty ? $0.name : $0.app) }, uniquingKeysWith: { first, _ in first })
        r.gpu.apps = GPUAttribution.groups(gpuUsage, owners: owners)
        oldTime = now
        return r
    }
}
@MainActor final class Monitor: ObservableObject {
    @Published var reading = Reading()
    @Published var history: [Sample] = []
    @Published var paused = false {
        didSet { alertEngine.reset(); if !paused { refresh(); refreshDocker() } }
    }
    @Published var docker = DockerSnapshot()
    @Published var dockerLoading = false
    @Published var caches = CacheSnapshot()
    @Published var cacheScanning = false
    @Published var cacheCleaning: Set<String> = []
    @Published var cacheMessages: [String: String] = [:]
    @Published var cacheLastAction: String?
    @Published var alerts: [SustainedAlert] = []
    @Published var alertsEnabled = true { didSet { alertEngine.reset() } }
    @Published var notificationStatus = "Optional: send alerts to Notification Center"
    @Published var notificationsEnabled = false
    @Published private(set) var keepAwake = false
    @Published private(set) var keepAwakeError: String?
    private var alertEngine = SustainedAlertEngine()
    private let keepAwakeSession = KeepAwakeSession()
    private var lastDockerAttempt = Date.distantPast
    private let dockerQueue = DispatchQueue(label: "Nori.docker", qos: .utility)
    private let cacheQueue = DispatchQueue(label: "Nori.caches", qos: .utility)
    @Published var thermal = ProcessInfo.processInfo.thermalState
    private let collector = Collector()
    private let queue = DispatchQueue(label: "Pulse.collector", qos: .utility)
    private var timer: Timer?
    private var collecting = false
    init() {
        // Presence is a cheap existence check; sizes cost a disk walk and wait for an explicit scan.
        caches = CacheSnapshot(measurements: CacheCollector.presence())
        refresh()
        refreshDocker()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        guard !paused, !collecting else { return }
        if Date().timeIntervalSince(lastDockerAttempt) >= 10 { refreshDocker() }
        collecting = true
        queue.async { [weak self, collector] in
            let result = collector.collect()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.collecting = false
                guard !self.paused else { return }
                self.reading = result
                self.thermal = ProcessInfo.processInfo.thermalState
                if result.valid { self.history.append(Sample(time: result.time, cpu: result.cpu, memory: result.memory, gpu: result.gpu.available ? result.gpu.device : nil, temperature: result.temperature > 0 ? result.temperature : nil)) }
                self.evaluateAlerts(result)
                self.history.removeAll { $0.time < Date().addingTimeInterval(-900) }
            }
        }
    }
    func refreshDocker() {
        guard !paused, !dockerLoading else { return }
        dockerLoading = true; lastDockerAttempt = Date()
        dockerQueue.async {
            let snapshot = DockerCollector.collect()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dockerLoading = false
                if !self.paused { self.docker = snapshot }
            }
        }
    }
    // Sizes are measured on demand only: walking these trees is far too expensive for the 2-second loop.
    // Each result is published as it lands so a slow location cannot hold up the rest of the list.
    func scanCaches() {
        guard !cacheScanning, cacheCleaning.isEmpty else { return }
        cacheScanning = true
        caches = CacheSnapshot(measurements: CacheCollector.presence())
        let home = NSHomeDirectory()
        cacheQueue.async { [weak self] in
            for (index, location) in CacheCatalog.all.enumerated() {
                let measurement = CacheCollector.measure(location, home: home)
                Task { @MainActor [weak self] in
                    guard let self, self.cacheScanning, index < self.caches.measurements.count else { return }
                    self.caches.measurements[index] = measurement
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.caches.scanned = Date()
                self.cacheScanning = false
            }
        }
    }
    func cleanCache(_ item: CacheMeasurement) {
        guard item.location.kind == .cache, !cacheScanning, !cacheCleaning.contains(item.id) else { return }
        cacheCleaning.insert(item.id)
        cacheMessages[item.id] = nil
        let oldBytes = item.bytes
        let location = item.location
        let home = NSHomeDirectory()
        cacheQueue.async { [weak self] in
            let result = CacheCollector.cleanup(location, home: home)
            let measurement = result == .cleaned
                ? CacheCollector.measure(location, home: home)
                : item
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cacheCleaning.remove(item.id)
                switch result {
                case .cleaned:
                    if let index = self.caches.measurements.firstIndex(where: { $0.id == item.id }) {
                        self.caches.measurements[index] = measurement
                    }
                    let reclaimed = oldBytes.map { " (" + bytes(UInt64(max(0, $0))) + ")" } ?? ""
                    self.cacheLastAction = "Cleaned \(location.tool) \(location.name)\(reclaimed)."
                case .refused(let message), .failed(let message):
                    self.cacheMessages[item.id] = message
                    self.cacheLastAction = nil
                }
            }
        }
    }
    private func evaluateAlerts(_ result: Reading) {
        guard alertsEnabled, result.valid else { alertEngine.reset(); return }
        let rules = [
            AlertRule(id: "cpu", title: "Sustained CPU load", detail: "System CPU stayed at or above 85% for 60 seconds. Check the busiest apps.", active: result.cpu >= 85),
            AlertRule(id: "heat", title: "Sustained high temperature", detail: "CPU sensor average stayed at or above 90°C for 60 seconds. Consider pausing a heavy workload.", active: result.temperature >= 90),
            AlertRule(id: "memory", title: "Sustained memory pressure", detail: "macOS reported elevated or critical memory pressure for 60 seconds. Review the largest apps.", active: result.pressure == .warning || result.pressure == .critical)
        ]
        let events = alertEngine.evaluate(rules, at: result.time, duration: 60)
        alerts.insert(contentsOf: events, at: 0)
        alerts = Array(alerts.prefix(30))
        if notificationsEnabled {
            for event in events {
                let content = UNMutableNotificationContent()
                content.title = "Nori · " + event.title; content.body = event.detail
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)) { error in
                    if let error { Task { @MainActor [weak self] in self?.notificationStatus = "Notification failed: " + error.localizedDescription } }
                }
            }
        }
    }
    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor [weak self] in
                self?.notificationsEnabled = granted
                self?.notificationStatus = granted ? "Notification Center alerts enabled" : "Notifications are off. Allow Nori in System Settings → Notifications."
                if let error { self?.notificationStatus = error.localizedDescription }
            }
        }
    }
    func toggleKeepAwake() {
        let error = keepAwake ? keepAwakeSession.stop() : keepAwakeSession.start()
        keepAwake = keepAwakeSession.isActive
        keepAwakeError = error.map { String(format: "macOS could not change the sleep assertion (0x%08X).", UInt32(bitPattern: $0)) }
    }
    var thermalName: String {
        switch thermal { case .nominal: "Normal"; case .fair: "Warm"; case .serious: "Hot"; case .critical: "Critical"; @unknown default: "Unknown" }
    }
    var insight: String {
        if thermal == .serious || thermal == .critical { return "Your Mac is running hot. Pausing a heavy workload may help it cool down." }
        if reading.temperature >= 90 { return "CPU sensors are reading high. Check the busiest processes below; macOS thermal state is reported separately." }
        if reading.pressure == .critical || reading.pressure == .warning { return reading.pressure.explanation }
        if reading.cpu > 80 { return "Your processor is busy. The process list shows where that work is going." }
        return "There’s room to breathe. Your Mac’s CPU and thermal state look comfortable."
    }
}
func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }

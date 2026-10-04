import Foundation
import Darwin
import Network
import SystemConfiguration

enum NetworkConnectionStatus: String, Sendable {
    case connected = "Connected"
    case connecting = "Connecting"
    case offline = "Offline"
}

struct NetworkCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
}

struct NetworkRates: Equatable, Sendable {
    var download: Double = 0
    var upload: Double = 0
}

struct NetworkReading: Equatable, Sendable {
    var status: NetworkConnectionStatus = .connecting
    var interfaceName: String?
    var interfaceType = "Network"
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var isExpensive = false
    var isConstrained = false

    var connected: Bool { status == .connected }
    var active: Bool { connected && max(downloadBytesPerSecond, uploadBytesPerSecond) >= 512 }
    var activityName: String {
        guard active else { return connected ? "Quiet" : status.rawValue }
        if downloadBytesPerSecond > uploadBytesPerSecond * 1.5 { return "Downloading" }
        if uploadBytesPerSecond > downloadBytesPerSecond * 1.5 { return "Uploading" }
        return "Sending + receiving"
    }
}

struct NetworkRateCalculator {
    private var previousInterface: String?
    private var previousCounters: NetworkCounters?
    private var previousTime: TimeInterval?

    mutating func sample(interface: String?, counters: NetworkCounters?, at time: TimeInterval) -> NetworkRates {
        guard let interface, let counters else {
            previousInterface = nil
            previousCounters = nil
            previousTime = nil
            return NetworkRates()
        }
        defer {
            previousInterface = interface
            previousCounters = counters
            previousTime = time
        }
        guard interface == previousInterface,
              let old = previousCounters,
              let oldTime = previousTime,
              time > oldTime,
              counters.received >= old.received,
              counters.sent >= old.sent else { return NetworkRates() }
        let elapsed = time - oldTime
        return NetworkRates(
            download: Double(counters.received - old.received) / elapsed,
            upload: Double(counters.sent - old.sent) / elapsed
        )
    }
}

private struct NetworkPathSnapshot: Sendable {
    var status: NetworkConnectionStatus = .connecting
    var interfaceName: String?
    var interfaceType = "Network"
    var isExpensive = false
    var isConstrained = false
}

final class NetworkSampler: @unchecked Sendable {
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "Nori.network.path", qos: .utility)
    private let lock = NSLock()
    private var path = NetworkPathSnapshot()
    private var rateCalculator = NetworkRateCalculator()

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status: NetworkConnectionStatus
            switch path.status {
            case .satisfied: status = .connected
            case .requiresConnection: status = .connecting
            case .unsatisfied: status = .offline
            @unknown default: status = .offline
            }
            let type: String
            if path.usesInterfaceType(.wifi) { type = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { type = "Ethernet" }
            else if path.usesInterfaceType(.cellular) { type = "Cellular" }
            else if path.usesInterfaceType(.loopback) { type = "Loopback" }
            else { type = "Network" }
            let active = path.availableInterfaces.first { interface in
                path.usesInterfaceType(interface.type) && interface.type != .loopback
            }
            self.lock.lock()
            self.path = NetworkPathSnapshot(
                status: status,
                interfaceName: active?.name,
                interfaceType: type,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            self.lock.unlock()
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit { pathMonitor.cancel() }

    func collect() -> NetworkReading {
        lock.lock()
        let snapshot = path
        lock.unlock()
        guard snapshot.status == .connected else {
            _ = rateCalculator.sample(interface: nil, counters: nil, at: ProcessInfo.processInfo.systemUptime)
            return NetworkReading(
                status: snapshot.status,
                interfaceName: snapshot.interfaceName,
                interfaceType: snapshot.interfaceType,
                isExpensive: snapshot.isExpensive,
                isConstrained: snapshot.isConstrained
            )
        }
        let interface = Self.primaryInterface() ?? snapshot.interfaceName
        let counters = interface.flatMap(Self.counters(for:))
        let rates = rateCalculator.sample(
            interface: interface,
            counters: counters,
            at: ProcessInfo.processInfo.systemUptime
        )
        return NetworkReading(
            status: snapshot.status,
            interfaceName: interface,
            interfaceType: Self.interfaceType(for: interface, fallback: snapshot.interfaceType),
            downloadBytesPerSecond: rates.download,
            uploadBytesPerSecond: rates.upload,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained
        )
    }

    private static func primaryInterface() -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
                  let name = value["PrimaryInterface"] as? String,
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    private static func counters(for interface: String) -> NetworkCounters? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(address) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let value = item.pointee
            if String(cString: value.ifa_name) == interface,
               let rawData = value.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                return NetworkCounters(
                    received: UInt64(data.ifi_ibytes),
                    sent: UInt64(data.ifi_obytes)
                )
            }
            current = value.ifa_next
        }
        return nil
    }

    private static func interfaceType(for interface: String?, fallback: String) -> String {
        guard let interface else { return fallback }
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") { return "VPN" }
        if interface.hasPrefix("pdp_ip") { return "Cellular" }
        if interface.hasPrefix("bridge") { return "Bridge" }
        return fallback
    }
}

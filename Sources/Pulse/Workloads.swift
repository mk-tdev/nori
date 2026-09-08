import Foundation

struct ProcessReading: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let memory: UInt64
    var parent: Int32 = 0
    var path: String = ""
    var app: String = ""
}
struct AppWorkload: Identifiable {
    var id: String { name }
    let name: String
    let processes: [ProcessReading]
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
}
enum AppGrouping {
    static func explicitApp(_ p: ProcessReading) -> String? {
        // Some distributions embed Codex/Claude helpers inside a differently named host bundle.
        let name = p.name.lowercased()
        if name == "codex" || name.hasPrefix("codex (") || name.hasPrefix("codex helper") { return "Codex" }
        if name == "claude" || name.hasPrefix("claude helper") { return "Claude" }
        if name == "google chrome" || name.hasPrefix("google chrome helper") { return "Chrome" }
        if name == "docker" || name.hasPrefix("com.docker.") || name == "vpnkit" { return "Docker" }
        // The outer bundle owns its embedded helpers, even if they have their own .app.
        if let range = p.path.range(of: ".app/") {
            let bundle = URL(fileURLWithPath: String(p.path[..<range.lowerBound])).lastPathComponent
            return bundle == "Google Chrome" ? "Chrome" : bundle
        }
        return nil
    }
    static func assign(_ processes: [ProcessReading]) -> [ProcessReading] {
        let byPID = Dictionary(processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return processes.map { process in
            var p = process
            var cursor = process
            var seen = Set<Int32>()
            var owner: String?
            while seen.insert(cursor.id).inserted {
                if let name = explicitApp(cursor) { owner = name; break }
                guard let parent = byPID[cursor.parent], parent.id > 1 else { break }
                cursor = parent
            }
            p.app = owner ?? p.name
            return p
        }
    }
    static func groups(_ processes: [ProcessReading]) -> [AppWorkload] {
        Dictionary(grouping: processes, by: { $0.app.isEmpty ? $0.name : $0.app })
            .map { AppWorkload(name: $0.key, processes: $0.value) }.sorted { $0.cpu > $1.cpu }
    }
}

enum MemoryPressure: String {
    case unknown = "Unavailable", normal = "Normal", warning = "Elevated", critical = "Critical"
    init(raw: Int32) {
        switch raw { case 1: self = .normal; case 2: self = .warning; case 4: self = .critical; default: self = .unknown }
    }
    var explanation: String {
        switch self {
        case .normal: "macOS reports enough memory capacity for current workloads."
        case .warning: "macOS is under memory pressure. Closing a large workload may improve responsiveness."
        case .critical: "macOS reports critical memory pressure. Workloads may stall while memory is reclaimed."
        case .unknown: "macOS pressure could not be read. RAM usage alone does not indicate a slowdown."
        }
    }
}

struct SustainedAlert: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
}
struct AlertRule: Identifiable {
    let id: String
    let title: String
    let detail: String
    let active: Bool
}
struct SustainedAlertEngine {
    private var since: [String: Date] = [:]
    private var fired = Set<String>()
    private var lastSample: Date?
    mutating func reset() { since.removeAll(); fired.removeAll(); lastSample = nil }
    mutating func evaluate(_ rules: [AlertRule], at now: Date, duration: TimeInterval) -> [SustainedAlert] {
        // Pauses, sleep, and missed samples never count as sustained observations.
        if let lastSample, now.timeIntervalSince(lastSample) > 8 || now < lastSample { reset() }
        lastSample = now
        var events: [SustainedAlert] = []
        for rule in rules {
            if !rule.active { since[rule.id] = nil; fired.remove(rule.id); continue }
            if since[rule.id] == nil { since[rule.id] = now }
            if now.timeIntervalSince(since[rule.id]!) >= duration, !fired.contains(rule.id) {
                fired.insert(rule.id)
                events.append(SustainedAlert(date: now, title: rule.title, detail: rule.detail))
            }
        }
        return events
    }
}

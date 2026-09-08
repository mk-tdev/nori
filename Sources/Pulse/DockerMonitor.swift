import Foundation

struct ContainerReading: Identifiable, Decodable {
    let id: String
    let name: String
    let cpuText: String
    let memoryText: String
    let memoryPercent: String
    let network: String
    let disk: String
    let pids: String
    var cpu: Double { Double(cpuText.replacingOccurrences(of: "%", with: "")) ?? 0 }
    var memory: Double { Double(memoryPercent.replacingOccurrences(of: "%", with: "")) ?? 0 }
    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", cpuText = "CPUPerc", memoryText = "MemUsage"
        case memoryPercent = "MemPerc", network = "NetIO", disk = "BlockIO", pids = "PIDs"
    }
}
struct DockerSnapshot {
    var containers: [ContainerReading] = []
    var status = "Connecting to local Docker…"
    var date: Date?
    var available = false
}
enum DockerCollector {
    static func parse(_ data: Data) throws -> [ContainerReading] {
        try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(ContainerReading.self, from: Data($0.utf8)) }
            .sorted { $0.cpu > $1.cpu }
    }
    static func collect() -> DockerSnapshot {
        let manager = FileManager.default
        let executables = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        guard let executable = executables.first(where: { manager.isExecutableFile(atPath: $0) }) else {
            return DockerSnapshot(status: "Docker CLI not found. Install Docker Desktop to view containers.")
        }
        let sockets = [NSHomeDirectory() + "/.docker/run/docker.sock", "/var/run/docker.sock"]
        guard let socket = sockets.first(where: { manager.fileExists(atPath: $0) }) else {
            return DockerSnapshot(status: "Local Docker socket not found. Start Docker Desktop, then refresh.")
        }
        var env = ProcessInfo.processInfo.environment
        // Explicit local socket avoids accidentally monitoring a remote Docker context.
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] { env.removeValue(forKey: key) }
        let arguments = ["--host", "unix://" + socket, "stats", "--no-stream", "--format", "{{json .}}"]
        switch Shell.run(executable, arguments, timeout: 8, environment: env) {
        case .launchFailed(let message):
            return DockerSnapshot(status: "Docker could not be started: \(message)")
        case .timedOut:
            return DockerSnapshot(status: "Docker did not respond within 8 seconds. Check Docker Desktop and refresh.")
        case .failed:
            return DockerSnapshot(status: "Local Docker is unavailable or access was denied. Start Docker Desktop and refresh.")
        case .output(let data):
            do {
                let rows = try parse(data)
                return DockerSnapshot(containers: rows, status: rows.isEmpty ? "No running containers" : "\(rows.count) running containers", date: Date(), available: true)
            } catch {
                return DockerSnapshot(status: "Docker returned an unreadable metrics response. Refresh to try again.")
            }
        }
    }
}

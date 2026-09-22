import Foundation
import Metal

struct GPUAppReading: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let usage: Double
    let processCount: Int
}

struct GPUReading {
    private static let hardwareName = MTLCreateSystemDefaultDevice()?.name ?? "Mac GPU"
    var device: Double = -1
    var renderer: Double = -1
    var tiler: Double = -1
    var allocatedMemory: UInt64 = 0
    var inUseMemory: UInt64 = 0
    var coreCount: Int = 0
    var apps: [GPUAppReading] = []
    var available: Bool { device >= 0 }
    var name: String { Self.hardwareName }
}

enum GPUAttribution {
    struct ProcessUsage {
        let pid: Int32
        let name: String
        let usage: Double
    }

    static func groups(_ usages: [ProcessUsage], owners: [Int32: String]) -> [GPUAppReading] {
        let named = usages.map { usage in
            (owners[usage.pid] ?? usage.name, usage)
        }
        return Dictionary(grouping: named, by: \.0).map { name, values in
            GPUAppReading(
                name: name,
                usage: values.reduce(0) { $0 + $1.1.usage },
                processCount: Set(values.map { $0.1.pid }).count
            )
        }.sorted { $0.usage > $1.usage }
    }
}

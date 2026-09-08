import Foundation

// Developer tools spread reclaimable downloads and irreplaceable history across the same directories.
// Kind records which is which so session transcripts are never presented as reclaimable cache.
enum CacheKind: String, CaseIterable {
    case cache = "Cache", data = "Data"
    var explanation: String {
        switch self {
        case .cache: "Rebuilt automatically by the tool after removal."
        case .data: "History or installed content. Removing it loses something."
        }
    }
}
struct CacheLocation: Identifiable {
    let id: String
    let tool: String
    let name: String
    let relativePath: String
    let kind: CacheKind
    let hint: String
    func path(home: String) -> String { home + "/" + relativePath }
}
struct CacheMeasurement: Identifiable {
    enum State: Equatable {
        case pending, absent, unreadable, timedOut
        case measured(bytes: Int64, partial: Bool)
    }
    var id: String { location.id }
    let location: CacheLocation
    var state: State = .pending
    // Only a completed measurement contributes to a total; pending and failed rows stay out of the sums.
    var bytes: Int64? {
        if case .measured(let value, _) = state { return value }
        return nil
    }
    var present: Bool { state != .absent }
}
struct CacheSnapshot {
    var measurements: [CacheMeasurement] = []
    var scanned: Date?
    var present: [CacheMeasurement] { measurements.filter(\.present) }
    var unmeasured: Int { present.filter { $0.bytes == nil }.count }
    var partial: Bool { measurements.contains { if case .measured(_, let partial) = $0.state { return partial }; return false } }
    func bytes(_ kind: CacheKind) -> Int64 { measurements.filter { $0.location.kind == kind }.compactMap(\.bytes).reduce(0, +) }
}
enum CacheCleanupResult: Equatable {
    case cleaned
    case refused(String)
    case failed(String)
}
// Paths are deliberately non-overlapping so the totals never count the same bytes twice.
// This is a catalog of known locations, not an exhaustive scan of the home directory.
enum CacheCatalog {
    static let all: [CacheLocation] = [
        .init(id: "npm", tool: "npm", name: "Package cache", relativePath: ".npm/_cacache", kind: .cache, hint: "npm cache clean --force"),
        .init(id: "npx", tool: "npm", name: "npx installs", relativePath: ".npm/_npx", kind: .cache, hint: "Re-downloaded on demand"),
        .init(id: "yarn-classic", tool: "Yarn", name: "Package cache (v1)", relativePath: "Library/Caches/Yarn", kind: .cache, hint: "yarn cache clean"),
        .init(id: "yarn-berry", tool: "Yarn", name: "Package cache (Berry)", relativePath: ".yarn/berry/cache", kind: .cache, hint: "yarn cache clean"),
        .init(id: "pnpm-store", tool: "pnpm", name: "Content-addressable store", relativePath: "Library/pnpm/store", kind: .cache, hint: "pnpm store prune"),
        .init(id: "pnpm-cache", tool: "pnpm", name: "Metadata cache", relativePath: "Library/Caches/pnpm", kind: .cache, hint: "pnpm store prune"),
        .init(id: "bun", tool: "Bun", name: "Install cache", relativePath: ".bun/install/cache", kind: .cache, hint: "bun pm cache rm"),
        .init(id: "deno", tool: "Deno", name: "Module cache", relativePath: "Library/Caches/deno", kind: .cache, hint: "deno clean"),
        .init(id: "node-gyp", tool: "node-gyp", name: "Node headers", relativePath: "Library/Caches/node-gyp", kind: .cache, hint: "Re-downloaded per build"),
        .init(id: "typescript", tool: "TypeScript", name: "Type definitions", relativePath: "Library/Caches/typescript", kind: .cache, hint: "Re-downloaded on demand"),
        .init(id: "electron", tool: "Electron", name: "Binary downloads", relativePath: "Library/Caches/electron", kind: .cache, hint: "Re-downloaded on install"),
        .init(id: "playwright", tool: "Playwright", name: "Browser builds", relativePath: "Library/Caches/ms-playwright", kind: .cache, hint: "playwright uninstall --all"),
        .init(id: "puppeteer", tool: "Puppeteer", name: "Browser builds", relativePath: ".cache/puppeteer", kind: .cache, hint: "Re-downloaded on install"),
        .init(id: "uv", tool: "uv", name: "Wheel and source cache", relativePath: ".cache/uv", kind: .cache, hint: "uv cache clean"),
        .init(id: "pip", tool: "pip", name: "Wheel cache", relativePath: "Library/Caches/pip", kind: .cache, hint: "pip cache purge"),
        .init(id: "homebrew", tool: "Homebrew", name: "Downloads", relativePath: "Library/Caches/Homebrew", kind: .cache, hint: "brew cleanup --prune=all"),
        .init(id: "go-build", tool: "Go", name: "Build cache", relativePath: "Library/Caches/go-build", kind: .cache, hint: "go clean -cache"),
        .init(id: "go-mod", tool: "Go", name: "Module cache", relativePath: "go/pkg/mod", kind: .cache, hint: "go clean -modcache"),
        .init(id: "cargo", tool: "Cargo", name: "Registry", relativePath: ".cargo/registry", kind: .cache, hint: "Re-downloaded on build"),
        .init(id: "gradle", tool: "Gradle", name: "Dependency caches", relativePath: ".gradle/caches", kind: .cache, hint: "Re-downloaded on build"),
        .init(id: "maven", tool: "Maven", name: "Local repository", relativePath: ".m2/repository", kind: .cache, hint: "Re-downloaded on build"),
        .init(id: "derived-data", tool: "Xcode", name: "DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", kind: .cache, hint: "Rebuilt by Xcode"),
        .init(id: "swiftpm", tool: "SwiftPM", name: "Dependency cache", relativePath: "Library/Caches/org.swift.swiftpm", kind: .cache, hint: "swift package purge-cache"),
        .init(id: "codex-cache", tool: "Codex", name: "Cache", relativePath: ".codex/cache", kind: .cache, hint: "Rebuilt on demand"),
        .init(id: "claude-cache", tool: "Claude", name: "Cache", relativePath: ".claude/cache", kind: .cache, hint: "Rebuilt on demand"),
        .init(id: "claude-shell", tool: "Claude", name: "Shell snapshots", relativePath: ".claude/shell-snapshots", kind: .cache, hint: "Recreated per session"),
        .init(id: "claude-cli", tool: "Claude", name: "CLI cache", relativePath: "Library/Caches/claude-cli-nodejs", kind: .cache, hint: "Rebuilt on demand"),
        .init(id: "codex-sessions", tool: "Codex", name: "Session transcripts", relativePath: ".codex/sessions", kind: .data, hint: "Conversation history, not cache"),
        .init(id: "codex-archived", tool: "Codex", name: "Archived sessions", relativePath: ".codex/archived_sessions", kind: .data, hint: "Conversation history, not cache"),
        .init(id: "codex-images", tool: "Codex", name: "Generated images", relativePath: ".codex/generated_images", kind: .data, hint: "Generated output, not cache"),
        .init(id: "codex-plugins", tool: "Codex", name: "Installed plugins", relativePath: ".codex/plugins", kind: .data, hint: "Installed content; would need reinstalling"),
        .init(id: "claude-projects", tool: "Claude", name: "Session history", relativePath: ".claude/projects", kind: .data, hint: "Conversation history, not cache"),
        .init(id: "claude-plugins", tool: "Claude", name: "Installed plugins", relativePath: ".claude/plugins", kind: .data, hint: "Installed content; would need reinstalling"),
        .init(id: "docker-vm", tool: "Docker", name: "Linux VM disk image", relativePath: "Library/Containers/com.docker.docker/Data/vms", kind: .data, hint: "Holds images and volumes; reclaim with docker system prune"),
    ]
}
enum CacheCollector {
    static let timeout: TimeInterval = 30
    // du reports allocated blocks in kibibytes; a warning line on stderr is discarded, so the last line carries the total.
    static func parseKilobytes(_ data: Data) -> Int64? {
        guard let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let field = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let value = Int64(field) else { return nil }
        return value
    }
    static func presence(_ locations: [CacheLocation] = CacheCatalog.all, home: String = NSHomeDirectory()) -> [CacheMeasurement] {
        locations.map { CacheMeasurement(location: $0, state: FileManager.default.fileExists(atPath: $0.path(home: home)) ? .pending : .absent) }
    }
    static func measure(_ location: CacheLocation, home: String = NSHomeDirectory()) -> CacheMeasurement {
        let path = location.path(home: home)
        guard FileManager.default.fileExists(atPath: path) else { return CacheMeasurement(location: location, state: .absent) }
        switch Shell.run("/usr/bin/du", ["-s", "-k", "-x", path], timeout: timeout) {
        case .timedOut: return CacheMeasurement(location: location, state: .timedOut)
        case .launchFailed: return CacheMeasurement(location: location, state: .unreadable)
        case .output(let data):
            guard let kilobytes = parseKilobytes(data) else { return CacheMeasurement(location: location, state: .unreadable) }
            return CacheMeasurement(location: location, state: .measured(bytes: kilobytes * 1024, partial: false))
        // du exits non-zero when a subdirectory is unreadable but still totals what it could reach.
        case .failed(let data, _):
            guard let kilobytes = parseKilobytes(data) else { return CacheMeasurement(location: location, state: .unreadable) }
            return CacheMeasurement(location: location, state: .measured(bytes: kilobytes * 1024, partial: true))
        }
    }
    static func scan(home: String = NSHomeDirectory()) -> CacheSnapshot {
        CacheSnapshot(measurements: CacheCatalog.all.map { measure($0, home: home) }, scanned: Date())
    }
    // Cleanup is deliberately path-based instead of invoking a package manager. That keeps a
    // row action scoped to exactly the directory the user selected.
    static func cleanup(_ location: CacheLocation, home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> CacheCleanupResult {
        guard location.kind == .cache else {
            return .refused("Tool data is protected from one-click cleanup.")
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        let targetURL = homeURL.appendingPathComponent(location.relativePath, isDirectory: true).standardizedFileURL
        let homePrefix = homeURL.path.hasSuffix("/") ? homeURL.path : homeURL.path + "/"
        guard targetURL.path.hasPrefix(homePrefix), targetURL.path != homeURL.path else {
            return .refused("The cache path is outside your home directory.")
        }
        guard fileManager.fileExists(atPath: targetURL.path) else { return .cleaned }
        do {
            try fileManager.removeItem(at: targetURL)
            return .cleaned
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

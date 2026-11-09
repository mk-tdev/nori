import XCTest
@testable import Pulse

final class NoriTests: XCTestCase {
    func testAccountStoreRoundTripsWithoutCredentialMaterial() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("accounts.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = VercelSession(id: UUID(), name: "Work", directory: "/private/work-vercel", username: "builder", isDefault: false)
        let profile = DeveloperProfile(id: UUID(), name: "Work", githubLogin: "work-user", vercelSessionID: session.id, vercelTeam: "studio", gitName: "Builder", gitEmail: "builder@example.com", projectPath: "/tmp/project")
        let expected = AccountStoreData(profiles: [profile], vercelSessions: [session], activeProfileID: profile.id)
        try AccountStore.save(expected, to: file)
        XCTAssertEqual(AccountStore.load(from: file), expected)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)
    }

    func testGitHubOwnerParsingSupportsHTTPAndSSHRemotes() {
        XCTAssertEqual(ProfileInspector.githubOwner(from: "https://github.com/mk-tdev/nori.git"), "mk-tdev")
        XCTAssertEqual(ProfileInspector.githubOwner(from: "git@github.com:pixeltrendanalytics-devs/app.git"), "pixeltrendanalytics-devs")
        XCTAssertNil(ProfileInspector.githubOwner(from: "https://gitlab.com/team/app.git"))
    }

    func testProfileSwitchAppliesVercelSelectionAndRepositoryIdentity() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("commands.log")
        let gh = try fakeExecutable(at: root.appendingPathComponent("gh"), body: "echo \"$@\" >> \"\(log.path)\"\nexit 0")
        let vercel = try fakeExecutable(at: root.appendingPathComponent("vercel"), body: "echo \"$@\" >> \"\(log.path)\"\nexit 0")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(runGit(["init", project.path]), 0)
        let session = VercelSession(id: UUID(), name: "Work", directory: root.appendingPathComponent("vercel-work").path, username: "work", isDefault: false)
        let profile = DeveloperProfile(id: UUID(), name: "Work", githubLogin: "work-user", vercelSessionID: session.id, vercelTeam: "work-team", gitName: "Work Author", gitEmail: "work@example.com", projectPath: project.path)
        let activeFile = root.appendingPathComponent("active-vercel")
        let result = ProfileSwitcher.apply(profile, sessions: [session], previousGitHubLogin: "personal-user", githubExecutable: gh.path, vercelExecutable: vercel.path, activeVercelFile: activeFile)
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(try String(contentsOf: activeFile, encoding: .utf8), session.directory)
        XCTAssertEqual(gitOutput(project, ["config", "--local", "--get", "user.name"]), "Work Author")
        XCTAssertEqual(gitOutput(project, ["config", "--local", "--get", "user.email"]), "work@example.com")
        let commands = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(commands.contains("auth switch --hostname github.com --user work-user"))
        XCTAssertTrue(commands.contains("teams switch work-team"))
    }

    func testProfileSwitchRollsBackGitHubAndVercelWhenTeamSwitchFails() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("commands.log")
        let gh = try fakeExecutable(at: root.appendingPathComponent("gh"), body: "echo \"$@\" >> \"\(log.path)\"\nexit 0")
        let vercel = try fakeExecutable(at: root.appendingPathComponent("vercel"), body: "exit 1")
        let session = VercelSession(id: UUID(), name: "Work", directory: "/tmp/work", username: nil, isDefault: false)
        let profile = DeveloperProfile(id: UUID(), name: "Work", githubLogin: "work-user", vercelSessionID: session.id, vercelTeam: "missing-team", gitName: "", gitEmail: "", projectPath: "")
        let activeFile = root.appendingPathComponent("active-vercel")
        try Data("/tmp/personal".utf8).write(to: activeFile)
        let result = ProfileSwitcher.apply(profile, sessions: [session], previousGitHubLogin: "personal-user", githubExecutable: gh.path, vercelExecutable: vercel.path, activeVercelFile: activeFile)
        XCTAssertFalse(result.success)
        XCTAssertEqual(try String(contentsOf: activeFile, encoding: .utf8), "/tmp/personal")
        let commands = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(commands.contains("--user work-user"))
        XCTAssertTrue(commands.contains("--user personal-user"))
    }

    func testNetworkRateCalculatorUsesElapsedTimeAndResetsSafely() {
        var calculator = NetworkRateCalculator()
        XCTAssertEqual(
            calculator.sample(interface: "en0", counters: NetworkCounters(received: 1_000, sent: 2_000), at: 10),
            NetworkRates()
        )
        XCTAssertEqual(
            calculator.sample(interface: "en0", counters: NetworkCounters(received: 5_000, sent: 4_000), at: 12),
            NetworkRates(download: 2_000, upload: 1_000)
        )
        XCTAssertEqual(
            calculator.sample(interface: "en1", counters: NetworkCounters(received: 9_000, sent: 9_000), at: 14),
            NetworkRates()
        )
        XCTAssertEqual(
            calculator.sample(interface: "en1", counters: NetworkCounters(received: 100, sent: 100), at: 16),
            NetworkRates()
        )
        XCTAssertEqual(calculator.sample(interface: nil, counters: nil, at: 18), NetworkRates())
    }

    func testNetworkActivityLabelsDominantTrafficDirection() {
        var reading = NetworkReading(status: .connected, downloadBytesPerSecond: 4_000, uploadBytesPerSecond: 1_000)
        XCTAssertTrue(reading.active)
        XCTAssertEqual(reading.activityName, "Downloading")
        reading.downloadBytesPerSecond = 1_000
        reading.uploadBytesPerSecond = 4_000
        XCTAssertEqual(reading.activityName, "Uploading")
        reading.downloadBytesPerSecond = 3_000
        XCTAssertEqual(reading.activityName, "Sending + receiving")
        reading.downloadBytesPerSecond = 0
        reading.uploadBytesPerSecond = 0
        XCTAssertEqual(reading.activityName, "Quiet")
    }

    func testGPUAttributionCombinesProcessesByOwningApp() {
        let usage = [
            GPUAttribution.ProcessUsage(pid: 10, name: "Codex Helper", usage: 12.5),
            GPUAttribution.ProcessUsage(pid: 11, name: "node", usage: 7.5),
            GPUAttribution.ProcessUsage(pid: 20, name: "WindowServer", usage: 4)
        ]
        let groups = GPUAttribution.groups(usage, owners: [10: "Codex", 11: "Codex"])
        XCTAssertEqual(groups.first, GPUAppReading(name: "Codex", usage: 20, processCount: 2))
        XCTAssertEqual(groups.last, GPUAppReading(name: "WindowServer", usage: 4, processCount: 1))
    }

    func testKeepAwakeSessionStartsOnceAndReleasesItsAssertion() {
        var acquisitions = 0
        var released: [UInt32] = []
        let session = KeepAwakeSession(
            acquire: { acquisitions += 1; return (42, 0) },
            release: { released.append($0); return 0 }
        )
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.start())
        XCTAssertNil(session.start())
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(acquisitions, 1)
        XCTAssertNil(session.stop())
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(released, [42])
    }

    func testKeepAwakeSessionReportsAcquireAndReleaseFailures() {
        let acquireFailure = KeepAwakeSession(acquire: { (nil, -1) }, release: { _ in 0 })
        XCTAssertEqual(acquireFailure.start(), -1)
        XCTAssertFalse(acquireFailure.isActive)

        let releaseFailure = KeepAwakeSession(acquire: { (7, 0) }, release: { _ in -2 })
        XCTAssertNil(releaseFailure.start())
        XCTAssertEqual(releaseFailure.stop(), -2)
        XCTAssertTrue(releaseFailure.isActive)
    }

    func testLiveKeepAwakeAssertionCanBeStartedAndStopped() throws {
        let session = KeepAwakeSession()
        XCTAssertNil(session.start())
        XCTAssertTrue(session.isActive)
        XCTAssertNil(session.stop())
        XCTAssertFalse(session.isActive)
    }

    func testGroupsHelpersAndChildrenWithoutDoubleCounting() {
        let inputs = [
            ProcessReading(id: 1, name: "Codex", cpu: 20, memory: 100, path: "/Applications/Codex.app/Contents/MacOS/Codex"),
            ProcessReading(id: 2, name: "Codex Helper", cpu: 30, memory: 200, path: "/Applications/Codex.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            ProcessReading(id: 3, name: "node", cpu: 40, memory: 300, parent: 2),
            ProcessReading(id: 4, name: "node", cpu: 10, memory: 50),
            ProcessReading(id: 5, name: "com.docker.backend", cpu: 5, memory: 60)
        ]
        let groups = AppGrouping.groups(AppGrouping.assign(inputs))
        let codex = groups.first { $0.name == "Codex" }!
        XCTAssertEqual(codex.cpu, 90); XCTAssertEqual(codex.memory, 600)
        XCTAssertEqual(codex.processes.count, 3)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.processes.count }, inputs.count)
        XCTAssertTrue(groups.contains { $0.name == "node" })
        XCTAssertTrue(groups.contains { $0.name == "Docker" })
    }
    func testParentCycleTerminates() {
        let items = [ProcessReading(id: 10, name: "a", cpu: 0, memory: 0, parent: 11), ProcessReading(id: 11, name: "b", cpu: 0, memory: 0, parent: 10)]
        XCTAssertEqual(AppGrouping.assign(items).count, 2)
    }
    func testNamedHelpersInsideDifferentHostBundle() {
        let p = ProcessReading(id: 100, name: "Codex (Renderer)", cpu: 3, memory: 10, path: "/Applications/ChatGPT.app/Contents/Helpers/renderer")
        XCTAssertEqual(AppGrouping.assign([p]).first?.app, "Codex")
    }
    func testAlertRequiresContinuousTimeAndRearmsAfterRecovery() {
        var engine = SustainedAlertEngine()
        let start = Date(timeIntervalSince1970: 0)
        func rule(_ active: Bool) -> [AlertRule] { [AlertRule(id: "cpu", title: "CPU", detail: "High", active: active)] }
        for second in stride(from: 0, through: 58, by: 2) {
            XCTAssertTrue(engine.evaluate(rule(true), at: start.addingTimeInterval(Double(second)), duration: 60).isEmpty)
        }
        XCTAssertEqual(engine.evaluate(rule(true), at: start.addingTimeInterval(60), duration: 60).count, 1)
        XCTAssertTrue(engine.evaluate(rule(true), at: start.addingTimeInterval(62), duration: 60).isEmpty)
        _ = engine.evaluate(rule(false), at: start.addingTimeInterval(64), duration: 60)
        XCTAssertTrue(engine.evaluate(rule(true), at: start.addingTimeInterval(66), duration: 60).isEmpty)
        for second in stride(from: 68, through: 124, by: 2) { _ = engine.evaluate(rule(true), at: start.addingTimeInterval(Double(second)), duration: 60) }
        XCTAssertEqual(engine.evaluate(rule(true), at: start.addingTimeInterval(126), duration: 60).count, 1)
    }
    func testSamplingGapDoesNotTriggerAlert() {
        var engine = SustainedAlertEngine()
        let rule = [AlertRule(id: "heat", title: "Heat", detail: "High", active: true)]
        _ = engine.evaluate(rule, at: Date(timeIntervalSince1970: 0), duration: 60)
        XCTAssertTrue(engine.evaluate(rule, at: Date(timeIntervalSince1970: 70), duration: 60).isEmpty)
    }
    func testCatalogIdentifiersAndPathsDoNotOverlap() {
        let ids = CacheCatalog.all.map(\.id), paths = CacheCatalog.all.map(\.relativePath)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(paths).count, paths.count)
        // Totals sum independent measurements, so no catalog path may sit inside another.
        for outer in paths { for inner in paths where inner != outer { XCTAssertFalse(inner.hasPrefix(outer + "/"), "\(inner) is nested inside \(outer)") } }
        XCTAssertTrue(CacheCatalog.all.contains { $0.id == "codex-sessions" && $0.kind == .data })
        XCTAssertTrue(CacheCatalog.all.contains { $0.id == "npm" && $0.kind == .cache })
    }
    func testDuOutputParsing() {
        XCTAssertEqual(CacheCollector.parseKilobytes(Data("12501816\t/Users/x/.npm/_cacache\n".utf8)), 12501816)
        XCTAssertEqual(CacheCollector.parseKilobytes(Data("0\t/Users/x/empty".utf8)), 0)
        XCTAssertNil(CacheCollector.parseKilobytes(Data()))
        XCTAssertNil(CacheCollector.parseKilobytes(Data("du: /x: No such file or directory\n".utf8)))
    }
    func testMeasuresRealDirectoryAndReportsAbsentPaths() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(count: 1_048_576).write(to: home.appendingPathComponent("cache/blob"))
        let present = CacheLocation(id: "t", tool: "T", name: "C", relativePath: "cache", kind: .cache, hint: "")
        let missing = CacheLocation(id: "m", tool: "M", name: "C", relativePath: "gone", kind: .cache, hint: "")
        let measured = CacheCollector.measure(present, home: home.path)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(measured.bytes), 1_048_576)
        XCTAssertTrue(measured.present)
        XCTAssertEqual(CacheCollector.measure(missing, home: home.path).state, .absent)
        XCTAssertFalse(CacheCollector.measure(missing, home: home.path).present)
        XCTAssertEqual(CacheCollector.presence([present, missing], home: home.path).map(\.state), [.pending, .absent])
    }
    func testSnapshotTotalsSeparateKindsAndIgnoreUnmeasured() {
        func location(_ id: String, _ kind: CacheKind) -> CacheLocation { CacheLocation(id: id, tool: id, name: id, relativePath: id, kind: kind, hint: "") }
        let snapshot = CacheSnapshot(measurements: [
            CacheMeasurement(location: location("a", .cache), state: .measured(bytes: 1000, partial: false)),
            CacheMeasurement(location: location("b", .cache), state: .measured(bytes: 500, partial: true)),
            CacheMeasurement(location: location("c", .cache), state: .pending),
            CacheMeasurement(location: location("d", .cache), state: .timedOut),
            CacheMeasurement(location: location("e", .data), state: .measured(bytes: 90, partial: false)),
            CacheMeasurement(location: location("f", .data), state: .absent)
        ])
        XCTAssertEqual(snapshot.bytes(.cache), 1500)
        XCTAssertEqual(snapshot.bytes(.data), 90)
        XCTAssertEqual(snapshot.present.count, 5)
        XCTAssertEqual(snapshot.unmeasured, 2)
        XCTAssertTrue(snapshot.partial)
    }
    func testCleanupDeletesOnlySelectedCacheAndRefusesToolData() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cache = home.appendingPathComponent("cache")
        let other = home.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache.appendingPathComponent("item"))
        try Data("keep".utf8).write(to: other.appendingPathComponent("item"))
        defer { try? FileManager.default.removeItem(at: home) }
        let location = CacheLocation(id: "cache", tool: "Test", name: "Cache", relativePath: "cache", kind: .cache, hint: "")
        XCTAssertEqual(CacheCollector.cleanup(location, home: home.path), .cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let data = CacheLocation(id: "data", tool: "Test", name: "Data", relativePath: "other", kind: .data, hint: "")
        guard case .refused = CacheCollector.cleanup(data, home: home.path) else { return XCTFail("Tool data cleanup was not refused") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let traversal = CacheLocation(id: "escape", tool: "Test", name: "Escape", relativePath: "../outside", kind: .cache, hint: "")
        guard case .refused = CacheCollector.cleanup(traversal, home: home.path) else { return XCTFail("Path traversal was not refused") }
    }
    func testDockerJSONAndEmptyStates() throws {
        let json = #"{"ID":"abc","Name":"database","CPUPerc":"132.4%","MemUsage":"2GiB / 4GiB","MemPerc":"50.00%","NetIO":"1MB / 2MB","BlockIO":"0B / 1MB","PIDs":"12"}"#
        let rows = try DockerCollector.parse(Data(json.utf8))
        XCTAssertEqual(rows.first?.cpu, 132.4)
        XCTAssertEqual(rows.first?.memory, 50)
        XCTAssertTrue(try DockerCollector.parse(Data()).isEmpty)
        XCTAssertThrowsError(try DockerCollector.parse(Data("invalid".utf8)))
    }
    func testPressureAndTemperatureBoundaries() {
        XCTAssertEqual(MemoryPressure(raw: 1), .normal)
        XCTAssertEqual(MemoryPressure(raw: 2), .warning)
        XCTAssertEqual(MemoryPressure(raw: 4), .critical)
        XCTAssertEqual(MemoryPressure(raw: 0), .unknown)
        XCTAssertEqual(TemperatureBand(reading: 59.9), .cool)
        XCTAssertEqual(TemperatureBand(reading: 60), .moderate)
        XCTAssertEqual(TemperatureBand(reading: 75), .warm)
        XCTAssertEqual(TemperatureBand(reading: 90), .hot)
        XCTAssertEqual(TemperatureBand(reading: .nan), .unavailable)
    }

    private func fakeExecutable(at url: URL, body: String) throws -> URL {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func runGit(_ arguments: [String]) -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }

    private func gitOutput(_ project: URL, _ arguments: [String]) -> String {
        let pipe = Pipe(); let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", project.path] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

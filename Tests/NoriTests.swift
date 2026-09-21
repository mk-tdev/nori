import XCTest
@testable import Pulse

final class NoriTests: XCTestCase {
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
}

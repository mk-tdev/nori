import Foundation
import PulseSystem

final class KeepAwakeSession {
    typealias Acquire = () -> (id: UInt32?, error: Int32)
    typealias Release = (UInt32) -> Int32

    private let acquire: Acquire
    private let release: Release
    private(set) var assertionID: UInt32?

    var isActive: Bool { assertionID != nil }

    init(
        acquire: @escaping Acquire = {
            var identifier: UInt32 = 0
            let result = pulse_prevent_display_sleep(&identifier)
            return (result == 0 ? identifier : nil, result)
        },
        release: @escaping Release = { pulse_allow_display_sleep($0) }
    ) {
        self.acquire = acquire
        self.release = release
    }

    @discardableResult
    func start() -> Int32? {
        guard assertionID == nil else { return nil }
        let result = acquire()
        guard result.error == 0, let identifier = result.id else { return result.error }
        assertionID = identifier
        return nil
    }

    @discardableResult
    func stop() -> Int32? {
        guard let identifier = assertionID else { return nil }
        let result = release(identifier)
        guard result == 0 else { return result }
        assertionID = nil
        return nil
    }

    deinit {
        if let identifier = assertionID { _ = release(identifier) }
    }
}

import Foundation
import Darwin

enum ShellResult {
    case output(Data)
    case failed(Data, Int32)
    case timedOut
    case launchFailed(String)
}
enum Shell {
    // Standard output is drained concurrently so a large response cannot fill the pipe and deadlock the child.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, environment: [String: String]? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .launchFailed(error.localizedDescription) }
        final class Buffer: @unchecked Sendable { var data = Data() }
        let buffer = Buffer()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            buffer.data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = drained.wait(timeout: .now() + 2)
            return .timedOut
        }
        guard drained.wait(timeout: .now() + 2) == .success else { return .failed(Data(), process.terminationStatus) }
        return process.terminationStatus == 0 ? .output(buffer.data) : .failed(buffer.data, process.terminationStatus)
    }
}

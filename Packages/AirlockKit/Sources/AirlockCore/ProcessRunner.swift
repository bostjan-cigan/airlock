import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var output: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct ProcessError: Error, CustomStringConvertible {
    public var command: [String]
    public var result: ProcessResult
    public var description: String {
        let msg = result.errorOutput.isEmpty ? result.output : result.errorOutput
        return "\(command.joined(separator: " ")) exited \(result.status): \(msg)"
    }
}

/// Runs host executables (git, tar) off the main thread.
public enum ProcessRunner {
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        check: Bool = true
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        // Drain pipes concurrently so large outputs never block the child.
        async let outData = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Nothing will write to the pipes: close them so the readers above finish
                // instead of waiting forever.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                cont.resume(throwing: error)
                return
            }
            if let inPipe, let stdin {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let result = ProcessResult(status: status, stdout: await outData, stderr: await errData)
        if check, status != 0 { throw ProcessError(command: [executable] + arguments, result: result) }
        return result
    }
}

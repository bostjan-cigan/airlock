import AirlockRuntime
import Foundation

/// An interactive TTY exec. Owns one hijacked connection for its lifetime.
final class DockerTerminalSession: TerminalSession {
    let output: AsyncStream<Data>
    private let input: AsyncStream<Data>.Continuation
    private let client: DockerClient
    private let execID: String
    private let task: Task<Void, Never>

    init(client: DockerClient, execID: String, size: TerminalSize) {
        self.client = client
        self.execID = execID
        let (output, outputCont) = AsyncStream<Data>.makeStream()
        let (input, inputCont) = AsyncStream<Data>.makeStream()
        self.output = output
        self.input = inputCont

        task = Task {
            do {
                let start = ExecStartRequest(Tty: true, ConsoleSize: [size.rows, size.cols])
                try await client.hijack("/exec/\(execID)/start", json: start) { reader, writer in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await data in input { try await writer.write(data) }
                        }
                        try await reader.streamToEOF { bytes in outputCont.yield(Data(bytes)) }
                        group.cancelAll()
                    }
                }
            } catch is CancellationError {
            } catch {
                outputCont.yield(Data("\r\n[airlock] terminal error: \(error)\r\n".utf8))
            }
            outputCont.finish()
        }
    }

    deinit {
        task.cancel()
        input.finish()
    }

    func write(_ data: Data) async throws {
        input.yield(data)
    }

    func resize(_ size: TerminalSize) async throws {
        try await client.request("POST", "/exec/\(execID)/resize", query: ["h": "\(size.rows)", "w": "\(size.cols)"])
    }

    func close() async {
        input.finish()
        task.cancel()
    }
}

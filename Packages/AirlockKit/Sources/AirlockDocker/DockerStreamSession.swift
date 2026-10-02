import AirlockRuntime
import Foundation

/// A non-TTY exec with stdin attached: raw bytes in, the command's stdout out.
/// Used to pipe a forwarded port through `socat` inside the container.
final class DockerStreamSession: TerminalSession {
    let output: AsyncStream<Data>
    private let input: AsyncStream<Data>.Continuation
    private let task: Task<Void, Never>

    init(client: DockerClient, execID: String) {
        let (output, outputCont) = AsyncStream<Data>.makeStream()
        let (input, inputCont) = AsyncStream<Data>.makeStream()
        self.output = output
        self.input = inputCont

        task = Task {
            try? await client.hijack("/exec/\(execID)/start", json: ExecStartRequest(Tty: false)) { reader, writer in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await data in input { try await writer.write(data) }
                    }
                    // Without a TTY, Docker frames output by stream; keep stdout only.
                    var demux = StreamDemuxer()
                    try await reader.streamToEOF { bytes in
                        for (stream, payload) in demux.feed(bytes) where stream == .stdout {
                            outputCont.yield(Data(payload))
                        }
                    }
                    group.cancelAll()
                }
            }
            outputCont.finish()
        }
    }

    deinit {
        task.cancel()
        input.finish()
    }

    func write(_ data: Data) async throws { input.yield(data) }

    func resize(_ size: TerminalSize) async throws {}

    func close() async {
        input.finish()
        task.cancel()
    }
}

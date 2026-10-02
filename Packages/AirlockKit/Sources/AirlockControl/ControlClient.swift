import Foundation
import NIOCore
import NIOPosix

public struct ControlError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Talks to the running AIrlock app over its control socket.
public struct ControlClient: Sendable {
    public let socketPath: String
    /// Starts the app when nothing is listening. Nil disables auto-launch.
    public let launchApp: (@Sendable () -> Void)?

    public init(socketPath: String, launchApp: (@Sendable () -> Void)? = nil) {
        self.socketPath = socketPath
        self.launchApp = launchApp
    }

    public func call<P: Codable & Sendable, R: Codable & Sendable>(_ method: ControlMethod, _ params: P, as: R.Type = R.self) async throws -> R {
        let request = try ControlCoding.encoder.encode(RequestEnvelope(id: 1, method: method, params: params)) + Data([10])
        let line = try await sendWithLaunch(request)
        let response = try ControlCoding.decoder.decode(ResponseEnvelope<R>.self, from: line)
        if let error = response.error { throw ControlError(error) }
        guard let result = response.result else { throw ControlError("Empty response from AIrlock.") }
        return result
    }

    private func sendWithLaunch(_ request: Data) async throws -> Data {
        do {
            return try await send(request)
        } catch let error as ControlError {
            throw error
        } catch {
            guard let launchApp else { throw ControlError("AIrlock isn't running. Open the AIrlock app and try again.") }
            launchApp()
            // Give the app time to start and open its socket.
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                if let reply = try? await send(request) { return reply }
            }
            throw ControlError("AIrlock didn't start. Open the AIrlock app and try again.")
        }
    }

    private func send(_ request: Data) async throws -> Data {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(unixDomainSocketPath: socketPath) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(bytes: request))
            var buffer: [UInt8] = []
            for try await var chunk in inbound {
                buffer += chunk.readBytes(length: chunk.readableBytes) ?? []
                if let newline = buffer.firstIndex(of: 10) { return Data(buffer[..<newline]) }
            }
            throw ControlError("AIrlock closed the connection without answering.")
        }
    }
}

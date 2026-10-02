import Foundation
import NIOCore
import NIOPosix

/// One HTTP exchange over the Docker unix socket.
///
/// Each request opens its own connection (`Connection: close`), which keeps the
/// client stateless and makes hijacked exec streams trivial: after the response
/// head, the socket simply becomes the raw stream.
struct DockerConnection {
    typealias Writer = NIOAsyncChannelOutboundWriter<ByteBuffer>

    static func with<R: Sendable>(
        socketPath: String,
        _ body: (inout ResponseReader, Writer) async throws -> R
    ) async throws -> R {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .connect(unixDomainSocketPath: socketPath) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var reader = ResponseReader(iterator: inbound.makeAsyncIterator())
            return try await body(&reader, outbound)
        }
    }
}

/// Buffered reader over the inbound side of a connection.
struct ResponseReader {
    var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    var buffer: [UInt8] = []
    var eof = false

    /// Reads the next chunk from the socket into `buffer`. Returns false at EOF.
    mutating func fill() async throws -> Bool {
        guard !eof else { return false }
        guard var chunk = try await iterator.next() else {
            eof = true
            return false
        }
        if let bytes = chunk.readBytes(length: chunk.readableBytes) { buffer.append(contentsOf: bytes) }
        return true
    }

    mutating func readHead() async throws -> HTTPResponseHead {
        while true {
            if let head = try HTTPParsing.parseHead(&buffer) {
                // Skip interim 1xx responses other than 101 Switching Protocols.
                if (100..<200).contains(head.status), head.status != 101 { continue }
                return head
            }
            guard try await fill() else { throw HTTPParseError(description: "Connection closed before response head") }
        }
    }

    /// Delivers the response body in pieces as it arrives.
    mutating func streamBody(_ head: HTTPResponseHead, _ onData: ([UInt8]) async throws -> Void) async throws {
        if head.hasNoBody { return }
        if head.isChunked {
            var decoder = ChunkedDecoder()
            while true {
                let out = try decoder.decode(&buffer)
                if !out.isEmpty { try await onData(out) }
                if decoder.isDone { return }
                guard try await fill() else { return }
            }
        } else if var remaining = head.contentLength {
            while remaining > 0 {
                if buffer.isEmpty, !(try await fill()) { throw HTTPParseError(description: "Connection closed mid-body") }
                let n = min(remaining, buffer.count)
                try await onData(Array(buffer[..<n]))
                buffer.removeSubrange(..<n)
                remaining -= n
            }
        } else {
            try await streamToEOF(onData)
        }
    }

    /// Everything up to EOF — for hijacked raw streams and close-delimited bodies.
    mutating func streamToEOF(_ onData: ([UInt8]) async throws -> Void) async throws {
        while true {
            if !buffer.isEmpty {
                let bytes = buffer
                buffer.removeAll(keepingCapacity: true)
                try await onData(bytes)
            }
            guard try await fill() else { return }
        }
    }

    mutating func readBody(_ head: HTTPResponseHead) async throws -> Data {
        var data = Data()
        try await streamBody(head) { data.append(contentsOf: $0) }
        return data
    }
}

extension DockerConnection.Writer {
    func write(_ data: Data) async throws {
        try await write(ByteBuffer(bytes: data))
    }
}

import AirlockRuntime
import Foundation
import NIOCore
import NIOPosix

/// Forwards `127.0.0.1:<hostPort>` on the Mac to a port inside a task's container.
///
/// Each connection opens an exec stream running `socat` in the agent container and
/// pipes bytes both ways. Ports can come and go without recreating the container,
/// and nothing listens beyond localhost.
final class PortForwarder: Sendable {
    let hostPort: Int
    private let channel: Channel

    private init(hostPort: Int, channel: Channel) {
        self.hostPort = hostPort
        self.channel = channel
    }

    /// Listens on `preferred`, or the next free port above it.
    static func start(preferred: Int, open: @escaping @Sendable () async throws -> any TerminalSession) async throws -> PortForwarder {
        var lastError: Error?
        for port in preferred..<(preferred + 100) where port < 65536 {
            // SO_REUSEADDR would let this listener sit beside another program's wildcard
            // listener on the same port, and localhost:<port> would reach either of them.
            guard !isTaken(port) else { continue }
            do {
                let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { child in
                        child.pipeline.addHandler(ForwardHandler(open: open))
                    }
                    .bind(host: "127.0.0.1", port: port)
                    .get()
                return PortForwarder(hostPort: port, channel: channel)
            } catch {
                lastError = error
            }
        }
        throw EngineError("No free port on localhost near \(preferred): \(lastError.map(String.init(describing:)) ?? "")")
    }

    func stop() {
        channel.close(promise: nil)
    }

    /// Whether any program listens on this port, on any IPv4 or IPv6 address: a probe socket
    /// without SO_REUSEADDR can't bind the wildcard address then.
    static func isTaken(_ port: Int) -> Bool {
        func probe(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            if family == AF_INET6 {
                var on: Int32 = 1
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = in_port_t(UInt16(port).bigEndian)
                address.sin6_addr = in6addr_any
                return withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) != 0 }
                }
            }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 }
            }
        }
        return probe(AF_INET) || probe(AF_INET6)
    }
}

/// Pipes one accepted connection through an exec stream.
private final class ForwardHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let open: @Sendable () async throws -> any TerminalSession
    /// Bytes from the local client, in order, until it disconnects.
    private let input: AsyncStream<Data>
    private let inputSink: AsyncStream<Data>.Continuation

    init(open: @escaping @Sendable () async throws -> any TerminalSession) {
        self.open = open
        (input, inputSink) = AsyncStream<Data>.makeStream()
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let (open, input) = (open, input)
        Task {
            if let session = try? await open() {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await data in input { try? await session.write(data) }
                        await session.close()
                    }
                    group.addTask {
                        for await data in session.output {
                            _ = try? await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
                        }
                        _ = try? await channel.close().get()
                    }
                }
            }
            _ = try? await channel.close().get()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { inputSink.yield(Data(bytes)) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inputSink.finish()
    }
}

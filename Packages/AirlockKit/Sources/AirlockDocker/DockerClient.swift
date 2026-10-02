import Foundation

public struct DockerError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var message: String
    public var description: String { "Docker (\(status)): \(message)" }
}

/// Thin Docker Engine API client over the local unix socket.
public struct DockerClient: Sendable {
    public let socketPath: String
    /// Oldest API version that has everything AIrlock uses (ConsoleSize on exec, etc.).
    public static let apiVersion = "v1.44"

    public init(socketPath: String) { self.socketPath = socketPath }

    /// Finds a responsive Docker socket: `$DOCKER_HOST`, Docker Desktop, the system socket, OrbStack, Colima.
    public static func discoverSocket(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            candidates.append(String(host.dropFirst("unix://".count)))
        }
        candidates += [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.colima/docker.sock",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Requests

    func target(_ path: String, _ query: [String: String]) -> String {
        var target = "/\(Self.apiVersion)\(path)"
        if !query.isEmpty {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/:"))
            let q = query.sorted { $0.key < $1.key }.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            target += "?" + q.joined(separator: "&")
        }
        return target
    }

    /// Sends a request and returns the full response body. Throws `DockerError` on 4xx/5xx.
    @discardableResult
    public func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        try await DockerConnection.with(socketPath: socketPath) { reader, writer in
            var headers = [("Connection", "close")]
            if body != nil { headers.append(("Content-Type", contentType)) }
            try await writer.write(HTTPParsing.serializeRequest(method: method, target: target(path, query), headers: headers, body: body))
            let head = try await reader.readHead()
            let data = try await reader.readBody(head)
            try Self.check(head, data)
            return data
        }
    }

    @discardableResult
    public func request<Body: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], json: Body) async throws -> Data {
        try await request(method, path, query: query, body: try JSONEncoder().encode(json))
    }

    /// Sends a request and streams newline-delimited JSON messages from the body.
    public func streamJSONLines(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String = "application/json",
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        try await DockerConnection.with(socketPath: socketPath) { reader, writer in
            var headers = [("Connection", "close")]
            if body != nil { headers.append(("Content-Type", contentType)) }
            try await writer.write(HTTPParsing.serializeRequest(method: method, target: target(path, query), headers: headers, body: body))
            let head = try await reader.readHead()
            if head.status >= 400 {
                try Self.check(head, try await reader.readBody(head))
            }
            var splitter = LineSplitter()
            try await reader.streamBody(head) { bytes in
                for line in splitter.feed(bytes) { try await onLine(line) }
            }
            if let last = splitter.flush() { try await onLine(last) }
        }
    }

    /// Starts a hijacked exec: after the response head the connection carries the
    /// raw process stream. `session` receives the reader positioned at the stream.
    func hijack<R: Sendable>(
        _ path: String,
        json: some Encodable,
        session: (inout ResponseReader, DockerConnection.Writer) async throws -> R
    ) async throws -> R {
        let body = try JSONEncoder().encode(json)
        return try await DockerConnection.with(socketPath: socketPath) { reader, writer in
            let headers = [("Content-Type", "application/json"), ("Connection", "Upgrade"), ("Upgrade", "tcp")]
            try await writer.write(HTTPParsing.serializeRequest(method: "POST", target: target(path, [:]), headers: headers, body: body))
            let head = try await reader.readHead()
            if head.status >= 400 {
                try Self.check(head, try await reader.readBody(head))
            }
            return try await session(&reader, writer)
        }
    }

    static func check(_ head: HTTPResponseHead, _ body: Data) throws {
        guard head.status >= 400 else { return }
        struct Message: Decodable { var message: String }
        let message = (try? JSONDecoder().decode(Message.self, from: body).message)
            ?? String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw DockerError(status: head.status, message: message.isEmpty ? head.reason : message)
    }
}

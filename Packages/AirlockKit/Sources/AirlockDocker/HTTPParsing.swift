import Foundation

/// Minimal HTTP/1.1 response parsing for the Docker socket.
///
/// Docker needs connection hijacking (exec/attach), which general-purpose HTTP
/// clients don't expose, so AIrlock speaks HTTP/1.1 itself. Everything here is
/// pure byte manipulation and unit-tested without a socket.
public struct HTTPResponseHead: Sendable, Equatable {
    public var status: Int
    public var reason: String
    /// Header names lowercased.
    public var headers: [String: String]

    public var contentLength: Int? { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false }
    public var hasNoBody: Bool { status == 204 || status == 304 || status == 101 || (100..<200).contains(status) }
}

public struct HTTPParseError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public enum HTTPParsing {
    static let crlfcrlf: [UInt8] = Array("\r\n\r\n".utf8)

    /// Parses and removes a complete response head from the front of `buffer`.
    /// Returns nil when more bytes are needed.
    public static func parseHead(_ buffer: inout [UInt8]) throws -> HTTPResponseHead? {
        guard let end = buffer.firstRange(of: crlfcrlf) else { return nil }
        let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)

        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw HTTPParseError(description: "Malformed status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return HTTPResponseHead(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers)
    }

    /// Serializes a request. Bodies are always sent with Content-Length.
    public static func serializeRequest(
        method: String,
        target: String,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: docker\r\nUser-Agent: AIrlock\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body {
            head += "Content-Length: \(body.count)\r\n"
        } else if ["POST", "PUT"].contains(method) {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// Incremental decoder for `Transfer-Encoding: chunked`.
public struct ChunkedDecoder: Sendable {
    enum State: Sendable { case size, data(remaining: Int), dataCRLF, trailer, done }
    var state: State = .size

    public init() {}

    public var isDone: Bool { if case .done = state { true } else { false } }

    /// Consumes as much of `buffer` as possible and returns decoded body bytes.
    public mutating func decode(_ buffer: inout [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        loop: while true {
            switch state {
            case .size:
                guard let lineEnd = buffer.firstRange(of: [13, 10]) else { break loop }
                let line = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<lineEnd.upperBound)
                let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(hex, radix: 16) else { throw HTTPParseError(description: "Bad chunk size: \(line)") }
                state = size == 0 ? .trailer : .data(remaining: size)
            case .data(let remaining):
                guard !buffer.isEmpty else { break loop }
                let n = min(remaining, buffer.count)
                out.append(contentsOf: buffer[..<n])
                buffer.removeSubrange(..<n)
                state = remaining - n == 0 ? .dataCRLF : .data(remaining: remaining - n)
            case .dataCRLF:
                guard buffer.count >= 2 else { break loop }
                buffer.removeSubrange(..<2)
                state = .size
            case .trailer:
                guard let lineEnd = buffer.firstRange(of: [13, 10]) else { break loop }
                let empty = lineEnd.lowerBound == buffer.startIndex
                buffer.removeSubrange(..<lineEnd.upperBound)
                if empty { state = .done }
            case .done:
                break loop
            }
        }
        return out
    }
}

/// Splits Docker's multiplexed stdout/stderr stream (non-TTY exec and logs).
///
/// Each frame is `[stream, 0, 0, 0, size(4, big-endian)]` followed by `size` bytes.
public struct StreamDemuxer: Sendable {
    public enum Stream: UInt8, Sendable { case stdin = 0, stdout = 1, stderr = 2 }

    var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [(Stream, [UInt8])] {
        buffer.append(contentsOf: bytes)
        var frames: [(Stream, [UInt8])] = []
        while buffer.count >= 8 {
            let size = Int(buffer[4]) << 24 | Int(buffer[5]) << 16 | Int(buffer[6]) << 8 | Int(buffer[7])
            guard buffer.count >= 8 + size else { break }
            let stream = Stream(rawValue: buffer[0]) ?? .stdout
            frames.append((stream, Array(buffer[8..<(8 + size)])))
            buffer.removeSubrange(..<(8 + size))
        }
        return frames
    }
}

/// Splits a byte stream into newline-delimited JSON lines.
public struct LineSplitter: Sendable {
    var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    public mutating func flush() -> String? {
        defer { buffer = [] }
        let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

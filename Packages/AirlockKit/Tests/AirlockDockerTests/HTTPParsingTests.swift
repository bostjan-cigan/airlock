import AirlockRuntime
import Foundation
import Testing
@testable import AirlockDocker

@Suite struct HTTPParsingTests {
    @Test func parsesHeadAndLeavesBody() throws {
        var buffer = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let head = try #require(try HTTPParsing.parseHead(&buffer))
        #expect(head.status == 200)
        #expect(head.reason == "OK")
        #expect(head.headers["content-type"] == "application/json")
        #expect(head.contentLength == 2)
        #expect(buffer == Array("{}".utf8))
    }

    @Test func incompleteHeadNeedsMoreBytes() throws {
        var buffer = Array("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\n".utf8)
        #expect(try HTTPParsing.parseHead(&buffer) == nil)
        #expect(buffer.count > 0)
    }

    @Test func rejectsGarbage() {
        var buffer = Array("hello\r\n\r\n".utf8)
        #expect(throws: HTTPParseError.self) { try HTTPParsing.parseHead(&buffer) }
    }

    @Test func serializesRequestWithBody() {
        let data = HTTPParsing.serializeRequest(method: "POST", target: "/v1.44/x", headers: [("A", "b")], body: Data("{}".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("POST /v1.44/x HTTP/1.1\r\nHost: docker\r\n"))
        #expect(text.contains("A: b\r\n"))
        #expect(text.hasSuffix("Content-Length: 2\r\n\r\n{}"))
    }

    @Test func chunkedDecodingAcrossSplits() throws {
        let raw = Array("4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n".utf8)
        var decoder = ChunkedDecoder()
        var out: [UInt8] = []
        var pending: [UInt8] = []
        for byte in raw {
            pending.append(byte)
            out += try decoder.decode(&pending)
        }
        #expect(String(decoding: out, as: UTF8.self) == "Wikipedia")
        #expect(decoder.isDone)
    }

    @Test func demuxesStdoutAndStderr() {
        var demux = StreamDemuxer()
        let frames: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 3] + Array("out".utf8) + [2, 0, 0, 0, 0, 0, 0, 3] + Array("err".utf8)
        var got = demux.feed(frames.prefix(5))
        #expect(got.isEmpty)
        got = demux.feed(frames.dropFirst(5))
        #expect(got.count == 2)
        #expect(got[0].0 == .stdout && got[0].1 == Array("out".utf8))
        #expect(got[1].0 == .stderr && got[1].1 == Array("err".utf8))
    }

    @Test func splitsLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Array("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(splitter.feed(Array(":2}\n".utf8)) == ["{\"b\":2}"])
        #expect(splitter.flush() == nil)
    }

    @Test func encodesTargetQuery() {
        let client = DockerClient(socketPath: "/dev/null")
        #expect(client.target("/build", ["t": "airlock/base:abc", "rm": "1"]) == "/v1.44/build?rm=1&t=airlock%2Fbase%3Aabc")
    }
}

@Suite struct DockerModelTests {
    @Test func containerSpecEncodesHardenedHostConfig() throws {
        let spec = ContainerSpec(
            name: "airlock-1", image: "airlock/claude-code:1",
            labels: ["airlock.task": "x"],
            mounts: [.bind(hostPath: "/h", containerPath: "/workspace"), .volume(name: "v", containerPath: "/data")],
            environment: ["B": "2", "A": "1"],
            capAdd: ["NET_ADMIN"],
            resources: .init(cpus: 2, memoryMB: 1024)
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CreateContainerRequest(spec))) as! [String: Any]
        #expect(json["Env"] as? [String] == ["A=1", "B=2"])
        let host = json["HostConfig"] as! [String: Any]
        #expect(host["SecurityOpt"] as? [String] == ["no-new-privileges"])
        #expect(host["CapAdd"] as? [String] == ["NET_ADMIN"])
        #expect(host["Init"] as? Bool == true)
        #expect(host["NanoCpus"] as? Int == 2_000_000_000)
        #expect(host["Memory"] as? Int == 1024 * 1024 * 1024)
        let mounts = host["Mounts"] as! [[String: Any]]
        #expect(mounts[0]["Type"] as? String == "bind")
        #expect(mounts[1]["Type"] as? String == "volume")
    }
}

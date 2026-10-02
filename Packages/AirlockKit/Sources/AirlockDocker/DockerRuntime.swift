import AirlockCore
import AirlockRuntime
import Foundation

public struct DockerRuntime: ContainerRuntime {
    public let client: DockerClient
    public var kind: RuntimeKind { .docker }

    public init(client: DockerClient) { self.client = client }

    /// A runtime on the first Docker socket found, or nil when there is none.
    public static func discover() -> DockerRuntime? {
        DockerClient.discoverSocket().map { DockerRuntime(client: DockerClient(socketPath: $0)) }
    }

    public func availability() async -> RuntimeAvailability {
        do {
            let data = try await client.request("GET", "/version")
            let version = try JSONDecoder().decode(VersionResponse.self, from: data)
            return .available(version: version.Version)
        } catch {
            return .unavailable(reason: "Docker isn't responding on \(client.socketPath). Start Docker Desktop, OrbStack or Colima.")
        }
    }

    // MARK: Images

    public func imageExists(_ ref: String) async throws -> Bool {
        do {
            try await client.request("GET", "/images/\(ref)/json")
            return true
        } catch let error as DockerError where error.status == 404 {
            return false
        }
    }

    public func ensureImage(_ recipe: ImageRecipe, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        var buildArgs = recipe.buildArgs
        if let parent = recipe.parent?.recipe {
            buildArgs["BASE_IMAGE"] = try await ensureImage(parent, progress: progress)
        }
        let tag = try recipe.tag()
        if try await imageExists(tag) { return tag }

        progress("Building \(tag)")
        let context = try await Self.tarContext(recipe.contextDirectory)
        let args = String(decoding: try JSONEncoder().encode(buildArgs), as: UTF8.self)
        let labels = String(decoding: try JSONEncoder().encode(["com.bostjancigan.airlock": "1"]), as: UTF8.self)
        try await client.streamJSONLines(
            "POST", "/build",
            query: ["t": tag, "rm": "1", "forcerm": "1", "buildargs": args, "labels": labels],
            body: context,
            contentType: "application/x-tar"
        ) { line in
            guard let msg = try? JSONDecoder().decode(BuildMessage.self, from: Data(line.utf8)) else { return }
            if let error = msg.errorDetail?.message ?? msg.error {
                throw DockerError(status: 500, message: "Image build failed: \(error)")
            }
            if let text = (msg.stream ?? msg.status)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                progress(text)
            }
        }
        guard try await imageExists(tag) else {
            throw DockerError(status: 500, message: "Image build finished but \(tag) is missing")
        }
        return tag
    }

    static func tarContext(_ dir: URL) async throws -> Data {
        try await ProcessRunner.run(
            "/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-c", "-f", "-", "-C", dir.path, "."],
            environment: ["COPYFILE_DISABLE": "1"]
        ).stdout
    }

    // MARK: Containers

    public func create(_ spec: ContainerSpec) async throws -> String {
        let data = try await client.request("POST", "/containers/create", query: ["name": spec.name], json: CreateContainerRequest(spec))
        return try JSONDecoder().decode(CreateResponse.self, from: data).Id
    }

    public func start(_ id: String) async throws {
        // 304 (already running) is not an error status.
        try await client.request("POST", "/containers/\(id)/start")
    }

    public func stop(_ id: String, timeout: Duration) async throws {
        do {
            try await client.request("POST", "/containers/\(id)/stop", query: ["t": "\(Int(timeout.components.seconds))"])
        } catch let error as DockerError where error.status == 404 {
            // Gone. (Already stopped answers 304, which isn't an error status.)
        }
    }

    public func remove(_ id: String) async throws {
        do {
            try await client.request("DELETE", "/containers/\(id)", query: ["force": "1", "v": "1"])
        } catch let error as DockerError where error.status == 404 {
            // Already gone.
        }
    }

    public func state(_ id: String) async throws -> ContainerState {
        do {
            let data = try await client.request("GET", "/containers/\(id)/json")
            let info = try JSONDecoder().decode(ContainerInspect.self, from: data)
            return info.State.Running ? .running : .stopped(exitCode: info.State.ExitCode)
        } catch let error as DockerError where error.status == 404 {
            return .missing
        }
    }

    // MARK: Exec

    func createExec(_ id: String, _ spec: ExecSpec, tty: Bool, size: TerminalSize? = nil, stdin: Bool? = nil) async throws -> String {
        let data = try await client.request("POST", "/containers/\(id)/exec", json: ExecCreateRequest(spec, tty: tty, size: size, stdin: stdin))
        return try JSONDecoder().decode(CreateResponse.self, from: data).Id
    }

    func execExitCode(_ execID: String) async throws -> Int {
        // The stream can close a moment before Docker records the exit code.
        for _ in 0..<50 {
            let data = try await client.request("GET", "/exec/\(execID)/json")
            let info = try JSONDecoder().decode(ExecInspect.self, from: data)
            if !info.Running, let code = info.ExitCode { return code }
            try await Task.sleep(for: .milliseconds(20))
        }
        return -1
    }

    public func exec(_ id: String, _ spec: ExecSpec) async throws -> ExecResult {
        let execID = try await createExec(id, spec, tty: false)
        let (stdout, stderr) = try await client.hijack("/exec/\(execID)/start", json: ExecStartRequest(Tty: false)) { reader, _ in
            var demux = StreamDemuxer()
            var out = Data(), err = Data()
            try await reader.streamToEOF { bytes in
                for (stream, payload) in demux.feed(bytes) {
                    if stream == .stderr { err.append(contentsOf: payload) } else { out.append(contentsOf: payload) }
                }
            }
            return (out, err)
        }
        return ExecResult(exitCode: try await execExitCode(execID), stdout: stdout, stderr: stderr)
    }

    public func openTerminal(_ id: String, _ spec: ExecSpec, size: TerminalSize) async throws -> any TerminalSession {
        let execID = try await createExec(id, spec, tty: true, size: size)
        return DockerTerminalSession(client: client, execID: execID, size: size)
    }

    public func openStream(_ id: String, _ spec: ExecSpec) async throws -> any TerminalSession {
        let execID = try await createExec(id, spec, tty: false, stdin: true)
        return DockerStreamSession(client: client, execID: execID)
    }

    // MARK: Files and volumes

    public func copyIn(_ id: String, tar: Data, to path: String) async throws {
        try await client.request("PUT", "/containers/\(id)/archive", query: ["path": path], body: tar, contentType: "application/x-tar")
    }

    /// Bytes used by AIrlock's images (`airlock/…`) and volumes (`airlock-…`).
    public func diskUsage() async throws -> (images: Int64, volumes: Int64) {
        struct DF: Decodable {
            struct Image: Decodable { var RepoTags: [String]?; var Size: Int64 }
            struct Volume: Decodable {
                struct Usage: Decodable { var Size: Int64 }
                var Name: String
                var UsageData: Usage?
            }
            var Images: [Image]?
            var Volumes: [Volume]?
        }
        let df = try JSONDecoder().decode(DF.self, from: try await client.request("GET", "/system/df"))
        let images = (df.Images ?? []).filter { $0.RepoTags?.contains { $0.hasPrefix("airlock/") } == true }.reduce(0) { $0 + $1.Size }
        let volumes = (df.Volumes ?? []).filter { $0.Name.hasPrefix("airlock-") }.reduce(0) { $0 + max($1.UsageData?.Size ?? 0, 0) }
        return (images, volumes)
    }

    /// Docker measures CPU over about a second when it isn't streaming.
    public func usage(_ id: String) async throws -> ResourceUsage? {
        struct Stats: Decodable {
            struct CPU: Decodable {
                struct Usage: Decodable { var total_usage: UInt64 }
                var cpu_usage: Usage
                var system_cpu_usage: UInt64?
                var online_cpus: Int?
            }
            struct Memory: Decodable {
                var usage: UInt64?
                var stats: [String: UInt64]?
            }
            var cpu_stats: CPU
            var precpu_stats: CPU
            var memory_stats: Memory
        }
        let data = try await client.request("GET", "/containers/\(id)/stats", query: ["stream": "false"])
        guard let stats = try? JSONDecoder().decode(Stats.self, from: data) else { return nil }
        let cpuDelta = Double(stats.cpu_stats.cpu_usage.total_usage) - Double(stats.precpu_stats.cpu_usage.total_usage)
        let systemDelta = Double(stats.cpu_stats.system_cpu_usage ?? 0) - Double(stats.precpu_stats.system_cpu_usage ?? 0)
        let cpus = Double(stats.cpu_stats.online_cpus ?? 1)
        let cpu = systemDelta > 0 && cpuDelta > 0 ? cpuDelta / systemDelta * cpus * 100 : 0
        // Like `docker stats`: page cache the kernel can drop doesn't count.
        let cache = stats.memory_stats.stats?["inactive_file"] ?? 0
        let memory = (stats.memory_stats.usage ?? 0) - min(cache, stats.memory_stats.usage ?? 0)
        return ResourceUsage(cpuPercent: cpu, memoryBytes: memory)
    }

    public func createVolume(_ name: String, labels: [String: String]) async throws {
        struct Body: Encodable { var Name: String; var Labels: [String: String] }
        try await client.request("POST", "/volumes/create", json: Body(Name: name, Labels: labels))
    }

    public func removeVolume(_ name: String) async throws {
        do {
            try await client.request("DELETE", "/volumes/\(name)", query: ["force": "1"])
        } catch let error as DockerError where error.status == 404 {
            // Already gone.
        }
    }

    /// Container IDs carrying the given label, running or not.
    public func containers(label: String) async throws -> [(id: String, labels: [String: String], running: Bool)] {
        struct Item: Decodable { var Id: String; var Labels: [String: String]?; var State: String }
        let filters = String(decoding: try JSONEncoder().encode(["label": [label]]), as: UTF8.self)
        let data = try await client.request("GET", "/containers/json", query: ["all": "1", "filters": filters])
        return try JSONDecoder().decode([Item].self, from: data).map { ($0.Id, $0.Labels ?? [:], $0.State == "running") }
    }
}

extension DockerRuntime: ServiceRuntime {
    public func pullImage(_ ref: String, progress: @escaping @Sendable (String) -> Void) async throws {
        if try await imageExists(ref) { return }
        let (name, tag) = Self.splitReference(ref)
        progress("Pulling \(ref)…")
        let data = try await client.request("POST", "/images/create", query: ["fromImage": name, "tag": tag])
        // The body is a stream of JSON progress lines; an error arrives as one of them.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let message = try? JSONDecoder().decode(BuildMessage.self, from: line), let error = message.error ?? message.errorDetail?.message {
                throw DockerError(status: 500, message: "Couldn't pull \(ref): \(error)")
            }
        }
    }

    /// `postgres:16` → ("postgres", "16"); digests and registry ports are kept intact.
    static func splitReference(_ ref: String) -> (String, String) {
        if ref.contains("@") { return (ref, "") }
        let lastSlash = ref.lastIndex(of: "/") ?? ref.startIndex
        if let colon = ref[lastSlash...].lastIndex(of: ":") {
            return (String(ref[..<colon]), String(ref[ref.index(after: colon)...]))
        }
        return (ref, "latest")
    }

    public func exposedPorts(image: String) async throws -> [Int] {
        let data = try await client.request("GET", "/images/\(image)/json")
        let info = try JSONDecoder().decode(ImageInspect.self, from: data)
        return (info.Config?.ExposedPorts ?? [:]).keys
            .compactMap { key in key.hasSuffix("/udp") ? nil : Int(key.split(separator: "/").first ?? "") }
            .sorted()
    }

    public func health(_ id: String) async throws -> String? {
        let data = try await client.request("GET", "/containers/\(id)/json")
        return try JSONDecoder().decode(ContainerInspect.self, from: data).State.Health?.Status
    }

    public func logs(_ id: String, tail: Int) async throws -> String {
        let data = try await client.request("GET", "/containers/\(id)/logs", query: ["stdout": "1", "stderr": "1", "tail": "\(tail)"])
        var demux = StreamDemuxer()
        var out = Data()
        for (_, payload) in demux.feed([UInt8](data)) { out.append(contentsOf: payload) }
        return String(decoding: out, as: UTF8.self)
    }

    public func restart(_ id: String) async throws {
        try await client.request("POST", "/containers/\(id)/restart", query: ["t": "5"])
    }
}

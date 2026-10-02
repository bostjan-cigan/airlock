import AirlockCore
import AirlockRuntime
import Foundation

/// Reads a project's compose file and turns its infrastructure services into
/// containers that share the agent's network namespace.
///
/// Compose itself only reads the file (`docker compose config` resolves `.env`,
/// `extends`, profiles and interpolation); AIrlock creates the containers, so it
/// decides what a service may do.
public enum ComposeServices {
    static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    /// The compose file in `dir`, relative to it: a top-level one, or the one a
    /// devcontainer points at.
    public static func detect(in dir: URL) -> String? {
        let fm = FileManager.default
        if let name = fileNames.first(where: { fm.fileExists(atPath: dir.appending(path: $0).path) }) { return name }
        if let fromDevcontainer = devcontainerCompose(in: dir) { return fromDevcontainer }
        // AIrlock's own settings may be the only compose file, with extra services.
        return fm.fileExists(atPath: dir.appending(path: ProjectConfig.fileName).path) ? ProjectConfig.fileName : nil
    }

    static func devcontainerCompose(in dir: URL) -> String? {
        let fm = FileManager.default
        let devcontainer = dir.appending(path: ".devcontainer/devcontainer.json")
        guard let data = try? Data(contentsOf: devcontainer),
              let json = try? JSONSerialization.jsonObject(with: Self.stripComments(data)) as? [String: Any] else { return nil }
        let files = (json["dockerComposeFile"] as? [String]) ?? (json["dockerComposeFile"] as? String).map { [$0] } ?? []
        return files.first.map { ".devcontainer/\($0)" }.flatMap { path in
            let url = dir.appending(path: path).standardizedFileURL
            return fm.fileExists(atPath: url.path) ? String(url.path.dropFirst(dir.standardizedFileURL.path.count + 1)) : nil
        }
    }

    /// devcontainer.json is JSON with comments: drop `//` and `/* */` outside strings.
    static func stripComments(_ data: Data) -> Data {
        let chars = Array(String(decoding: data, as: UTF8.self))
        var out: [Character] = []
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inString {
                out.append(c)
                if c == "\\", let next { out.append(next); i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            } else if c == "/", next == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            } else {
                out.append(c)
            }
            i += 1
        }
        return Data(String(out).utf8)
    }

    /// `path` with links resolved, when that's still inside `checkout`. The agent writes the
    /// checkout, so a folder in it may be a link to anywhere on the Mac.
    public static func confined(_ path: String, to checkout: String) -> String? {
        let base = realPath(checkout)
        let real = realPath(path)
        return real == base || real.hasPrefix(base + "/") ? real : nil
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The `docker` CLI, which a GUI app's PATH usually doesn't include.
    public static func dockerCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Docker.app/Contents/Resources/bin/docker", "\(home)/.orbstack/bin/docker",
                "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `docker compose config` in `dir` and decodes the result. AIrlock's own
    /// `.airlock/compose.yaml`, when there is one, is merged on top of `file`.
    public static func load(dir: URL, file: String, dockerSocket: String?) async throws -> ComposeProject {
        var files = [file]
        if file != ProjectConfig.fileName, FileManager.default.fileExists(atPath: dir.appending(path: ProjectConfig.fileName).path) {
            files.append(ProjectConfig.fileName)
        }
        return try JSONDecoder().decode(ComposeProject.self, from: try await configJSON(dir: dir, files: files, dockerSocket: dockerSocket))
    }

    /// `docker compose config --format json` for these files, merged in order.
    static func configJSON(dir: URL, files: [String], dockerSocket: String?) async throws -> Data {
        guard let docker = dockerCLI() else {
            throw EngineError("Reading \(files.joined(separator: " and ")) needs the docker command (it comes with Docker Desktop and OrbStack).")
        }
        var env: [String: String] = [:]
        if let dockerSocket { env["DOCKER_HOST"] = "unix://\(dockerSocket)" }
        let result = try await ProcessRunner.run(docker, ["compose"] + files.flatMap { ["-f", $0] } + ["config", "--format", "json"],
                                                 cwd: dir, environment: env, check: false)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError("Couldn't read \(files.joined(separator: " and ")): \(message)")
        }
        return result.stdout
    }

    /// Services AIrlock will start, the ones it skips, and in what order to start them.
    /// `root` is where the compose file's relative paths point (the user's repository, where
    /// it was read); nil means repository files aren't on the Mac (isolated clone). Bind mounts
    /// inside `root` are moved to the same place in `checkout`, the task's own files.
    public static func plan(_ project: ComposeProject, volumePrefix: String, root: String?, checkout: String? = nil) -> ServicePlan {
        var kept: [PlannedService] = []
        var skipped: [String: String] = [:]
        for (name, service) in project.services.sorted(by: { $0.key < $1.key }) {
            // `agent` in AIrlock's settings describes the agent's own container.
            guard name != "agent" else { continue }
            guard let image = service.image, !image.isEmpty else {
                skipped[name] = service.build != nil ? "Built from the repository; the agent runs it in its own container" : "No image"
                continue
            }
            kept.append(map(name, image: image, service, volumePrefix: volumePrefix, root: root, checkout: checkout))
        }
        let (resolved, collisions) = resolvePortCollisions(kept)
        skipped.merge(collisions) { a, _ in a }
        return ServicePlan(services: order(resolved), skipped: skipped)
    }

    static func map(_ name: String, image: String, _ s: ComposeProject.Service, volumePrefix: String, root: String?, checkout: String? = nil) -> PlannedService {
        var dropped: [String] = []
        var mounts: [MountSpec] = []
        var volumes: [String] = []

        if let ports = s.ports, !ports.isEmpty {
            let list = ports.map { p in p.published.map { "\($0):\(p.target)" } ?? "\(p.target)" }
            dropped.append("ports \(list.joined(separator: ", ")) (not exposed on your Mac; use Expose instead)")
        }
        if s.privileged == true { dropped.append("privileged mode") }
        if let caps = s.cap_add, !caps.isEmpty { dropped.append("extra capabilities \(caps.joined(separator: ", "))") }
        if let devices = s.devices, !devices.isEmpty { dropped.append("devices") }
        if let mode = s.network_mode { dropped.append("network_mode \(mode)") }
        if let pid = s.pid { dropped.append("pid \(pid)") }
        if let ipc = s.ipc { dropped.append("ipc \(ipc)") }
        if let opts = s.security_opt, !opts.isEmpty { dropped.append("security_opt \(opts.joined(separator: ", "))") }

        let rootPath = root.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for volume in s.volumes ?? [] {
            switch volume.type {
            case "volume":
                guard let source = volume.source else {
                    dropped.append("anonymous volume at \(volume.target)")
                    continue
                }
                let name = "\(volumePrefix)-\(source)"
                volumes.append(name)
                mounts.append(.volume(name: name, containerPath: volume.target))
            case "bind":
                let source = checkout == nil ? URL(fileURLWithPath: volume.source ?? "").standardizedFileURL.resolvingSymlinksInPath().path
                    : realPath(volume.source ?? "")
                if let rootPath, source == rootPath || source.hasPrefix(rootPath + "/") {
                    guard let checkout else {
                        mounts.append(.bind(hostPath: source, containerPath: volume.target, readOnly: volume.read_only ?? false))
                        continue
                    }
                    if let inside = confined(checkout + source.dropFirst(rootPath.count), to: checkout) {
                        mounts.append(.bind(hostPath: inside, containerPath: volume.target, readOnly: volume.read_only ?? false))
                    } else {
                        dropped.append("bind mount of \(volume.source ?? "?") (in the task's files it leads outside them)")
                    }
                } else if rootPath == nil {
                    dropped.append("bind mount \(volume.target) (repository files aren't on your Mac in an isolated clone)")
                } else {
                    dropped.append("bind mount of \(volume.source ?? "?") (outside the repository)")
                }
            case "tmpfs":
                break
            default:
                dropped.append("\(volume.type) mount at \(volume.target)")
            }
        }

        var ports = (s.ports ?? []).map(\.target)
        ports += (s.expose ?? []).compactMap { Int($0.split(separator: "/").first ?? "") }

        return PlannedService(
            name: name,
            image: image,
            command: s.command ?? [],
            entrypoint: s.entrypoint,
            environment: (s.environment ?? [:]).compactMapValues { $0 },
            workdir: s.working_dir,
            user: s.user,
            healthcheck: s.healthcheck.flatMap(healthcheck),
            tmpfs: s.tmpfs ?? [],
            mounts: mounts,
            volumes: volumes,
            ports: Array(Set(ports)).sorted(),
            dependsOn: (s.depends_on ?? [:]).keys.sorted(),
            dropped: dropped
        )
    }

    static func healthcheck(_ h: ComposeProject.Healthcheck) -> HealthcheckSpec? {
        if h.disable == true { return HealthcheckSpec(test: ["NONE"]) }
        guard let test = h.test, !test.isEmpty else { return nil }
        return HealthcheckSpec(test: test, interval: h.interval.flatMap(goDuration), timeout: h.timeout.flatMap(goDuration),
                               retries: h.retries, startPeriod: h.start_period.flatMap(goDuration))
    }

    /// Parses Go-style durations as compose prints them: "2s", "1m30s", "500ms".
    static func goDuration(_ text: String) -> Duration? {
        var total = Duration.zero
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "h": total += .seconds(value * 3600)
            case "m": total += .seconds(value * 60)
            case "s": total += .seconds(value)
            case "ms": total += .milliseconds(value)
            case "us", "µs": total += .microseconds(value)
            case "ns": total += .nanoseconds(Int64(value))
            default: return false
            }
            number = ""
            unit = ""
            return true
        }
        for ch in text {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else {
                unit.append(ch)
            }
        }
        return flush() ? total : nil
    }

    /// Services share one network namespace, so two can't listen on the same port.
    /// The later one (alphabetically, after dependencies) is skipped.
    public static func resolvePortCollisions(_ services: [PlannedService]) -> ([PlannedService], [String: String]) {
        var owner: [Int: String] = [:]
        var kept: [PlannedService] = []
        var skipped: [String: String] = [:]
        for service in services {
            if let clash = service.ports.first(where: { owner[$0] != nil }) {
                skipped[service.name] = "Port \(clash) is already used by \(owner[clash]!); services share one network"
                continue
            }
            for port in service.ports { owner[port] = service.name }
            kept.append(service)
        }
        return (kept, skipped)
    }

    /// Dependencies first; ties alphabetical. Dependencies on skipped services are ignored.
    static func order(_ services: [PlannedService]) -> [PlannedService] {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var done: Set<String> = []
        var visiting: Set<String> = []
        var out: [PlannedService] = []
        func visit(_ name: String) {
            guard let service = byName[name], !done.contains(name), !visiting.contains(name) else { return }
            visiting.insert(name)
            service.dependsOn.forEach(visit)
            visiting.remove(name)
            done.insert(name)
            out.append(service)
        }
        services.map(\.name).sorted().forEach(visit)
        return out
    }
}

/// The parts of `docker compose config --format json` AIrlock reads.
public struct ComposeProject: Decodable, Sendable {
    public struct Service: Decodable, Sendable {
        var image: String?
        var build: JSONAny?
        var command: [String]?
        var entrypoint: [String]?
        var environment: [String: String?]?
        var working_dir: String?
        var user: String?
        var healthcheck: Healthcheck?
        var depends_on: [String: JSONAny]?
        var tmpfs: [String]?
        var ports: [Port]?
        var expose: [String]?
        var volumes: [Volume]?
        var privileged: Bool?
        var cap_add: [String]?
        var devices: [JSONAny]?
        var network_mode: String?
        var pid: String?
        var ipc: String?
        var security_opt: [String]?
    }

    public struct Port: Decodable, Sendable {
        var target: Int
        var published: String?
    }

    public struct Volume: Decodable, Sendable {
        var type: String
        var source: String?
        var target: String
        var read_only: Bool?
    }

    public struct Healthcheck: Decodable, Sendable {
        var test: [String]?
        var interval: String?
        var timeout: String?
        var retries: Int?
        var start_period: String?
        var disable: Bool?
    }

    public var services: [String: Service]
}

/// Accepts any JSON value; only its presence matters.
public struct JSONAny: Decodable, Sendable {
    public init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

public struct ServicePlan: Sendable {
    /// In start order.
    public var services: [PlannedService]
    public var skipped: [String: String]
}

public struct PlannedService: Sendable, Equatable {
    public var name: String
    public var image: String
    public var command: [String]
    public var entrypoint: [String]?
    public var environment: [String: String]
    public var workdir: String?
    public var user: String?
    public var healthcheck: HealthcheckSpec?
    public var tmpfs: [String]
    public var mounts: [MountSpec]
    public var volumes: [String]
    public var ports: [Int]
    public var dependsOn: [String]
    public var dropped: [String]

    /// The container for this service, sharing the agent container's network.
    public func containerSpec(task: AgentTask, agentContainerID: String) -> ContainerSpec {
        ContainerSpec(
            name: "\(task.containerName)-\(name)",
            image: image,
            labels: ["airlock.task": task.id.uuidString, "airlock.service": name],
            mounts: mounts,
            environment: environment,
            command: command,
            user: user,
            workdir: workdir,
            resources: task.resources,
            networkMode: "container:\(agentContainerID)",
            entrypoint: entrypoint,
            healthcheck: healthcheck,
            tmpfs: tmpfs.isEmpty ? nil : Dictionary(uniqueKeysWithValues: tmpfs.map { ($0, "") })
        )
    }
}

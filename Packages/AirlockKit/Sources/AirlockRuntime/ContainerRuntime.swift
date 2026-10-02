import AirlockCore
import Foundation

/// A container backend (Docker Engine, Apple Containerization).
///
/// Implementations are expected to be safe to call from any task.
public protocol ContainerRuntime: Sendable {
    var kind: RuntimeKind { get }

    /// Whether the backend can be used right now, and why not if it can't.
    func availability() async -> RuntimeAvailability

    /// Builds (or reuses) the image for `recipe`, returning its reference.
    func ensureImage(_ recipe: ImageRecipe, progress: @escaping @Sendable (String) -> Void) async throws -> String

    func create(_ spec: ContainerSpec) async throws -> String
    func start(_ id: String) async throws
    func stop(_ id: String, timeout: Duration) async throws
    func remove(_ id: String) async throws
    func state(_ id: String) async throws -> ContainerState

    /// Runs a command to completion and captures its output.
    func exec(_ id: String, _ spec: ExecSpec) async throws -> ExecResult

    /// Runs a command attached to a pseudo-terminal.
    func openTerminal(_ id: String, _ spec: ExecSpec, size: TerminalSize) async throws -> any TerminalSession

    /// Extracts a tar archive into `path` inside the container.
    func copyIn(_ id: String, tar: Data, to path: String) async throws

    func createVolume(_ name: String, labels: [String: String]) async throws
    func removeVolume(_ name: String) async throws

    /// Runs a command with raw stdin/stdout (no TTY), for piping bytes such as a forwarded port.
    func openStream(_ id: String, _ spec: ExecSpec) async throws -> any TerminalSession

    /// CPU and memory the container uses now; nil when the runtime can't tell.
    func usage(_ id: String) async throws -> ResourceUsage?
}

/// What running a project's compose services needs beyond a plain container runtime.
public protocol ServiceRuntime: ContainerRuntime {
    /// Pulls `ref` on the host (outside any task's network policy) unless it's already there.
    func pullImage(_ ref: String, progress: @escaping @Sendable (String) -> Void) async throws
    /// TCP ports the image declares with EXPOSE.
    func exposedPorts(image: String) async throws -> [Int]
    /// "healthy", "unhealthy", "starting", or nil when the container has no healthcheck.
    func health(_ id: String) async throws -> String?
    func logs(_ id: String, tail: Int) async throws -> String
    func restart(_ id: String) async throws
}

/// A compose-style healthcheck.
public struct HealthcheckSpec: Codable, Sendable, Equatable {
    /// `["CMD", ...]`, `["CMD-SHELL", "..."]` or `["NONE"]`.
    public var test: [String]
    public var interval: Duration?
    public var timeout: Duration?
    public var retries: Int?
    public var startPeriod: Duration?

    public init(test: [String], interval: Duration? = nil, timeout: Duration? = nil, retries: Int? = nil, startPeriod: Duration? = nil) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }
}

public enum RuntimeAvailability: Sendable, Equatable {
    case available(version: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum ContainerState: Sendable, Equatable {
    case running
    case stopped(exitCode: Int?)
    case missing
}

public struct ContainerSpec: Codable, Sendable, Equatable {
    public var name: String
    public var image: String
    public var labels: [String: String]
    public var mounts: [MountSpec]
    public var environment: [String: String]
    public var command: [String]
    public var user: String?
    public var workdir: String?
    public var capAdd: [String]
    public var resources: ResourceLimits
    // Used by compose services. Optional so specs saved by older builds still decode.
    /// e.g. `container:<agent container>` to share its network namespace.
    public var networkMode: String?
    /// `name:ip` entries added to /etc/hosts.
    public var extraHosts: [String]?
    public var entrypoint: [String]?
    public var healthcheck: HealthcheckSpec?
    /// Container path to mount options, e.g. `["/tmp": "size=64m"]`.
    public var tmpfs: [String: String]?

    public init(
        name: String,
        image: String,
        labels: [String: String] = [:],
        mounts: [MountSpec] = [],
        environment: [String: String] = [:],
        command: [String] = [],
        user: String? = nil,
        workdir: String? = nil,
        capAdd: [String] = [],
        resources: ResourceLimits = .default,
        networkMode: String? = nil,
        extraHosts: [String]? = nil,
        entrypoint: [String]? = nil,
        healthcheck: HealthcheckSpec? = nil,
        tmpfs: [String: String]? = nil
    ) {
        self.name = name
        self.image = image
        self.labels = labels
        self.mounts = mounts
        self.environment = environment
        self.command = command
        self.user = user
        self.workdir = workdir
        self.capAdd = capAdd
        self.resources = resources
        self.networkMode = networkMode
        self.extraHosts = extraHosts
        self.entrypoint = entrypoint
        self.healthcheck = healthcheck
        self.tmpfs = tmpfs
    }
}

public enum MountSpec: Codable, Sendable, Equatable {
    case bind(hostPath: String, containerPath: String, readOnly: Bool = false)
    case volume(name: String, containerPath: String)

    public var containerPath: String {
        switch self {
        case .bind(_, let path, _), .volume(_, let path): path
        }
    }
}

public struct ExecSpec: Sendable, Equatable {
    public var command: [String]
    public var user: String?
    public var workdir: String?
    public var environment: [String: String]

    public init(_ command: [String], user: String? = nil, workdir: String? = nil, environment: [String: String] = [:]) {
        self.command = command
        self.user = user
        self.workdir = workdir
        self.environment = environment
    }

    /// Where root looks up commands. The image's own PATH starts with the agent's mise
    /// shims, which the agent can write: a root command found there would run its code.
    public static let rootPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// True when the command runs as root (no user means the container's default, root).
    public var runsAsRoot: Bool { user == nil || user == "root" || user == "0" || user?.hasPrefix("0:") == true }

    /// The environment to pass: root always gets `rootPath`.
    public var resolvedEnvironment: [String: String] {
        guard runsAsRoot else { return environment }
        var env = environment
        env["PATH"] = Self.rootPath
        return env
    }
}

public struct ExecResult: Sendable {
    public var exitCode: Int
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

public struct ExecError: Error, CustomStringConvertible {
    public var command: [String]
    public var result: ExecResult
    public init(command: [String], result: ExecResult) {
        self.command = command
        self.result = result
    }
    public var description: String {
        "\(command.joined(separator: " ")) exited \(result.exitCode): \(result.errorOutput.isEmpty ? result.output : result.errorOutput)"
    }
}

extension ContainerRuntime {
    /// `exec` that throws on non-zero exit.
    @discardableResult
    public func run(_ id: String, _ spec: ExecSpec) async throws -> ExecResult {
        let result = try await exec(id, spec)
        guard result.exitCode == 0 else { throw ExecError(command: spec.command, result: result) }
        return result
    }
}

public struct TerminalSize: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// A live pseudo-terminal connection into a container.
/// What a container uses right now.
public struct ResourceUsage: Codable, Hashable, Sendable {
    /// Of one core: 250 means two and a half cores busy.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(cpuPercent: Double, memoryBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    public var memoryMB: Int { Int(memoryBytes / 1_048_576) }
}

public protocol TerminalSession: AnyObject, Sendable {
    /// Bytes produced by the terminal. Finishes when the session ends.
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(_ size: TerminalSize) async throws
    func close() async
}

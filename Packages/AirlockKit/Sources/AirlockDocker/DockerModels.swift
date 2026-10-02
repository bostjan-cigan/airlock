import AirlockRuntime
import Foundation

// Request and response bodies for the Docker Engine API. Property names match
// the API's PascalCase keys so they encode without CodingKeys.

struct CreateContainerRequest: Encodable, Equatable {
    var Image: String
    var Cmd: [String]?
    var Entrypoint: [String]?
    var Healthcheck: Health?
    var Env: [String]?
    var User: String?
    var WorkingDir: String?
    var Labels: [String: String]
    var Tty: Bool = false
    var HostConfig: Host

    struct Host: Encodable, Equatable {
        var Mounts: [MountItem]
        var CapAdd: [String]?
        var SecurityOpt: [String]
        var NanoCpus: Int64
        var Memory: Int64
        var Init: Bool
        var NetworkMode: String?
        var ExtraHosts: [String]?
        var Tmpfs: [String: String]?
    }

    /// Durations are in nanoseconds.
    struct Health: Encodable, Equatable {
        var Test: [String]
        var Interval: Int64?
        var Timeout: Int64?
        var Retries: Int?
        var StartPeriod: Int64?
    }

    struct MountItem: Encodable, Equatable {
        var `Type`: String
        var Source: String
        var Target: String
        var ReadOnly: Bool
    }

    init(_ spec: ContainerSpec) {
        Image = spec.image
        Cmd = spec.command.isEmpty ? nil : spec.command
        Entrypoint = spec.entrypoint
        Healthcheck = spec.healthcheck.map { h in
            func ns(_ d: Duration?) -> Int64? { d.map { $0.components.seconds * 1_000_000_000 + $0.components.attoseconds / 1_000_000_000 } }
            return Health(Test: h.test, Interval: ns(h.interval), Timeout: ns(h.timeout), Retries: h.retries, StartPeriod: ns(h.startPeriod))
        }
        Env = spec.environment.isEmpty ? nil : spec.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        User = spec.user
        WorkingDir = spec.workdir
        Labels = spec.labels
        self.HostConfig = Host(
            Mounts: spec.mounts.map { mount in
                switch mount {
                case .bind(let host, let target, let ro): MountItem(Type: "bind", Source: host, Target: target, ReadOnly: ro)
                case .volume(let name, let target): MountItem(Type: "volume", Source: name, Target: target, ReadOnly: false)
                }
            },
            CapAdd: spec.capAdd.isEmpty ? nil : spec.capAdd,
            // Nothing in the container may gain privileges via setuid or file capabilities.
            SecurityOpt: ["no-new-privileges"],
            NanoCpus: Int64(spec.resources.cpus) * 1_000_000_000,
            Memory: Int64(spec.resources.memoryMB) * 1024 * 1024,
            Init: true,
            NetworkMode: spec.networkMode,
            ExtraHosts: spec.extraHosts,
            Tmpfs: spec.tmpfs
        )
    }
}

struct CreateResponse: Decodable { var Id: String }

struct ExecCreateRequest: Encodable {
    var AttachStdin: Bool
    var AttachStdout = true
    var AttachStderr = true
    var Tty: Bool
    var Cmd: [String]
    var Env: [String]?
    var User: String?
    var WorkingDir: String?
    var ConsoleSize: [Int]?

    init(_ spec: ExecSpec, tty: Bool, size: TerminalSize? = nil, stdin: Bool? = nil) {
        AttachStdin = stdin ?? tty
        Tty = tty
        Cmd = spec.command
        let env = spec.resolvedEnvironment
        Env = env.isEmpty ? nil : env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        User = spec.user
        WorkingDir = spec.workdir
        ConsoleSize = size.map { [$0.rows, $0.cols] }
    }
}

struct ExecStartRequest: Encodable {
    var Detach = false
    var Tty: Bool
    var ConsoleSize: [Int]?
}

struct ExecInspect: Decodable {
    var Running: Bool
    var ExitCode: Int?
}

struct ContainerInspect: Decodable {
    struct State: Decodable {
        struct Health: Decodable { var Status: String }
        var Running: Bool
        var ExitCode: Int?
        var Health: Health?
    }
    var Id: String
    var State: State
}

struct ImageInspect: Decodable {
    struct Config: Decodable { var ExposedPorts: [String: [String: String]]? }
    var Config: Config?
}

struct VersionResponse: Decodable {
    var Version: String
    var ApiVersion: String
}

struct BuildMessage: Decodable {
    struct ErrorDetail: Decodable { var message: String? }
    var stream: String?
    var status: String?
    var error: String?
    var errorDetail: ErrorDetail?
}

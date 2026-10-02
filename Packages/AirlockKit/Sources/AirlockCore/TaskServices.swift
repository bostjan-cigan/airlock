import Foundation

/// A project's compose services running next to the agent, sharing its network.
public struct TaskServices: Codable, Hashable, Sendable {
    /// The compose file the services came from, relative to the repository root.
    public var composeFile: String?
    public var items: [ServiceInstance]
    /// Services that weren't started, with the reason (e.g. "built from the repo").
    public var skipped: [String: String]

    public init(composeFile: String?, items: [ServiceInstance] = [], skipped: [String: String] = [:]) {
        self.composeFile = composeFile
        self.items = items
        self.skipped = skipped
    }

    public var hasFailure: Bool { items.contains { if case .failed = $0.state { true } else { false } } }
}

public struct ServiceInstance: Codable, Hashable, Sendable, Identifiable {
    public enum State: Codable, Hashable, Sendable {
        case pending, pulling, starting, healthy, running, stopped
        case failed(String)

        public var title: String {
            switch self {
            case .pending: "Waiting"
            case .pulling: "Pulling image"
            case .starting: "Starting"
            case .healthy: "Healthy"
            case .running: "Running"
            case .stopped: "Stopped"
            case .failed(let reason): "Failed: \(reason)"
            }
        }

        public var isUp: Bool { self == .healthy || self == .running }
    }

    /// The compose service name; also its hostname inside the task.
    public var name: String
    public var image: String
    public var containerID: String?
    public var state: State
    /// Ports it listens on inside the task (from compose and the image).
    public var ports: [Int]
    /// Per-task volumes it uses.
    public var volumes: [String]
    /// What AIrlock removed from its compose definition, in plain words.
    public var dropped: [String]
    public var startedAt: Date?

    public init(name: String, image: String, containerID: String? = nil, state: State = .pending,
                ports: [Int] = [], volumes: [String] = [], dropped: [String] = [], startedAt: Date? = nil) {
        self.name = name
        self.image = image
        self.containerID = containerID
        self.state = state
        self.ports = ports
        self.volumes = volumes
        self.dropped = dropped
        self.startedAt = startedAt
    }

    public var id: String { name }

    /// "db:5432", or just the name when no port is known.
    public var address: String { ports.first.map { "\(name):\($0)" } ?? name }
}

/// A port inside the task forwarded to localhost on the Mac.
public struct PortForward: Codable, Hashable, Sendable, Identifiable {
    public var containerPort: Int
    public var hostPort: Int
    /// The service it belongs to, when it was exposed by service name.
    public var service: String?

    public init(containerPort: Int, hostPort: Int, service: String? = nil) {
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.service = service
    }

    public var id: Int { containerPort }
    public var url: String { "http://localhost:\(hostPort)" }
    public var label: String { service.map { "\($0) \(containerPort)" } ?? "\(containerPort)" }
}

import AirlockCore
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// A self-contained, serializable view of a task for the plugin and other clients.
public struct TaskSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var shortID: String
    public var title: String
    public var repoPath: String
    public var branch: String
    public var runtime: String
    public var workspace: String
    public var network: String
    public var startedFrom: String
    public var project: String
    public var tags: [String]
    /// Access beyond the default sandbox, e.g. "Open network". Empty for the default.
    public var access: [String]
    public var services: [ServiceSnapshot]
    public var skippedServices: [String: String]
    /// A compose file in the repository when services weren't requested.
    public var composeFile: String?
    public var ports: [PortForward]
    /// Restricted network only: hosts this task may reach beyond the agent's built-in ones.
    public var allowedHosts: [String]
    /// Hosts the agent was refused that the user hasn't allowed or declined yet.
    public var blockedHosts: [BlockedHost]
    /// "4 CPU · 8 GB (auto, Rust)".
    public var resources: String?
    /// What each container uses right now: "agent 1.2 GB, 35% CPU".
    public var usage: [String]
    /// Detected tools, e.g. "Python 3.12 · Go 1.22", and anything the user should know.
    public var tools: String?
    public var notices: [String]
    /// `starting`, `working`, `needs_input`, `ready`, `failed`, `exited`, `stopped`, `done`.
    public var status: String
    public var statusDetail: String?
    /// The latest progress step the agent reported in this turn.
    public var milestone: String?
    /// Everything the agent said at the end of its last turn (untrusted text).
    public var lastAgentMessage: String?
    /// Set for an inspection: where it stands and, once it has run, its report.
    public var inspection: Inspection?
    /// Set for a sealed task: its setup and what its install scripts did.
    public var sealing: Sealing?
    public var lastEventID: Int
    public var recentActivity: [String]
    public var updatedAt: Date

    public init(
        id: String, shortID: String, title: String, repoPath: String, branch: String, runtime: String,
        workspace: String, network: String, startedFrom: String, project: String, tags: [String], access: [String] = [],
        services: [ServiceSnapshot] = [], skippedServices: [String: String] = [:], composeFile: String? = nil, ports: [PortForward] = [],
        allowedHosts: [String] = [], blockedHosts: [BlockedHost] = [], resources: String? = nil, usage: [String] = [],
        tools: String? = nil, notices: [String] = [],
        status: String, statusDetail: String?, milestone: String?,
        lastAgentMessage: String?, inspection: Inspection? = nil, sealing: Sealing? = nil, lastEventID: Int, recentActivity: [String], updatedAt: Date
    ) {
        self.inspection = inspection
        self.sealing = sealing
        self.id = id
        self.shortID = shortID
        self.title = title
        self.repoPath = repoPath
        self.branch = branch
        self.runtime = runtime
        self.workspace = workspace
        self.network = network
        self.startedFrom = startedFrom
        self.project = project
        self.tags = tags
        self.access = access
        self.services = services
        self.skippedServices = skippedServices
        self.composeFile = composeFile
        self.ports = ports
        self.allowedHosts = allowedHosts
        self.blockedHosts = blockedHosts
        self.resources = resources
        self.usage = usage
        self.tools = tools
        self.notices = notices
        self.status = status
        self.statusDetail = statusDetail
        self.milestone = milestone
        self.lastAgentMessage = lastAgentMessage
        self.lastEventID = lastEventID
        self.recentActivity = recentActivity
        self.updatedAt = updatedAt
    }
}

public struct ServiceSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var image: String
    public var state: String
    public var address: String
    public var dropped: [String]
}

/// What `AIrlock --watch` prints from: changes since the last poll.
public struct TaskProgress: Codable, Sendable, Equatable {
    public var status: String
    public var detail: String?
    public var milestones: [String]
    /// Ports forwarded to localhost right now, as "3000 → http://localhost:3000".
    public var ports: [String]
    /// Hosts the agent was refused and nobody has decided on yet.
    public var blocked: [String]
    public var lastEventID: Int
    /// The agent's turn is over (finished, asking, failed, stopped or exited).
    public var ended: Bool
    /// An inspection's current step ("Network closed"); nil for other tasks.
    public var inspectionPhase: String?
    /// A sealed task's setup step, then "Setup done".
    public var setupPhase: String?

    public init(status: String, detail: String?, milestones: [String], ports: [String] = [], blocked: [String] = [], lastEventID: Int, ended: Bool,
                inspectionPhase: String? = nil, setupPhase: String? = nil) {
        self.inspectionPhase = inspectionPhase
        self.setupPhase = setupPhase
        self.blocked = blocked
        self.status = status
        self.detail = detail
        self.milestones = milestones
        self.ports = ports
        self.lastEventID = lastEventID
        self.ended = ended
    }
}

extension TaskEngine {
    public func snapshot(_ id: UUID, includeMessage: Bool = true) -> TaskSnapshot? {
        guard let task = task(id) else { return nil }
        let list = events(for: id)
        let provider = Providers.provider(for: task.providerID)
        var message: String?
        if includeMessage, let transcript = list.last(where: { $0.transcriptPath != nil })?.transcriptPath {
            message = provider.flatMap { lastAgentMessage(id, transcript: transcript, provider: $0) }
        }
        return TaskSnapshot(
            id: task.id.uuidString,
            shortID: task.shortID,
            title: task.title,
            repoPath: task.repo.path,
            branch: task.workspace.branch,
            runtime: task.runtime.rawValue,
            workspace: (task.workspace.mode == .worktree ? "worktree (\(task.workspace.hostPath ?? "pending"))" : "isolated clone")
                + (task.repo.isPlainFolder ? " of a plain folder (not a git repository); its work is applied to the folder's files" : ""),
            network: task.isSealed ? "sealed" : task.network.displayName.lowercased(),
            startedFrom: task.origin?.isChat == true ? "chat" : "app",
            project: project(task.projectID)?.name ?? task.repo.name,
            tags: task.tags,
            access: task.permissions.filter(\.isElevated).map(\.title),
            services: (task.services?.items ?? []).map {
                ServiceSnapshot(name: $0.name, image: $0.image, state: $0.state.title, address: $0.address, dropped: $0.dropped)
            },
            skippedServices: task.services?.skipped ?? [:],
            composeFile: task.services == nil ? ComposeServices.detect(in: URL(fileURLWithPath: task.repo.path)) : nil,
            ports: task.ports,
            allowedHosts: { if case .restricted(let extra) = task.network { extra } else { [] } }(),
            blockedHosts: task.blockedHosts,
            resources: task.resources.summary + (task.resourceReason.map { " (\($0))" } ?? ""),
            usage: usage(for: id).sorted { $0.key == "agent" || ($1.key != "agent" && $0.key < $1.key) }.map {
                "\($0.key) \(ResourcePlanner.gigabytes($0.value.memoryMB)), \(Int($0.value.cpuPercent.rounded()))% CPU"
            },
            tools: task.stack?.summary,
            notices: (task.stack?.notices ?? []) + task.setupNotes,
            status: task.status.rawValue,
            statusDetail: task.statusDetail,
            milestone: list.currentMilestone,
            lastAgentMessage: message,
            inspection: task.inspection,
            sealing: task.sealing,
            lastEventID: list.last?.id ?? -1,
            recentActivity: list.suffix(8).map { "\($0.timestamp.formatted(date: .omitted, time: .standard)) \($0.summary)" },
            updatedAt: task.lastActivityAt ?? task.updatedAt
        )
    }

    public func snapshots(repoPath: String? = nil, projectID: UUID? = nil, tag: String? = nil) -> [TaskSnapshot] {
        let tag = tag.flatMap(Tag.normalize)
        return allTasks()
            .filter { repoPath == nil || $0.repo.path == repoPath }
            .filter { projectID == nil || $0.projectID == projectID }
            .filter { tag == nil || $0.tags.contains(tag!) }
            .sorted { ($0.lastActivityAt ?? $0.updatedAt) > ($1.lastActivityAt ?? $1.updatedAt) }
            .compactMap { snapshot($0.id, includeMessage: false) }
    }

    /// Finds a task by full UUID or by a unique prefix of its short ID.
    public func resolveTaskID(_ text: String) -> UUID? {
        if let id = UUID(uuidString: text), task(id) != nil { return id }
        let needle = text.lowercased()
        let matches = allTasks().filter { $0.shortID.hasPrefix(needle) || $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Blocks until the agent stops working (finished its turn, asks something,
    /// stopped or failed) after `afterEventID`, or until `timeout` passes.
    public func waitForUpdate(_ id: UUID, afterEventID: Int?, timeout: Duration) async -> TaskSnapshot? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let task = task(id) else { return nil }
            let lastEvent = events(for: id).last?.id ?? -1
            let isNew = afterEventID.map { lastEvent > $0 } ?? true
            if let phase = task.inspection?.phase, phase == .finished || phase == .failed { return snapshot(id) }
            switch task.status {
            case .failed, .stopped, .exited, .done: return snapshot(id)
            case .needsInput, .ready: if isNew { return snapshot(id) }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return snapshot(id)
    }

    /// Types a message into the agent's session as if the user had sent it.
    public func sendMessage(_ id: UUID, _ text: String) async throws {
        guard let task = task(id), let containerID = task.containerID, task.lifecycle == .running,
              let runtime = runtime(task.runtime) else {
            throw EngineError("The task isn't running. Start it first.")
        }
        let user = ContainerPaths.user
        let session = ContainerPaths.tmuxSession
        // Bracketed paste keeps multi-line messages together; Enter submits.
        try await runtime.run(containerID, ExecSpec(["tmux", "set-buffer", "-b", "airlock-message", "--", text], user: user))
        try await runtime.run(containerID, ExecSpec(["tmux", "paste-buffer", "-p", "-d", "-b", "airlock-message", "-t", session], user: user))
        try await Task.sleep(for: .milliseconds(300))
        try await runtime.run(containerID, ExecSpec(["tmux", "send-keys", "-t", session, "Enter"], user: user))
        markWorking(id)
    }

    /// New milestones since `afterEventID`, the current status, and whether the turn is over.
    public func progress(_ id: UUID, after afterEventID: Int?) -> TaskProgress? {
        guard let task = task(id) else { return nil }
        let list = events(for: id)
        let after = afterEventID ?? -1
        let fresh = list.filter { $0.id > after }
        let inspectionEnded = task.inspection.map { [.finished, .failed].contains($0.phase) } ?? false
        let turnEnded: Bool = switch task.status {
        case .failed, .stopped, .exited, .done: true
        // A finished turn or a question counts once the event behind it is new to the caller.
        case .ready: fresh.contains { $0.kind == .stop } || afterEventID == nil
        case .needsInput: fresh.contains { $0.kind == .notification || $0.kind == .stop } || afterEventID == nil
        default: false
        }
        let ended = inspectionEnded || turnEnded
        return TaskProgress(
            status: task.status.rawValue,
            detail: task.statusDetail,
            milestones: fresh.compactMap(\.milestone),
            ports: task.ports.map { "\($0.label) → \($0.url)" },
            blocked: task.blockedHosts.map(\.name),
            lastEventID: list.last?.id ?? after,
            ended: ended,
            inspectionPhase: task.inspection?.phase.title,
            setupPhase: task.sealing?.report == nil ? task.sealing?.phase.title : (task.sealing.map { _ in "Setup done" })
        )
    }
}

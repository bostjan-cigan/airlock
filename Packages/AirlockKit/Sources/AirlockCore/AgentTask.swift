import Foundation

/// One unit of work: an agent running in its own container against one repository.
public struct AgentTask: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var repo: RepoRef
    public var providerID: ProviderID
    public var runtime: RuntimeKind
    public var workspace: WorkspaceSpec
    public var network: NetworkProfile
    public var resources: ResourceLimits
    public var environmentID: String?
    /// Where the task was started. Nil for tasks saved before origins existed.
    public var origin: TaskOrigin?
    /// Project the task belongs to. Nil only until the engine assigns the repo's default project.
    public var projectID: UUID?
    /// Normalized labels (see `Tag.normalize`).
    public var tags: [String]
    /// What the agent was given at its last launch. Nil until then.
    public var access: TaskAccess?
    /// Explicit opt-in: the agent gets the GitHub token (if one is set) and network access to
    /// GitHub. Off by default: agents commit locally, and pushing is left to the user.
    public var githubAccess: Bool
    /// Hosts the agent tried to reach on a restricted network that nobody has allowed or
    /// declined yet. A finished turn with any of these needs the user.
    public var blockedHosts: [BlockedHost]
    /// Blocked hosts the user declined; they aren't reported again.
    public var ignoredHosts: [String]
    /// What the repository was detected to need at the last launch. Nil until then.
    public var stack: ProjectStack?
    /// Why `resources` are what they are: "auto, Rust", "set for this task", "project default".
    public var resourceReason: String?
    /// Things that didn't fully work when the workspace was set up (submodules, LFS files).
    public var setupNotes: [String]
    /// Compose services requested for this task; nil when none were.
    public var services: TaskServices?
    /// Ports forwarded to localhost on the Mac.
    public var ports: [PortForward]
    /// Set for a task that inspects an untrusted repository instead of working on one.
    public var inspection: Inspection?
    /// Set for a coding task whose network closes before dependency code runs.
    public var sealing: Sealing?
    /// The last time its work was handed off to the user's repository (or folder).
    public var handoff: Handoff?

    public var imageRef: String?
    public var containerID: String?

    public var lifecycle: Lifecycle
    public var activity: Activity
    public var isDone: Bool

    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivityAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        repo: RepoRef,
        providerID: ProviderID = .claudeCode,
        runtime: RuntimeKind = .docker,
        workspace: WorkspaceSpec,
        network: NetworkProfile = .restricted(extraDomains: []),
        resources: ResourceLimits = .default,
        environmentID: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.repo = repo
        self.providerID = providerID
        self.runtime = runtime
        self.workspace = workspace
        self.network = network
        self.resources = resources
        self.environmentID = environmentID
        self.tags = []
        self.githubAccess = false
        self.blockedHosts = []
        self.ignoredHosts = []
        self.setupNotes = []
        self.ports = []
        self.lifecycle = .provisioning
        self.activity = .unknown
        self.isDone = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Short, filesystem- and container-name-safe identifier.
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    public var containerName: String { "airlock-\(shortID)" }

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, repo, providerID, runtime, workspace, network, resources, environmentID, origin
        case projectID, tags, access, githubAccess, blockedHosts, ignoredHosts, stack, resourceReason, setupNotes, services, ports, inspection, sealing, handoff, imageRef, containerID, lifecycle, activity, isDone, createdAt, updatedAt, lastActivityAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        prompt = try c.decode(String.self, forKey: .prompt)
        repo = try c.decode(RepoRef.self, forKey: .repo)
        providerID = try c.decode(ProviderID.self, forKey: .providerID)
        runtime = try c.decode(RuntimeKind.self, forKey: .runtime)
        workspace = try c.decode(WorkspaceSpec.self, forKey: .workspace)
        network = try c.decode(NetworkProfile.self, forKey: .network)
        resources = try c.decode(ResourceLimits.self, forKey: .resources)
        environmentID = try c.decodeIfPresent(String.self, forKey: .environmentID)
        origin = try c.decodeIfPresent(TaskOrigin.self, forKey: .origin)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        access = try? c.decodeIfPresent(TaskAccess.self, forKey: .access)
        githubAccess = try c.decodeIfPresent(Bool.self, forKey: .githubAccess) ?? false
        blockedHosts = (try? c.decodeIfPresent([BlockedHost].self, forKey: .blockedHosts)) ?? []
        ignoredHosts = (try? c.decodeIfPresent([String].self, forKey: .ignoredHosts)) ?? []
        stack = try? c.decodeIfPresent(ProjectStack.self, forKey: .stack)
        resourceReason = try? c.decodeIfPresent(String.self, forKey: .resourceReason)
        setupNotes = (try? c.decodeIfPresent([String].self, forKey: .setupNotes)) ?? []
        services = try? c.decodeIfPresent(TaskServices.self, forKey: .services)
        ports = (try? c.decodeIfPresent([PortForward].self, forKey: .ports)) ?? []
        inspection = try? c.decodeIfPresent(Inspection.self, forKey: .inspection)
        sealing = try? c.decodeIfPresent(Sealing.self, forKey: .sealing)
        handoff = try? c.decodeIfPresent(Handoff.self, forKey: .handoff)
        imageRef = try c.decodeIfPresent(String.self, forKey: .imageRef)
        containerID = try c.decodeIfPresent(String.self, forKey: .containerID)
        lifecycle = try c.decode(Lifecycle.self, forKey: .lifecycle)
        activity = (try? c.decode(Activity.self, forKey: .activity)) ?? .unknown
        isDone = try c.decode(Bool.self, forKey: .isDone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
    }
}

/// Credentials handed to the agent when it last started.
public struct TaskAccess: Codable, Hashable, Sendable {
    public enum Credential: String, Codable, Hashable, Sendable {
        /// Long-lived Claude subscription token.
        case claudeToken
        /// Anthropic API key, billed per use.
        case apiKey
    }

    public var credential: Credential?
    /// A GitHub token was passed as `GH_TOKEN`.
    public var github: Bool

    public init(credential: Credential?, github: Bool) {
        self.credential = credential
        self.github = github
    }
}

public enum Tag {
    /// Lowercase, trimmed, inner whitespace turned into `-`; empty tags are dropped.
    public static func normalize(_ tag: String) -> String? {
        let parts = tag.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
        let joined = parts.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "#-"))
        return joined.isEmpty ? nil : String(joined.prefix(40))
    }

    /// Applies additions and removals, keeping order and dropping duplicates.
    public static func apply(_ tags: [String], add: [String], remove: [String]) -> [String] {
        let removing = Set(remove.compactMap(normalize))
        var out: [String] = []
        for tag in tags + add.compactMap(normalize) where !removing.contains(tag) && !out.contains(tag) {
            out.append(tag)
        }
        return out
    }
}

public enum TaskOrigin: Codable, Hashable, Sendable {
    /// Started from the New Task sheet.
    case app
    /// Handed off from a Claude chat through the AIrlock plugin.
    case chat(label: String?)

    public var isChat: Bool {
        if case .chat = self { return true }
        return false
    }
}

public struct RepoRef: Codable, Hashable, Sendable {
    /// Absolute path to the repository root on the host.
    public var path: String
    public var remoteURL: String?
    /// Branch, tag or commit the task starts from.
    public var baseRef: String
    /// A folder that wasn't a git repository: AIrlock manages a temporary one in it and
    /// applies the task's result to the folder's files. Absent in records of git repositories.
    public var plainFolder: Bool?

    public init(path: String, remoteURL: String? = nil, baseRef: String, plainFolder: Bool = false) {
        self.path = path
        self.remoteURL = remoteURL
        self.baseRef = baseRef
        self.plainFolder = plainFolder ? true : nil
    }

    public var isPlainFolder: Bool { plainFolder == true }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let claudeCode: ProviderID = "claude-code"
}

public enum RuntimeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case docker
    case apple

    /// UserDefaults key for the runtime new tasks use (Settings › Runtimes).
    public static let defaultsKey = "defaultRuntime"

    /// The runtime chosen in Settings, Docker if none was.
    public static var savedDefault: RuntimeKind {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(RuntimeKind.init) ?? .docker
    }

    public var displayName: String {
        switch self {
        case .docker: "Docker"
        case .apple: "Apple VM"
        }
    }
}

public struct WorkspaceSpec: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Git worktree on the host, bind-mounted into the container.
        case worktree
        /// Repository cloned into a container-owned volume; the host checkout is never touched.
        case volumeClone

        public var displayName: String {
            switch self {
            case .worktree: "Git worktree"
            case .volumeClone: "Isolated clone"
            }
        }
    }

    public var mode: Mode
    /// Branch the agent works on, e.g. `airlock/fix-login`.
    public var branch: String
    /// Commit `baseRef` resolved to when the task was created; diffs are taken against it.
    public var baseCommit: String?
    /// Worktree mode: host path of the worktree.
    public var hostPath: String?
    /// Volume-clone mode: name of the volume holding the clone.
    public var volumeName: String?
    /// Worktree mode: the checkout is a repository of its own (refs and config apart from the
    /// user's, objects borrowed read-only), so the agent can't move the user's branches.
    /// Nil for tasks made before, which share the user's repository through `git worktree`.
    public var ownRepository: Bool?
    /// A base-branch commit the agent was asked to merge; once it's in the task branch it
    /// becomes `baseCommit`, so the diff shows only the task's own changes again.
    public var pendingBase: String?

    public init(mode: Mode, branch: String, baseCommit: String? = nil, hostPath: String? = nil, volumeName: String? = nil) {
        self.mode = mode
        self.branch = branch
        self.baseCommit = baseCommit
        self.hostPath = hostPath
        self.volumeName = volumeName
    }
}

public enum NetworkProfile: Codable, Hashable, Sendable {
    /// Unrestricted outbound network.
    case open
    /// Outbound traffic limited to the provider's domains plus `extraDomains`.
    case restricted(extraDomains: [String])

    public var isRestricted: Bool {
        if case .restricted = self { return true }
        return false
    }

    public var displayName: String { isRestricted ? "Restricted" : "Open" }
}

public struct ResourceLimits: Codable, Hashable, Sendable {
    public var cpus: Int
    public var memoryMB: Int

    public init(cpus: Int, memoryMB: Int) {
        self.cpus = cpus
        self.memoryMB = memoryMB
    }

    public static let `default` = ResourceLimits(cpus: 2, memoryMB: 4096)
}

public enum Lifecycle: Codable, Hashable, Sendable {
    case provisioning
    case buildingImage
    case starting
    case running
    case stopped
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .provisioning, .buildingImage, .starting, .running: true
        case .stopped, .failed: false
        }
    }

    public var displayName: String {
        switch self {
        case .provisioning: "Preparing workspace"
        case .buildingImage: "Building image"
        case .starting: "Starting"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

public enum Activity: Codable, Hashable, Sendable {
    case unknown
    case working(tool: String?)
    /// The agent asked something or is waiting at its prompt.
    case needsInput(reason: String?)
    /// The agent finished its turn; its result is ready to review. Shown as "Ready".
    case idle(lastMessage: String?)
    /// An API error (credits, auth, rate limit) ended the turn.
    case error(reason: String)
    /// The agent process ended.
    case exited
}

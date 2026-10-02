import AirlockCore
import AirlockEngine
import Foundation

/// Requests the running app accepts on its control socket: one JSON object per
/// line, answered by one JSON object per line.
///
///     → {"id": 1, "method": "startTask", "params": {...}}
///     ← {"id": 1, "result": {...}}   or   {"id": 1, "error": "message"}
public enum ControlMethod: String, Codable, Sendable {
    case ping
    case startTask
    case listTasks
    case getTask
    case waitForTask
    case sendMessage
    case getChanges
    case bringBack
    case stopTask
    case startStoppedTask
    case watchTask
    case tagTask
    case listProjects
    case createProject
    case moveTask
    case exposePort
    case unexposePort
    case listPorts
    case serviceLogs
    case restartService
    case completeTask
    case allowDomains
    case updateFromBase
    case startInspection
    case reviewHandoff
    case handOff
}

public struct StartTaskParams: Codable, Sendable {
    public var repoPath: String
    public var prompt: String
    public var title: String?
    public var baseRef: String?
    public var runtime: String?
    public var workspace: String?
    public var network: String?
    public var extraDomains: [String]?
    /// Free-form label for where the hand-off came from (e.g. the chat's project).
    public var origin: String?
    /// AIrlock project, by name or id. Nil picks the repository's only or default project.
    public var project: String?
    public var tags: [String]?
    public var services: Bool?
    public var expose: [Int]?
    /// Explicit opt-in to the GitHub token and network access to GitHub.
    public var github: Bool?
    /// Container size; omitted sizes are chosen automatically.
    public var cpus: Int?
    public var memoryGB: Int?

    public init(repoPath: String, prompt: String, title: String? = nil, baseRef: String? = nil, runtime: String? = nil,
                workspace: String? = nil, network: String? = nil, extraDomains: [String]? = nil, origin: String? = nil,
                project: String? = nil, tags: [String]? = nil, services: Bool? = nil, expose: [Int]? = nil, github: Bool? = nil,
                cpus: Int? = nil, memoryGB: Int? = nil) {
        self.github = github
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.repoPath = repoPath
        self.prompt = prompt
        self.title = title
        self.baseRef = baseRef
        self.runtime = runtime
        self.workspace = workspace
        self.network = network
        self.extraDomains = extraDomains
        self.origin = origin
        self.project = project
        self.tags = tags
        self.services = services
        self.expose = expose
    }
}

public struct PortParams: Codable, Sendable {
    public var taskID: String
    public var port: Int?
    public var hostPort: Int?
    public var service: String?
    public init(taskID: String, port: Int?, hostPort: Int? = nil, service: String? = nil) {
        self.taskID = taskID
        self.port = port
        self.hostPort = hostPort
        self.service = service
    }
}

public struct ServiceParams: Codable, Sendable {
    public var taskID: String
    public var service: String
    public var tail: Int?
    public init(taskID: String, service: String, tail: Int? = nil) {
        self.taskID = taskID
        self.service = service
        self.tail = tail
    }
}

public struct PortsResult: Codable, Sendable {
    public var forwarded: [PortForward]
    /// Ports something listens on inside the task, or that services declare, not yet forwarded.
    public var suggestions: [Int]
    public init(forwarded: [PortForward], suggestions: [Int]) {
        self.forwarded = forwarded
        self.suggestions = suggestions
    }
}

/// Inspect an untrusted repository: `source` is an https URL (cloned inside the VM) or a folder.
public struct InspectionParams: Codable, Sendable {
    public var source: String
    public var command: String?
    public var investigate: Bool?
    public var runtime: String?
    public var origin: String?
    public init(source: String, command: String? = nil, investigate: Bool? = nil, runtime: String? = nil, origin: String? = nil) {
        self.source = source
        self.command = command
        self.investigate = investigate
        self.runtime = runtime
        self.origin = origin
    }
}

public struct CompleteParams: Codable, Sendable {
    public var taskID: String
    /// Also stop and delete the task's containers and workspace (the branch is kept).
    public var removeContainers: Bool?
    public init(taskID: String, removeContainers: Bool?) {
        self.taskID = taskID
        self.removeContainers = removeContainers
    }
}

public struct CompleteResult: Codable, Sendable {
    public var shortID: String
    public var title: String
    public var branch: String
    /// The task's containers, workspace and record were deleted.
    public var removed: Bool
    /// Isolated-clone commits were fetched into the user's repository before deleting.
    public var broughtBack: Bool
    /// The task works in an isolated clone (its commits live in the container until brought back).
    public var isolatedClone: Bool
    /// Files with uncommitted changes that deleting would lose; nil when unknown.
    public var uncommittedFiles: Int?
    /// The task works on a plain folder: removing it applies its work to the folder's files.
    public var plainFolder: Bool?
    /// Plain folder, after removal: what happened to the `.git` AIrlock created there.
    public var folderGit: String?
    public init(shortID: String, title: String, branch: String, removed: Bool, broughtBack: Bool,
                isolatedClone: Bool, uncommittedFiles: Int?, plainFolder: Bool? = nil, folderGit: String? = nil) {
        self.plainFolder = plainFolder
        self.folderGit = folderGit
        self.shortID = shortID
        self.title = title
        self.branch = branch
        self.removed = removed
        self.broughtBack = broughtBack
        self.isolatedClone = isolatedClone
        self.uncommittedFiles = uncommittedFiles
    }
}

public struct TaskParams: Codable, Sendable {
    public var taskID: String
    public init(taskID: String) { self.taskID = taskID }
}

public struct ListParams: Codable, Sendable {
    public var repoPath: String?
    /// Project name or id.
    public var project: String?
    public var tag: String?
    public init(repoPath: String?, project: String? = nil, tag: String? = nil) {
        self.repoPath = repoPath
        self.project = project
        self.tag = tag
    }
}

public struct WatchParams: Codable, Sendable {
    public var taskID: String
    public var afterEventID: Int?
    public init(taskID: String, afterEventID: Int?) {
        self.taskID = taskID
        self.afterEventID = afterEventID
    }
}

public struct TagParams: Codable, Sendable {
    public var taskID: String
    public var add: [String]?
    public var remove: [String]?
    public init(taskID: String, add: [String]?, remove: [String]?) {
        self.taskID = taskID
        self.add = add
        self.remove = remove
    }
}

public struct ProjectParams: Codable, Sendable {
    public var name: String?
    public var repoPath: String?
    /// create_project: hosts the project's restricted tasks may also reach.
    public var allowedHosts: [String]?
    public init(name: String?, repoPath: String?, allowedHosts: [String]? = nil) {
        self.name = name
        self.repoPath = repoPath
        self.allowedHosts = allowedHosts
    }
}

/// Changes a task's allowlist (live), a project's defaults, or both.
public struct AllowDomainsParams: Codable, Sendable {
    public var taskID: String?
    public var project: String?
    public var add: [String]?
    public var remove: [String]?
    public init(taskID: String?, project: String?, add: [String]?, remove: [String]?) {
        self.taskID = taskID
        self.project = project
        self.add = add
        self.remove = remove
    }
}

public struct AllowDomainsResult: Codable, Sendable {
    public var taskShortID: String?
    public var task: NetworkChange?
    public var project: String?
    public var projectHosts: [String]?
    public init(taskShortID: String? = nil, task: NetworkChange? = nil, project: String? = nil, projectHosts: [String]? = nil) {
        self.taskShortID = taskShortID
        self.task = task
        self.project = project
        self.projectHosts = projectHosts
    }
}

public struct MoveParams: Codable, Sendable {
    public var taskID: String
    public var project: String
    public init(taskID: String, project: String) {
        self.taskID = taskID
        self.project = project
    }
}

public struct ProjectSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var repoPath: String
    public var activeTasks: Int
    public var totalTasks: Int
    public var allowedHosts: [String]
    public init(id: String, name: String, repoPath: String, activeTasks: Int, totalTasks: Int, allowedHosts: [String] = []) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.activeTasks = activeTasks
        self.totalTasks = totalTasks
        self.allowedHosts = allowedHosts
    }
}

public struct WaitParams: Codable, Sendable {
    public var taskID: String
    public var afterEventID: Int?
    public var timeoutSeconds: Int?
    public init(taskID: String, afterEventID: Int?, timeoutSeconds: Int?) {
        self.taskID = taskID
        self.afterEventID = afterEventID
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct MessageParams: Codable, Sendable {
    public var taskID: String
    public var text: String
    public init(taskID: String, text: String) {
        self.taskID = taskID
        self.text = text
    }
}

public struct ChangesParams: Codable, Sendable {
    public var taskID: String
    public var includeDiff: Bool?
    public init(taskID: String, includeDiff: Bool?) {
        self.taskID = taskID
        self.includeDiff = includeDiff
    }
}

public struct ChangesResult: Codable, Sendable {
    public struct File: Codable, Sendable {
        public var path: String
        public var kind: String
        public var additions: Int?
        public var deletions: Int?
    }
    public var branch: String
    public var files: [File]
    public var commits: [String]
    public var diff: String?
}

public struct OK: Codable, Sendable {
    public var ok = true
    public var message: String?
    public init(message: String? = nil) { self.message = message }
}

struct RequestEnvelope<Params: Codable>: Codable {
    var id: Int
    var method: ControlMethod
    var params: Params?
}

struct MethodPeek: Decodable {
    var id: Int
    var method: ControlMethod
}

struct ResponseEnvelope<Result: Codable>: Codable {
    var id: Int
    var result: Result?
    var error: String?
}

enum ControlCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum ControlSocket {
    /// Lives next to the task data, so each data root has its own control socket.
    public static func path(for paths: Paths) -> String {
        paths.root.appending(path: "control.sock").path
    }
}

import Foundation

/// On-disk layout. Every task is one self-contained directory:
///
///     <root>/projects.json            named projects, each linked to a repository
///     <root>/managed-folders.json     plain folders whose temporary `.git` AIrlock created
///     <root>/tasks/<id>/task.json
///     <root>/tasks/<id>/events/        hook events written by the agent (mounted at /airlock/events)
///     <root>/tasks/<id>/agent-config/  the agent's home config (mounted at ~/.claude)
///     <root>/worktrees/<id>/           worktree-mode checkout
public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var `default`: Paths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(root: base.appending(path: "AIrlock", directoryHint: .isDirectory))
    }

    public var tasks: URL { root.appending(path: "tasks", directoryHint: .isDirectory) }
    public var worktrees: URL { root.appending(path: "worktrees", directoryHint: .isDirectory) }
    public var settings: URL { root.appending(path: "settings.json") }
    public var projects: URL { root.appending(path: "projects.json") }
    public var managedFolders: URL { root.appending(path: "managed-folders.json") }

    public func taskDir(_ id: UUID) -> URL { tasks.appending(path: id.uuidString, directoryHint: .isDirectory) }
    public func taskFile(_ id: UUID) -> URL { taskDir(id).appending(path: "task.json") }
    public func events(_ id: UUID) -> URL { taskDir(id).appending(path: "events", directoryHint: .isDirectory) }
    public func agentConfig(_ id: UUID) -> URL { taskDir(id).appending(path: "agent-config", directoryHint: .isDirectory) }
    public func worktree(_ id: UUID) -> URL { worktrees.appending(path: id.uuidString, directoryHint: .isDirectory) }
}

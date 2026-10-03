import AirlockCore
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// Nothing a task makes reaches the user's repository on its own. Its commits are copied into
/// a repository of AIrlock's own while it works (so they can be shown), and into the user's
/// repository only when the work is handed off: by the user in the app, or by the chat that
/// reviewed it with them, once they confirm in the app.
extension TaskEngine {
    /// AIrlock's copy of the task's commits: a bare repository AIrlock made, borrowing the
    /// user's objects for the base. Only bundles made in the container are fetched into it.
    func keptRepository(_ task: AgentTask) async throws -> URL {
        let dir = paths.taskDir(task.id).appending(path: "work.git", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.appending(path: "HEAD").path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await ProcessRunner.run("/usr/bin/git", ["init", "--bare", "--quiet", dir.path])
            let stores = await TaskRepository.objectStores(of: URL(fileURLWithPath: task.repo.path))
            try Data((stores.joined(separator: "\n") + "\n").utf8).write(to: dir.appending(path: "objects/info/alternates"))
        }
        return dir
    }

    /// The tip of the task branch in AIrlock's copy; nil before anything was copied.
    func keptTip(_ task: AgentTask) async -> String? {
        guard let kept = try? await keptRepository(task) else { return nil }
        return try? await HostGit(kept).run("rev-parse", "--verify", "--quiet", "refs/heads/\(task.workspace.branch)^{commit}")
    }

    /// Copies the running task's branch into AIrlock's copy.
    func keepWork(_ id: UUID) async throws {
        guard let task = tasks[id], task.containerID != nil, !task.isInspection,
              task.workspace.mode == .volumeClone || task.workspace.ownRepository == true else { return }
        let runtime = try runtime(for: task)
        try await Workspaces.provisioner(for: task, paths: paths, runtime: runtime, user: ContainerPaths.user)
            .bringBack(task, into: try await keptRepository(task))
    }

    /// Commits on the task branch that haven't been handed off yet.
    public func hasWorkToHandOff(_ id: UUID) async -> Bool {
        guard let task = tasks[id], !task.isInspection, let base = task.workspace.baseCommit else { return false }
        if await containerRunning(task) { try? await keepWork(id) }
        guard let tip = await keptTip(task) else { return false }
        return tip != base && tip != task.handoff?.commit
    }

    /// What handing off would bring out, for the user and the chat to review.
    public func handoffReview(_ id: UUID) async throws -> HandoffReview {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard !task.isInspection else { throw EngineError("Nothing comes out of an inspection: it only reports what happened inside.") }
        guard let base = task.workspace.baseCommit else { throw EngineError("The task hasn't started working yet.") }
        if await containerRunning(task) { try? await keepWork(id) }
        let changes: WorkspaceChanges
        if task.repo.isPlainFolder {
            // A folder gets everything, uncommitted changes included.
            changes = try await self.changes(id)
        } else {
            changes = try await GitInspector.committedChanges(in: HostGit(try await keptRepository(task)), branch: task.workspace.branch, since: base)
        }
        let tip = await keptTip(task)
        return HandoffReview(
            title: task.title, branch: task.workspace.branch,
            commits: changes.commits.map { UntrustedText.oneLine($0) },
            files: changes.files.count,
            additions: changes.files.compactMap(\.additions).reduce(0, +),
            deletions: changes.files.compactMap(\.deletions).reduce(0, +),
            attention: HandoffReview.attention(for: changes.files.map { UntrustedText.oneLine($0.path, limit: 300) }),
            setup: task.sealing?.report?.summary, setupFindings: task.sealing?.report?.findings ?? 0,
            uncommitted: task.repo.isPlainFolder ? nil : await uncommittedFileCount(id),
            nothingNew: !task.repo.isPlainFolder && (tip == nil || tip == base || tip == task.handoff?.commit),
            plainFolder: task.repo.isPlainFolder
        )
    }

    /// Brings the task's work into the user's repository as its branch (or, for a plain folder,
    /// into the folder's files). Callers have the user's agreement; the chat's path asks first.
    @discardableResult
    public func handOff(_ id: UUID) async throws -> Handoff {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard !task.isInspection else { throw EngineError("Nothing comes out of an inspection: it only reports what happened inside.") }
        guard let base = task.workspace.baseCommit else { throw EngineError("The task hasn't started working yet.") }
        let repo = URL(fileURLWithPath: task.repo.path)

        if task.repo.isPlainFolder {
            try await applyToFolder(id)
            let tip = (try? await HostGit(repo).run("rev-parse", "--verify", "--quiet", "refs/heads/\(task.workspace.branch)^{commit}")) ?? base
            return recordHandoff(id, tip)
        }

        // The latest commits first: a stopped container is started for a moment.
        if let containerID = task.containerID, let runtime = runtimes[task.runtime],
           (try? await runtime.state(containerID)).map({ $0 != .missing }) == true {
            try await withRunningContainer(id) { _ in try await self.keepWork(id) }
        }
        let kept = try await keptRepository(task)
        let ref = "refs/heads/\(task.workspace.branch)"
        guard let tip = await keptTip(task) else { throw EngineError("The task has no commits to hand off yet.") }
        // Without --force: a branch the user moved on in their repository is never overwritten.
        do {
            try await HostGit(repo).run("fetch", "--quiet", "--no-tags", kept.path, "\(ref):\(ref)")
        } catch {
            throw EngineError("""
            Couldn't hand off: \(task.workspace.branch) in your repository has commits the task's branch doesn't \
            (or the agent rewrote its history). Rename or delete that branch, then hand off again.
            """)
        }
        if task.workspace.mode == .worktree, let path = task.workspace.hostPath {
            await TaskRepository.copyLFSObjects(from: URL(fileURLWithPath: path), into: repo)
        }
        log(id, "Handed off \(task.workspace.branch) at \(tip.prefix(8))")
        return recordHandoff(id, tip)
    }

    private func recordHandoff(_ id: UUID, _ tip: String) -> Handoff {
        let handoff = Handoff(commit: tip)
        update(id) { $0.handoff = handoff }
        return handoff
    }
}

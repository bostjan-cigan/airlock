import AirlockCore
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// What `updateFromBase` did.
public enum BaseUpdate: Equatable, Sendable {
    case upToDate
    /// Merged into the task branch on the Mac; the count of new base commits.
    case merged(Int)
    /// The running agent was asked to merge (and resolve conflicts, run tests).
    case askedAgent(Int)
    /// A merge on the Mac hit conflicts and was undone.
    case conflict([String])
}

extension TaskEngine {
    /// How many commits the base branch gained since the task started (or last updated).
    public func baseUpdates(_ id: UUID) async -> Int {
        guard let task = tasks[id], !task.repo.isPlainFolder, !task.isInspection, let base = task.workspace.baseCommit else { return 0 }
        let repo = HostGit(URL(fileURLWithPath: task.repo.path))
        guard let tip = try? await repo.run("rev-parse", "--verify", "\(task.repo.baseRef)^{commit}"), tip != base,
              let count = try? await repo.run("rev-list", "--count", "\(base)..\(tip)") else { return 0 }
        return Int(count) ?? 0
    }

    /// Brings the base branch's new commits into the task. A running agent is asked to merge
    /// them, so it can resolve conflicts and re-run tests in context; otherwise AIrlock merges
    /// inside the (briefly started) container and undoes the merge if it conflicts. Git never
    /// runs in the task's repository from the Mac.
    @discardableResult
    public func updateFromBase(_ id: UUID) async throws -> BaseUpdate {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard !task.repo.isPlainFolder, !task.isInspection else { throw EngineError("This task has no base branch to update from.") }
        let count = await baseUpdates(id)
        guard count > 0 else { return .upToDate }
        let repo = HostGit(URL(fileURLWithPath: task.repo.path))
        let tip = try await repo.run("rev-parse", "--verify", "\(task.repo.baseRef)^{commit}")
        let runtime = try runtime(for: task)
        let running = task.lifecycle == .running

        return try await withRunningContainer(id) { task in
            let git = Workspaces.provisioner(for: task, paths: paths, runtime: runtime, user: ContainerPaths.user).git(task)
            if task.workspace.mode == .volumeClone, let containerID = task.containerID {
                try await copyBase(task, tip: tip, runtime: runtime, containerID: containerID)
            } else {
                // Its objects are borrowed from the user's repository, so a ref is all it takes.
                try await git.run("update-ref", "refs/airlock/base", tip)
            }

            if running {
                update(id) { $0.workspace.pendingBase = tip }
                try await sendMessage(id, """
                The base branch `\(task.repo.baseRef)` has \(count) new commit\(count == 1 ? "" : "s") (now at \(tip.prefix(10))). \
                Merge it into your branch with `git merge \(tip.prefix(10))`, resolve any conflicts, run the tests, then carry on.
                """)
                return .askedAgent(count)
            }

            let (status, _) = try await git.git(PlainFolder.commitConfig + ["merge", "--no-edit", "-m", "Merge \(task.repo.baseRef) into \(task.workspace.branch)", tip])
            if status != 0 {
                let conflicts = (try? await git.run("diff", "--name-only", "--diff-filter=U")) ?? ""
                _ = try? await git.run("merge", "--abort")
                return .conflict(conflicts.split(separator: "\n").map { UntrustedText.oneLine(String($0)) })
            }
            update(id) {
                $0.workspace.baseCommit = tip
                $0.workspace.pendingBase = nil
            }
            await syncTaskBranch(id)
            return .merged(count)
        }
    }

    /// Once the agent has merged the base commit it was asked to, diffs start from there.
    func settlePendingBase(_ id: UUID) async {
        guard let task = tasks[id], task.workspace.pendingBase != nil, await containerRunning(task),
              let pending = task.workspace.pendingBase, let runtime = runtimes[task.runtime] else { return }
        let git = Workspaces.provisioner(for: task, paths: paths, runtime: runtime, user: ContainerPaths.user).git(task)
        guard let (status, _) = try? await git.git(["merge-base", "--is-ancestor", pending, "HEAD"]), status == 0 else { return }
        update(id) {
            $0.workspace.baseCommit = pending
            $0.workspace.pendingBase = nil
        }
    }

    /// Puts the base branch's new commits into an isolated clone, as a bundle.
    private func copyBase(_ task: AgentTask, tip: String, runtime: any ContainerRuntime, containerID: String) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "airlock-\(task.shortID)-base")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let repo = HostGit(URL(fileURLWithPath: task.repo.path))
        try await repo.run("update-ref", "refs/airlock/base-\(task.shortID)", tip)
        defer { Task { try? await repo.run("update-ref", "-d", "refs/airlock/base-\(task.shortID)") } }
        try await repo.run("bundle", "create", staging.appending(path: "base.bundle").path,
                           "refs/airlock/base-\(task.shortID)", "^\(task.workspace.baseCommit ?? tip)")
        let tar = try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-c", "-f", "-", "-C", staging.path, "base.bundle"],
                                              environment: ["COPYFILE_DISABLE": "1"]).stdout
        try await runtime.copyIn(containerID, tar: tar, to: "/tmp")
        try await runtime.run(containerID, ExecSpec(["git", "-C", "/workspace", "fetch", "--quiet", "/tmp/base.bundle",
                                                     "+refs/airlock/base-\(task.shortID):refs/airlock/base"], user: ContainerPaths.user))
        _ = try? await runtime.exec(containerID, ExecSpec(["rm", "-f", "/tmp/base.bundle"], user: "root"))
    }
}

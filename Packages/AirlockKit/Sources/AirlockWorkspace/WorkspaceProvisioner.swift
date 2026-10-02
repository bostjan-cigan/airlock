import AirlockCore
import AirlockRuntime
import Foundation

/// Gets a task's code into its container and its changes back out.
public protocol WorkspaceProvisioner: Sendable {
    /// Host-side preparation before the container exists. Fills in the task's
    /// workspace details (branch, base commit, paths) and returns the mounts to add.
    func prepare(_ task: inout AgentTask) async throws -> [MountSpec]

    /// Container-side setup once the container is running.
    func populate(_ task: AgentTask, containerID: String) async throws

    /// Git access to the task's working tree.
    func git(_ task: AgentTask) -> any GitRunner

    /// Copies the task branch, as a bundle made in its container, into `repo`: AIrlock's own
    /// copy of the work, or (at handoff) the user's repository.
    func bringBack(_ task: AgentTask, into repo: URL) async throws

    /// Removes the workspace. The task branch in the host repository is kept.
    func cleanup(_ task: AgentTask) async throws
}

extension WorkspaceProvisioner {
    public func changes(_ task: AgentTask) async throws -> WorkspaceChanges {
        guard let base = task.workspace.baseCommit else { return .empty }
        return try await GitInspector.changes(git(task), since: base)
    }

    /// A patch of everything that changed since the base commit, untracked files included.
    public func exportPatch(_ task: AgentTask) async throws -> String {
        try await changes(task).diff
    }
}

public enum Workspaces {
    public static func provisioner(
        for task: AgentTask,
        paths: Paths,
        runtime: any ContainerRuntime,
        user: String
    ) -> any WorkspaceProvisioner {
        switch task.workspace.mode {
        case .worktree: WorktreeProvisioner(paths: paths, runtime: runtime, user: user)
        case .volumeClone: VolumeCloneProvisioner(runtime: runtime, user: user)
        }
    }

    /// `airlock/<slug-of-title>`, made unique against existing host branches.
    public static func branchName(for task: AgentTask, existing: Set<String>) -> String {
        let slug = task.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, c in if !(c == "-" && out.last == "-") { out.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        let base = "airlock/\(slug.isEmpty ? task.shortID : String(slug))"
        return existing.contains(base) ? "\(base)-\(task.shortID)" : base
    }

    /// Resolves symlinks the way the kernel does, keeping `/private` (unlike `URL.resolvingSymlinksInPath`).
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func resolveBase(_ repo: HostGit, _ task: inout AgentTask) async throws {
        if (try? await repo.run("rev-parse", "--verify", "HEAD")) == nil,
           (try? await repo.run("for-each-ref", "--count=1", "refs/heads/"))?.isEmpty != false {
            // AIrlock never commits into a repository it didn't create.
            throw PlainFolderError("\(task.repo.name) is a git repository with no commits yet. Make a first commit, then start the task again.")
        }
        task.workspace.baseCommit = try await repo.run("rev-parse", "--verify", "\(task.repo.baseRef)^{commit}")
        let branches = try await repo.run("for-each-ref", "--format=%(refname:short)", "refs/heads/")
        task.workspace.branch = branchName(for: task, existing: Set(branches.split(separator: "\n").map(String.init)))
        if task.repo.remoteURL == nil {
            task.repo.remoteURL = try? await repo.run("remote", "get-url", "origin")
        }
    }
}

/// A checkout of its own on the Mac, bind-mounted at /workspace.
///
/// The checkout is a `git clone --shared` of the user's repository: it borrows objects
/// (mounted read-only) but has its own refs, so the agent can't move the user's branches.
/// Everything in it, `.git` included, is the agent's to write, so AIrlock never runs git on
/// it from the Mac: git runs inside the container (`sandboxGit`), and the task branch comes
/// back as a bundle (`bringBack`, whenever the agent finishes a turn).
///
/// Tasks made before this layout shared the user's `.git` with the container read-write;
/// they can't be started any more.
public struct WorktreeProvisioner: WorkspaceProvisioner {
    public let paths: Paths
    /// Git for the task's repository, run where its config and hooks can't reach the Mac.
    let sandboxGit: @Sendable (AgentTask) -> any GitRunner

    public init(paths: Paths, runtime: any ContainerRuntime, user: String) {
        self.paths = paths
        sandboxGit = { ContainerGit(runtime: runtime, containerID: $0.containerID ?? "", directory: "/workspace", user: user) }
    }

    /// Tests: git for the checkout, in place of the container.
    init(paths: Paths, sandboxGit: @escaping @Sendable (AgentTask) -> any GitRunner) {
        self.paths = paths
        self.sandboxGit = sandboxGit
    }

    public func prepare(_ task: inout AgentTask) async throws -> [MountSpec] {
        let repo = URL(fileURLWithPath: task.repo.path)
        let checkout = paths.worktree(task.id)
        if task.workspace.hostPath == nil {
            try await Workspaces.resolveBase(HostGit(repo), &task)
            let notes = try await TaskRepository.create(from: repo, at: checkout, branch: task.workspace.branch,
                                                        base: task.workspace.baseCommit!, remoteURL: task.repo.remoteURL)
            task.workspace.hostPath = Workspaces.realPath(checkout.path)
            task.workspace.ownRepository = true
            task.setupNotes = notes
        }
        guard task.workspace.ownRepository == true else {
            throw PlainFolderError("""
            This task was made by an older AIrlock that shared your repository's .git with the container. \
            It can't be started any more; delete it and start a new task. Its branch \(task.workspace.branch) stays.
            """)
        }
        return try await ownMounts(task)
    }

    func ownMounts(_ task: AgentTask) async throws -> [MountSpec] {
        let checkout = URL(fileURLWithPath: task.workspace.hostPath!)
        let dir = paths.taskDir(task.id)
        let hooks = dir.appending(path: "git-hooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let config = try configCopy(of: checkout, in: dir)
        let stores = await TaskRepository.objectStores(of: URL(fileURLWithPath: task.repo.path))
        return [.bind(hostPath: checkout.path, containerPath: "/workspace")]
            + TaskRepository.borrowedObjectMounts(checkout: checkout, stores: stores)
            + [
                .bind(hostPath: hooks.path, containerPath: "/workspace/.git/hooks", readOnly: true),
                .bind(hostPath: config.path, containerPath: "/workspace/.git/config", readOnly: true),
            ]
    }

    /// The agent sees a read-only git config: a copy AIrlock made when it created the
    /// checkout, before the agent ever ran. Mounting a copy (rather than the file itself) also
    /// keeps Apple VMs from merging the file's share with its folder's.
    func configCopy(of checkout: URL, in taskDir: URL) throws -> URL {
        let dir = taskDir.appending(path: "git-config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: "config")
        if SafeFile.isRegularFile("config", in: dir) { return copy }
        // Tasks from before the copy was kept: their checkout's config is read once, safely.
        guard let data = SafeFile.read(".git/config", in: checkout, limit: 256 * 1024) else {
            throw PlainFolderError("The task's git config is missing or isn't a regular file.")
        }
        try SafeFile.write(data, to: "config", in: dir)
        return copy
    }

    public func populate(_ task: AgentTask, containerID: String) async throws {}

    public func git(_ task: AgentTask) -> any GitRunner { sandboxGit(task) }

    /// Fetches the task branch into `repo` as a bundle made in the container.
    public func bringBack(_ task: AgentTask, into repo: URL) async throws {
        guard task.workspace.ownRepository == true, let base = task.workspace.baseCommit else { return }
        try await TaskRepository.bringBack(branch: task.workspace.branch, base: base, from: sandboxGit(task), into: repo)
    }

    /// Deletes the checkout. The engine brings the branch back first, while the container runs.
    public func cleanup(_ task: AgentTask) async throws {
        guard let path = task.workspace.hostPath else { return }
        // Docker Desktop can hold a just-removed container's mounts (e.g. a dependency
        // volume over `node_modules`) for a moment, so give the folder a few tries.
        for attempt in 0..<5 where FileManager.default.fileExists(atPath: path) {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            try? FileManager.default.removeItem(atPath: path)
        }
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        if task.workspace.ownRepository != true {
            // The older layout's worktree entry; `prune` drops it without looking inside the folder.
            try? await HostGit(URL(fileURLWithPath: task.repo.path)).run("worktree", "prune")
        }
    }
}

/// The repository cloned into a container-owned volume. The host checkout is
/// never mounted; changes come back as a git bundle fetched into the host repo.
public struct VolumeCloneProvisioner: WorkspaceProvisioner {
    public let runtime: any ContainerRuntime
    public let user: String

    public init(runtime: any ContainerRuntime, user: String) {
        self.runtime = runtime
        self.user = user
    }

    public func prepare(_ task: inout AgentTask) async throws -> [MountSpec] {
        if task.workspace.volumeName == nil {
            try await Workspaces.resolveBase(HostGit(URL(fileURLWithPath: task.repo.path)), &task)
            let name = "\(task.containerName)-workspace"
            try await runtime.createVolume(name, labels: ["airlock.task": task.id.uuidString])
            task.workspace.volumeName = name
        }
        return [.volume(name: task.workspace.volumeName!, containerPath: "/workspace")]
    }

    public func populate(_ task: AgentTask, containerID: String) async throws {
        let inContainer = ContainerGit(runtime: runtime, containerID: containerID, directory: "/workspace", user: user)
        if (try? await inContainer.run("rev-parse", "--git-dir")) != nil { return }
        // A fresh volume may be root-owned (Apple VM block volumes are).
        try await runtime.run(containerID, ExecSpec(["sh", "-c", "chown \"$OWNER:$OWNER\" /workspace && rm -rf /workspace/lost+found"], user: "root", environment: ["OWNER": user]))

        // The task's repository is made on the Mac, with submodules and LFS files, then
        // copied in whole: everything the agent needs, and nothing that points back here.
        let staging = FileManager.default.temporaryDirectory.appending(path: "airlock-\(task.shortID)-clone")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let checkout = staging.appending(path: "repo")
        try await TaskRepository.create(from: URL(fileURLWithPath: task.repo.path), at: checkout, branch: task.workspace.branch,
                                        base: task.workspace.baseCommit ?? "HEAD", remoteURL: task.repo.remoteURL)
        let git = HostGit(checkout)
        try await git.run("repack", "-a", "-d", "-q")
        try? FileManager.default.removeItem(at: checkout.appending(path: ".git/objects/info/alternates"))

        let inner = staging.appending(path: "workspace.tar")
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-c", "-f", inner.path, "-C", checkout.path, "."],
                                    environment: ["COPYFILE_DISABLE": "1"])
        let outer = try await ProcessRunner.run(
            "/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-c", "-f", "-", "-C", staging.path, "workspace.tar"],
            environment: ["COPYFILE_DISABLE": "1"]
        ).stdout
        try await runtime.copyIn(containerID, tar: outer, to: "/tmp")
        try await runtime.run(containerID, ExecSpec(["tar", "-xf", "/tmp/workspace.tar", "-C", "/workspace"], user: user))
        _ = try? await runtime.exec(containerID, ExecSpec(["rm", "-f", "/tmp/workspace.tar"], user: "root"))
    }

    public func git(_ task: AgentTask) -> any GitRunner {
        ContainerGit(runtime: runtime, containerID: task.containerID ?? "", directory: "/workspace", user: user)
    }

    /// Fetches the task branch's commits into the host repo as `airlock/<slug>`.
    /// Uncommitted changes stay in the container.
    public func bringBack(_ task: AgentTask, into repo: URL) async throws {
        guard task.containerID != nil, let base = task.workspace.baseCommit else { return }
        try await TaskRepository.bringBack(branch: task.workspace.branch, base: base, from: git(task), into: repo)
    }

    public func cleanup(_ task: AgentTask) async throws {
        if let name = task.workspace.volumeName { try await runtime.removeVolume(name) }
    }
}

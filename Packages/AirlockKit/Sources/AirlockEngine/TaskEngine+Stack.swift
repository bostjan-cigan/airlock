import AirlockCore
import AirlockDocker
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// Per-project toolchains, package caches and Linux-only dependency folders.
extension TaskEngine {
    /// What the project needs: read from the user's repository on the Mac, then adjusted by
    /// the project's own settings when it has any.
    func detectStack(_ task: AgentTask, config: ProjectConfig?) -> ProjectStack {
        var stack = StackDetector.detect(at: settingsSource(task))
        if let config {
            let allowed = config.allow.compactMap { try? NetworkRules.normalize($0) }
            stack.apply(tools: config.tools, packages: config.packages, allow: allowed, source: config.source)
        }
        return stack
    }

    /// The project's AIrlock settings (`.airlock/compose.yaml` or `x-airlock`), if any.
    func loadProjectConfig(_ task: AgentTask) async throws -> ProjectConfig? {
        try await ProjectConfig.load(repo: settingsSource(task), dockerSocket: (runtimes[.docker] as? DockerRuntime)?.client.socketPath)
    }

    /// Where a task's settings come from: the user's repository, never the task's checkout.
    /// The agent can write anything in its checkout, and these settings widen its network,
    /// pick its image and run builds on the Mac; a change it makes there applies once the
    /// user has it in their own repository.
    func settingsSource(_ task: AgentTask) -> URL {
        URL(fileURLWithPath: task.repo.path)
    }

    /// The base image recipe: AIrlock's own, or on the project's `agent` image.
    func agentBase(_ task: AgentTask, config: ProjectConfig?) async throws -> ImageRecipe {
        if let image = config?.agentImage { return Providers.baseRecipe(from: image) }
        guard let build = config?.agentBuild else { return Providers.baseRecipe() }
        guard let docker = ComposeServices.dockerCLI() else {
            throw EngineError("Building the agent image in \(config?.source ?? "the settings") needs the docker command.")
        }
        log(task.id, "Building the project's agent image…")
        var args = ["build", "-q"]
        if let dockerfile = build.dockerfile { args += ["-f", dockerfile] }
        if let target = build.target { args += ["--target", target] }
        args.append(build.context)
        var env: [String: String] = [:]
        if let socket = (runtimes[.docker] as? DockerRuntime)?.client.socketPath { env["DOCKER_HOST"] = "unix://\(socket)" }
        let result = try await ProcessRunner.run(docker, args, cwd: settingsSource(task), environment: env, check: false)
        let imageID = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, imageID.hasPrefix("sha256:") else {
            throw EngineError("Couldn't build the agent image from \(config?.source ?? "the settings"): \(String(decoding: result.stderr, as: UTF8.self).suffix(800))")
        }
        // Tagged by content, so the layers on top are rebuilt only when it changes.
        let tag = "airlock/agent:\(imageID.dropFirst(7).prefix(12))"
        _ = try await ProcessRunner.run(docker, ["tag", imageID, tag], environment: env, check: false)
        return Providers.baseRecipe(from: tag)
    }

    /// Writes `.airlock/compose.yaml` into the task's repository, filled in from what was
    /// detected, unless there is one already. Returns its location.
    public func createProjectConfig(_ id: UUID) throws -> URL {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        let url = URL(fileURLWithPath: task.repo.path).appending(path: ProjectConfig.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stack = task.stack ?? StackDetector.detect(at: URL(fileURLWithPath: task.repo.path))
            try Data(ProjectConfig.template(for: stack).utf8).write(to: url)
        }
        return url
    }

    /// The image with the stack's tools on top of the agent image.
    func stackRecipe(_ task: AgentTask, stack: ProjectStack, parent: ImageRecipe) throws -> ImageRecipe {
        let learned = (project(task.projectID)?.packages ?? []).filter(StackImage.isInstallable)
        return try StackImage.recipe(for: stack, learnedPackages: learned, parent: parent, paths: paths)
    }

    /// The task's own package cache at `~/.cache`, and, in worktree mode, volumes over the
    /// checkout's dependency folders so Linux builds of them never land in the Mac folder.
    ///
    /// The cache belongs to this task alone: a package one task downloads (or tampers with)
    /// never reaches another. It's a volume on every runtime (a disk image for Apple VMs), so
    /// nothing in it is a file on the Mac, and it goes with the task.
    func stackMounts(_ task: AgentTask, stack: ProjectStack, runtime: any ContainerRuntime) async throws -> [MountSpec] {
        let cache = Self.cacheVolume(task)
        try await runtime.createVolume(cache, labels: ["airlock.task": task.id.uuidString])
        var mounts: [MountSpec] = [.volume(name: cache, containerPath: ContainerPaths.cache)]
        if task.workspace.mode == .worktree {
            for folder in stack.dependencyFolders {
                let name = Self.dependencyVolume(task, folder)
                try await runtime.createVolume(name, labels: ["airlock.task": task.id.uuidString])
                mounts.append(.volume(name: name, containerPath: "\(ContainerPaths.workspace)/\(folder)"))
            }
        }
        return mounts
    }

    static func cacheVolume(_ task: AgentTask) -> String { "\(task.containerName)-cache" }

    static func dependencyVolume(_ task: AgentTask, _ folder: String) -> String {
        "\(task.containerName)-\(folder.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "/", with: "-"))"
    }

    /// New volumes are root's; the agent needs to write to them.
    func prepareStackMounts(_ task: AgentTask, stack: ProjectStack, runtime: any ContainerRuntime, containerID: String) async {
        let dirs = [ContainerPaths.cache] + (task.workspace.mode == .worktree ? stack.dependencyFolders.map { "\(ContainerPaths.workspace)/\($0)" } : [])
        let script = "for d in \"$@\"; do [ -d \"$d\" ] && chown \(ContainerPaths.user):\(ContainerPaths.user) \"$d\" 2>/dev/null; done; exit 0"
        _ = try? await runtime.exec(containerID, ExecSpec(["sh", "-c", script, "chown"] + dirs, user: "root"))
    }

    /// Debian packages the agent installed with `airlock-install` become part of the
    /// project, so its next image has them already.
    func syncInstalledPackages(_ id: UUID, runtime: any ContainerRuntime, containerID: String) async {
        // An inspection's packages are the repository's choice: never carried into other tasks.
        guard let task = tasks[id], !task.isInspection, let projectID = task.projectID,
              let result = try? await runtime.exec(containerID, ExecSpec(["cat", "/run/airlock/installed-packages"], user: "root")),
              result.exitCode == 0 else { return }
        let names = result.output.split(separator: "\n").map(String.init).filter(StackImage.isInstallable)
        guard let index = projectList.firstIndex(where: { $0.id == projectID }) else { return }
        let fresh = names.filter { !projectList[index].packages.contains($0) }
        guard !fresh.isEmpty else { return }
        projectList[index].packages += fresh
        saveProjects()
        log(id, "Installed \(fresh.joined(separator: ", ")); new tasks in this project get them ready-made")
    }

    /// Copies the task's commits into AIrlock's own copy (never the user's repository), as a
    /// bundle made in its running container: after each turn, and before it stops. They reach
    /// the user only when the work is handed off.
    func syncTaskBranch(_ id: UUID) async {
        guard let task = tasks[id] else { return }
        do {
            try await keepWork(id)
        } catch {
            log(id, "Couldn't copy \(task.workspace.branch)'s commits out of the container: \(error)")
        }
    }

    /// The task's own cache and dependency volumes.
    func removeTaskVolumes(_ task: AgentTask, runtime: any ContainerRuntime) async {
        try? await runtime.removeVolume(Self.cacheVolume(task))
        for folder in task.stack?.dependencyFolders ?? [] where task.workspace.mode == .worktree {
            try? await runtime.removeVolume(Self.dependencyVolume(task, folder))
        }
    }

    /// A deleted project's package cache from before caches were per task, on every runtime.
    func removeProjectCache(_ projectID: UUID) async {
        let short = String(projectID.uuidString.prefix(8)).lowercased()
        try? FileManager.default.removeItem(at: paths.root.appending(path: "caches/\(short)"))
        for runtime in runtimes.values where runtime.kind != .apple {
            try? await runtime.removeVolume("airlock-cache-\(short)")
        }
    }
}

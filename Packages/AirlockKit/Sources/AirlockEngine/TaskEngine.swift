import AirlockApple
import AirlockCore
import AirlockDocker
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// What the user fills in on the New Task sheet.
public struct NewTaskRequest: Sendable {
    public var title: String
    public var prompt: String
    public var repoPath: String
    public var baseRef: String
    public var providerID: ProviderID
    public var runtime: RuntimeKind
    public var workspaceMode: WorkspaceSpec.Mode
    public var network: NetworkProfile
    /// Nil sizes the container automatically (see `ResourcePlanner`).
    public var resources: ResourceLimits?
    /// Project to file the task under; nil picks the repo's only or default project.
    public var projectID: UUID?
    public var tags: [String]
    /// Start the repository's compose services next to the agent.
    public var services: Bool
    /// Ports to forward to localhost once the agent is up.
    public var expose: [Int]
    /// Give the agent the GitHub token and network access to GitHub. Off unless asked for.
    public var github: Bool
    /// Add the project's default hosts to a restricted network. The New Task sheet shows
    /// them in its own list instead, so whatever the user removed there stays removed.
    public var includeProjectHosts: Bool
    /// On a restricted network: download dependencies with scripts off, close the network, then
    /// run their install scripts (recorded) before the agent starts. On unless asked otherwise.
    public var sealed: Bool

    public init(
        title: String, prompt: String, repoPath: String, baseRef: String,
        providerID: ProviderID = .claudeCode, runtime: RuntimeKind = .docker,
        // Isolated by default: nothing the agent writes (packages, build output) lands on the Mac.
        workspaceMode: WorkspaceSpec.Mode = .volumeClone,
        network: NetworkProfile = .restricted(extraDomains: []),
        resources: ResourceLimits? = nil,
        projectID: UUID? = nil,
        tags: [String] = [],
        services: Bool = false,
        expose: [Int] = [],
        github: Bool = false,
        includeProjectHosts: Bool = true,
        sealed: Bool = true
    ) {
        self.includeProjectHosts = includeProjectHosts
        self.sealed = sealed
        self.title = title
        self.prompt = prompt
        self.repoPath = repoPath
        self.baseRef = baseRef
        self.providerID = providerID
        self.runtime = runtime
        self.workspaceMode = workspaceMode
        self.network = network
        self.resources = resources
        self.projectID = projectID
        self.tags = tags
        self.services = services
        self.expose = expose
        self.github = github
    }
}

public enum EngineUpdate: Sendable {
    case task(AgentTask)
    case removed(UUID)
    case projects([Project])
    case events(UUID, [AgentEvent])
    /// Progress output (image builds, setup) for a task.
    case log(UUID, String)
    /// Something happened the user should hear about.
    case attention(AgentTask, AgentEvent)
    /// A task's agent was refused hosts that weren't blocked before.
    case blocked(AgentTask, [BlockedHost])
    /// What a task's containers use right now, by container ("agent" or a service's name).
    case usage(UUID, [String: ResourceUsage])
}

public struct EngineError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Owns every task's lifecycle: workspace, image, container, agent and activity.
public actor TaskEngine {
    public nonisolated let paths: Paths
    public nonisolated let updates: AsyncStream<EngineUpdate>
    let updateSink: AsyncStream<EngineUpdate>.Continuation
    let store: TaskStore
    private let projectStore: ProjectStore
    private let secrets: any SecretStore
    var runtimes: [RuntimeKind: any ContainerRuntime]

    var tasks: [UUID: AgentTask] = [:]
    var projectList: [Project] = []
    /// Consecutive liveness checks that found the agent's pane back at a shell.
    private var exitStrikes: [UUID: Int] = [:]
    /// Open localhost listeners per task, by container port.
    var forwarders: [UUID: [Int: PortForwarder]] = [:]
    /// Service plans computed at launch, reused when containers must be recreated.
    var servicePlans: [UUID: ServicePlan] = [:]
    private var events: [UUID: [AgentEvent]] = [:]
    var watchers: [UUID: Task<Void, Never>] = [:]
    private var eventOffsets: [UUID: UInt64] = [:]
    /// Plain folders whose temporary `.git` AIrlock created.
    public nonisolated let managedFolders: ManagedFolders
    /// The last queued git operation per plain folder; see `serialized`.
    private var folderQueues: [String: Task<Void, Never>] = [:]
    /// Restricted tasks' DNS logs: how far each was read, and the reader's state.
    var dnsOffsets: [UUID: Int] = [:]
    var dnsReaders: [UUID: DNSLogReader] = [:]
    /// When an allowlisted host last made the firewall re-resolve (its addresses moved).
    var firewallRefreshed: [UUID: Date] = [:]
    /// When each running task's `airlock-install` packages were last read.
    var packagesSynced: [UUID: Date] = [:]
    /// Stopped tasks whose container AIrlock started for a moment to read their work.
    var briefStarts: Set<UUID> = []
    /// Latest usage per task, by container, and the polls reading it.
    var usage: [UUID: [String: ResourceUsage]] = [:]
    var usagePolls: [UUID: Task<Void, Never>] = [:]
    var usageReadAt: [UUID: Date] = [:]

    public init(paths: Paths = .default, secrets: any SecretStore, runtimes: [RuntimeKind: any ContainerRuntime]) {
        self.paths = paths
        self.store = TaskStore(paths: paths)
        self.projectStore = ProjectStore(paths: paths)
        self.managedFolders = ManagedFolders(file: paths.managedFolders)
        self.secrets = secrets
        self.runtimes = runtimes
        (updates, updateSink) = AsyncStream<EngineUpdate>.makeStream()
    }

    // MARK: Loading

    /// Loads saved tasks and reconciles them with what the runtimes report.
    public func bootstrap() async -> [AgentTask] {
        let loaded = (try? store.loadAll()) ?? []
        projectList = (try? projectStore.load()) ?? []
        for var task in loaded {
            if task.projectID == nil || !projectList.contains(where: { $0.id == task.projectID }) {
                task.projectID = defaultProject(forRepo: task.repo.path).id
                try? store.save(task)
            }
            switch task.lifecycle {
            case .provisioning, .buildingImage, .starting:
                task.lifecycle = .failed("Interrupted when AIrlock quit. Start the task to try again.")
            default:
                break
            }
            tasks[task.id] = task
            replayEvents(task.id)
        }
        for id in tasks.keys { await refreshState(id) }
        for task in tasks.values where task.lifecycle == .running { await restoreForwards(task.id) }
        return Array(tasks.values)
    }

    public func task(_ id: UUID) -> AgentTask? { tasks[id] }
    public func allTasks() -> [AgentTask] { Array(tasks.values) }
    func runtime(_ kind: RuntimeKind) -> (any ContainerRuntime)? { runtimes[kind] }

    /// The agent was just given input, so it's working until its next event says otherwise.
    func markWorking(_ id: UUID) {
        exitStrikes[id] = nil
        update(id) {
            $0.activity = .working(tool: nil)
            $0.lastActivityAt = .now
        }
    }
    public func events(for id: UUID) -> [AgentEvent] { events[id] ?? [] }

    public func runtimeStatus() async -> [RuntimeKind: RuntimeAvailability] {
        var out: [RuntimeKind: RuntimeAvailability] = [:]
        for kind in RuntimeKind.allCases {
            out[kind] = await runtimes[kind]?.availability() ?? .unavailable(reason: Self.missingRuntimeReason(kind))
        }
        return out
    }

    public func setRuntime(_ runtime: (any ContainerRuntime)?, for kind: RuntimeKind) {
        runtimes[kind] = runtime
    }

    /// How a failed toolchain setup starts, so the app can offer to create the settings file.
    public static let setupFailure = "Couldn’t set up"

    static func missingRuntimeReason(_ kind: RuntimeKind) -> String {
        switch kind {
        case .docker: "No Docker socket found. Install Docker Desktop, OrbStack or Colima."
        case .apple: "Apple VM runtime isn't set up yet."
        }
    }

    // MARK: Creating and launching

    public func create(_ request: NewTaskRequest, origin: TaskOrigin = .app) async throws -> AgentTask {
        guard let provider = Providers.provider(for: request.providerID) else { throw EngineError("Unknown agent \(request.providerID.rawValue)") }
        // Fail now rather than after the task appears, so callers get a clear answer.
        _ = try loadSecrets(for: provider, github: false)
        let project = try resolveProject(request.projectID, repoPath: request.repoPath)
        let plain = isPlainFolder(request.repoPath)
        if plain { try PlainFolder.checkAllowed(request.repoPath) }
        var network = request.network
        if case .restricted(let extra) = network {
            let own = try extra.map(NetworkRules.normalize)
            network = .restricted(extraDomains: NetworkRules.merge(request.includeProjectHosts ? project.allowedHosts : [], own))
        }
        var task = AgentTask(
            title: request.title,
            prompt: request.prompt,
            repo: RepoRef(path: request.repoPath, baseRef: plain ? PlainFolder.branch : request.baseRef, plainFolder: plain),
            providerID: request.providerID,
            runtime: request.runtime,
            workspace: WorkspaceSpec(mode: request.workspaceMode, branch: ""),
            network: network
        )
        let plan = await planResources(repoPath: request.repoPath, projectID: project.id, explicit: request.resources, services: request.services)
        task.resources = plan.limits
        task.resourceReason = plan.reason
        // Known before launch, so the sheet, the chat and the inspector can show tools and notices.
        task.stack = StackDetector.detect(at: URL(fileURLWithPath: request.repoPath))
        task.origin = origin
        task.projectID = project.id
        task.tags = Tag.apply([], add: request.tags, remove: [])
        task.githubAccess = request.github
        if request.sealed, network.isRestricted { task.sealing = Sealing() }
        if request.services {
            guard request.runtime == .docker else { throw EngineError("Services run on Docker only; this task uses \(request.runtime.displayName).") }
            guard let file = ComposeServices.detect(in: URL(fileURLWithPath: request.repoPath)) else {
                throw EngineError("No compose file (compose.yaml or docker-compose.yml) in \(Project.defaultName(forRepo: request.repoPath)).")
            }
            task.services = TaskServices(composeFile: file)
        }
        task.ports = request.expose.map { PortForward(containerPort: $0, hostPort: $0) }
        tasks[task.id] = task
        try store.save(task)
        updateSink.yield(.task(task))
        Task { await self.launch(task.id) }
        return task
    }

    /// Takes a task from nothing to a running agent. Safe to call again after a failure.
    public func launch(_ id: UUID) async {
        do {
            if tasks[id]?.isInspection == true {
                try await inspectionSteps(id)
            } else {
                try await launchSteps(id)
            }
        } catch {
            if tasks[id]?.isInspection == true { update(id) { $0.inspection?.phase = .failed } }
            fail(id, String(describing: error))
            log(id, "Failed: \(error)")
        }
    }

    private func launchSteps(_ id: UUID) async throws {
        guard var task = tasks[id] else { return }
        let runtime = try runtime(for: task)
        let provider = try provider(for: task)
        let secretValues = try loadSecrets(for: provider, github: task.githubAccess)

        update(id) {
            $0.lifecycle = .provisioning
            $0.access = Self.access(secretValues)
        }
        // Nothing of the old container may run while AIrlock writes into the agent's folders.
        await removeServiceContainers(id)
        if let old = task.containerID {
            try? await runtime.remove(old)
            update(id) { $0.containerID = nil }
            task.containerID = nil
        }
        if task.sealing != nil {
            // Every full launch sets up again: download first, the network closes after.
            task.sealing?.phase = .downloading
            task.sealing?.sealedAt = nil
            replace(task)
        }
        if task.repo.isPlainFolder, task.workspace.baseCommit == nil {
            // The task starts from the folder as it is now.
            let (path, registry) = (task.repo.path, managedFolders)
            try await serialized(path) { try await PlainFolder.snapshot(path, registry: registry) }
        }
        let workspace = Workspaces.provisioner(for: task, paths: paths, runtime: runtime, user: ContainerPaths.user)
        let workspaceMounts = try await workspace.prepare(&task)
        for note in task.setupNotes { log(id, note) }
        let config = try await loadProjectConfig(task)
        let stack = detectStack(task, config: config)
        task.stack = stack
        try provider.seedConfig(at: paths.agentConfig(id), for: task, secrets: secretValues)
        try FileManager.default.createDirectory(at: paths.events(id), withIntermediateDirectories: true)
        let networkFile = try writeNetworkConfig(task, provider: provider)
        replace(task)

        update(id) { $0.lifecycle = .buildingImage }
        if let summary = stack.summary { log(id, "Detected \(summary)\(config.map { " (with \($0.source))" } ?? "")") }
        let parent = provider.imageRecipe(base: try await agentBase(task, config: config))
        let recipe = try stackRecipe(task, stack: stack, parent: parent)
        let image: String
        do {
            image = try await runtime.ensureImage(recipe) { [weak self] line in
                Task { await self?.log(id, line) }
            }
        } catch where recipe.name != parent.name || config?.agentImage != nil {
            throw EngineError(Self.setupFailure + " \(stack.summary ?? "the project's tools"): \(error). "
                + "Add \(ProjectConfig.fileName) to say what this project needs.")
        }
        update(id) { $0.imageRef = image }
        let cacheMounts = try await stackMounts(task, stack: stack, runtime: runtime)

        var extraHosts: [String]?
        if task.services != nil {
            let plan = try await planServices(id, runtime: runtime)
            extraHosts = plan.services.map { "\($0.name):127.0.0.1" }
        }

        update(id) { $0.lifecycle = .starting }
        resetDNSLog(id)
        let spec = ContainerSpec(
            name: task.containerName,
            image: image,
            labels: ["airlock.task": id.uuidString, "airlock.provider": task.providerID.rawValue],
            mounts: workspaceMounts + [
                .bind(hostPath: paths.agentConfig(id).path, containerPath: provider.configMountPath),
                .bind(hostPath: paths.events(id).path, containerPath: ContainerPaths.events),
                .bind(hostPath: networkFile.path, containerPath: ContainerPaths.networkConfig, readOnly: true),
            ] + cacheMounts,
            environment: try await containerEnvironment(task).merging(config?.environment ?? [:]) { own, _ in own },
            capAdd: task.network.isRestricted ? ["NET_ADMIN", "NET_RAW"] : [],
            resources: task.resources,
            extraHosts: extraHosts
        )
        let containerID = try await runtime.create(spec)
        update(id) { $0.containerID = containerID }
        try await runtime.start(containerID)
        try await waitUntilReady(runtime, containerID)
        await prepareStackMounts(task, stack: stack, runtime: runtime, containerID: containerID)

        try await workspace.populate(tasks[id]!, containerID: containerID)
        try await sealedSetup(id, runtime: runtime, containerID: containerID)
        await startServices(id)
        try await startAgent(id, resume: false, secrets: secretValues)
        update(id) { $0.lifecycle = .running }
        watch(id)
        await restoreForwards(id)
    }

    /// Waits until `airlock-init` has applied the network policy and dropped privileges.
    func waitUntilReady(_ runtime: any ContainerRuntime, _ id: String) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            switch try await runtime.state(id) {
            case .running:
                if let marker = try? await runtime.exec(id, ExecSpec(["test", "-f", ContainerPaths.readyMarker])), marker.exitCode == 0 {
                    return
                }
            case .stopped(let code):
                throw EngineError("Container exited during startup (code \(code.map(String.init) ?? "?")). If the task is restricted, the firewall couldn't be set up.")
            case .missing:
                throw EngineError("Container disappeared during startup.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw EngineError("Container didn't finish starting in time.")
    }

    func startAgent(_ id: UUID, resume: Bool, secrets: [SecretKey: String]) async throws {
        guard let task = tasks[id], let containerID = task.containerID else { return }
        let runtime = try runtime(for: task)
        let provider = try provider(for: task)
        try await handProxyCredential(provider, secrets: secrets, runtime: runtime, containerID: containerID)
        let command = provider.launchCommand(for: task, resume: resume).map(Self.shellQuote).joined(separator: " ")
        var env = provider.environment(for: task, secrets: secrets)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        try await runtime.run(containerID, ExecSpec(
            ["tmux", "new-session", "-d", "-s", ContainerPaths.tmuxSession, "-x", "160", "-y", "48",
             "-c", ContainerPaths.workspace, "zsh", "-lc", "\(command); exec zsh"],
            user: ContainerPaths.user,
            workdir: ContainerPaths.workspace,
            environment: env
        ))
    }

    /// Writes the real API credential where only `airlock-proxy` can read it. Root writes it
    /// (the value travels in that one process's environment, readable only by root), so it's
    /// never in the agent's environment, its files or the container's configuration.
    func handProxyCredential(_ provider: any AgentProvider, secrets: [SecretKey: String],
                             runtime: any ContainerRuntime, containerID: String) async throws {
        guard let credential = provider.proxyCredential(secrets: secrets) else { return }
        let dir = ContainerPaths.proxyDirectory
        let script = "umask 077 && printf '%s' \"$AIRLOCK_CREDENTIAL\" > \(dir)/token.new && chown airlock-proxy:airlock-proxy \(dir)/token.new && mv -f \(dir)/token.new \(dir)/token"
        try await runtime.run(containerID, ExecSpec(["sh", "-c", script], user: "root", environment: ["AIRLOCK_CREDENTIAL": credential]))
    }

    // MARK: Lifecycle actions

    public func stop(_ id: UUID) async {
        guard let task = tasks[id], let containerID = task.containerID, let runtime = runtimes[task.runtime] else { return }
        // The branch can only be read while the container runs.
        await syncTaskBranch(id)
        closeForwards(id)
        await stopServices(id)
        do {
            try await runtime.stop(containerID, timeout: .seconds(5))
            update(id) {
                $0.lifecycle = .stopped
                $0.activity = .idle(lastMessage: nil)
            }
        } catch {
            update(id) { $0.lifecycle = .failed("Couldn't stop: \(error)") }
        }
    }

    /// Starts a stopped task and resumes its agent conversation.
    public func start(_ id: UUID) async {
        guard let task = tasks[id] else { return }
        guard let containerID = task.containerID, let runtime = runtimes[task.runtime],
              case .stopped = try? await runtime.state(containerID) else {
            // Never got as far as a container, or it's gone: run the full launch.
            await launch(id)
            return
        }
        if let inspection = task.inspection, !inspection.investigate {
            // Nothing runs in it but what's already there; the network stays closed (its file says so).
            do {
                update(id) { $0.lifecycle = .starting }
                try await runtime.start(containerID)
                try await waitUntilReady(runtime, containerID)
                update(id) { $0.lifecycle = .running }
            } catch {
                fail(id, String(describing: error))
            }
            return
        }
        do {
            let provider = try provider(for: task)
            let secretValues = try loadSecrets(for: provider, github: task.githubAccess)
            try provider.seedConfig(at: paths.agentConfig(id), for: task, secrets: secretValues)
            update(id) {
                $0.lifecycle = .starting
                $0.access = Self.access(secretValues)
            }
            resetDNSLog(id)
            try await runtime.start(containerID)
            try await waitUntilReady(runtime, containerID)
            await startServices(id)
            try await startAgent(id, resume: true, secrets: secretValues)
            update(id) {
                $0.lifecycle = .running
                $0.activity = .working(tool: nil)
            }
            watch(id)
            await restoreForwards(id)
        } catch {
            fail(id, String(describing: error))
        }
    }

    /// Kills the agent's session and starts it again, continuing the conversation.
    public func restartAgent(_ id: UUID) async {
        guard let task = tasks[id], let containerID = task.containerID, let runtime = runtimes[task.runtime],
              task.inspection?.investigate != false else { return }
        do {
            _ = try? await runtime.exec(containerID, ExecSpec(["tmux", "kill-session", "-t", ContainerPaths.tmuxSession], user: ContainerPaths.user))
            let secretValues = try loadSecrets(for: provider(for: task), github: task.githubAccess)
            try await startAgent(id, resume: true, secrets: secretValues)
            update(id) { $0.access = Self.access(secretValues) }
            markWorking(id)
        } catch {
            log(id, "Couldn't restart the agent: \(error)")
        }
    }

    /// Tasks whose containers stop when the app quits (Apple VMs live in-process).
    public func tasksEndingWithApp() -> [AgentTask] {
        tasks.values.filter { $0.runtime == .apple && $0.lifecycle.isActive }
    }

    /// Stops in-process VMs gracefully. Their tasks can be started again later.
    public func prepareForQuit() async {
        for task in tasksEndingWithApp() {
            await syncTaskBranch(task.id)
            watchers.removeValue(forKey: task.id)?.cancel()
            closeForwards(task.id)
            update(task.id) {
                $0.lifecycle = .stopped
                $0.activity = .idle(lastMessage: nil)
            }
        }
        if let apple = runtimes[.apple] as? AppleContainerRuntime {
            await apple.stopAll()
        }
    }

    /// Demo mode only: shows a task in a state that loading from disk can't restore (starting).
    public func overrideForDemo(_ task: AgentTask) {
        replace(task)
    }

    public func setDone(_ id: UUID, _ done: Bool) {
        update(id) { $0.isDone = done }
    }

    /// Adds and removes tags; returns the task's tags afterwards.
    @discardableResult
    public func setTags(_ id: UUID, add: [String] = [], remove: [String] = []) throws -> [String] {
        guard tasks[id] != nil else { throw EngineError("No such task.") }
        update(id) { $0.tags = Tag.apply($0.tags, add: add, remove: remove) }
        return tasks[id]?.tags ?? []
    }

    // MARK: Projects

    public func projects() -> [Project] { projectList }
    public func project(_ id: UUID?) -> Project? { projectList.first { $0.id == id } }

    /// Finds a project by id, or by name (case-insensitive), optionally within one repository.
    public func findProject(_ text: String, repoPath: String? = nil) -> Project? {
        if let id = UUID(uuidString: text), let project = project(id) { return project }
        let matches = projectList.filter {
            $0.name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (repoPath == nil || $0.repoPath == repoPath)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public func createProject(name: String, repoPath: String) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EngineError("Give the project a name.") }
        guard FileManager.default.fileExists(atPath: repoPath) else { throw EngineError("No repository at \(repoPath).") }
        if let existing = projectList.first(where: { $0.repoPath == repoPath && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let project = Project(name: name, repoPath: repoPath)
        projectList.append(project)
        saveProjects()
        return project
    }

    public func renameProject(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projectList.firstIndex(where: { $0.id == id }) else { return }
        projectList[index].name = name
        saveProjects()
    }

    /// Deletes a project along with its tasks: their containers are stopped and removed, as
    /// with `remove`. Task branches in the host repo are kept. A task that can't be cleaned up
    /// moves to the repository's default project instead, and the first such error is rethrown.
    public func deleteProject(_ id: UUID) async throws {
        guard let project = project(id) else { return }
        projectList.removeAll { $0.id == id }
        var failure: Error?
        for task in tasks.values where task.projectID == id {
            do {
                try await remove(task.id, applyToFolder: true)
            } catch {
                failure = failure ?? error
                let fallback = defaultProject(forRepo: project.repoPath)
                update(task.id) { $0.projectID = fallback.id }
            }
        }
        saveProjects()
        await removeProjectCache(id)
        if let failure { throw failure }
    }

    public func moveTask(_ id: UUID, to projectID: UUID) throws {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard let project = project(projectID) else { throw EngineError("No such project.") }
        guard project.repoPath == task.repo.path else {
            throw EngineError("“\(project.name)” belongs to \(project.repoName); this task works on \(task.repo.name).")
        }
        update(id) { $0.projectID = projectID }
    }

    /// The project new tasks for a repository go to when none is chosen: the repo's only
    /// project, else the one named after the repo (created if needed).
    func resolveProject(_ id: UUID?, repoPath: String) throws -> Project {
        if let id {
            guard let project = project(id) else { throw EngineError("No such project.") }
            guard project.repoPath == repoPath else {
                throw EngineError("“\(project.name)” belongs to \(project.repoName), not \(Project.defaultName(forRepo: repoPath)).")
            }
            return project
        }
        let inRepo = projectList.filter { $0.repoPath == repoPath }
        if inRepo.count == 1 { return inRepo[0] }
        return defaultProject(forRepo: repoPath)
    }

    private func defaultProject(forRepo path: String) -> Project {
        let name = Project.defaultName(forRepo: path)
        if let existing = projectList.first(where: { $0.repoPath == path && $0.name == name }) { return existing }
        let project = Project(name: name, repoPath: path)
        projectList.append(project)
        saveProjects()
        return project
    }

    func saveProjects() {
        try? projectStore.save(projectList)
        updateSink.yield(.projects(projectList))
    }

    /// Removes the container, workspace and task record. The task branch in the host repo is kept.
    ///
    /// For a plain folder, `applyToFolder` first merges the task's work into the folder's files
    /// (nothing is removed if that fails). Removing the folder's last task deletes the `.git`
    /// AIrlock created there, if the safeguards in `PlainFolder.release` allow it.
    @discardableResult
    public func remove(_ id: UUID, applyToFolder apply: Bool = false) async throws -> PlainFolder.Release? {
        guard let task = tasks[id] else { return nil }
        if apply, task.repo.isPlainFolder { try await applyToFolder(id) }
        watchers.removeValue(forKey: id)?.cancel()
        closeForwards(id)
        await removeServiceContainers(id, volumes: true)
        servicePlans[id] = nil
        let runtime = runtimes[task.runtime]
        if let containerID = task.containerID, let runtime {
            // Work that wasn't handed off goes with the task: the app and the chat ask first.
            await syncInstalledPackages(id, runtime: runtime, containerID: containerID)
            try? await runtime.remove(containerID)
            await removeTaskVolumes(task, runtime: runtime)
        }
        if let runtime {
            try await Workspaces.provisioner(for: task, paths: paths, runtime: runtime, user: ContainerPaths.user).cleanup(task)
        }
        try store.delete(id)
        tasks[id] = nil
        events[id] = nil
        eventOffsets[id] = nil
        updateSink.yield(.removed(id))
        guard task.repo.isPlainFolder else { return nil }
        let (path, registry) = (task.repo.path, managedFolders)
        return try await serialized(path) { [self] in
            // Checked once queued: a task created meanwhile keeps the folder's repository.
            guard await !hasTasks(onFolder: path) else { return nil }
            return await PlainFolder.release(path, registry: registry)
        }
    }

    // MARK: Plain folders

    /// True for a folder outside any git repository, or one whose `.git` AIrlock manages.
    public nonisolated func isPlainFolder(_ path: String) -> Bool {
        PlainFolder.isPlain(path) || PlainFolder.isManaged(path, registry: managedFolders)
    }

    func hasTasks(onFolder path: String) -> Bool {
        tasks.values.contains { $0.repo.path == path }
    }

    /// Commits whatever the agent left uncommitted, then merges the task branch into the
    /// folder's files. A conflict aborts the merge and leaves the folder as it was.
    public func applyToFolder(_ id: UUID) async throws {
        guard let task = tasks[id], !task.isInspection else { return }
        guard task.repo.isPlainFolder else {
            throw EngineError("This task works on a git repository; its work is on branch \(task.workspace.branch).")
        }
        // Never got a workspace, so there's nothing to apply.
        guard task.workspace.baseCommit != nil else { return }
        // The task's repository is only used from inside its container.
        try await withRunningContainer(id) { task in
            let provisioner = try self.provisioner(for: task)
            let git = provisioner.git(task)
            if !(try await git.run("status", "--porcelain")).isEmpty {
                try await git.run("add", "-A")
                try await git.run(PlainFolder.commitConfig + ["commit", "--quiet", "--no-verify", "-m", "Uncommitted work from “\(task.title)”"])
            }
            try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
        }
        let (path, branch, title, registry) = (task.repo.path, task.workspace.branch, task.title, managedFolders)
        try await serialized(path) { try await PlainFolder.apply(path, branch: branch, title: title, registry: registry) }
    }

    /// Runs git work on a plain folder one operation at a time, so concurrent tasks can't
    /// interleave snapshots, merges and the final cleanup.
    private func serialized<T: Sendable>(_ path: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = folderQueues[path]
        let work = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        folderQueues[path] = Task { _ = try? await work.value }
        return try await work.value
    }

    // MARK: Terminal and changes

    /// Attaches to the agent's tmux session (creating a shell session if it's gone).
    public func openTerminal(_ id: UUID, size: TerminalSize) async throws -> any TerminalSession {
        guard let task = tasks[id], let containerID = task.containerID else { throw EngineError("This task has no container yet.") }
        return try await runtime(for: task).openTerminal(containerID, ExecSpec(
            ["tmux", "new-session", "-A", "-s", ContainerPaths.tmuxSession, "-c", ContainerPaths.workspace],
            user: ContainerPaths.user,
            workdir: ContainerPaths.workspace,
            environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"]
        ), size: size)
    }

    /// What the task changed. While its container runs, git runs in there and sees uncommitted
    /// work too; otherwise it's the commits already brought back into the user's repository.
    public func changes(_ id: UUID) async throws -> WorkspaceChanges {
        await settlePendingBase(id)
        guard let task = tasks[id], !task.isInspection, let base = task.workspace.baseCommit else { return .empty }
        if await containerRunning(task) { return try await provisioner(for: task).changes(task) }
        // AIrlock's copy of its commits: the user's repository only has them once handed off.
        return try await GitInspector.committedChanges(in: HostGit(try await keptRepository(task)), branch: task.workspace.branch, since: base)
    }

    /// Files with uncommitted changes in the task's workspace; nil when that can't be checked
    /// (its container isn't running).
    public func uncommittedFileCount(_ id: UUID) async -> Int? {
        guard let task = tasks[id], !task.isInspection, await containerRunning(task) else { return nil }
        guard let status = try? await provisioner(for: task).git(task).run("status", "--porcelain") else { return nil }
        return status.split(separator: "\n").count
    }

    func containerRunning(_ task: AgentTask) async -> Bool {
        guard let containerID = task.containerID, let runtime = runtimes[task.runtime],
              case .running? = try? await runtime.state(containerID) else { return false }
        return true
    }

    /// Runs `body` with the task's container up. A stopped container is started just for it
    /// (without the agent) and stopped again: the task's repository is only used from inside.
    func withRunningContainer<T: Sendable>(_ id: UUID, _ body: (AgentTask) async throws -> T) async throws -> T {
        guard let task = tasks[id], let containerID = task.containerID else {
            throw EngineError("This task has no container, so its work can't be read. Start it first.")
        }
        let runtime = try runtime(for: task)
        switch try await runtime.state(containerID) {
        case .running:
            return try await body(task)
        case .missing:
            throw EngineError("This task's container is gone, so its work can't be read from it. Commits brought back earlier are on its branch.")
        case .stopped:
            briefStarts.insert(id)
            defer { briefStarts.remove(id) }
            log(id, "Starting the container for a moment to read the task's work…")
            try await runtime.start(containerID)
            do {
                try await waitUntilReady(runtime, containerID)
                let result = try await body(tasks[id] ?? task)
                try? await runtime.stop(containerID, timeout: .seconds(5))
                return result
            } catch {
                try? await runtime.stop(containerID, timeout: .seconds(5))
                throw error
            }
        }
    }

    /// Why the task's checkout shouldn't be opened in the user's own tools (Terminal, an
    /// editor), or nil. Those run git there with the checkout's settings, which the agent
    /// can change: so only a stopped task whose settings are still AIrlock's.
    public func openOnMacProblem(_ id: UUID) async -> String? {
        guard let task = tasks[id], let path = task.workspace.hostPath else { return "This task has no files on this Mac." }
        if await containerRunning(task) {
            return "Stop the task first. While it runs, the agent can change its git settings at any moment, and your shell or editor would run them on your Mac. The task's own terminal is safe to use."
        }
        let trusted = paths.taskDir(id).appending(path: "git-config/config")
        if let reason = TaskRepository.tamperedReason(checkout: URL(fileURLWithPath: path), trustedConfig: trusted) {
            return "AIrlock won't open this task's files outside the sandbox: \(reason) from inside the container. Review its branch in your own repository instead."
        }
        return nil
    }

    public func exportPatch(_ id: UUID) async throws -> String {
        guard let task = tasks[id] else { return "" }
        return try await provisioner(for: task).exportPatch(task)
    }

    /// Hands the task's work off (see `handOff`); kept for older callers.
    public func bringBack(_ id: UUID) async throws {
        try await handOff(id)
    }

    // MARK: Activity

    /// Polls the task's event log and container state while it runs.
    func watch(_ id: UUID) {
        watchers[id]?.cancel()
        watchers[id] = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.readNewEvents(id)
                if tick % 5 == 0 { await self?.refreshState(id) }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func replayEvents(_ id: UUID) {
        eventOffsets[id] = 0
        events[id] = []
        readNewEvents(id, notify: false)
    }

    /// Reads what the agent's hooks appended. The log is in a folder the agent writes, so it's
    /// read with `SafeFile` (no symlinks, no FIFOs) and at most `eventChunk` bytes at a time.
    private func readNewEvents(_ id: UUID, notify: Bool = true) {
        guard let task = tasks[id], let provider = Providers.provider(for: task.providerID) else { return }
        guard let file = SafeFile.open("events.jsonl", in: paths.events(id)) else { return }
        var offset = eventOffsets[id] ?? 0
        if file.size < offset { offset = 0 }
        try? file.handle.seek(toOffset: offset)
        guard let data = try? file.handle.read(upToCount: Self.eventChunk), !data.isEmpty else { return }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // A single line longer than a whole chunk isn't a hook event: skip it.
            if data.count == Self.eventChunk { eventOffsets[id] = offset + UInt64(data.count) }
            return
        }
        let complete = data[data.startIndex...lastNewline]
        eventOffsets[id] = offset + UInt64(complete.count)

        let configDir = paths.agentConfig(id).path
        let mount = provider.configMountPath
        let decoder = provider.eventDecoder { path in
            // Only a path inside the agent's config folder, mapped to the same place on the Mac.
            SafeFile.relativePath(path, under: mount).map { "\(configDir)/\($0)" }
        }
        var list = events[id] ?? []
        var activity = task.activity
        var newEvents: [AgentEvent] = []
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let event = decoder.decode(line: String(decoding: line, as: UTF8.self), index: list.count) else { continue }
            list.append(event)
            newEvents.append(event)
            activity = ActivityReducer.reduce(activity, event)
        }
        guard !newEvents.isEmpty else { return }
        events[id] = list

        if case .idle(nil) = activity, newEvents.last?.kind == .stop,
           let transcript = newEvents.last?.transcriptPath {
            activity = .idle(lastMessage: lastAgentMessage(id, transcript: transcript, provider: provider).map { UntrustedText.oneLine($0) })
        }
        exitStrikes[id] = nil
        let lastTimestamp = newEvents.last?.timestamp
        update(id) {
            $0.activity = activity
            $0.lastActivityAt = lastTimestamp
        }
        updateSink.yield(.events(id, list))
        // A finished turn's commits show up on the task branch in the user's repository.
        if newEvents.contains(where: { [.stop, .stopFailure, .sessionEnd].contains($0.kind) }) {
            Task { await self.syncTaskBranch(id) }
        }
        if notify, let last = newEvents.last, ActivityReducer.shouldNotify(last), let task = tasks[id] {
            updateSink.yield(.attention(task, last))
        }
    }

    /// How much of the event log is read per poll.
    static let eventChunk = 1 << 20

    /// The agent's last message, from its transcript: a file in the agent's config folder, read
    /// without following links and only its last few megabytes.
    func lastAgentMessage(_ id: UUID, transcript path: String, provider: any AgentProvider) -> String? {
        let root = paths.agentConfig(id)
        guard let relative = SafeFile.relativePath(path, under: root.path),
              let data = SafeFile.readTail(relative, in: root, limit: 8 << 20) else { return nil }
        return provider.lastMessageText(transcript: data)
    }

    /// Syncs the task's lifecycle with the container's actual state.
    private func refreshState(_ id: UUID) async {
        guard let task = tasks[id], let containerID = task.containerID, let runtime = runtimes[task.runtime] else { return }
        guard case .running = task.lifecycle else {
            if case .stopped = task.lifecycle, !briefStarts.contains(id), case .running? = try? await runtime.state(containerID) {
                update(id) { $0.lifecycle = .running }
                watch(id)
            }
            return
        }
        switch try? await runtime.state(containerID) {
        case .running?:
            if watchers[id] == nil { watch(id) }
            await checkAgentAlive(id, runtime: runtime, containerID: containerID)
            await refreshServices(id)
            await scanBlockedHosts(id, runtime: runtime, containerID: containerID)
            startUsagePoll(id)
            if Date.now.timeIntervalSince(packagesSynced[id] ?? .distantPast) > 30 {
                packagesSynced[id] = .now
                await syncInstalledPackages(id, runtime: runtime, containerID: containerID)
                await checkDecoyReads(id, runtime: runtime, containerID: containerID)
            }
        case .stopped?:
            update(id) {
                $0.lifecycle = .stopped
                $0.activity = .idle(lastMessage: nil)
            }
            watchers.removeValue(forKey: id)?.cancel()
            closeForwards(id)
        case .missing?:
            update(id) {
                $0.lifecycle = .stopped
                $0.containerID = nil
            }
            watchers.removeValue(forKey: id)?.cancel()
        case nil:
            break
        }
    }

    /// The container outlives the agent: when it exits, `exec zsh` takes over its pane.
    /// So the agent is alive while the pane's process has a child. tmux's own
    /// `pane_current_command` can't tell: it reports the shell even while the agent runs.
    /// Two strikes in a row avoid flagging the moment between the login shell and the agent.
    private func checkAgentAlive(_ id: UUID, runtime: any ContainerRuntime, containerID: String) async {
        guard let task = tasks[id], !(events[id] ?? []).isEmpty else { return }
        let probe = "pgrep -P \"$(tmux display-message -p -t \(ContainerPaths.tmuxSession) '#{pane_pid}')\" >/dev/null"
        guard let result = try? await runtime.exec(containerID, ExecSpec(["sh", "-c", probe], user: ContainerPaths.user)) else { return }
        if result.exitCode == 0 {
            exitStrikes[id] = nil
            if task.activity == .exited { update(id) { $0.activity = .idle(lastMessage: nil) } }
            return
        }
        guard task.activity != .exited else { return }
        exitStrikes[id, default: 0] += 1
        guard exitStrikes[id, default: 0] >= 2 else { return }
        exitStrikes[id] = nil
        update(id) { $0.activity = .exited }
        attention(id, .sessionEnd, "The agent exited")
    }

    /// Marks a task failed and tells whoever is listening.
    func fail(_ id: UUID, _ message: String) {
        update(id) { $0.lifecycle = .failed(message) }
        attention(id, .stopFailure, message)
    }

    /// Notifies about something that didn't come from the agent's own hooks.
    func attention(_ id: UUID, _ kind: AgentEvent.Kind, _ summary: String) {
        guard let task = tasks[id] else { return }
        let event = AgentEvent(id: (events[id]?.last?.id ?? -1) + 1, timestamp: .now, kind: kind, summary: summary)
        updateSink.yield(.attention(task, event))
    }

    // MARK: Helpers

    func runtime(for task: AgentTask) throws -> any ContainerRuntime {
        guard let runtime = runtimes[task.runtime] else { throw EngineError(Self.missingRuntimeReason(task.runtime)) }
        return runtime
    }

    func provider(for task: AgentTask) throws -> any AgentProvider {
        guard let provider = Providers.provider(for: task.providerID) else { throw EngineError("Unknown agent \(task.providerID.rawValue)") }
        return provider
    }

    func provisioner(for task: AgentTask) throws -> any WorkspaceProvisioner {
        Workspaces.provisioner(for: task, paths: paths, runtime: try runtime(for: task), user: ContainerPaths.user)
    }

    /// The secrets the agent is given. The GitHub token only goes to tasks that opted in.
    func loadSecrets(for provider: any AgentProvider, github: Bool) throws -> [SecretKey: String] {
        var values: [SecretKey: String] = [:]
        for key in provider.acceptedSecrets + (github ? [.githubToken] : []) {
            if let value = try secrets.get(key), !value.isEmpty { values[key] = value }
        }
        guard provider.acceptedSecrets.contains(where: { values[$0] != nil }) else {
            throw EngineError("Add a \(provider.displayName) token or API key in Settings before starting a task.")
        }
        return values
    }

    /// What the agent receives from these secrets; mirrors the provider's preference order.
    static func access(_ secrets: [SecretKey: String]) -> TaskAccess {
        let credential: TaskAccess.Credential? = secrets[.claudeOAuthToken] != nil ? .claudeToken
            : secrets[.anthropicAPIKey] != nil ? .apiKey : nil
        return TaskAccess(credential: credential, github: secrets[.githubToken] != nil)
    }

    func writeNetworkConfig(_ task: AgentTask, provider: any AgentProvider) throws -> URL {
        let url = paths.taskDir(task.id).appending(path: "network.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.networkConfig(task, provider: provider).write(to: url, options: .atomic)
        return url
    }

    /// What `airlock-firewall` reads: every allowed host or address, and whether GitHub is allowed.
    static func networkConfig(_ task: AgentTask, provider: any AgentProvider) throws -> Data {
        if let inspection = task.inspection {
            // Registries and the repository's host while downloading; nothing at all once it's closed.
            // Claude's API only through the proxy, and only when Claude investigates.
            var domains: [String] = []
            if inspection.phase == .preparing || inspection.phase == .downloading {
                domains = Inspection.downloadHosts
                if case .url(let text) = inspection.source, let host = URL(string: text)?.host { domains.append(host) }
            }
            let config: [String: Any] = ["domains": Array(Set(domains)).sorted(), "github": false,
                                         "proxyDomains": inspection.investigate ? provider.proxyHosts : []]
            return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        }
        if let sealing = task.sealing, sealing.phase == .sealed, case .restricted(let extra) = task.network {
            // Closed: only hosts the user allowed (and GitHub when opted in). Claude through the proxy.
            let config: [String: Any] = ["domains": Array(Set(extra)).sorted(), "github": task.githubAccess,
                                         "proxyDomains": provider.proxyHosts]
            return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        }
        var domains = provider.defaultAllowlist + (task.sealing != nil ? Inspection.downloadHosts : [])
        if case .restricted(let extra) = task.network { domains += extra }
        domains += (task.stack?.hosts ?? []) + NetworkRules.systemPackageHosts
        let config: [String: Any] = ["domains": Array(Set(domains)).sorted(), "github": task.githubAccess,
                                     "proxyDomains": provider.proxyHosts]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    private func containerEnvironment(_ task: AgentTask) async throws -> [String: String] {
        var env = ProjectStack.cacheEnvironment
        env["AIRLOCK_TASK_ID"] = task.id.uuidString
        // npm reads ~/.npmrc on every run, and in a sealed task that's a decoy.
        if task.isSealed { env["npm_config_userconfig"] = "/dev/null" }
        env["AIRLOCK_NETWORK"] = task.network.isRestricted ? "restricted" : "open"
        let repo = HostGit(URL(fileURLWithPath: task.repo.path))
        if let name = try? await repo.run("config", "user.name"), !name.isEmpty {
            env["GIT_AUTHOR_NAME"] = name
            env["GIT_COMMITTER_NAME"] = name
        }
        if let email = try? await repo.run("config", "user.email"), !email.isEmpty {
            env["GIT_AUTHOR_EMAIL"] = email
            env["GIT_COMMITTER_EMAIL"] = email
        }
        return env
    }

    func update(_ id: UUID, _ change: (inout AgentTask) -> Void) {
        guard var task = tasks[id] else { return }
        change(&task)
        task.updatedAt = .now
        replace(task)
    }

    func replace(_ task: AgentTask) {
        tasks[task.id] = task
        try? store.save(task)
        updateSink.yield(.task(task))
    }

    func log(_ id: UUID, _ line: String) {
        updateSink.yield(.log(id, line))
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

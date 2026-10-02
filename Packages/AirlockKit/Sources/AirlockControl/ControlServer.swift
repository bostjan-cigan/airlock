import AirlockCore
import AirlockEngine
import AirlockWorkspace
import Foundation
import NIOCore
import NIOPosix

/// Something a client (the chat) asked for that widens a task's sandbox. The user decides
/// in the app: a chat can be talked into asking by text the agent wrote, so its word isn't enough.
public struct ApprovalRequest: Sendable, Identifiable {
    public let id = UUID()
    /// "Let “Fix login” reach these hosts?"
    public var title: String
    /// What exactly: hosts, a port, kinds of access.
    public var items: [String]
    public var detail: String
    /// Set when the request is to hand a task's work off: the sheet shows the review.
    public var handoff: HandoffReview?
    /// The button that says yes ("Allow", "Hand Off").
    public var confirmTitle: String

    public init(title: String, items: [String], detail: String, handoff: HandoffReview? = nil, confirmTitle: String = "Allow") {
        self.title = title
        self.items = items
        self.detail = detail
        self.handoff = handoff
        self.confirmTitle = confirmTitle
    }
}

/// Serves the control protocol on a unix socket, backed by the app's engine.
///
/// The socket is created with owner-only permissions; anything that can open it
/// can already read and write the user's files.
public final class ControlServer: Sendable {
    let engine: TaskEngine
    let path: String
    /// Called when a client starts a task, so the app can surface it.
    let onTaskStarted: @Sendable (UUID) -> Void
    /// Runtime for tasks that don't name one (Settings › Runtimes).
    let defaultRuntime: @Sendable () -> RuntimeKind
    /// Asks the user about a request that widens a sandbox; false declines. Cancelled (and
    /// declined) after `approvalTimeout`.
    let approve: @Sendable (ApprovalRequest) async -> Bool
    let approvalTimeout: Duration

    public init(engine: TaskEngine, path: String, onTaskStarted: @escaping @Sendable (UUID) -> Void = { _ in },
                defaultRuntime: @escaping @Sendable () -> RuntimeKind = { RuntimeKind.savedDefault },
                approvalTimeout: Duration = .seconds(180),
                approve: @escaping @Sendable (ApprovalRequest) async -> Bool = { _ in false }) {
        self.engine = engine
        self.path = path
        self.onTaskStarted = onTaskStarted
        self.defaultRuntime = defaultRuntime
        self.approvalTimeout = approvalTimeout
        self.approve = approve
    }

    /// Throws unless the user allows `request` in the app in time.
    func requireApproval(_ request: ApprovalRequest) async throws {
        let (approve, timeout) = (self.approve, approvalTimeout)
        let allowed = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await approve(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch allowed {
        case true?: return
        case false?:
            throw EngineError("The user declined this in AIrlock (\(request.title)). Tell them; don't ask again unless they bring it up.")
        case nil:
            throw EngineError("Nobody answered in AIrlock in time (\(request.title)). Ask the user to look at the AIrlock window, then try again.")
        }
    }

    /// Runs until cancelled.
    public func run() async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        chmod(path, 0o600)
        try await server.executeThenClose { connections in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in connections {
                    group.addTask { await self.serve(connection) }
                }
            }
        }
    }

    private func serve(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        try? await connection.executeThenClose { inbound, outbound in
            var buffer: [UInt8] = []
            for try await var chunk in inbound {
                buffer += chunk.readBytes(length: chunk.readableBytes) ?? []
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    var reply = await handle(line)
                    reply.append(10)
                    try await outbound.write(ByteBuffer(bytes: reply))
                }
            }
        }
    }

    /// Decodes one request line and returns the encoded response.
    func handle(_ line: Data) async -> Data {
        let peek: MethodPeek
        do {
            peek = try ControlCoding.decoder.decode(MethodPeek.self, from: line)
        } catch {
            return encode(ResponseEnvelope<OK>(id: 0, result: nil, error: "Bad request: \(error)"))
        }
        do {
            switch peek.method {
            case .ping:
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: "AIrlock"), error: nil))
            case .startTask:
                let p: StartTaskParams = try params(line)
                return try await respond(peek.id, startTask(p))
            case .listTasks:
                var p: ListParams = (try? params(line)) ?? ListParams(repoPath: nil)
                p.repoPath = await normalized(p.repoPath)
                var projectID: UUID?
                if let name = p.project {
                    guard let project = await engine.findProject(name, repoPath: p.repoPath) else {
                        throw EngineError(await unknownProject(name, repoPath: p.repoPath))
                    }
                    projectID = project.id
                }
                return await respond(peek.id, engine.snapshots(repoPath: projectID == nil ? p.repoPath : nil, projectID: projectID, tag: p.tag))
            case .getTask:
                let p: TaskParams = try params(line)
                return try await respond(peek.id, snapshot(try await resolve(p.taskID)))
            case .waitForTask:
                let p: WaitParams = try params(line)
                let id = try await resolve(p.taskID)
                let timeout = Duration.seconds(min(max(p.timeoutSeconds ?? 600, 1), 3600))
                guard let snapshot = await engine.waitForUpdate(id, afterEventID: p.afterEventID, timeout: timeout) else {
                    throw EngineError("Task not found.")
                }
                return encode(ResponseEnvelope(id: peek.id, result: snapshot, error: nil))
            case .sendMessage:
                let p: MessageParams = try params(line)
                try await engine.sendMessage(try await resolve(p.taskID), p.text)
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: "Sent"), error: nil))
            case .getChanges:
                let p: ChangesParams = try params(line)
                return try await respond(peek.id, changes(try await resolve(p.taskID), includeDiff: p.includeDiff ?? false))
            case .bringBack, .handOff:
                let p: TaskParams = try params(line)
                let id = try await resolve(p.taskID)
                try await handOff(id)
                let task = await engine.task(id)
                let message = task?.repo.isPlainFolder == true
                    ? "Handed off: the task's work is applied to the files in \(task?.repo.path ?? "the folder")."
                    : "Handed off: the task's commits are on \(task?.workspace.branch ?? "its branch") in the user's repository."
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: message), error: nil))
            case .reviewHandoff:
                let p: TaskParams = try params(line)
                return respond(peek.id, try await engine.handoffReview(try await resolve(p.taskID)))
            case .stopTask:
                let p: TaskParams = try params(line)
                await engine.stop(try await resolve(p.taskID))
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: "Stopped"), error: nil))
            case .startStoppedTask:
                let p: TaskParams = try params(line)
                let id = try await resolve(p.taskID)
                Task { await engine.start(id) }
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: "Starting"), error: nil))
            case .watchTask:
                let p: WatchParams = try params(line)
                guard let progress = await engine.progress(try await resolve(p.taskID), after: p.afterEventID) else {
                    throw EngineError("Task not found.")
                }
                return respond(peek.id, progress)
            case .tagTask:
                let p: TagParams = try params(line)
                let id = try await resolve(p.taskID)
                try await engine.setTags(id, add: p.add ?? [], remove: p.remove ?? [])
                return try await respond(peek.id, snapshot(id))
            case .listProjects:
                let p: ProjectParams = (try? params(line)) ?? ProjectParams(name: nil, repoPath: nil)
                return await respond(peek.id, projectSnapshots(repoPath: await normalized(p.repoPath)))
            case .createProject:
                let p: ProjectParams = try params(line)
                guard let name = p.name, let repoPath = p.repoPath else { throw EngineError("name and repo_path are required.") }
                let root = try await workRoot(repoPath)
                var project = try await engine.createProject(name: name, repoPath: root)
                if let hosts = p.allowedHosts, !hosts.isEmpty {
                    try await requireApproval(ApprovalRequest(
                        title: "Let new tasks in “\(project.name)” reach \(hosts.count == 1 ? "this host" : "these hosts")?", items: hosts,
                        detail: "A Claude chat created this project and asked for these hosts on every new task's network."))
                    project = try await engine.setProjectHosts(project.id, add: hosts)
                }
                let list = await projectSnapshots(repoPath: root)
                return respond(peek.id, list.first { $0.id == project.id.uuidString } ?? list[0])
            case .exposePort:
                let p: PortParams = try params(line)
                let id = try await resolve(p.taskID)
                let what = p.service.map { "\($0)\(p.port.map { ":\($0)" } ?? "")" } ?? p.port.map { "port \($0)" } ?? "a port"
                try await requireApproval(ApprovalRequest(
                    title: "Open \(what) of “\(await engine.task(id)?.title ?? "a task")” on this Mac?", items: ["localhost\(p.hostPort.map { ":\($0)" } ?? "")"],
                    detail: "A Claude chat asked for this. What the task serves there can be opened in your browser and by other apps on this Mac."))
                let forward = try await engine.expose(id, port: p.port, hostPort: p.hostPort, service: p.service)
                return respond(peek.id, forward)
            case .unexposePort:
                let p: PortParams = try params(line)
                guard let port = p.port else { throw EngineError("port is required.") }
                await engine.unexpose(try await resolve(p.taskID), port: port)
                return respond(peek.id, OK(message: "Stopped forwarding \(port)."))
            case .listPorts:
                let p: TaskParams = try params(line)
                let id = try await resolve(p.taskID)
                return respond(peek.id, await portsResult(id))
            case .serviceLogs:
                let p: ServiceParams = try params(line)
                let text = try await engine.serviceLogs(try await resolve(p.taskID), service: p.service, tail: min(max(p.tail ?? 200, 1), 2000))
                return respond(peek.id, OK(message: text))
            case .restartService:
                let p: ServiceParams = try params(line)
                let id = try await resolve(p.taskID)
                try await engine.restartService(id, service: p.service)
                return try await respond(peek.id, snapshot(id))
            case .moveTask:
                let p: MoveParams = try params(line)
                let id = try await resolve(p.taskID)
                let repoPath = await engine.task(id)?.repo.path
                guard let project = await engine.findProject(p.project, repoPath: repoPath) else {
                    throw EngineError(await unknownProject(p.project, repoPath: repoPath))
                }
                try await engine.moveTask(id, to: project.id)
                return try await respond(peek.id, snapshot(id))
            case .updateFromBase:
                let p: TaskParams = try params(line)
                let id = try await resolve(p.taskID)
                let base = await engine.task(id)?.repo.baseRef ?? "the base branch"
                let message: String = switch try await engine.updateFromBase(id) {
                case .upToDate: "The task is up to date with \(base)."
                case .merged(let n): "Merged \(n) new commit\(n == 1 ? "" : "s") from \(base) into the task branch."
                case .askedAgent(let n): "Asked the agent to merge \(n) new commit\(n == 1 ? "" : "s") from \(base) and resolve any conflicts. Follow it with the watch command or wait_for_task."
                case .conflict(let files): "Merging \(base) conflicts in \(files.joined(separator: ", ")); nothing was changed. Resume the task and the agent can resolve them."
                }
                return encode(ResponseEnvelope(id: peek.id, result: OK(message: message), error: nil))
            case .allowDomains:
                let p: AllowDomainsParams = try params(line)
                return try await respond(peek.id, allowDomains(p))
            case .startInspection:
                let p: InspectionParams = try params(line)
                return try await respond(peek.id, startInspection(p))
            case .completeTask:
                let p: CompleteParams = try params(line)
                return try await respond(peek.id, completeTask(try await resolve(p.taskID), remove: p.removeContainers ?? false))
            }
        } catch {
            return encode(ResponseEnvelope<OK>(id: peek.id, result: nil, error: String(describing: error)))
        }
    }

    private func startTask(_ p: StartTaskParams) async throws -> TaskSnapshot {
        let repo = HostGit(URL(fileURLWithPath: p.repoPath))
        let root = try await workRoot(p.repoPath)
        var projectID: UUID?
        if let name = p.project, !name.isEmpty {
            // Never create a project implicitly: the caller decides, with the user.
            guard let project = await engine.findProject(name, repoPath: root) else {
                throw EngineError(await unknownProject(name, repoPath: root))
            }
            projectID = project.id
        }
        var baseRef = p.baseRef ?? ""
        if baseRef.isEmpty {
            baseRef = (try? await repo.run("branch", "--show-current")).flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        }
        let runtime = p.runtime.flatMap(RuntimeKind.init) ?? defaultRuntime()
        // An isolated clone unless the chat asks for a worktree by name.
        let mode: WorkspaceSpec.Mode = p.workspace == "worktree" ? .worktree : .volumeClone
        let network: NetworkProfile = p.network == "open" ? .open : .restricted(extraDomains: p.extraDomains ?? [])
        // Sealed unless the chat asks for a restricted (registries open) or open network.
        let sealed = p.network != "restricted" && p.network != "open"
        let title = p.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(p.prompt.split(separator: "\n").first ?? "Handed-off task").prefix(60).description

        let status = await engine.runtimeStatus()[runtime]
        guard status?.isAvailable == true else {
            if case .unavailable(let reason)? = status {
                throw EngineError(p.runtime == nil ? "\(reason) (\(runtime.displayName) is the default in AIrlock Settings › Runtimes.)" : reason)
            }
            throw EngineError("\(runtime.displayName) isn't available.")
        }

        var wider: [String] = []
        if network == .open { wider.append("An open network: any host on the internet") }
        if case .restricted(let extra) = network, !extra.isEmpty { wider.append("Extra hosts: \(extra.joined(separator: ", "))") }
        if p.github == true { wider.append("Your GitHub token, and GitHub on its network") }
        if !wider.isEmpty {
            try await requireApproval(ApprovalRequest(
                title: "Start “\(title)” with more access?", items: wider,
                detail: "A Claude chat is starting this task in \(URL(fileURLWithPath: root).lastPathComponent) and asked for more than the usual sandbox."))
        }

        let resources = await explicitResources(p)
        let task = try await engine.create(
            NewTaskRequest(title: title, prompt: p.prompt, repoPath: root, baseRef: baseRef,
                           runtime: runtime, workspaceMode: mode, network: network, resources: resources,
                           projectID: projectID, tags: p.tags ?? [], services: p.services ?? false, expose: p.expose ?? [],
                           github: p.github ?? false, sealed: sealed),
            origin: .chat(label: p.origin)
        )
        onTaskStarted(task.id)
        return try await snapshot(task.id)
    }

    /// Starts inspecting an untrusted repository. Nothing about it widens a sandbox (it has
    /// no tokens, and its network closes), so it needs no approval.
    private func startInspection(_ p: InspectionParams) async throws -> TaskSnapshot {
        let text = p.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: Inspection.Source = text.lowercased().hasPrefix("https://") ? .url(text) : .folder(text)
        // Apple VMs by default: each has its own Linux kernel. Docker when asked, or when there's no other.
        let status = await engine.runtimeStatus()
        let runtime: RuntimeKind
        if let asked = p.runtime.flatMap(RuntimeKind.init) {
            runtime = asked
        } else {
            runtime = status[.apple]?.isAvailable == true ? .apple : .docker
        }
        guard status[runtime]?.isAvailable == true else {
            if case .unavailable(let reason)? = status[runtime] { throw EngineError(reason) }
            throw EngineError("\(runtime.displayName) isn't available.")
        }
        let task = try await engine.createInspection(
            InspectionRequest(source: source, command: p.command, investigate: p.investigate ?? false, runtime: runtime),
            origin: .chat(label: p.origin))
        onTaskStarted(task.id)
        return try await snapshot(task.id)
    }

    /// Work leaves the sandbox only with two yeses: the chat asked (after reviewing it with the
    /// user), and the user confirms the same review in the app.
    private func handOff(_ id: UUID) async throws {
        let review = try await engine.handoffReview(id)
        guard !review.nothingNew || review.plainFolder else {
            throw EngineError("Nothing new to hand off: \(review.branch) is already in the user's repository as it is.")
        }
        try await requireApproval(Self.handoffRequest(review))
        try await engine.handOff(id)
    }

    public static func handoffRequest(_ review: HandoffReview) -> ApprovalRequest {
        var items = [review.summary]
        if let setup = review.setup { items.append("Setup: \(setup)") }
        items += review.attention.map { "\($0.path): \($0.reason)" }
        if let n = review.uncommitted, n > 0 { items.append("\(n) uncommitted file\(n == 1 ? "" : "s") stay behind") }
        return ApprovalRequest(
            title: "Hand off “\(review.title)”?", items: items,
            detail: review.plainFolder
                ? "Its work is applied to the folder’s files. Asked from a Claude chat, which reviewed the changes with you."
                : "Its branch appears in your repository. Nothing else leaves the container. Asked from a Claude chat, which reviewed the changes with you.",
            handoff: review, confirmTitle: "Hand Off")
    }

    /// Marks a task done and, when asked, stops and deletes its containers and workspace.
    /// Isolated-clone commits are fetched into the host repository first, so only the
    /// uncommitted changes are lost; the task branch is kept.
    private func completeTask(_ id: UUID, remove: Bool) async throws -> CompleteResult {
        guard let task = await engine.task(id) else { throw EngineError("Task not found.") }
        await engine.setDone(id, true)
        let isolatedClone = task.workspace.mode == .volumeClone
        var result = CompleteResult(shortID: task.shortID, title: task.title, branch: task.workspace.branch, removed: false,
                                    broughtBack: false, isolatedClone: isolatedClone, uncommittedFiles: await engine.uncommittedFileCount(id),
                                    plainFolder: task.repo.isPlainFolder ? true : nil)
        guard remove else { return result }
        if task.repo.isPlainFolder {
            // Applying the work to the folder is a handoff: the user confirms it in the app
            // (a task that never started has nothing to apply).
            if task.workspace.baseCommit != nil {
                let review = try await engine.handoffReview(id)
                try await requireApproval(Self.handoffRequest(review))
            }
            // Applies the work to the folder first; a conflict throws before anything is deleted.
            let release = try await engine.remove(id, applyToFolder: true)
            result.broughtBack = true
            result.removed = true
            switch release {
            case .removed?: result.folderGit = "AIrlock's temporary .git was deleted; the folder is plain again."
            case .kept(let reason)?: result.folderGit = "The folder's .git was kept and is now the user's: \(reason)"
            case .notManaged?, nil: break
            }
            return result
        }
        if !task.isInspection, await engine.hasWorkToHandOff(id) {
            throw EngineError("""
            Marked done, but nothing was deleted: this task's work hasn't been handed off. Review it with get_changes, \
            go through it with the user, then hand_off (they confirm in AIrlock) and complete_task again. Or, if the \
            user doesn't want the work, they can delete the task in the AIrlock app.
            """)
        }
        try await engine.remove(id)
        result.removed = true
        return result
    }

    /// A size from chat: whichever of CPU and memory is given, the other one automatic.
    private func explicitResources(_ p: StartTaskParams) async -> ResourceLimits? {
        guard p.cpus != nil || p.memoryGB != nil else { return nil }
        let auto = await engine.planResources(repoPath: p.repoPath, projectID: nil).limits
        return ResourceLimits(cpus: min(max(p.cpus ?? auto.cpus, 1), 32),
                              memoryMB: min(max(p.memoryGB.map { $0 * 1024 } ?? auto.memoryMB, 1024), 131_072))
    }

    private func allowDomains(_ p: AllowDomainsParams) async throws -> AllowDomainsResult {
        guard p.taskID != nil || p.project != nil else { throw EngineError("Give a task_id, a project, or both.") }
        guard !(p.add ?? []).isEmpty || !(p.remove ?? []).isEmpty else { throw EngineError("Nothing to add or remove.") }
        if let add = p.add, !add.isEmpty {
            var whom: [String] = []
            if let text = p.taskID, let id = await engine.resolveTaskID(text), let task = await engine.task(id) { whom.append("“\(task.title)”") }
            if let project = p.project { whom.append("new tasks in project “\(project)”") }
            try await requireApproval(ApprovalRequest(
                title: "Let \(whom.joined(separator: " and ")) reach \(add.count == 1 ? "this host" : "these hosts")?", items: add,
                detail: "A Claude chat asked for this. The agent can then send and receive anything there."))
        }
        var result = AllowDomainsResult()
        var projectID: UUID?
        if let text = p.taskID {
            let id = try await resolve(text)
            result.taskShortID = await engine.task(id)?.shortID
            result.task = try await engine.setAllowedHosts(id, add: p.add ?? [], remove: p.remove ?? [], by: "from chat")
            projectID = await engine.task(id)?.projectID
        }
        if let name = p.project {
            // Within the task's repository first, so a name several repositories use resolves.
            var taskRepo: String?
            if let projectID { taskRepo = await engine.project(projectID)?.repoPath }
            var found = await engine.findProject(name, repoPath: taskRepo)
            if found == nil { found = await engine.findProject(name) }
            guard let project = found else { throw EngineError(await unknownProject(name, repoPath: nil)) }
            let updated = try await engine.setProjectHosts(project.id, add: p.add ?? [], remove: p.remove ?? [])
            result.project = updated.name
            result.projectHosts = updated.allowedHosts
        }
        return result
    }

    private func changes(_ id: UUID, includeDiff: Bool) async throws -> ChangesResult {
        let c = try await engine.changes(id)
        let branch = await engine.task(id)?.workspace.branch ?? ""
        let limit = 60_000
        return ChangesResult(
            branch: branch,
            files: c.files.map { .init(path: $0.path, kind: $0.kind.rawValue, additions: $0.additions, deletions: $0.deletions) },
            commits: c.commits,
            diff: includeDiff ? (c.diff.count > limit ? String(c.diff.prefix(limit)) + "\n…(diff truncated)" : c.diff) : nil
        )
    }

    private func portsResult(_ id: UUID) async -> PortsResult {
        let task = await engine.task(id)
        let forwarded = task?.ports ?? []
        let declared = (task?.services?.items ?? []).flatMap(\.ports)
        let listening = await engine.listeningPorts(id)
        let taken = Set(forwarded.map(\.containerPort))
        return PortsResult(forwarded: forwarded, suggestions: Array(Set(declared + listening).subtracting(taken)).sorted())
    }

    /// The repository root for a path inside one, or the folder itself when it's in no repository.
    private func workRoot(_ path: String) async throws -> String {
        if let root = try? await HostGit(URL(fileURLWithPath: path)).run("rev-parse", "--show-toplevel") { return root }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError("No folder at \(path).")
        }
        // Resolved like git resolves a repository root, so the path stays the same once AIrlock adds a .git.
        return Workspaces.realPath(path)
    }

    /// The repository root for a path inside it, so paths match what tasks and projects store.
    private func normalized(_ path: String?) async -> String? {
        guard let path else { return nil }
        return (try? await workRoot(path)) ?? path
    }

    private func projectSnapshots(repoPath: String?) async -> [ProjectSnapshot] {
        let tasks = await engine.allTasks()
        return TaskGrouping.sortedProjects(await engine.projects(), tasks: tasks)
            .filter { repoPath == nil || $0.repoPath == repoPath }
            .map { project in
                let own = tasks.filter { $0.projectID == project.id }
                return ProjectSnapshot(id: project.id.uuidString, name: project.name, repoPath: project.repoPath,
                                       activeTasks: own.filter { $0.statusGroup != .recent }.count, totalTasks: own.count,
                                       allowedHosts: project.allowedHosts)
            }
    }

    private func unknownProject(_ name: String, repoPath: String?) async -> String {
        let names = await engine.projects().filter { repoPath == nil || $0.repoPath == repoPath }.map { "“\($0.name)”" }
        let scope = repoPath.map { " for \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        let existing = names.isEmpty ? "There are no projects\(scope) yet." : "Projects\(scope): \(names.joined(separator: ", "))."
        return "No project named “\(name)”. \(existing) Use create_project if the user wants a new one."
    }

    private func resolve(_ text: String) async throws -> UUID {
        guard let id = await engine.resolveTaskID(text) else { throw EngineError("No task matches \(text).") }
        return id
    }

    private func snapshot(_ id: UUID) async throws -> TaskSnapshot {
        guard let s = await engine.snapshot(id) else { throw EngineError("Task not found.") }
        return s
    }

    private func params<P: Codable>(_ line: Data) throws -> P {
        guard let p = try ControlCoding.decoder.decode(RequestEnvelope<P>.self, from: line).params else {
            throw EngineError("Missing params.")
        }
        return p
    }

    private func respond<R: Codable>(_ id: Int, _ result: R) -> Data {
        encode(ResponseEnvelope(id: id, result: result, error: nil))
    }

    private func encode<R: Codable>(_ envelope: ResponseEnvelope<R>) -> Data {
        (try? ControlCoding.encoder.encode(envelope)) ?? Data(#"{"id":0,"error":"encoding failed"}"#.utf8)
    }
}


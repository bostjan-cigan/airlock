import AirlockApple
import AirlockControl
import AppKit
import AirlockCore
import AirlockDocker
import AirlockEngine
import AirlockRuntime
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications

/// UI-side mirror of the engine's state.
@MainActor
@Observable
public final class AppModel {
    public let engine: TaskEngine
    public let secrets: any SecretStore
    public let appleAssets: AppleRuntimeAssets

    public private(set) var tasks: [UUID: AgentTask] = [:]
    public private(set) var projects: [Project] = []
    public private(set) var events: [UUID: [AgentEvent]] = [:]
    public private(set) var logs: [UUID: [String]] = [:]
    public private(set) var runtimeStatus: [RuntimeKind: RuntimeAvailability] = [:]
    /// Kernel download progress (0...1) while installing Apple VM support.
    public private(set) var kernelDownload: Double?
    /// What the sidebar shows in the task list.
    public var scope: SidebarScope = .active
    public var selection: UUID?
    public var filterText = ""
    public var isPresentingNewTask = false
    public var isPresentingNewProject = false
    public var errorMessage: String?
    /// The allowlist sheet: a task's hosts, or a project's defaults.
    public var networkEditor: NetworkEditTarget?
    /// The "wants to connect to" prompt for a task's blocked hosts.
    public var blockedReview: TaskRef?
    /// The Hand Off review for a task.
    public var handoffSheet: TaskRef?
    /// Hosts the firewall found no addresses for at the last change, per task.
    public private(set) var unresolvedHosts: [UUID: Set<String>] = [:]
    /// What each running task's containers use now, by container ("agent" or a service).
    public private(set) var usage: [UUID: [String: ResourceUsage]] = [:]
    /// True while AIrlock holds off idle sleep for running tasks.
    public private(set) var keepsMacAwake = false
    /// Seeded sample data on a fake runtime (`AIrlock --demo`); see `AppModel.demo()`.
    public internal(set) var isDemo = false
    /// `--demo --screenshots`: no Demo badge in the toolbar.
    public internal(set) var hidesDemoBadge = false
    /// The tab a newly selected task opens on; the screenshot tour changes it.
    var demoDetailTab: DetailTab = .terminal
    /// The screenshot tour opens the New Task sheet with its options showing.
    var demoShowsNewTaskOptions = false
    /// Bumped to ask the always-present menu bar label to open the main window.
    public private(set) var windowRequest = 0
    /// Requests from a chat that widen a sandbox, waiting for the user (oldest first).
    public private(set) var approvals: [ApprovalRequest] = []

    @ObservationIgnored let terminals = TerminalRegistry()
    /// Holds off idle sleep while tasks are starting or working.
    @ObservationIgnored private var awakeAssertion: IOPMAssertionID?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var controlServer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var approvalAnswers: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(engine: TaskEngine, secrets: any SecretStore, appleAssets: AppleRuntimeAssets) {
        self.engine = engine
        self.secrets = secrets
        self.appleAssets = appleAssets
    }

    /// The real app wiring: Keychain secrets and whichever runtimes are installed.
    public static func live() -> AppModel {
        let paths = Paths.default
        let assets = AppleRuntimeAssets(root: paths.root.appending(path: "apple", directoryHint: .isDirectory))
        let docker = DockerRuntime.discover()
        var runtimes: [RuntimeKind: any ContainerRuntime] = [:]
        if let docker { runtimes[.docker] = docker }
        runtimes[.apple] = AppleContainerRuntime(assets: assets, builder: docker)
        let secrets = KeychainSecretStore()
        return AppModel(engine: TaskEngine(paths: paths, secrets: secrets, runtimes: runtimes), secrets: secrets, appleAssets: assets)
    }

    public func start() async {
        guard !started else { return }
        started = true
        for task in await engine.bootstrap() {
            tasks[task.id] = task
            events[task.id] = await engine.events(for: task.id)
        }
        projects = await engine.projects()
        if isDemo { await applyDemoOverrides() }
        if isDemo, let folder = ScreenshotTour.folder {
            Task { await ScreenshotTour(model: self, folder: folder).run() }
        }
        await refreshRuntimes()
        // The demo never takes the real app's place for the plugin.
        if !isDemo {
            startControlServer()
            startMaintenance()
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.blockedCategory, actions: [
                UNNotificationAction(identifier: Self.allowAction, title: "Allow"),
            ], intentIdentifiers: []),
        ])
        for await update in engine.updates {
            apply(update)
        }
    }

    func apply(_ update: EngineUpdate) {
        switch update {
        case .task(let task):
            tasks[task.id] = task
            updateKeepAwake()
        case .projects(let list):
            projects = list
            if case .project(let id) = scope, !list.contains(where: { $0.id == id }) { scope = .active }
        case .removed(let id):
            tasks[id] = nil
            events[id] = nil
            logs[id] = nil
            usage[id] = nil
            terminals.close(id)
            if selection == id { selection = nil }
        case .events(let id, let list):
            events[id] = list
        case .log(let id, let line):
            let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            logs[id, default: []].append(clean)
            if logs[id]!.count > 500 { logs[id]!.removeFirst(logs[id]!.count - 500) }
        case .attention(let task, let event):
            notify(task, event)
        case .blocked(let task, _):
            notifyBlocked(task)
        case .usage(let id, let readings):
            usage[id] = readings
        }
    }

    /// Lets the Claude plugin (via `AIrlock --mcp`) start and follow tasks.
    private func startControlServer() {
        let server = ControlServer(engine: engine, path: ControlSocket.path(for: engine.paths), approve: { [weak self] request in
            await self?.requestApproval(request) ?? false
        })
        controlServer = Task.detached {
            do {
                try await server.run()
            } catch {
                await MainActor.run { self.errorMessage = "The plugin bridge couldn't start: \(error)" }
            }
        }
    }

    // MARK: Approvals

    /// Asks the user about a chat's request to widen a sandbox. Declined if the request is
    /// cancelled (the chat stopped waiting).
    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalAnswers[request.id] = continuation
                approvals.append(request)
                notifyApproval(request)
                openWindow()
                NSApp.activate()
            }
        } onCancel: {
            Task { @MainActor in self.answerApproval(request.id, allowed: false) }
        }
    }

    public func answerApproval(_ id: UUID, allowed: Bool) {
        approvals.removeAll { $0.id == id }
        approvalAnswers.removeValue(forKey: id)?.resume(returning: allowed)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval-\(id.uuidString)"])
    }

    private func notifyApproval(_ request: ApprovalRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.items.joined(separator: ", ")
        content.userInfo = ["approval": request.id.uuidString]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-\(request.id.uuidString)", content: content, trigger: nil))
    }

    /// States the demo can't save to disk, applied once its tasks are loaded.
    private func applyDemoOverrides() async {
        let file = engine.paths.root.appending(path: "demo-starting.json")
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        for id in ids.compactMap(UUID.init(uuidString:)) {
            guard var task = tasks[id] else { continue }
            task.lifecycle = .buildingImage
            task.activity = .unknown
            await engine.overrideForDemo(task)
            tasks[id] = task
        }
    }

    public func refreshRuntimes() async {
        if isDemo {
            runtimeStatus = await engine.runtimeStatus()
            return
        }
        if runtimeStatus[.docker]?.isAvailable != true, let docker = DockerRuntime.discover() {
            await engine.setRuntime(docker, for: .docker)
            if runtimeStatus[.apple]?.isAvailable != true {
                await engine.setRuntime(AppleContainerRuntime(assets: appleAssets, builder: docker), for: .apple)
            }
        }
        runtimeStatus = await engine.runtimeStatus()
    }

    /// Downloads the Linux kernel Apple VMs boot.
    public func installAppleKernel() async {
        kernelDownload = 0
        defer { kernelDownload = nil }
        do {
            try await appleAssets.installKernel { value in
                Task { @MainActor in self.kernelDownload = value }
            }
        } catch {
            errorMessage = "Couldn't install the kernel: \(error)"
        }
        await refreshRuntimes()
    }

    // MARK: Derived state

    public var selectedTask: AgentTask? { selection.flatMap { tasks[$0] } }
    public var runningCount: Int { tasks.values.filter { $0.statusGroup == .running }.count }
    public var needsYou: [AgentTask] { sorted(tasks.values.filter { $0.statusGroup == .needsYou }) }
    public var running: [AgentTask] { sorted(tasks.values.filter { $0.statusGroup == .running }) }

    /// Tasks in the current scope, after the filter field.
    public var scopedTasks: [AgentTask] {
        TaskGrouping.filter(TaskGrouping.tasks(Array(tasks.values), in: scope), query: filterText) { self.project(for: $0)?.name }
    }

    public var sortedProjects: [Project] { TaskGrouping.sortedProjects(projects, tasks: Array(tasks.values)) }
    public var allTags: [String] { TaskGrouping.tags(Array(tasks.values)) }

    public func project(for task: AgentTask) -> Project? { projects.first { $0.id == task.projectID } }
    public func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    public func count(_ scope: SidebarScope) -> Int {
        TaskGrouping.tasks(Array(tasks.values), in: scope).filter { $0.statusGroup != .recent }.count
    }

    /// Whether more than one project shares this project's repository.
    public func repoIsShared(_ project: Project) -> Bool {
        projects.filter { $0.repoPath == project.repoPath }.count > 1
    }

    /// The agent's latest reported step in its current turn.
    public func milestone(_ task: AgentTask) -> String? { events[task.id]?.currentMilestone }

    private func sorted(_ list: [AgentTask]) -> [AgentTask] { list.sorted { $0.recency > $1.recency } }

    /// Selects a task (switching the sidebar if it's out of scope) and opens the window.
    public func reveal(_ id: UUID) {
        if let task = tasks[id], !TaskGrouping.tasks([task], in: scope).isEmpty {
            // Already visible.
        } else if let task = tasks[id], let projectID = task.projectID {
            scope = .project(projectID)
        } else {
            scope = .all
        }
        filterText = ""
        selection = id
        windowRequest += 1
    }

    public func openWindow() { windowRequest += 1 }

    /// Apple VM tasks that stop when the app quits.
    public var tasksEndingWithApp: [AgentTask] {
        tasks.values.filter { $0.runtime == .apple && $0.lifecycle.isActive }
    }

    public func prepareForQuit() async {
        terminals.closeAll()
        await engine.prepareForQuit()
    }

    // MARK: Actions

    public func createTask(_ request: NewTaskRequest) async {
        guard !isDemo else {
            errorMessage = "Demo mode doesn’t start tasks. Quit and open AIrlock without --demo to run one."
            return
        }
        do {
            let task = try await engine.create(request)
            tasks[task.id] = task
            reveal(task.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func perform(_ action: @escaping (TaskEngine) async throws -> Void) {
        Task {
            do { try await action(engine) } catch { errorMessage = String(describing: error) }
        }
    }

    public func createProject(name: String, repoPath: String) async {
        do {
            let project = try await engine.createProject(name: name, repoPath: repoPath)
            projects = await engine.projects()
            scope = .project(project.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func notify(_ task: AgentTask, _ event: AgentEvent) {
        // A turn that ended on blocked hosts: the allow prompt is what the user needs.
        if event.kind == .stop, !task.blockedHosts.isEmpty { return notifyBlocked(task) }
        let content = UNMutableNotificationContent()
        content.title = task.title
        switch event.kind {
        case .stop:
            content.subtitle = "Finished"
            if case .idle(let message?) = task.activity { content.body = message }
        case .stopFailure:
            content.subtitle = "Failed"
            content.body = event.summary
        case .sessionEnd:
            content.subtitle = "Agent exited"
            content.body = "Start it again from AIrlock to continue."
        default:
            content.subtitle = "Needs you"
            content.body = event.summary
        }
        content.userInfo = ["task": task.id.uuidString]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Day to day

    /// Keeps the Mac from idle sleep while any task is starting or working; closing the lid
    /// still sleeps it.
    private func updateKeepAwake() {
        let busy = tasks.values.contains { $0.status == .starting || $0.status == .working }
        if busy, awakeAssertion == nil {
            var id: IOPMAssertionID = 0
            let reason = "AIrlock tasks are running" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                awakeAssertion = id
            }
        } else if !busy, let id = awakeAssertion {
            IOPMAssertionRelease(id)
            awakeAssertion = nil
        }
        if keepsMacAwake != (awakeAssertion != nil) { keepsMacAwake = awakeAssertion != nil }
    }

    /// Once at launch and then daily: a newer Claude Code, and old finished tasks.
    private func startMaintenance() {
        maintenance = Task { [engine] in
            while !Task.isCancelled {
                await engine.refreshAgentVersion()
                if UserDefaults.standard.object(forKey: Self.autoCleanKey) as? Bool ?? true {
                    await engine.removeFinishedTasks(olderThan: 7)
                }
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    public static let autoCleanKey = "removeFinishedTasks"

    // MARK: Network

    public nonisolated static let blockedCategory = "blocked-hosts"
    public nonisolated static let allowAction = "allow"

    /// One notification per task (replaced as more hosts are blocked), with an Allow action.
    private func notifyBlocked(_ task: AgentTask) {
        guard let summary = task.blockedSummary else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.subtitle = summary
        content.body = "Allow it to reach \(task.blockedHosts.count == 1 ? "this host" : "these hosts"), or review in AIrlock."
        content.categoryIdentifier = Self.blockedCategory
        content.userInfo = ["task": task.id.uuidString]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "blocked-\(task.id.uuidString)", content: content, trigger: nil))
    }

    /// Allows hosts the task was refused, and optionally keeps them for the project's new tasks.
    public func allowBlocked(_ id: UUID, _ hosts: [String], forProject: Bool = false) async {
        guard let task = tasks[id], !hosts.isEmpty else { return }
        do {
            let change = try await engine.setAllowedHosts(id, add: hosts)
            unresolvedHosts[id] = Set(change.unresolved)
            if forProject, let projectID = task.projectID {
                try await engine.setProjectHosts(projectID, add: hosts)
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["blocked-\(id.uuidString)"])
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Every host the task is currently blocked on (the notification's Allow action).
    public func allowAllBlocked(_ id: UUID) async {
        await allowBlocked(id, tasks[id]?.blockedHosts.map(\.name) ?? [])
    }

    public func declineBlocked(_ id: UUID, _ hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        await engine.ignoreBlockedHosts(id, hosts)
        if tasks[id]?.blockedHosts.isEmpty ?? true {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["blocked-\(id.uuidString)"])
        }
    }

    /// Adds a host from the allowlist sheet. Returns a message to show inline when it's not valid.
    public func addHost(_ host: String, to target: NetworkEditTarget) async -> String? {
        do {
            switch target {
            case .task(let id):
                let change = try await engine.setAllowedHosts(id, add: [host])
                unresolvedHosts[id] = Set(change.unresolved)
            case .project(let id):
                try await engine.setProjectHosts(id, add: [host])
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    public func removeHosts(_ hosts: [String], from target: NetworkEditTarget) async {
        do {
            switch target {
            case .task(let id): try await engine.setAllowedHosts(id, remove: hosts)
            case .project(let id): try await engine.setProjectHosts(id, remove: hosts)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// What the allowlist sheet edits.
public enum NetworkEditTarget: Identifiable, Hashable, Sendable {
    case task(UUID)
    case project(UUID)

    public var id: String {
        switch self {
        case .task(let id): "task-\(id)"
        case .project(let id): "project-\(id)"
        }
    }
}

/// A task to present a sheet for.
public struct TaskRef: Identifiable, Hashable, Sendable {
    public var id: UUID
    public init(_ id: UUID) { self.id = id }
}

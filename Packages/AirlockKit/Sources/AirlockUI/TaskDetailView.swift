import AirlockCore
import AirlockEngine
import AirlockWorkspace
import AppKit
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case changes = "Changes"
    case report = "Report"
    var id: String { rawValue }

    /// An inspection has a report instead of changes: nothing comes out of it.
    static func tabs(for task: AgentTask) -> [DetailTab] {
        task.isInspection ? [.report, .terminal] : [.terminal, .changes]
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var tab: DetailTab
    /// The inspector stays as the user left it, across tasks and launches.
    @AppStorage("inspectorShown") private var inspectorShown = true
    @AppStorage("inspectorTab") private var inspectorTab: InspectorTab = .containers

    init(task: AgentTask, tab: DetailTab = .terminal) {
        self.task = task
        _tab = State(initialValue: task.isInspection ? .report : tab)
    }

    var body: some View {
        TaskDetailColumn(task: task, tab: $tab) {
            inspectorTab = .access
            inspectorShown = true
        }
        .navigationTitle(task.title)
        .navigationSubtitle(model.project(for: task)?.name ?? task.repo.name)
        .inspector(isPresented: $inspectorShown) {
            TaskInspector(task: task, tab: $inspectorTab)
                .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItemGroup {
                if task.lifecycle == .running {
                    Button { model.perform { await $0.stop(task.id) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop the container. Its files are kept.")
                } else if !task.lifecycle.isActive {
                    Button { model.perform { await $0.start(task.id) } } label: { Label("Start", systemImage: "play.fill") }
                        .help("Start the container and resume the agent’s conversation")
                }
                Menu { TaskActions(task: task) } label: { Label("More", systemImage: "ellipsis.circle") }
                    .help("More")
                Button { inspectorShown.toggle() } label: { Label("Info", systemImage: "info.circle") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(inspectorShown ? "Hide Info (⌥⌘I)" : "Show Info (⌥⌘I)")
            }
        }
    }
}

/// Header, banner, the Terminal/Changes switch and the chosen tab, filling the column.
struct TaskDetailColumn: View {
    let task: AgentTask
    @Binding var tab: DetailTab
    let showAccess: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TaskHeader(task: task, showAccess: showAccess)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            BlockedBanner(task: task)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            Picker("", selection: $tab) {
                ForEach(DetailTab.tabs(for: task)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 12)
            Divider()
            // Each tab takes the rest of the height, so the header stays at the top
            // whatever the tab's own content wants.
            Group {
                switch tab {
                case .terminal: TerminalTab(task: task)
                case .changes: ChangesTab(task: task)
                case .report: InspectionReportView(task: task)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Title, then one line: status (with its dot), project, and when it started. A task with
/// more access than the default sandbox gets one button naming it.
struct TaskHeader: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    let showAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Circle()
                    .fill(task.statusColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(task.simpleStatus).fontWeight(.medium) + Text(rest).foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let elevated = task.elevatedSummary {
                Button(action: showAccess) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(elevated)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .help("Show this task’s access")
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "· api · Started 10:41"
    var rest: String {
        let project = model.project(for: task)?.name ?? task.repo.name
        let minutes = Date.now.timeIntervalSince(task.createdAt) / 60
        let started = minutes < 60
            ? task.createdAt.formatted(.relative(presentation: .named))
            : StartTime.short(task.createdAt)
        return "  ·  \(project)  ·  Started \(started)"
    }

    /// What the agent asked, or why it failed. Blocked hosts have their own banner.
    var detail: String? {
        guard task.blockedHosts.isEmpty || task.status != .needsInput else { return nil }
        switch task.status {
        case .needsInput, .failed: return task.statusDetail
        default: return nil
        }
    }
}

/// Where to open the task's work.
struct OpenActions: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask

    var body: some View {
        if let path = task.workspace.hostPath {
            Button("VS Code") { openChecked { openInEditor(path) } }
            Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Terminal") { openChecked { openInTerminal(path) } }
            Divider()
        }
        Button("Copy branch name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.workspace.branch, forType: .string)
        }
    }

    /// Editors and shells run git in the folder, with settings the agent may have changed.
    func openChecked(_ open: @escaping @MainActor () -> Void) {
        let (engine, id) = (model.engine, task.id)
        Task { @MainActor in
            if let problem = await engine.openOnMacProblem(id) {
                model.errorMessage = problem
            } else {
                open()
            }
        }
    }

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Context menu for a task row.
struct TaskActions: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask

    var body: some View {
        if task.lifecycle == .running {
            Button("Stop") { model.perform { await $0.stop(task.id) } }
            Button("Restart agent") { model.perform { await $0.restartAgent(task.id) } }
        } else if !task.lifecycle.isActive {
            Button("Start") { model.perform { await $0.start(task.id) } }
        }
        Button(task.isDone ? "Mark as not done" : "Mark as done") {
            model.perform { await $0.setDone(task.id, !task.isDone) }
        }
        Divider()
        Menu("Open") { OpenActions(task: task) }
        Button("Network…") { model.networkEditor = .task(task.id) }
        Menu("Tags") {
            ForEach(model.allTags, id: \.self) { tag in
                Toggle(tag, isOn: Binding(
                    get: { task.tags.contains(tag) },
                    set: { on in model.perform { try await $0.setTags(task.id, add: on ? [tag] : [], remove: on ? [] : [tag]) } }
                ))
            }
            if !model.allTags.isEmpty { Divider() }
            Button("New tag…") { promptForTag() }
        }
        let siblings = model.projects.filter { $0.repoPath == task.repo.path && $0.id != task.projectID }
        if !siblings.isEmpty {
            Menu("Move to project") {
                ForEach(siblings) { project in
                    Button(project.name) { model.perform { try await $0.moveTask(task.id, to: project.id) } }
                }
            }
        }
        if !task.isInspection {
            Button("Hand Off…") { model.handoffSheet = TaskRef(task.id) }
        }
        Divider()
        Button("Remove task…", role: .destructive) {
            task.repo.isPlainFolder ? confirmPlainFolderRemoval() : confirmRemoval()
        }
    }

    func confirmRemoval() {
        let (engine, task) = (model.engine, task)
        Task { @MainActor in
            let unsent = await engine.hasWorkToHandOff(task.id)
            let alert = NSAlert()
            alert.messageText = "Remove “\(task.title)”?"
            alert.informativeText = task.isInspection
                ? "This deletes the VM and everything in it."
                : unsent
                    ? "Its work hasn’t been handed off, so its commits are deleted with it. Hand it off first to keep them."
                    : "This deletes the container and its workspace. What was handed off stays on \(task.workspace.branch) in your repository."
            alert.addButton(withTitle: "Remove")
            if unsent { alert.addButton(withTitle: "Hand Off…") }
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn: model.perform { try await $0.remove(task.id) }
            case .alertSecondButtonReturn where unsent: model.handoffSheet = TaskRef(task.id)
            default: break
            }
        }
    }

    /// A plain folder has no branch to keep the work on: apply it to the files or discard it.
    func confirmPlainFolderRemoval() {
        let alert = NSAlert()
        alert.messageText = "Remove “\(task.title)”?"
        let last = !model.tasks.values.contains { $0.id != task.id && $0.repo.path == task.repo.path }
        alert.informativeText = "This deletes the container and its workspace. \(task.repo.name) isn't a git repository, so apply the task's work to its files first, or discard it."
            + (last ? " This is the folder's last task, so the temporary .git AIrlock added there is deleted too." : "")
        alert.addButton(withTitle: "Apply and Remove")
        alert.addButton(withTitle: "Discard and Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.perform { try await $0.remove(task.id, applyToFolder: true) }
        case .alertSecondButtonReturn: model.perform { try await $0.remove(task.id) }
        default: break
        }
    }

    func promptForTag() {
        let alert = NSAlert()
        alert.messageText = "New tag"
        let field = NSTextField(string: "")
        field.placeholderString = "release-2.4"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let tag = field.stringValue
            model.perform { try await $0.setTags(task.id, add: [tag]) }
        }
    }
}

// MARK: Terminal

struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask

    var body: some View {
        Group {
            if task.containerID != nil, task.lifecycle == .running {
                TerminalHostView(controller: model.terminals.controller(for: task.id, engine: model.engine), isRunning: true)
                    // Without ignoresSafeAreaEdges: [] the fill runs under the floating sidebar.
                    .background(Color(nsColor: NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)), ignoresSafeAreaEdges: [])
            } else {
                LifecycleView(task: task)
            }
        }
    }
}

/// Shown instead of the terminal while a task is starting, stopped or failed.
struct LifecycleView: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if task.lifecycle.isActive { ProgressView().controlSize(.small) }
                Text(headline).font(.headline)
                Spacer()
                if !task.lifecycle.isActive {
                    Button(task.containerID == nil ? "Start" : "Start and resume") {
                        model.perform { await $0.start(task.id) }
                    }
                }
            }
            if case .failed(let message) = task.lifecycle {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if message.hasPrefix(TaskEngine.setupFailure) {
                    Button("Create \(ProjectConfig.fileName)") {
                        Task {
                            do {
                                NSWorkspace.shared.open(try await model.engine.createProjectConfig(task.id))
                            } catch {
                                model.errorMessage = String(describing: error)
                            }
                        }
                    }
                    .help("Opens a settings file for this project, filled in from what was detected. Say which tools and packages it needs, then start the task again.")
                }
            }
            let log = model.logs[task.id] ?? []
            if !log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("log")
                    }
                    .onChange(of: log.count) { proxy.scrollTo("log", anchor: .bottom) }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    var headline: String {
        switch task.lifecycle {
        case .failed: "The task stopped with an error"
        case .stopped: "Stopped"
        default: task.lifecycle.displayName + "…"
        }
    }
}

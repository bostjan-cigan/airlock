import AirlockCore
import AirlockDocker
import AirlockEngine
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import AppKit
import SwiftUI

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastRepoPath") private var repoPath = ""
    @AppStorage(RuntimeKind.defaultsKey) private var defaultRuntime: RuntimeKind = .docker
    @State private var runtime: RuntimeKind = .docker
    /// Not remembered: every task starts isolated unless the user picks a worktree for it.
    @State private var workspaceMode: WorkspaceSpec.Mode = .volumeClone
    enum NetworkChoice: Hashable { case sealed, restricted, open }
    /// Not remembered: every task starts sealed unless the user picks otherwise for it.
    @State private var network: NetworkChoice = .sealed
    var restricted: Bool { network != .open }
    @AppStorage("lastProvider") private var providerID = ProviderID.claudeCode.rawValue
    /// What the repository looks like it needs, shown before starting.
    @State private var detectedStack: ProjectStack?
    /// The size the task would get automatically, and why.
    @State private var plan: ResourcePlan?
    /// A size the user picked for this task; nil keeps the automatic one.
    @State private var customSize: ResourceLimits?
    @State private var rememberSize = false
    @State private var editingSize = false

    @State private var title = ""
    @State private var prompt = ""
    @State private var baseRef = ""
    @State private var branches: [String] = []
    @State private var repoError: String?
    /// The folder isn't a git repository (or its `.git` is AIrlock's temporary one).
    @State private var plainFolder = false
    @State private var extraDomains = ""
    /// The chosen project's default hosts, already shown in "Also allow".
    @State private var prefilledHosts: [String] = []
    @State private var projectID: UUID?
    @State private var tags = ""
    @State private var showOptions = false
    @State private var startServices = false
    /// Never remembered between tasks: GitHub access is asked for each time.
    @State private var githubAccess = false
    /// What the repository's compose file would start: (file, kept, skipped) or why it can't.
    @State private var servicePreview: ServicePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New task")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                workSections
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start task") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding(20)
        }
        .frame(width: 560)
        // The automatic size follows the repository, project and services.
        .task(id: "\(repoPath)|\(projectID?.uuidString ?? "")|\(startServices)|\(customSize?.summary ?? "")") { await loadPlan() }
        .task {
            runtime = defaultRuntime
            if model.demoShowsNewTaskOptions {
                showOptions = true
                title = "Add rate limiting to the token endpoint"
            }
            if case .project(let id) = model.scope, let project = model.project(id) {
                projectID = id
                repoPath = project.repoPath
            }
            prefillProjectHosts()
            await loadBranches()
            await loadPlan()
        }
    }

    // MARK: Working on code

    @ViewBuilder var workSections: some View {
                Section {
                    Picker("Project", selection: $projectID) {
                        Text(model.projects.isEmpty ? "Default for the repository" : "Choose a repository…").tag(UUID?.none)
                        ForEach(model.sortedProjects) { project in
                            Text(model.repoIsShared(project) ? "\(project.name) — \(project.repoName)" : project.name)
                                .tag(Optional(project.id))
                        }
                    }
                    .onChange(of: projectID) {
                        prefillProjectHosts()
                        guard let project = projectID.flatMap(model.project) else { return }
                        if project.repoPath != repoPath {
                            repoPath = project.repoPath
                            Task { await loadBranches() }
                        }
                    }
                    LabeledContent("Repository") {
                        HStack {
                            Text(repoPath.isEmpty ? "Choose a repository or folder" : abbreviated(repoPath))
                                .foregroundStyle(repoPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button("Choose…", action: chooseRepo)
                        }
                    }
                    if let repoError {
                        Text(repoError).foregroundStyle(.red).font(.callout)
                    }
                    if plainFolder {
                        Text("Not a git repository. AIrlock adds a temporary .git so the agent can work on a branch, applies the result to the folder's files when you remove the task, and deletes the .git with the folder's last task.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Start from", selection: $baseRef) {
                            ForEach(branches, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(branches.isEmpty)
                    }
                    if let tools = detectedStack?.summary {
                        LabeledContent("Tools") { Text(tools).foregroundStyle(.secondary) }
                            .help("Detected from the repository and installed in the task automatically.")
                    }
                    ForEach(detectedStack?.notices ?? [], id: \.self) { notice in
                        Label(notice, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let preview = servicePreview {
                        Toggle(isOn: $startServices) {
                            Text("Start services")
                            Text(preview.summary)
                        }
                        .disabled(!preview.usable || runtime != .docker)
                        if runtime != .docker {
                            Text("Services run on Docker only.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Size") {
                        HStack(spacing: 8) {
                            Text(sizeSummary).foregroundStyle(.secondary)
                            Button("Change…") { editingSize = true }
                                .popover(isPresented: $editingSize, arrowEdge: .bottom) { sizeEditor }
                        }
                    }
                    if let warning = plan?.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("Title", text: $title, prompt: Text("Fix login redirect loop"))
                    TextField("Tags", text: $tags, prompt: Text("release-2.4, overnight"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Task for the agent")
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background, in: .rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    }
                }
                Section(isExpanded: $showOptions) {
                    Picker("Agent", selection: $providerID) {
                        ForEach(Providers.all, id: \.id.rawValue) { Text($0.displayName).tag($0.id.rawValue) }
                    }
                    Picker("Runtime", selection: $runtime) {
                        ForEach(RuntimeKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                                .selectionDisabled(model.runtimeStatus[kind]?.isAvailable != true)
                        }
                    }
                    .pickerStyle(.segmented)
                    if case .unavailable(let reason)? = model.runtimeStatus[runtime] {
                        Text(reason).font(.callout).foregroundStyle(.orange)
                    } else if runtime == .docker {
                        Text("Apple VMs are safer: each has its own Linux kernel.").font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Workspace", selection: $workspaceMode) {
                        ForEach([WorkspaceSpec.Mode.volumeClone, .worktree], id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(workspaceMode == .worktree
                         ? "A folder on your Mac you can open while it works. Packages it installs and its build output land there too."
                         : "Everything stays inside the container, packages included. Its commits come back to your repository as a branch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Network", selection: $network) {
                        Text("Sealed").tag(NetworkChoice.sealed)
                        Text("Restricted").tag(NetworkChoice.restricted)
                        Text("Open").tag(NetworkChoice.open)
                    }
                    .pickerStyle(.segmented)
                    Text(networkCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if restricted {
                        TextField("Also allow", text: $extraDomains, prompt: Text("pypi.org, files.pythonhosted.org"))
                        if !prefilledHosts.isEmpty, let project = projectID.flatMap(model.project) {
                            Text("Includes \(project.name)’s defaults. Remove any this task doesn’t need.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $githubAccess) {
                        Text("GitHub access")
                        Text("Gives the agent your GitHub token and network access to GitHub so it can push or open pull requests itself. Off: it commits locally and you push after reviewing.")
                    }
                } header: {
                    HStack {
                        Text("Options")
                        Spacer()
                        if !showOptions {
                            Text(optionsSummary).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
    }

    var size: ResourceLimits { customSize ?? plan?.limits ?? .default }

    /// "4 CPU · 8 GB, automatic for Rust"
    var sizeSummary: String {
        guard customSize == nil, let plan else { return size.summary }
        return plan.reason.hasPrefix("auto") ? size.summary + (plan.reason == "auto" ? ", automatic" : ", automatic for " + plan.reason.dropFirst(6))
            : size.summary + ", " + plan.reason
    }

    var sizeEditor: some View {
        let host = ResourcePlanner.Host.current
        return VStack(alignment: .leading, spacing: 12) {
            Text("Container size").font(.headline)
            Stepper("CPUs: \(size.cpus)", value: Binding(
                get: { size.cpus },
                set: { customSize = ResourceLimits(cpus: $0, memoryMB: size.memoryMB) }
            ), in: 1...max(host.cores, 1))
            Stepper("Memory: \(ResourcePlanner.gigabytes(size.memoryMB))", value: Binding(
                get: { size.memoryMB / 1024 },
                set: { customSize = ResourceLimits(cpus: size.cpus, memoryMB: $0 * 1024) }
            ), in: 1...max(host.memoryMB / 1024 - 2, 2))
            if projectID != nil {
                Toggle("Remember for this project", isOn: $rememberSize)
            }
            HStack {
                if customSize != nil {
                    Button("Use Automatic") { customSize = nil; rememberSize = false }
                }
                Spacer()
                Button("Done") { editingSize = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// What `create` would choose, refreshed when the repository, project or services change.
    func loadPlan() async {
        guard !repoPath.isEmpty else { return }
        detectedStack = StackDetector.detect(at: URL(fileURLWithPath: repoPath))
        plan = await model.engine.planResources(repoPath: repoPath, projectID: projectID.flatMap(model.project)?.id,
                                                explicit: customSize, services: startServices)
    }

    var networkCaption: String {
        switch network {
        case .sealed: "Packages download with install scripts off, then the network closes before any of their code runs. The agent reaches only Claude. New hosts wait for your OK."
        case .restricted: "Package registries stay open while the agent works."
        case .open: "Any host. Its packages’ code can send anything anywhere."
        }
    }

    var optionsSummary: String {
        [runtime.displayName, workspaceMode.displayName, network == .sealed ? "Sealed network" : network == .restricted ? "Restricted network" : "Open network",
        ].joined(separator: " · ") + (githubAccess ? " · GitHub access" : "")
    }

    var canStart: Bool {
        !repoPath.isEmpty && repoError == nil && !baseRef.isEmpty
            && !(title.isEmpty && prompt.isEmpty)
            && model.runtimeStatus[runtime]?.isAvailable == true
    }

    func start() {
        let domains = extraDomains.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let effectiveTitle = title.isEmpty
            ? String(prompt.split(separator: "\n").first ?? "Untitled task").prefix(60).description
            : title
        let request = NewTaskRequest(
            title: effectiveTitle,
            prompt: prompt,
            repoPath: repoPath,
            baseRef: baseRef,
            providerID: ProviderID(rawValue: providerID),
            runtime: runtime,
            workspaceMode: workspaceMode,
            network: restricted ? .restricted(extraDomains: domains) : .open,
            resources: customSize,
            projectID: projectID.flatMap(model.project)?.repoPath == repoPath ? projectID : nil,
            tags: tags.split(separator: ",").map(String.init),
            services: startServices && runtime == .docker && servicePreview?.usable == true,
            github: githubAccess,
            // Shown in Also allow already, where the user may have removed some.
            includeProjectHosts: projectID == nil,
            sealed: network == .sealed
        )
        if rememberSize, let projectID = request.projectID ?? projectID {
            let size = customSize
            model.perform { await $0.setProjectResources(projectID, size) }
        }
        Task { await model.createTask(request) }
        dismiss()
    }

    /// Swaps the previous project's default hosts in "Also allow" for the chosen project's,
    /// keeping anything typed by hand.
    func prefillProjectHosts() {
        let typed = extraDomains.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            .filter { !prefilledHosts.contains($0) }
        prefilledHosts = projectID.flatMap(model.project)?.allowedHosts ?? []
        extraDomains = (prefilledHosts + typed.filter { !prefilledHosts.contains($0) }).joined(separator: ", ")
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if !repoPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: repoPath) }
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
            if projectID.flatMap(model.project)?.repoPath != url.path { projectID = nil }
            Task { await loadBranches() }
        }
    }

    func loadBranches() async {
        guard !repoPath.isEmpty else { return }
        let git = HostGit(URL(fileURLWithPath: repoPath))
        if model.engine.isPlainFolder(repoPath) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                plainFolder = false
                branches = []
                baseRef = ""
                repoError = "That folder doesn't exist."
                return
            }
            // Resolved like git resolves a repository root, so the path stays the same once AIrlock adds a .git.
            let resolved = Workspaces.realPath(repoPath)
            if resolved != repoPath { repoPath = resolved }
            plainFolder = true
            branches = []
            baseRef = PlainFolder.branch
            do {
                try PlainFolder.checkAllowed(repoPath)
                repoError = nil
            } catch {
                repoError = String(describing: error)
            }
            await loadServicePreview()
            return
        }
        plainFolder = false
        do {
            let root = try await git.run("rev-parse", "--show-toplevel")
            if root != repoPath { repoPath = root }
            let list = try await git.run("for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/")
            branches = list.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("airlock/") }
            let current = (try? await git.run("branch", "--show-current")) ?? ""
            baseRef = branches.contains(current) ? current : (branches.first ?? "HEAD")
            if branches.isEmpty { branches = ["HEAD"] }
            repoError = (try? await git.run("rev-parse", "--verify", "HEAD")) == nil && list.isEmpty
                ? "This repository has no commits yet. Make a first commit, then start a task."
                : nil
            await loadServicePreview()
        } catch {
            branches = []
            baseRef = ""
            repoError = "Couldn't read that repository."
        }
    }

    func loadServicePreview() async {
        let dir = URL(fileURLWithPath: repoPath)
        guard let file = ComposeServices.detect(in: dir) else {
            servicePreview = nil
            startServices = false
            return
        }
        do {
            let project = try await ComposeServices.load(dir: dir, file: file, dockerSocket: DockerClient.discoverSocket())
            let plan = ComposeServices.plan(project, volumePrefix: "preview", root: repoPath)
            servicePreview = ServicePreview(file: file, kept: plan.services.map(\.name), skipped: plan.skipped.keys.sorted(), problem: nil)
            startServices = !plan.services.isEmpty
        } catch {
            servicePreview = ServicePreview(file: file, kept: [], skipped: [], problem: String(describing: error))
            startServices = false
        }
    }

    func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct ServicePreview {
    var file: String
    var kept: [String]
    var skipped: [String]
    var problem: String?

    var usable: Bool { problem == nil && !kept.isEmpty }

    var summary: String {
        if let problem { return problem }
        if kept.isEmpty { return "\(file) has no services with a prebuilt image" }
        var text = "\(kept.joined(separator: ", ")) from \(file)"
        if !skipped.isEmpty { text += " · \(skipped.joined(separator: ", ")) skipped" }
        return text
    }
}

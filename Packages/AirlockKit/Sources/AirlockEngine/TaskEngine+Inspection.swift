import AirlockCore
import AirlockProviders
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// What starting an inspection takes: where the repository comes from, and how to run it.
public struct InspectionRequest: Sendable {
    public var source: Inspection.Source
    /// Run once the network is closed; nil runs install scripts for what was downloaded.
    public var command: String?
    /// Claude looks into what happened, inside the VM (its token stays with the proxy).
    public var investigate: Bool
    /// Apple VMs are recommended: each has its own Linux kernel.
    public var runtime: RuntimeKind

    public init(source: Inspection.Source, command: String? = nil, investigate: Bool = false, runtime: RuntimeKind = .apple) {
        self.source = source
        self.command = command
        self.investigate = investigate
        self.runtime = runtime
    }
}

/// Inspecting an untrusted repository: copy it in, download its dependencies with nothing of
/// theirs running, close the network, run it, and report what its code did.
extension TaskEngine {
    public func createInspection(_ request: InspectionRequest, origin: TaskOrigin = .app) async throws -> AgentTask {
        let source = try Self.checkedSource(request.source)
        if request.investigate {
            // Fail now rather than after the task appears.
            _ = try loadSecrets(for: try provider(for: AgentTask.inspectionTemplate), github: false)
        }
        let key = Self.projectKey(source)
        let project = try resolveProject(nil, repoPath: key)
        var task = AgentTask(
            title: "Inspect \(source.name)", prompt: "", repo: RepoRef(path: key, baseRef: ""),
            runtime: request.runtime, workspace: WorkspaceSpec(mode: .volumeClone, branch: ""),
            network: .restricted(extraDomains: [])
        )
        task.workspace.volumeName = "\(task.containerName)-workspace"
        task.inspection = Inspection(source: source, command: request.command, investigate: request.investigate)
        task.origin = origin
        task.projectID = project.id
        task.resourceReason = "inspection"
        tasks[task.id] = task
        try store.save(task)
        updateSink.yield(.task(task))
        Task { await self.launch(task.id) }
        return task
    }

    /// Only https URLs (cloned inside the VM) and existing folders.
    static func checkedSource(_ source: Inspection.Source) throws -> Inspection.Source {
        switch source {
        case .url(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, UntrustedText.isHostname(host),
                  url.user == nil, url.password == nil else {
                throw EngineError("Give an https URL of a git repository, like https://github.com/owner/repo.")
            }
            return .url(trimmed)
        case .folder(let path):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw EngineError("No folder at \(path).")
            }
            return .folder(Workspaces.realPath(path))
        }
    }

    /// What groups the inspection with others of the same repository (its project's key).
    static func projectKey(_ source: Inspection.Source) -> String {
        switch source {
        case .url(let url): url
        case .folder(let path): path
        }
    }

    // MARK: Running

    func inspectionSteps(_ id: UUID) async throws {
        guard var task = tasks[id], let inspection = task.inspection else { return }
        let runtime = try runtime(for: task)
        let provider = try provider(for: task)
        let secretValues = inspection.investigate ? try loadSecrets(for: provider, github: false) : [:]
        let node = ContainerPaths.user

        // Every attempt starts from nothing: a new VM, a new copy, a new record.
        watchers.removeValue(forKey: id)?.cancel()
        if let old = task.containerID { try? await runtime.remove(old) }
        if let volume = task.workspace.volumeName { try? await runtime.removeVolume(volume) }
        try? await runtime.removeVolume(Self.cacheVolume(task))
        update(id) {
            $0.containerID = nil
            $0.lifecycle = .provisioning
            $0.activity = .working(tool: Inspection.Phase.preparing.title)
            $0.access = Self.access(secretValues)
            $0.blockedHosts = []
            $0.inspection?.phase = .preparing
            $0.inspection?.sealedAt = nil
            $0.inspection?.report = nil
        }
        task = tasks[id]!

        let workspaceVolume = task.workspace.volumeName ?? "\(task.containerName)-workspace"
        try await runtime.createVolume(workspaceVolume, labels: ["airlock.task": id.uuidString])
        let cache = Self.cacheVolume(task)
        try await runtime.createVolume(cache, labels: ["airlock.task": id.uuidString])
        let networkFile = try writeNetworkConfig(task, provider: provider)
        // Nothing from the Mac but AIrlock's own network file; the agent's folders only when asked.
        var mounts: [MountSpec] = [
            .volume(name: workspaceVolume, containerPath: ContainerPaths.workspace),
            .volume(name: cache, containerPath: ContainerPaths.cache),
            .bind(hostPath: networkFile.path, containerPath: ContainerPaths.networkConfig, readOnly: true),
        ]
        if inspection.investigate {
            try provider.seedConfig(at: paths.agentConfig(id), for: task, secrets: secretValues)
            try FileManager.default.createDirectory(at: paths.events(id), withIntermediateDirectories: true)
            mounts += [
                .bind(hostPath: paths.agentConfig(id).path, containerPath: provider.configMountPath),
                .bind(hostPath: paths.events(id).path, containerPath: ContainerPaths.events),
            ]
        }

        update(id) { $0.lifecycle = .buildingImage }
        let recipe = Providers.inspectionRecipe(parent: provider.imageRecipe(base: Providers.baseRecipe()))
        let image = try await runtime.ensureImage(recipe) { [weak self] line in Task { await self?.log(id, line) } }
        update(id) {
            $0.imageRef = image
            $0.lifecycle = .starting
        }
        resetDNSLog(id)
        var environment = ProjectStack.cacheEnvironment
        environment["AIRLOCK_TASK_ID"] = id.uuidString
        environment["AIRLOCK_NETWORK"] = "restricted"
        let containerID = try await runtime.create(ContainerSpec(
            name: task.containerName, image: image,
            labels: ["airlock.task": id.uuidString, "airlock.provider": task.providerID.rawValue, "airlock.kind": "inspection"],
            mounts: mounts, environment: environment, capAdd: ["NET_ADMIN", "NET_RAW"], resources: task.resources
        ))
        update(id) { $0.containerID = containerID }
        try await runtime.start(containerID)
        try await waitUntilReady(runtime, containerID)
        try await runtime.run(containerID, ExecSpec(["sh", "-c", "chown node:node /workspace /home/node/.cache && rm -rf /workspace/lost+found"], user: "root"))
        update(id) { $0.lifecycle = .running }

        // 1. The repository and its dependencies, with nothing of theirs running.
        setPhase(id, .downloading)
        switch inspection.source {
        case .url(let url):
            let clone = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "clone", url], user: node))
            guard clone.exitCode == 0 else {
                throw EngineError("Couldn't clone \(url): \(UntrustedText.oneLine(clone.errorOutput + clone.output, limit: 300))")
            }
        case .folder(let path):
            try await copyFolderIn(path, task: task, runtime: runtime, containerID: containerID)
        }
        var report = InspectionReport()
        let download = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "download"], user: node, workdir: ContainerPaths.workspace))
        for line in (download.output + "\n" + download.errorOutput).split(separator: "\n") {
            log(id, UntrustedText.oneLine(String(line), limit: 400))
            if line.hasPrefix("step: ") { report.downloads.append(UntrustedText.oneLine(String(line.dropFirst(6)))) }
        }
        report.downloadFailed = download.exitCode != 0
        // Lookups so far were the downloads'; the record starts when the network closes.
        await scanBlockedHosts(id, runtime: runtime, containerID: containerID)
        update(id) { $0.blockedHosts = [] }

        // 2. Close the network, and make sure it is closed before anything of theirs runs.
        setPhase(id, .sealed)
        let sealed = tasks[id]!
        _ = try writeNetworkConfig(sealed, provider: provider)   // a restarted VM stays closed too
        _ = try await applyFirewall(sealed, runtime: runtime, containerID: containerID)
        let probe = try await runtime.exec(containerID, ExecSpec(
            ["sh", "-c", "getent hosts registry.npmjs.org >/dev/null || curl -s -m 5 -o /dev/null https://1.1.1.1"], user: node))
        guard probe.exitCode != 0 else {
            throw EngineError("The network didn't close, so nothing from the repository was run.")
        }
        _ = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "decoys"], user: node))
        try await runtime.run(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "seal"], user: "root"))
        update(id) { $0.inspection?.sealedAt = .now }

        // 3. Its code runs.
        setPhase(id, .running)
        let run = try await runtime.exec(containerID, ExecSpec(
            ["/usr/local/bin/airlock-inspect", "run"], user: node, workdir: ContainerPaths.workspace,
            environment: inspection.command.map { ["AIRLOCK_RUN": $0] } ?? [:]))
        let printed = run.output + (run.errorOutput.isEmpty ? "" : "\n" + run.errorOutput)
        if let first = printed.split(separator: "\n").first, first.hasPrefix("run: ") {
            report.command = UntrustedText.oneLine(String(first.dropFirst(5)), limit: 600)
        } else {
            report.command = inspection.command ?? ""
        }
        report.exitCode = run.exitCode
        report.output = UntrustedText.block(String(printed.suffix(6000)), limit: 6000)
        // A moment for anything it started in the background.
        try await Task.sleep(for: .seconds(3))

        // 4. What it did.
        let tree = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "tree"], user: node))
        let seen = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "report"], user: "root"))
        Self.read(tree.output + "\n" + seen.output, into: &report)
        await scanBlockedHosts(id, runtime: runtime, containerID: containerID)
        report.triedHosts = tasks[id]?.blockedHosts.map(\.name) ?? []
        let finalReport = report
        update(id) {
            $0.blockedHosts = []
            $0.inspection?.report = finalReport
        }
        log(id, "Report: \(report.summary)")

        if inspection.investigate {
            setPhase(id, .investigating)
            update(id) { $0.prompt = Self.investigationPrompt(finalReport, source: inspection.source) }
            try await startAgent(id, resume: false, secrets: secretValues)
            watch(id)
        } else {
            setPhase(id, .finished)
            update(id) { $0.activity = .idle(lastMessage: finalReport.summary) }
        }
        attention(id, .stop, "Inspection finished: \(report.summary)")
    }

    func setPhase(_ id: UUID, _ phase: Inspection.Phase) {
        update(id) {
            $0.inspection?.phase = phase
            if phase != .finished, phase != .investigating { $0.activity = .working(tool: phase.title) }
        }
        log(id, phase.title)
    }

    /// Copies a folder in as files: no git runs on the Mac, and links stay links (inside the VM
    /// they point nowhere on the Mac).
    func copyFolderIn(_ path: String, task: AgentTask, runtime: any ContainerRuntime, containerID: String) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "airlock-\(task.shortID)-inspect")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let inner = staging.appending(path: "repo.tar")
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-c", "-f", inner.path, "-C", path, "."],
                                    environment: ["COPYFILE_DISABLE": "1"])
        let outer = try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-c", "-f", "-", "-C", staging.path, "repo.tar"],
                                                environment: ["COPYFILE_DISABLE": "1"]).stdout
        try await runtime.copyIn(containerID, tar: outer, to: "/tmp")
        try await runtime.run(containerID, ExecSpec(["tar", "--no-same-owner", "-xf", "/tmp/repo.tar", "-C", ContainerPaths.workspace], user: ContainerPaths.user))
        _ = try? await runtime.exec(containerID, ExecSpec(["rm", "-f", "/tmp/repo.tar"], user: "root"))
    }

    /// Lines from `airlock-inspect tree` and `report`, cleaned.
    static func read(_ output: String, into report: inout InspectionReport) {
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            func value(_ prefix: String) -> String? {
                line.hasPrefix(prefix) ? UntrustedText.oneLine(String(line.dropFirst(prefix.count)), limit: 300) : nil
            }
            if let v = value("read ") { report.credentialReads.append(v) }
            else if let v = value("tried ") { report.triedAddresses.append(v) }
            else if let v = value("changed ") { report.changedOutside.append(v) }
            else if let v = value("process ") { report.processes.append(v) }
            else if let v = value("script ") { report.installScripts.append(v) }
            else if let v = value("repo ") { report.changedInRepo.append(v) }
        }
    }

    /// What Claude is asked to do in an inspection. The report's strings come from the VM.
    static func investigationPrompt(_ report: InspectionReport, source: Inspection.Source) -> String {
        func list(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "\(title): none" : "\(title):\n" + items.prefix(60).map { "- \($0)" }.joined(separator: "\n")
        }
        return """
        Investigate whether this repository is safe to install and run: \(source.label). It's at /workspace, with its \
        dependencies installed. The network is closed and stays closed; don't try to work around it.

        AIrlock downloaded the dependencies with install scripts off, closed the network, then ran: \(report.command.isEmpty ? "nothing" : report.command) \
        (exit \(report.exitCode.map(String.init) ?? "?")). It planted decoy credentials in the home folder and recorded what happened:

        \(list("Hosts looked up", report.triedHosts))
        \(list("Connections tried", report.triedAddresses))
        \(list("Decoy credentials read", report.credentialReads))
        \(list("Packages with install scripts", report.installScripts))
        \(list("Files changed outside the repository", report.changedOutside))
        \(list("Processes still running", report.processes))

        Explain each of these: which package or file caused it, and what its code does (quote file and line). Then look \
        for anything the record can't show: obfuscated code, code that only acts at runtime or after a delay, or that \
        checks whether it's in a sandbox. Don't commit anything. End with a verdict (safe, suspicious or malicious) and \
        the evidence for it.
        """
    }
}

extension AgentTask {
    /// Inspections use Claude Code's image and, when investigating, Claude Code.
    static let inspectionTemplate = AgentTask(title: "", prompt: "", repo: RepoRef(path: "", baseRef: ""), workspace: WorkspaceSpec(mode: .volumeClone, branch: ""))
}

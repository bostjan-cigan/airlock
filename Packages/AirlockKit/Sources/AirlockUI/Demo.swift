import AirlockApple
import AirlockCore
import AirlockEngine
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// `AIrlock --demo`: every UI state at once, with no containers, agents or plugin involved.
/// Tasks, events and transcripts are written to a throwaway folder and loaded the normal
/// way; a fake runtime answers for the containers and plays a canned Claude Code session in
/// each terminal, so nothing calls the API. Nothing touches the real AIrlock data, Docker or
/// the control socket. `--screenshots` also hides the Demo badge.
extension AppModel {
    public static func demo() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "AIrlock-Demo-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let paths = Paths(root: root)
        let runtimes: [RuntimeKind: DemoRuntime] = [.docker: DemoRuntime(kind: .docker), .apple: DemoRuntime(kind: .apple)]
        DemoSeed.write(to: paths, runtimes: runtimes)
        let secrets = InMemorySecretStore([.claudeOAuthToken: "sk-ant-oat01-demo"])
        let engine = TaskEngine(paths: paths, secrets: secrets, runtimes: runtimes)
        let model = AppModel(engine: engine, secrets: secrets, appleAssets: AppleRuntimeAssets(root: root.appending(path: "apple")))
        model.isDemo = true
        model.hidesDemoBadge = CommandLine.arguments.contains("--screenshots")
        return model
    }
}

/// Answers like a healthy runtime whose containers all run. Exec succeeds with no output,
/// terminals replay each task's canned agent session.
final class DemoRuntime: ContainerRuntime, @unchecked Sendable {
    let kind: RuntimeKind
    private let lock = NSLock()
    private var states: [String: ContainerState] = [:]
    /// Containers whose agent process has ended (their tmux pane is back at a shell).
    private var exitedAgents: Set<String> = []
    private var screens: [String: DemoScreen] = [:]
    /// The seeded checkout each container's `/workspace` stands for.
    private var workspaces: [String: String] = [:]

    init(kind: RuntimeKind) { self.kind = kind }

    func setWorkspace(_ id: String, _ path: String) { lock.withLock { workspaces[id] = path } }

    func setState(_ id: String, _ state: ContainerState) { lock.withLock { states[id] = state } }
    func setAgentExited(_ id: String) { _ = lock.withLock { exitedAgents.insert(id) } }
    func setScreen(_ id: String, _ screen: DemoScreen) { lock.withLock { screens[id] = screen } }

    func availability() async -> RuntimeAvailability { .available(version: "demo") }

    func ensureImage(_ recipe: ImageRecipe, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        for step in ["Step 1/4 : FROM node:22-bookworm-slim", "Step 2/4 : RUN apt-get install …", "Step 3/4 : COPY airlock-* /usr/local/bin/", "Step 4/4 : CMD airlock-init"] {
            progress(step)
            try await Task.sleep(for: .milliseconds(600))
        }
        return "airlock/demo:latest"
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        let id = "demo-\(UUID().uuidString.prefix(12).lowercased())"
        setState(id, .stopped(exitCode: nil))
        return id
    }

    func start(_ id: String) async throws { setState(id, .running) }
    func stop(_ id: String, timeout: Duration) async throws { setState(id, .stopped(exitCode: 0)) }
    func remove(_ id: String) async throws { setState(id, .missing) }
    func state(_ id: String) async throws -> ContainerState { lock.withLock { states[id] } ?? .running }

    func exec(_ id: String, _ spec: ExecSpec) async throws -> ExecResult {
        // Git "in the container" runs on the seeded checkout (sample data AIrlock made).
        if spec.command.starts(with: ["/usr/bin/git", "-C", "/workspace"]), let path = lock.withLock({ workspaces[id] }) {
            let r = try await ProcessRunner.run("/usr/bin/git", ["-C", path] + spec.command.dropFirst(3), check: false)
            return ExecResult(exitCode: Int(r.status), stdout: r.stdout, stderr: r.stderr)
        }
        // No DNS log in the demo: blocked hosts are the seeded ones.
        let script = spec.command.last ?? ""
        let agentGone = script.contains("pgrep -P") && lock.withLock { exitedAgents.contains(id) }
        let code = script.contains("/run/airlock/dns.log") ? 3 : agentGone ? 1 : 0
        return ExecResult(exitCode: code, stdout: Data(), stderr: Data())
    }

    func openTerminal(_ id: String, _ spec: ExecSpec, size: TerminalSize) async throws -> any TerminalSession {
        DemoTerminalSession(screen: lock.withLock { screens[id] } ?? DemoScreen(lines: []))
    }

    func openStream(_ id: String, _ spec: ExecSpec) async throws -> any TerminalSession { DemoTerminalSession(screen: DemoScreen(lines: [])) }
    func copyIn(_ id: String, tar: Data, to path: String) async throws {}

    /// Plausible, steady numbers per container.
    func usage(_ id: String) async throws -> ResourceUsage? {
        guard case .running = try await state(id) else { return nil }
        let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return ResourceUsage(cpuPercent: Double(seed % 90) + 5, memoryBytes: UInt64(300 + seed % 1600) * 1_048_576)
    }
    func createVolume(_ name: String, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
}

/// What a task's terminal shows: the session so far, lines that keep arriving while you watch,
/// and the spinner of a turn still in progress.
struct DemoScreen: Sendable {
    var lines: [String]
    var live: [String] = []
    /// "Fuzzing /oauth/token" for a working agent; nil when it's waiting at its prompt.
    var spinner: String?
    /// How long the turn has been running when the terminal opens.
    var elapsed: Int = 95
    /// The agent exited: a shell prompt instead of Claude Code's input box.
    var shell = false
}

/// Plays a `DemoScreen` and echoes what you type.
final class DemoTerminalSession: TerminalSession, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private var player: Task<Void, Never>?

    init(screen: DemoScreen) {
        (output, sink) = AsyncStream<Data>.makeStream()
        let sink = sink
        var opening = CC.welcome + screen.lines
        let working = screen.spinner != nil
        if !working { opening += screen.shell ? ["", CC.shellPrompt] : CC.inputBox }
        // The cursor sits in the input box, as in Claude Code, and is hidden while a turn runs.
        let cursor = working ? "\u{1B}[?25l" : screen.shell ? "" : "\u{1B}[2A\r\u{1B}[4C"
        sink.yield(Data((opening.joined(separator: "\r\n") + cursor).utf8))
        guard working else { return }
        player = Task {
            for line in screen.live {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 450...950)))
                if Task.isCancelled { return }
                sink.yield(Data("\r\n\(line)".utf8))
            }
            sink.yield(Data("\r\n\r\n".utf8))
            let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
            var tick = 0
            while !Task.isCancelled {
                let seconds = screen.elapsed + tick / 8
                let time = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
                let line = "\(CC.accent)\(glyphs[tick % glyphs.count])\(CC.reset) \(CC.accent)\(screen.spinner!)…\(CC.reset) \(CC.dim)(\(time) · ↓ \(String(format: "%.1f", 1.2 + Double(tick) / 90))k tokens · esc to interrupt)\(CC.reset)"
                sink.yield(Data("\r\u{1B}[2K\(line)".utf8))
                tick += 1
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    func write(_ data: Data) async throws {
        // Echo, turning Return into a fresh prompt.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\r\n> ")
        sink.yield(Data(text.utf8))
    }

    func resize(_ size: TerminalSize) async throws {}
    func close() async {
        player?.cancel()
        sink.finish()
    }
}

/// Claude Code's look, for the demo terminals.
enum CC {
    static let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"
    static let green = "\u{1B}[38;2;78;186;101m", red = "\u{1B}[38;2;255;107;128m"
    static let accent = "\u{1B}[38;2;215;119;87m", gray = "\u{1B}[38;2;153;153;153m"

    static let welcome: [String] = {
        let rows = ["\(accent)✻\(reset) Welcome to \(bold)Claude Code\(reset)!", "", "  \(dim)/help for help, /status for your current setup\(reset)", "", "  \(dim)cwd: /workspace\(reset)"]
        let plain = ["✻ Welcome to Claude Code!", "", "  /help for help, /status for your current setup", "", "  cwd: /workspace"]
        let width = 52
        return ["\(accent)╭\(String(repeating: "─", count: width))╮\(reset)"]
            + zip(rows, plain).map { "\(accent)│\(reset) \($0)\(String(repeating: " ", count: width - 1 - $1.count))\(accent)│\(reset)" }
            + ["\(accent)╰\(String(repeating: "─", count: width))╯\(reset)", ""]
    }()

    static let inputBox: [String] = [
        "",
        "\(gray)╭\(String(repeating: "─", count: 72))╮\(reset)",
        "\(gray)│\(reset) > \(String(repeating: " ", count: 69))\(gray)│\(reset)",
        "\(gray)╰\(String(repeating: "─", count: 72))╯\(reset)",
        "  \(red)⏵⏵ bypass permissions on\(reset) \(dim)(shift+tab to cycle)\(reset)",
    ]

    static let shellPrompt = "\(green)node@airlock\(reset):\(bold)/workspace\(reset)$ "

    static func user(_ text: String) -> [String] { ["\(gray)> \(text)\(reset)", ""] }

    /// The agent's text; continuation lines are indented under the bullet.
    static func say(_ lines: String...) -> [String] {
        lines.enumerated().map { $0 == 0 ? "\(bold)⏺\(reset) \($1)" : "  \($1)" } + [""]
    }

    static func tool(_ name: String, _ argument: String, _ output: [String] = [], failed: Bool = false) -> [String] {
        let head = "\(failed ? red : green)⏺\(reset) \(bold)\(name)\(reset)(\(argument))"
        let body = output.enumerated().map { "\($0 == 0 ? "  ⎿  " : "     ")\($1)" }
        return [head] + body + [""]
    }

    static func todos(_ items: [String], done: Int) -> [String] {
        let rows = items.enumerated().map { i, item in
            i < done ? "\(dim)☒ \u{1B}[9m\(item)\(reset)"
                : i == done ? "\(bold)☐ \(item)\(reset)"
                : "☐ \(item)"
        }
        return ["\(green)⏺\(reset) \(bold)Update Todos\(reset)"]
            + rows.enumerated().map { "\($0 == 0 ? "  ⎿  " : "     ")\($1)" } + [""]
    }

    static func pass(_ text: String) -> String { "\(green)✓\(reset) \(text)" }
    static func fail(_ text: String) -> String { "\(red)✗\(reset) \(text)" }
    static func muted(_ text: String) -> String { "\(dim)\(text)\(reset)" }
    static func error(_ text: String) -> String { "\(red)\(text)\(reset)" }
}

/// Creates the demo's repositories, projects and tasks (see `DemoContent`).
enum DemoSeed {
    static func write(to paths: Paths, runtimes: [RuntimeKind: DemoRuntime]) {
        try? FileManager.default.createDirectory(at: paths.tasks, withIntermediateDirectories: true)
        let content = DemoContent(root: paths.root.appending(path: "repos"))
        try? ProjectStore(paths: paths).save(content.projects)
        for seed in content.seeds { seed.write(paths: paths, runtime: runtimes[seed.runtime]!) }
        content.moveMainOn()
        try? JSONEncoder().encode(content.seeds.compactMap { seed in seed.overrideLifecycle.map { _ in seed.id.uuidString } })
            .write(to: paths.root.appending(path: "demo-starting.json"))
    }

    /// A git repository with these files committed on `main`.
    static func makeRepository(at url: URL, files: [String: String]) -> URL {
        writeFiles(files, in: url)
        git(url, "init", "-q", "-b", "main")
        commitAll(url, "Initial commit")
        return url
    }

    static func writeFiles(_ files: [String: String], in dir: URL) {
        let fm = FileManager.default
        for (name, text) in files {
            let file = dir.appending(path: name)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Commits everything and returns the short hash.
    @discardableResult
    static func commitAll(_ dir: URL, _ message: String) -> String {
        git(dir, "add", "-A")
        git(dir, "-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "commit", "-qm", message)
        return git(dir, "rev-parse", "--short", "HEAD")
    }

    @discardableResult
    static func git(_ dir: URL, _ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One demo task, written as AIrlock would have saved it.
struct Seed {
    enum Event {
        case start, exit
        case prompt(String)
        case question(String)
        case tool(String, String)
        /// A command whose host the network policy refused.
        case refused(String)
        case todo([String], done: Int)
        /// Matches a `Change.commit` with the same subject, for its hash.
        case commit(String)
        case stop(String?)
        case failure(String)
    }

    /// Work in the task's worktree: commits, then uncommitted edits.
    enum Change {
        case commit(String, [String: String])
        case edit([String: String])
    }

    let id = UUID()
    var title: String
    var project: Project
    var repo: URL
    var minutesAgo: Double
    var events: [Event]
    var tags: [String] = []
    var chat = false
    var changes: [Change] = []
    var screen = DemoScreen(lines: [])
    var blocked: [BlockedHost] = []
    var extraHosts: [String] = []
    var services: TaskServices?
    var ports: [PortForward] = []
    var plainFolder = false
    var mode: WorkspaceSpec.Mode = .worktree
    var runtime: RuntimeKind = .docker
    var network: NetworkProfile?
    var github = false
    var apiKey = false
    var lifecycle: Lifecycle = .running
    var activity: Activity?
    var done = false
    var overrideLifecycle: Lifecycle?
    var inspection: Inspection?
    /// A sealed task's setup report.
    var setup: InspectionReport?

    func write(paths: Paths, runtime demo: DemoRuntime) {
        let fm = FileManager.default
        let start = Date.now.addingTimeInterval(-minutesAgo * 60 - 300)
        var task = AgentTask(
            id: id, title: title, prompt: promptText, repo: RepoRef(path: repo.path, baseRef: plainFolder ? PlainFolder.branch : "main", plainFolder: plainFolder),
            runtime: runtime, workspace: WorkspaceSpec(mode: mode, branch: branchName),
            network: network ?? .restricted(extraDomains: extraHosts), createdAt: start
        )
        task.projectID = project.id
        task.tags = tags
        task.origin = chat ? .chat(label: project.repoName) : .app
        task.githubAccess = github
        task.access = TaskAccess(credential: apiKey ? .apiKey : .claudeToken, github: github)
        task.blockedHosts = blocked
        task.services = services
        task.ports = ports
        task.lifecycle = lifecycle
        task.activity = activity ?? .unknown
        let stack = StackDetector.detect(at: repo)
        task.stack = stack
        let plan = ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: nil, stack: stack, services: services?.items.count ?? 0, reservedMemoryMB: 0)
        task.resources = plan.limits
        task.resourceReason = plan.reason
        task.isDone = done
        if let setup {
            var sealing = Sealing()
            sealing.phase = .sealed
            sealing.sealedAt = start.addingTimeInterval(60)
            sealing.report = setup
            task.sealing = sealing
        }
        if let inspection {
            task.inspection = inspection
            task.repo = RepoRef(path: project.repoPath, baseRef: "")
            task.resourceReason = "inspection"
        }
        task.containerID = "demo-\(task.shortID)"
        task.imageRef = "airlock/claude-code:demo"
        task.updatedAt = Date.now.addingTimeInterval(-minutesAgo * 60)
        task.lastActivityAt = task.updatedAt
        if lifecycle == .stopped { demo.setState(task.containerID!, .stopped(exitCode: 0)) }
        if activity == .exited { demo.setAgentExited(task.containerID!) }
        demo.setScreen(task.containerID!, screen)

        var hashes: [String: String] = [:]
        if mode == .worktree, !plainFolder {
            let worktree = paths.worktree(id)
            DemoSeed.git(repo, "worktree", "add", "-q", "-b", branchName, worktree.path, "main")
            task.workspace.hostPath = worktree.path
            demo.setWorkspace(task.containerID!, worktree.path)
            task.workspace.baseCommit = DemoSeed.git(repo, "rev-parse", "main")
            for change in changes {
                switch change {
                case .commit(let subject, let files):
                    DemoSeed.writeFiles(files, in: worktree)
                    hashes[subject] = DemoSeed.commitAll(worktree, subject)
                case .edit(let files):
                    DemoSeed.writeFiles(files, in: worktree)
                }
            }
        } else {
            task.workspace.volumeName = "\(task.containerName)-workspace"
        }

        try? fm.createDirectory(at: paths.events(id), withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.agentConfig(id).appending(path: "projects"), withIntermediateDirectories: true)
        try? TaskStore(paths: paths).save(task)
        writeEvents(paths: paths, start: start, hashes: hashes)
    }

    var promptText: String {
        for event in events { if case .prompt(let text) = event { return text } }
        return title
    }

    var branchName: String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var name = String(slug)
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        return "airlock/" + name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Hook lines as `airlock-hook` writes them, plus a transcript for the last reply.
    private func writeEvents(paths: Paths, start: Date, hashes: [String: String]) {
        let transcriptName = "projects/demo-\(id.uuidString.prefix(8)).jsonl"
        let transcriptInContainer = "/home/node/.claude/\(transcriptName)"
        var lines: [String] = []
        var time = start
        func add(_ event: String, _ payload: [String: Any]) {
            time = time.addingTimeInterval(20)
            var payload = payload
            payload["transcript_path"] = transcriptInContainer
            let line: [String: Any] = ["ts": Self.timestamp(time), "event": event, "payload": payload]
            if let data = try? JSONSerialization.data(withJSONObject: line) { lines.append(String(decoding: data, as: UTF8.self)) }
        }
        var reply: String?
        for event in events {
            switch event {
            case .start: add("SessionStart", ["source": "startup"])
            case .exit: add("SessionEnd", ["reason": "other"])
            case .prompt(let text): add("UserPromptSubmit", ["prompt": text])
            case .question(let text): add("Notification", ["message": text, "notification_type": "permission_prompt"])
            case .tool(let name, let target):
                let key = name == "Bash" ? "command" : "file_path"
                add("PreToolUse", ["tool_name": name, "tool_input": [key: target]])
            case .refused(let command):
                add("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": command]])
                add("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command], "tool_response": ["stdout": "", "stderr": "Could not resolve host"]])
            case .todo(let items, let done):
                let todos = items.enumerated().map { i, item -> [String: String] in
                    ["content": item, "activeForm": item, "status": i < done ? "completed" : i == done ? "in_progress" : "pending"]
                }
                add("PostToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": todos]])
            case .commit(let subject):
                let hash = hashes[subject] ?? "4c1d9e2"
                let command = "git commit -qm '\(subject)' && git log --oneline -1"
                add("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command], "tool_response": ["stdout": "\(hash) \(subject)\n", "stderr": ""]])
            case .stop(let message):
                reply = message
                add("Stop", [:])
            case .failure(let reason):
                add("StopFailure", ["error": "billing_error", "error_details": reason])
            }
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: paths.events(id).appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        if let reply {
            let entry: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": reply]]]]
            if let data = try? JSONSerialization.data(withJSONObject: entry) {
                try? (String(decoding: data, as: UTF8.self) + "\n").write(to: paths.agentConfig(id).appending(path: transcriptName), atomically: true, encoding: .utf8)
            }
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

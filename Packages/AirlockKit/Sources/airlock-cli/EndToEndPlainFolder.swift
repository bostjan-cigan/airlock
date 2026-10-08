import AirlockCore
import AirlockEngine
import AirlockRuntime
import AirlockWorkspace
import Foundation

/// A task on a folder that isn't a git repository: AIrlock adds a temporary `.git`, the
/// agent's work (committed or not) is applied to the folder's files, and the `.git` goes away.
enum EndToEndPlainFolder {
    static func run(runtime: any ContainerRuntime, scratch: URL, mode: WorkspaceSpec.Mode) async throws {
        let root = scratch.appending(path: "e2e-plain-\(Int(Date().timeIntervalSince1970))")
        let folder = root.appending(path: "sample")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello\n".write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)

        let engine = TaskEngine(
            paths: Paths(root: root.appending(path: "support")),
            secrets: InMemorySecretStore([.anthropicAPIKey: "dummy-not-a-key"]),
            runtimes: [runtime.kind: runtime]
        )
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func read(_ name: String) -> String? { try? String(contentsOf: folder.appending(path: name), encoding: .utf8) }
        let gitDir = folder.appending(path: ".git").path

        let task = try await engine.create(NewTaskRequest(
            title: "Plain folder check", prompt: "Say hello", repoPath: folder.path, baseRef: "ignored",
            runtime: runtime.kind, workspaceMode: mode, network: .restricted(extraDomains: [])
        ))
        check("task marked plain folder", task.repo.isPlainFolder && task.repo.baseRef == PlainFolder.branch)
        try await EndToEnd.waitFor("running", timeout: 600) {
            let t = await engine.task(task.id)
            if case .failed(let m)? = t?.lifecycle { throw EngineError(m) }
            return t?.lifecycle == .running
        }
        let id = await engine.task(task.id)!.containerID!
        check("temporary .git created", FileManager.default.fileExists(atPath: gitDir + "/airlock-managed"))

        func sh(_ cmd: String) async throws -> ExecResult {
            try await runtime.exec(id, ExecSpec(["sh", "-c", cmd], user: "node", workdir: "/workspace"))
        }
        let seen = try await sh("cat README.md; git rev-parse --abbrev-ref HEAD 2>&1")
        let branch = await engine.task(task.id)!.workspace.branch
        check("folder files and task branch in /workspace", seen.output == "hello\n\(branch)\n", seen.output.replacingOccurrences(of: "\n", with: " "))

        // The agent commits one change and leaves another uncommitted, next to packages and build output.
        _ = try await sh("echo agent >> README.md && echo new > NEW.txt && git add -A && git commit -qm 'agent change' && echo left > LEFT.txt"
                         + " && mkdir -p node_modules/x dist && echo dep > node_modules/x/index.js && echo out > dist/app.js")
        // The user edits the folder meanwhile.
        try "mine\n".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let changes = try await engine.changes(task.id)
        check("changes visible", Set(changes.files.map(\.path)) == ["README.md", "NEW.txt", "LEFT.txt"],
              changes.files.map { "\($0.kind) \($0.path)" }.joined(separator: ", "))

        let release = try await engine.remove(task.id, applyToFolder: true)
        check("container removed", (try? await runtime.state(id)) == .missing)
        check("committed work applied", read("README.md") == "hello\nagent\n" && read("NEW.txt") == "new\n")
        check("uncommitted work applied", read("LEFT.txt") == "left\n")
        check("user's edit kept", read("notes.txt") == "mine\n")
        check("packages and build output stayed in the task", !FileManager.default.fileExists(atPath: folder.appending(path: "node_modules").path)
              && !FileManager.default.fileExists(atPath: folder.appending(path: "dist").path))
        check("temporary .git deleted", release == .removed && !FileManager.default.fileExists(atPath: gitDir), "\(String(describing: release))")
        try? FileManager.default.removeItem(at: root)
    }
}

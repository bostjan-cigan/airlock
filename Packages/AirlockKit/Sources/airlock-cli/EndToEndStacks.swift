import AirlockCore
import AirlockEngine
import AirlockRuntime
import Foundation

/// A Python project with no configuration: detection, the toolchain image, package hosts,
/// per-task caches, airlock-install, and dependency folders kept off the Mac.
enum EndToEndStacks {
    static func run(runtime: any ContainerRuntime, scratch: URL) async throws {
        let root = scratch.appending(path: "e2e-stacks-\(Int(Date().timeIntervalSince1970))")
        let repo = root.appending(path: "pyapp")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "3.12\n".write(to: repo.appending(path: ".python-version"), atomically: true, encoding: .utf8)
        try "six==1.16.0\n".write(to: repo.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
        try ".venv\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for cmd in [["init", "-q", "-b", "main"], ["add", "."], ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", "init"]] {
            try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + cmd)
        }
        let engine = TaskEngine(
            paths: Paths(root: root.appending(path: "support")),
            secrets: InMemorySecretStore([.anthropicAPIKey: "dummy-not-a-key"]),
            runtimes: [runtime.kind: runtime]
        )
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func start(_ title: String, resources: ResourceLimits? = nil) async throws -> (AgentTask, String) {
            let task = try await engine.create(NewTaskRequest(title: title, prompt: "Say hello", repoPath: repo.path, baseRef: "main",
                                                              runtime: runtime.kind, workspaceMode: .worktree, resources: resources, sealed: false))
            try await EndToEnd.waitFor("\(title) running", timeout: 900) {
                let t = await engine.task(task.id)
                if case .failed(let m)? = t?.lifecycle { throw EngineError(m) }
                return t?.lifecycle == .running
            }
            let t = await engine.task(task.id)!
            return (t, t.containerID!)
        }
        func sh(_ id: String, _ cmd: String) async throws -> ExecResult {
            // A login shell, like the agent's tmux session.
            try await runtime.exec(id, ExecSpec(["zsh", "-lc", cmd], user: "node", workdir: "/workspace"))
        }

        let (first, id1) = try await start("Stacks one")
        check("stack detected", first.stack?.summary == "Python 3.12", first.stack?.summary ?? "nil")
        let python = try await sh(id1, "python --version")
        check("Python 3.12 on PATH", python.output.hasPrefix("Python 3.12"), python.output + python.errorOutput)
        let venv = try await sh(id1, "python -m venv .venv && .venv/bin/pip install -q -r requirements.txt && .venv/bin/python -c 'import six; print(six.__version__)'")
        check("pip install from pypi (allowed automatically)", venv.output.contains("1.16.0"), venv.output + venv.errorOutput)
        let hostVenv = (try? FileManager.default.contentsOfDirectory(atPath: first.workspace.hostPath! + "/.venv")) ?? []
        check(".venv stays off the Mac", hostVenv.isEmpty, "\(hostVenv.count) entries in the worktree's .venv")
        let cache = try await sh(id1, "du -sk ~/.cache/pip | cut -f1")
        check("pip cache in ~/.cache", (Int(cache.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0, cache.output)
        let install = try await sh(id1, "airlock-install libpq-dev 2>&1 | tail -5; echo exit=$?; ls -la /run/airlock; dpkg -s libpq-dev | grep Status")
        check("airlock-install libpq-dev", install.output.contains("exit=0") && install.output.contains("install ok installed"), install.output + install.errorOutput)
        let refused = try await sh(id1, "airlock-install sudo; echo exit=$?")
        check("airlock-install refuses sudo", refused.output.contains("isn't allowed") && !refused.output.contains("exit=0"), refused.output)
        let injection = try await sh(id1, "airlock-install '../x' '-o' 2>&1; echo exit=$?")
        check("airlock-install refuses non-package names", injection.output.contains("isn't a Debian package name"), injection.output)
        try await engine.remove(first.id)
        let learned = await engine.projects().first { $0.id == first.projectID }?.packages ?? []
        check("installed package learned by the project", learned.contains("libpq-dev"), learned.joined(separator: ", "))

        let (second, id2) = try await start("Stacks two", resources: ResourceLimits(cpus: 3, memoryMB: 3072))
        if runtime.kind == .docker {
            let inspect = try await ProcessRunner.run(ComposeServices.dockerCLI() ?? "/usr/local/bin/docker",
                                                       ["inspect", "-f", "{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}", id2], check: false)
            check("chosen size applied to the container", String(decoding: inspect.stdout, as: UTF8.self).hasPrefix("3000000000 3221225472"),
                  String(decoding: inspect.stdout, as: UTF8.self) + "\(second.resourceReason ?? "")")
        } else {
            let cpus = try await sh(id2, "nproc")
            check("chosen size applied to the VM", cpus.output.trimmingCharacters(in: .whitespacesAndNewlines) == "3", cpus.output)
        }
        try await EndToEnd.waitFor("usage", timeout: 40) { await engine.usage(for: second.id)["agent"] != nil }
        let reading = await engine.usage(for: second.id)["agent"]
        check("live usage read", (reading?.memoryBytes ?? 0) > 0, "\(String(describing: reading))")
        let baked = try await sh(id2, "dpkg -s libpq-dev | grep Status")
        check("learned package baked into the next image", baked.output.contains("install ok installed"), baked.output + baked.errorOutput)
        let fresh = try await sh(id2, "ls -A ~/.cache/pip 2>/dev/null | wc -l")
        check("the next task gets a cache of its own", fresh.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", fresh.output)
        try await engine.remove(second.id)

        // Settings file: the project brings its own agent image and an extra package.
        try FileManager.default.createDirectory(at: repo.appending(path: ".airlock"), withIntermediateDirectories: true)
        try """
        x-airlock:
          packages: [jq]
          allow: [api.stripe.com]
        services:
          agent:
            image: python:3.12-bookworm
            environment:
              AIRLOCK_E2E: "yes"
        """.write(to: repo.appending(path: ".airlock/compose.yaml"), atomically: true, encoding: .utf8)
        for cmd in [["add", "."], ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", "settings"]] {
            try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + cmd)
        }
        let (third, id3) = try await start("Stacks three")
        let custom = try await sh(id3, "cat /etc/os-release | grep -c bookworm; /usr/local/bin/python3 --version; jq --version; echo $AIRLOCK_E2E; id -un; claude --version")
        check("agent runs on the project's image", custom.output.contains("Python 3.12") && custom.output.contains("jq-") && custom.output.contains("yes\nnode") && custom.output.contains("Claude Code"),
              custom.output.replacingOccurrences(of: "\n", with: " | ") + custom.errorOutput)
        check("settings recorded on the stack", third.stack?.configSource == ".airlock/compose.yaml" && third.stack?.allow == ["api.stripe.com"], "\(String(describing: third.stack))")
        try await engine.remove(third.id)
        if let project = await engine.projects().first(where: { $0.id == third.projectID }) {
            try await engine.deleteProject(project.id)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

import AirlockCore
import AirlockDocker
import AirlockEngine
import AirlockRuntime
import Foundation

/// Compose services next to the agent, and ports forwarded to localhost, on a real task.
enum EndToEndServices {
    static func run(runtime docker: DockerRuntime, scratch: URL) async throws {
        let root = scratch.appending(path: "e2e-services-\(Int(Date().timeIntervalSince1970))")
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for cmd in [["init", "-q", "-b", "main"], ["config", "user.name", "AIrlock Test"], ["config", "user.email", "test@example.invalid"]] {
            try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + cmd)
        }
        try """
        services:
          db:
            image: postgres:16-alpine
            environment:
              POSTGRES_PASSWORD: secret
            ports: ["5432:5432"]
            volumes: [pgdata:/var/lib/postgresql/data]
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 1s
              retries: 60
          cache:
            image: redis:7-alpine
            depends_on: [db]
          app:
            build: .
            depends_on: [db, cache]
        volumes:
          pgdata:
        """.write(to: repo.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "add", "."])
        try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "commit", "-qm", "init"])

        let engine = TaskEngine(
            paths: Paths(root: root.appending(path: "support")),
            secrets: InMemorySecretStore([.anthropicAPIKey: "dummy-not-a-key"]),
            runtimes: [.docker: docker]
        )
        let logTask = Task {
            for await update in engine.updates {
                if case .log(_, let line) = update, !line.hasPrefix(" ") { print("  \(line)") }
            }
        }
        defer { logTask.cancel() }

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let task = try await engine.create(NewTaskRequest(
            title: "Services check", prompt: "Say hello", repoPath: repo.path, baseRef: "main",
            runtime: .docker, network: .restricted(extraDomains: []), services: true, expose: [8000]
        ))
        try await EndToEnd.waitFor("running", timeout: 900) {
            let t = await engine.task(task.id)
            if case .failed(let m)? = t?.lifecycle { throw EngineError(m) }
            return t?.lifecycle == .running
        }
        let t = await engine.task(task.id)!
        let agent = t.containerID!
        func sh(_ id: String, _ cmd: String, user: String? = "node") async throws -> ExecResult {
            try await docker.exec(id, ExecSpec(["sh", "-c", cmd], user: user))
        }

        let services = t.services!
        check("infrastructure services planned", services.items.map(\.name) == ["db", "cache"], services.items.map(\.name).joined(separator: ", "))
        check("build service skipped", services.skipped["app"] != nil, services.skipped["app"] ?? "")
        let states = services.items.map { "\($0.name)=\($0.state.title)" }.joined(separator: " ")
        check("db healthy, cache running", services.items.first { $0.name == "db" }?.state == .healthy
              && services.items.first { $0.name == "cache" }?.state.isUp == true, states)
        check("db's host port dropped", services.items.first { $0.name == "db" }?.dropped.contains { $0.hasPrefix("ports 5432:5432") } == true)

        let reach = try await sh(agent, "socat -u /dev/null TCP:db:5432,connect-timeout=3 && socat -u /dev/null TCP:cache:6379,connect-timeout=3")
        check("agent reaches db:5432 and cache:6379", reach.exitCode == 0, reach.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))

        let cacheID = services.items.first { $0.name == "cache" }!.containerID!
        let egress = try await sh(cacheID, "wget -q -T 5 -O /dev/null http://example.com", user: nil)
        check("services follow the allowlist (example.com blocked)", egress.exitCode != 0, "exit \(egress.exitCode)")
        let published = try await ProcessRunner.run(ComposeServices.dockerCLI()!, ["port", cacheID], check: false)
        check("nothing published on the Mac", published.output.isEmpty)
        let ping = try await sh(cacheID, "redis-cli ping", user: nil)
        check("redis answers inside the task", ping.output.contains("PONG"), ping.output.trimmingCharacters(in: .whitespacesAndNewlines))

        // Ports: a server in the agent container, forwarded at creation (expose: [8000]).
        _ = try await sh(agent, "nohup node -e \"require('http').createServer((q,s)=>s.end('hello from the task')).listen(8000)\" >/dev/null 2>&1 &")
        try await Task.sleep(for: .seconds(1))
        let forward = await engine.task(task.id)?.ports.first { $0.containerPort == 8000 }
        check("port 8000 forwarded at start", forward != nil, forward.map(\.url) ?? "")
        if let forward {
            let body = try await ProcessRunner.run("/usr/bin/curl", ["-sS", "-m", "5", forward.url], check: false)
            check("localhost reaches the agent's server", body.output == "hello from the task", body.output + body.errorOutput)
        }
        let db = try await engine.expose(task.id, port: nil, service: "db")
        let dbOpen = try await ProcessRunner.run("/usr/bin/nc", ["-z", "-w", "3", "127.0.0.1", "\(db.hostPort)"], check: false)
        check("db exposed by service name", db.containerPort == 5432 && dbOpen.status == 0, "\(db.label) → \(db.hostPort)")
        let listening = await engine.listeningPorts(task.id)
        check("listening ports seen", listening.contains(8000) && listening.contains(5432), listening.map(String.init).joined(separator: ","))
        await engine.unexpose(task.id, port: 5432)
        let dbClosed = try await ProcessRunner.run("/usr/bin/nc", ["-z", "-w", "2", "127.0.0.1", "\(db.hostPort)"], check: false)
        check("unexpose closes the port", dbClosed.status != 0)

        let logs = try await engine.serviceLogs(task.id, service: "db", tail: 50)
        check("service logs", logs.contains("database system is ready"), "\(logs.count) chars")

        await engine.stop(task.id)
        let stopped = await engine.task(task.id)!
        check("stop stops the group", stopped.services!.items.allSatisfy { $0.state == .stopped })
        await engine.start(task.id)
        try await EndToEnd.waitFor("restart", timeout: 120) { await engine.task(task.id)?.lifecycle == .running }
        let restarted = await engine.task(task.id)!
        check("start brings services back", restarted.services!.items.allSatisfy(\.state.isUp),
              restarted.services!.items.map { "\($0.name)=\($0.state.title)" }.joined(separator: " "))
        _ = try await sh(agent, "nohup node -e \"require('http').createServer((q,s)=>s.end('again')).listen(8000)\" >/dev/null 2>&1 &")
        try await Task.sleep(for: .seconds(1))
        if let forward = restarted.ports.first(where: { $0.containerPort == 8000 }) {
            let body = try await ProcessRunner.run("/usr/bin/curl", ["-sS", "-m", "5", forward.url], check: false)
            check("forward restored after restart", body.output == "again", body.output + body.errorOutput)
        } else {
            check("forward restored after restart", false, "no forward")
        }

        let volumes = restarted.services!.items.flatMap(\.volumes)
        try await engine.remove(task.id)
        let leftovers = try await docker.containers(label: "airlock.task=\(task.id.uuidString)")
        check("remove deletes service containers", leftovers.isEmpty, "\(leftovers.count) left")
        var volumeGone = true
        for volume in volumes {
            let inspect = try await ProcessRunner.run(ComposeServices.dockerCLI()!, ["volume", "inspect", volume], check: false)
            if inspect.status == 0 { volumeGone = false }
        }
        check("remove deletes service volumes", volumeGone, volumes.joined(separator: ", "))
        try? FileManager.default.removeItem(at: root)
    }
}

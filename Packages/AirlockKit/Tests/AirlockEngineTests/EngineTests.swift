import AirlockCore
import AirlockProviders
import AirlockRuntime
import Foundation
import Testing
@testable import AirlockDocker
@testable import AirlockEngine

@Suite struct EngineTests {
    @Test func shellQuoting() {
        #expect(TaskEngine.shellQuote("claude") == "claude")
        #expect(TaskEngine.shellQuote("--dangerously-skip-permissions") == "--dangerously-skip-permissions")
        #expect(TaskEngine.shellQuote("Fix it") == "'Fix it'")
        #expect(TaskEngine.shellQuote("don't; rm -rf /") == "'don'\\''t; rm -rf /'")
        #expect(TaskEngine.shellQuote("") == "''")
    }
}

@Suite struct AccessTests {
    @Test func recordsWhatTheAgentGets() {
        let both = TaskEngine.access([.claudeOAuthToken: "t", .anthropicAPIKey: "k", .githubToken: "g"])
        #expect(both == TaskAccess(credential: .claudeToken, github: true))
        #expect(TaskEngine.access([.anthropicAPIKey: "k"]) == TaskAccess(credential: .apiKey, github: false))
    }
}

@Suite struct EngineProjectTests {
    func makeEngine() -> (TaskEngine, Paths) {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appending(path: "airlock-engine-\(UUID().uuidString.prefix(8))"))
        let secrets = InMemorySecretStore([.anthropicAPIKey: "sk-ant-api03-test"])
        return (TaskEngine(paths: paths, secrets: secrets, runtimes: [:]), paths)
    }

    func request(_ repo: String, project: UUID? = nil, tags: [String] = []) -> NewTaskRequest {
        NewTaskRequest(title: "t", prompt: "p", repoPath: repo, baseRef: "main", projectID: project, tags: tags)
    }

    @Test func resolvesProjects() async throws {
        let (engine, paths) = makeEngine()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let repo = paths.root.path
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        // No projects yet: the repo's default project is created.
        let first = try await engine.create(request(repo, tags: ["Release 2.4"]))
        let defaultProject = try #require(await engine.project(first.projectID))
        #expect(defaultProject.name == paths.root.lastPathComponent)
        #expect(first.tags == ["release-2.4"])

        // One project for the repo: it's used.
        let second = try await engine.create(request(repo))
        #expect(second.projectID == defaultProject.id)

        // Several: explicit wins, otherwise the default.
        let redesign = try await engine.createProject(name: "Redesign", repoPath: repo)
        #expect(try await engine.createProject(name: "redesign", repoPath: repo).id == redesign.id)
        #expect(try await engine.create(request(repo, project: redesign.id)).projectID == redesign.id)
        #expect(try await engine.create(request(repo)).projectID == defaultProject.id)
        #expect(await engine.findProject("REDESIGN", repoPath: repo)?.id == redesign.id)
        #expect(await engine.findProject("nope") == nil)

        // A project of another repo is refused.
        let other = paths.root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let foreign = try await engine.createProject(name: "Other", repoPath: other.path)
        await #expect(throws: EngineError.self) { try await engine.create(request(repo, project: foreign.id)) }
        await #expect(throws: EngineError.self) { try await engine.moveTask(first.id, to: foreign.id) }

        // Moving, then deleting the project deletes its tasks.
        try await engine.moveTask(first.id, to: redesign.id)
        #expect(await engine.task(first.id)?.projectID == redesign.id)
        try await engine.deleteProject(redesign.id)
        #expect(await engine.task(first.id) == nil)
        #expect(await engine.task(second.id)?.projectID == defaultProject.id)
        #expect(await engine.project(redesign.id) == nil)

        // Tags.
        #expect(try await engine.setTags(second.id, add: ["Auth", "auth"], remove: ["release-2.4"]) == ["auth"])
    }

    @Test func migratesTasksWithoutProjects() async throws {
        let (engine, paths) = makeEngine()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var task = AgentTask(title: "old", prompt: "", repo: RepoRef(path: "/r/webapp", baseRef: "main"), workspace: .init(mode: .worktree, branch: "b"))
        task.lifecycle = .stopped
        try TaskStore(paths: paths).save(task)
        let loaded = await engine.bootstrap()
        let project = try #require(await engine.project(loaded.first?.projectID))
        #expect(project.name == "webapp")
        #expect(try ProjectStore(paths: paths).load().map(\.name) == ["webapp"])
    }

    /// Writes hook lines for a running task, then boots an engine that replays them.
    func engineWithEvents(_ lines: [String]) async throws -> (TaskEngine, Paths, UUID) {
        let (engine, paths) = makeEngine()
        var task = AgentTask(title: "t", prompt: "", repo: RepoRef(path: "/r/webapp", baseRef: "main"), workspace: .init(mode: .worktree, branch: "b"))
        task.lifecycle = .running
        task.containerID = "c"
        try TaskStore(paths: paths).save(task)
        try FileManager.default.createDirectory(at: paths.events(task.id), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: paths.events(task.id).appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
        _ = await engine.bootstrap()
        return (engine, paths, task.id)
    }

    static let todo = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Run tests","activeForm":"Running tests","status":"in_progress"},{"content":"Commit","status":"pending"}]}}}"#

    @Test func progressReportsMilestonesThenTheTurnEnd() async throws {
        let (engine, paths, id) = try await engineWithEvents([
            #"{"ts":"x","event":"SessionStart","payload":{}}"#,
            #"{"ts":"x","event":"UserPromptSubmit","payload":{"prompt":"go"}}"#,
            Self.todo,
            #"{"ts":"x","event":"Stop","payload":{}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let all = try #require(await engine.progress(id, after: -1))
        #expect(all.milestones == ["Running tests (0/2 done)"])
        #expect(all.status == "ready")
        #expect(all.ended)
        #expect(all.lastEventID == 3)
        // Nothing new after the Stop: a ready task the caller already saw isn't "ended" again.
        let later = try #require(await engine.progress(id, after: 3))
        #expect(later.milestones.isEmpty)
        #expect(!later.ended)
    }

    @Test func apiErrorsFailFast() async throws {
        let (engine, paths, id) = try await engineWithEvents([
            #"{"ts":"x","event":"SessionStart","payload":{}}"#,
            #"{"ts":"x","event":"UserPromptSubmit","payload":{"prompt":"go"}}"#,
            #"{"ts":"x","event":"StopFailure","payload":{"error":"billing_error","error_details":"Credit balance is too low"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let snapshot = try #require(await engine.waitForUpdate(id, afterEventID: 1, timeout: .seconds(5)))
        #expect(snapshot.status == "failed")
        #expect(snapshot.statusDetail == "Out of API credits: Credit balance is too low")
        #expect(await engine.progress(id, after: 1)?.ended == true)
    }
}

@Suite struct ComposeServicesTests {
    /// `docker compose config --format json` output for a sample project at /repo.
    static let fixture = #"""
    {"name":"sample","services":{
      "api":{"build":{"context":"/repo","dockerfile":"Dockerfile"},"cap_add":["NET_ADMIN"],"command":null,
             "depends_on":{"db":{"condition":"service_healthy","required":true},"redis":{"condition":"service_started","required":true}},
             "entrypoint":null,"network_mode":"host","privileged":true,
             "volumes":[{"type":"bind","source":"/var/run/docker.sock","target":"/var/run/docker.sock","bind":{"create_host_path":true}}]},
      "db":{"command":null,"entrypoint":null,"environment":{"POSTGRES_PASSWORD":"secret","EMPTY":null},
            "healthcheck":{"test":["CMD-SHELL","pg_isready -U postgres"],"timeout":"3s","interval":"2s","retries":20,"start_period":"1m30s"},
            "image":"postgres:16-alpine","networks":{"default":null},
            "ports":[{"mode":"ingress","target":5432,"published":"5432","protocol":"tcp"}],
            "volumes":[{"type":"volume","source":"pgdata","target":"/var/lib/postgresql/data","volume":{}},
                       {"type":"bind","source":"/repo/data/init.sql","target":"/docker-entrypoint-initdb.d/init.sql","read_only":true,"bind":{"create_host_path":true}},
                       {"type":"bind","source":"/etc/passwd","target":"/x","bind":{}}]},
      "redis":{"command":["redis-server","--appendonly","yes"],"entrypoint":null,"image":"redis:7-alpine","depends_on":{"db":{"condition":"service_started"}},
               "networks":{"default":null},"tmpfs":["/tmp"],"expose":["6379"]},
      "redis2":{"image":"redis:7","expose":["6379/tcp"]}
    },"volumes":{"pgdata":{"name":"sample_pgdata"}}}
    """#

    func plan(root: String? = "/repo") throws -> ServicePlan {
        let project = try JSONDecoder().decode(ComposeProject.self, from: Data(Self.fixture.utf8))
        return ComposeServices.plan(project, volumePrefix: "airlock-abcd1234", root: root)
    }

    @Test func bindsStayInsideTheTaskFiles() throws {
        let base = URL(fileURLWithPath: ComposeServices.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-bind-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let checkout = base.appending(path: "checkout")
        try FileManager.default.createDirectory(at: checkout.appending(path: "data"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: checkout.appending(path: "ssh").path, withDestinationPath: NSHomeDirectory() + "/.ssh")
        #expect(ComposeServices.confined(checkout.path + "/data", to: checkout.path) == checkout.path + "/data")
        #expect(ComposeServices.confined(checkout.path + "/ssh", to: checkout.path) == nil)
        #expect(ComposeServices.confined(checkout.path + "/../x", to: checkout.path) == nil)

        // Binds from the user's repository move into the checkout; one that leads out is dropped.
        let compose = #"{"services":{"web":{"image":"nginx","volumes":[{"type":"bind","source":"/repo/data","target":"/d"},{"type":"bind","source":"/repo/ssh","target":"/s"}]}}}"#
        let project = try JSONDecoder().decode(ComposeProject.self, from: Data(compose.utf8))
        let web = try #require(ComposeServices.plan(project, volumePrefix: "p", root: "/repo", checkout: checkout.path).services.first)
        #expect(web.mounts == [.bind(hostPath: checkout.path + "/data", containerPath: "/d", readOnly: false)])
        #expect(web.dropped.contains { $0.contains("leads outside") })
    }

    @Test func keepsInfrastructureOnly() throws {
        let plan = try plan()
        #expect(plan.services.map(\.name) == ["db", "redis"])
        #expect(plan.skipped["api"]?.contains("Built from the repository") == true)
        #expect(plan.skipped["redis2"]?.contains("Port 6379 is already used by redis") == true)
    }

    @Test func mapsAndDropsSafely() throws {
        let db = try #require(try plan().services.first { $0.name == "db" })
        #expect(db.environment == ["POSTGRES_PASSWORD": "secret"])
        #expect(db.ports == [5432])
        #expect(db.volumes == ["airlock-abcd1234-pgdata"])
        #expect(db.mounts.contains(.volume(name: "airlock-abcd1234-pgdata", containerPath: "/var/lib/postgresql/data")))
        #expect(db.mounts.contains(.bind(hostPath: "/repo/data/init.sql", containerPath: "/docker-entrypoint-initdb.d/init.sql", readOnly: true)))
        #expect(!db.mounts.contains { $0.containerPath == "/x" })
        #expect(db.dropped.contains { $0.hasPrefix("ports 5432:5432") })
        #expect(db.dropped.contains { $0.contains("/etc/passwd") })
        #expect(db.healthcheck == HealthcheckSpec(test: ["CMD-SHELL", "pg_isready -U postgres"], interval: .seconds(2),
                                                  timeout: .seconds(3), retries: 20, startPeriod: .seconds(90)))
    }

    @Test func isolatedCloneDropsRepoBindMounts() throws {
        let db = try #require(try plan(root: nil).services.first { $0.name == "db" })
        #expect(!db.mounts.contains { if case .bind = $0 { true } else { false } })
        #expect(db.dropped.contains { $0.contains("isolated clone") })
    }

    @Test func containerSharesTheAgentsNetwork() throws {
        let redis = try #require(try plan().services.first { $0.name == "redis" })
        let task = AgentTask(title: "t", prompt: "", repo: RepoRef(path: "/repo", baseRef: "main"), workspace: .init(mode: .worktree, branch: "b"))
        let spec = redis.containerSpec(task: task, agentContainerID: "agent123")
        #expect(spec.networkMode == "container:agent123")
        #expect(spec.name == "\(task.containerName)-redis")
        #expect(spec.labels["airlock.service"] == "redis")
        #expect(spec.command == ["redis-server", "--appendonly", "yes"])
        #expect(spec.tmpfs == ["/tmp": ""])
        #expect(spec.capAdd.isEmpty)
    }

    @Test func dependenciesStartFirst() {
        func svc(_ name: String, _ deps: [String] = []) -> PlannedService {
            PlannedService(name: name, image: "x", command: [], entrypoint: nil, environment: [:], workdir: nil, user: nil,
                           healthcheck: nil, tmpfs: [], mounts: [], volumes: [], ports: [], dependsOn: deps, dropped: [])
        }
        #expect(ComposeServices.order([svc("a", ["c"]), svc("b"), svc("c", ["b"])]).map(\.name) == ["b", "c", "a"])
        #expect(ComposeServices.order([svc("a", ["missing"])]).map(\.name) == ["a"])
    }

    @Test func goDurations() {
        #expect(ComposeServices.goDuration("2s") == .seconds(2))
        #expect(ComposeServices.goDuration("1m30s") == .seconds(90))
        #expect(ComposeServices.goDuration("500ms") == .milliseconds(500))
        #expect(ComposeServices.goDuration("nonsense") == nil)
    }

    @Test func detectsComposeFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "airlock-compose-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: ".devcontainer"), withIntermediateDirectories: true)
        #expect(ComposeServices.detect(in: dir) == nil)
        try "services: {}".write(to: dir.appending(path: "docker-compose.dev.yml"), atomically: true, encoding: .utf8)
        try #"{ // comment\n "dockerComposeFile": "../docker-compose.dev.yml" }"#.replacingOccurrences(of: "\\n", with: "\n")
            .write(to: dir.appending(path: ".devcontainer/devcontainer.json"), atomically: true, encoding: .utf8)
        #expect(ComposeServices.detect(in: dir) == "docker-compose.dev.yml")
        try "services: {}".write(to: dir.appending(path: "compose.yaml"), atomically: true, encoding: .utf8)
        #expect(ComposeServices.detect(in: dir) == "compose.yaml")
    }
}

@Suite struct DockerReferenceTests {
    @Test func splitsImageReferences() {
        #expect(DockerRuntime.splitReference("postgres:16") == ("postgres", "16"))
        #expect(DockerRuntime.splitReference("redis") == ("redis", "latest"))
        #expect(DockerRuntime.splitReference("registry:5000/team/app") == ("registry:5000/team/app", "latest"))
        #expect(DockerRuntime.splitReference("ghcr.io/x/y:1.2") == ("ghcr.io/x/y", "1.2"))
    }
}

@Suite struct StackImageTests {
    @Test func dockerfileInstallsToolsAndPackages() {
        let stack = ProjectStack(tools: ["python": "3.12", "go": "1.22"], ecosystems: [.python, .go], packages: ["php-cli"])
        let file = StackImage.dockerfile(for: stack, learnedPackages: ["libpq-dev", "php-cli", "bad name; rm -rf /"])!
        #expect(file.contains("apt-get install -y --no-install-recommends php-cli libpq-dev &&"))
        #expect(!file.contains("rm -rf /\n") && !file.contains("bad name"))
        #expect(file.contains("RUN mise use -g go@1.22 python@3.12 && mise reshim"))
        #expect(file.hasSuffix("USER root\n"))
    }
}

@Suite struct ProjectConfigTests {
    @Test func parsesComposeConfigOutput() throws {
        let json = #"""
        {"name":"x","services":{"agent":{"image":"python:3.12-bookworm","environment":{"FOO":"bar","EMPTY":null},
          "deploy":{"resources":{"limits":{"cpus":4,"memory":"8589934592"}}}},"search":{"image":"redis:7"}},
         "x-airlock":{"allow":["api.stripe.com"],"packages":["libpq-dev"],"tools":{"node":"22","python":3.12}}}
        """#
        let config = try #require(try ProjectConfig.parse(Data(json.utf8), source: ".airlock/compose.yaml"))
        #expect(config.tools == ["node": "22", "python": "3.12"])
        #expect(config.packages == ["libpq-dev"] && config.allow == ["api.stripe.com"])
        #expect(config.agentImage == "python:3.12-bookworm" && config.agentBuild == nil)
        #expect(config.environment == ["FOO": "bar"])
        #expect(config.resources == ResourceLimits(cpus: 4, memoryMB: 8192))
    }

    @Test func nothingWithoutAirlockSettings() throws {
        #expect(try ProjectConfig.parse(Data(#"{"services":{"db":{"image":"postgres:16"}}}"#.utf8), source: "compose.yaml") == nil)
        let build = try #require(try ProjectConfig.parse(Data(#"{"services":{"agent":{"build":{"context":"/r","dockerfile":".airlock/Dockerfile","target":"dev"}}}}"#.utf8), source: "compose.yaml"))
        #expect(build.agentBuild == .init(context: "/r", dockerfile: ".airlock/Dockerfile", target: "dev"))
    }

    @Test func sizeInAirlockBlock() throws {
        let json = #"{"services":{},"x-airlock":{"resources":{"cpus":2,"memory":"6g"}}}"#
        #expect(try ProjectConfig.parse(Data(json.utf8), source: "x")?.resources == ResourceLimits(cpus: 2, memoryMB: 6144))
        #expect(ProjectConfig.Size.megabytes("512m") == 512 && ProjectConfig.Size.megabytes("8GB") == 8192 && ProjectConfig.Size.megabytes("x") == nil)
    }

    @Test func templateNamesDetectedTools() {
        let text = ProjectConfig.template(for: ProjectStack(tools: ["python": "3.13"], packages: ["libpq-dev"]))
        #expect(text.contains("    python: \"3.13\"") && text.contains("    - libpq-dev") && text.contains("x-airlock:"))
    }
}

@Suite struct ResourcePlannerTests {
    let mac = ResourcePlanner.Host(cores: 12, memoryMB: 32_768)

    @Test func precedence() {
        let explicit = ResourceLimits(cpus: 8, memoryMB: 16_384)
        let project = ResourceLimits(cpus: 6, memoryMB: 6_144)
        let config = (limits: ResourceLimits(cpus: 3, memoryMB: 3_072), source: ".airlock/compose.yaml")
        #expect(ResourcePlanner.plan(explicit: explicit, projectDefault: project, config: config, stack: nil, services: 0, reservedMemoryMB: 0, host: mac).reason == "set for this task")
        #expect(ResourcePlanner.plan(explicit: nil, projectDefault: project, config: config, stack: nil, services: 0, reservedMemoryMB: 0, host: mac).limits == project)
        #expect(ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: config, stack: nil, services: 0, reservedMemoryMB: 0, host: mac).reason == ".airlock/compose.yaml")
    }

    @Test func autoSizesHeavyStacks() {
        let light = ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: nil, stack: ProjectStack(ecosystems: [.python]), services: 0, reservedMemoryMB: 0, host: mac)
        #expect(light.limits == ResourceLimits(cpus: 4, memoryMB: 4096) && light.reason == "auto" && light.warning == nil)
        let rust = ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: nil, stack: ProjectStack(ecosystems: [.rust], heavy: true), services: 0, reservedMemoryMB: 0, host: mac)
        #expect(rust.limits == ResourceLimits(cpus: 4, memoryMB: 8192) && rust.reason == "auto, Rust")
        // A small Mac: never more than half its memory.
        let small = ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: nil, stack: ProjectStack(ecosystems: [.java], heavy: true), services: 0, reservedMemoryMB: 0,
                                         host: .init(cores: 8, memoryMB: 8192))
        #expect(small.limits.memoryMB == 4096 && small.limits.cpus == 2)
    }

    @Test func warnsWhenTheMacWouldRunShort() {
        let plan = ResourcePlanner.plan(explicit: nil, projectDefault: nil, config: nil, stack: nil, services: 2, reservedMemoryMB: 20_480, host: mac)
        #expect(plan.warning?.contains("of your Mac’s 32 GB") == true)
        #expect(ResourceLimits(cpus: 4, memoryMB: 1536).summary == "4 CPU · 1.5 GB")
    }
}

@Suite struct HostCoverageTests {
    @Test func parentDomainsCover() {
        let hosts: Set<String> = ["pypi.org", "amazonaws.com"]
        #expect(TaskEngine.covered("upload.pypi.org", by: hosts))
        #expect(TaskEngine.covered("s3.eu-west-1.amazonaws.com", by: hosts))
        #expect(!TaskEngine.covered("pypi.org.evil.com", by: hosts))
        #expect(!TaskEngine.covered("notpypi.org", by: hosts))
    }
}

@Suite struct InspectionTests {
    @Test func sourcesAreCheckedBeforeAnythingStarts() throws {
        #expect(try TaskEngine.checkedSource(.url(" https://github.com/a/b ")) == .url("https://github.com/a/b"))
        #expect(throws: EngineError.self) { try TaskEngine.checkedSource(.url("http://github.com/a/b")) }
        #expect(throws: EngineError.self) { try TaskEngine.checkedSource(.url("https://user:pass@github.com/a/b")) }
        #expect(throws: EngineError.self) { try TaskEngine.checkedSource(.url("git@github.com:a/b.git")) }
        #expect(throws: EngineError.self) { try TaskEngine.checkedSource(.folder("/no/such/folder")) }
        #expect(Inspection.Source.url("https://github.com/a/b.git").name == "b")
    }

    @Test func theNetworkClosesBeforeTheCodeRuns() throws {
        var task = AgentTask(title: "Inspect b", prompt: "", repo: RepoRef(path: "https://github.com/a/b", baseRef: ""),
                             workspace: .init(mode: .volumeClone, branch: ""))
        task.inspection = Inspection(source: .url("https://github.com/a/b"))
        func config() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: TaskEngine.networkConfig(task, provider: ClaudeCodeProvider())) as! [String: Any]
        }
        task.inspection?.phase = .downloading
        let downloading = try config()
        #expect((downloading["domains"] as? [String])?.contains("registry.npmjs.org") == true)
        #expect((downloading["domains"] as? [String])?.contains("github.com") == true)
        #expect((downloading["proxyDomains"] as? [String]) == [])
        for phase in [Inspection.Phase.sealed, .running, .finished, .failed] {
            task.inspection?.phase = phase
            #expect((try config()["domains"] as? [String]) == [], "\(phase)")
        }
        // Claude's API only through the proxy, and only when Claude investigates.
        task.inspection?.investigate = true
        #expect((try config()["proxyDomains"] as? [String]) == ["api.anthropic.com"])
    }

    @Test func readsTheRecordCleanly() {
        var report = InspectionReport()
        TaskEngine.read("""
            read ~/.npmrc
            tried 203.0.113.40:443
            changed /home/node/.bashrc
            changed /tmp/\u{1B}[2Jx
            process node -e setInterval(()=>0,1e3)
            script left-padz (postinstall)
            repo src/index.js
            something else
            """, into: &report)
        #expect(report.credentialReads == ["~/.npmrc"])
        #expect(report.triedAddresses == ["203.0.113.40:443"])
        #expect(report.changedOutside == ["/home/node/.bashrc", "/tmp/x"])
        #expect(report.processes.count == 1 && report.installScripts == ["left-padz (postinstall)"] && report.changedInRepo == ["src/index.js"])
        #expect(report.findings == 5)
        #expect(report.summary.hasPrefix("Tried to reach 1 host, read 1 credential file"))
        #expect(InspectionReport().summary == "Nothing suspicious seen")
    }
}

@Suite struct SealedNetworkTests {
    @Test func registriesOnlyUntilTheNetworkCloses() throws {
        var task = AgentTask(title: "t", prompt: "", repo: RepoRef(path: "/r", baseRef: "main"), workspace: .init(mode: .volumeClone, branch: ""),
                             network: .restricted(extraDomains: ["api.stripe.com"]))
        task.sealing = Sealing()
        func domains() throws -> [String] {
            let config = try JSONSerialization.jsonObject(with: TaskEngine.networkConfig(task, provider: ClaudeCodeProvider())) as! [String: Any]
            #expect(config["proxyDomains"] as? [String] == ["api.anthropic.com"])
            return config["domains"] as? [String] ?? []
        }
        #expect(try domains().contains("registry.npmjs.org"))
        #expect(try domains().contains("pypi.org"))
        task.sealing?.phase = .sealed
        // Closed: only what the user allowed.
        #expect(try domains() == ["api.stripe.com"])
    }

    @Test func newTasksAreSealedUnlessAskedOtherwise() {
        #expect(NewTaskRequest(title: "t", prompt: "p", repoPath: "/r", baseRef: "main").sealed)
        #expect(!NewTaskRequest(title: "t", prompt: "p", repoPath: "/r", baseRef: "main", sealed: false).sealed)
    }
}

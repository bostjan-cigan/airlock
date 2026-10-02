import Foundation
import Testing
@testable import AirlockCore

func makeTask(_ title: String, repo: String = "/r/webapp", lifecycle: Lifecycle = .running, activity: Activity = .unknown, done: Bool = false, at: TimeInterval = 0) -> AgentTask {
    var t = AgentTask(title: title, prompt: "", repo: RepoRef(path: repo, baseRef: "main"), workspace: .init(mode: .volumeClone, branch: "b"), createdAt: Date(timeIntervalSince1970: 1_000_000))
    t.lifecycle = lifecycle
    t.activity = activity
    t.isDone = done
    t.lastActivityAt = Date(timeIntervalSince1970: at)
    return t
}

@Suite struct GroupingTests {
    @Test func statuses() {
        #expect(makeTask("a", activity: .needsInput(reason: nil)).status == .needsInput)
        #expect(makeTask("a", activity: .working(tool: "Bash")).status == .working)
        #expect(makeTask("a", activity: .unknown).status == .working)
        #expect(makeTask("a", activity: .idle(lastMessage: "Done")).status == .ready)
        #expect(makeTask("a", activity: .error(reason: "Out of API credits")).status == .failed)
        #expect(makeTask("a", activity: .exited).status == .exited)
        #expect(makeTask("a", lifecycle: .buildingImage).status == .starting)
        #expect(makeTask("a", lifecycle: .stopped).status == .stopped)
        #expect(makeTask("a", lifecycle: .failed("x")).status == .failed)
        #expect(makeTask("a", activity: .needsInput(reason: nil), done: true).status == .done)
        #expect(makeTask("a", activity: .error(reason: "Out of API credits")).statusDetail == "Out of API credits")
    }

    @Test func statusGroups() {
        #expect(makeTask("a", activity: .needsInput(reason: nil)).statusGroup == .needsYou)
        #expect(makeTask("a", activity: .error(reason: "x")).statusGroup == .needsYou)
        #expect(makeTask("a", lifecycle: .failed("x")).statusGroup == .needsYou)
        #expect(makeTask("a", activity: .working(tool: nil)).statusGroup == .running)
        #expect(makeTask("a", lifecycle: .starting).statusGroup == .running)
        #expect(makeTask("a", activity: .idle(lastMessage: nil)).statusGroup == .recent)
        #expect(makeTask("a", lifecycle: .stopped).statusGroup == .recent)
    }

    @Test func scopesAndBuckets() {
        let projectA = UUID(), projectB = UUID()
        var waiting = makeTask("waiting", activity: .needsInput(reason: nil), at: 1)
        waiting.projectID = projectA
        waiting.tags = ["auth"]
        var working = makeTask("working", activity: .working(tool: nil), at: 100)
        working.projectID = projectB
        working.tags = ["auth", "overnight"]
        var old = makeTask("old", lifecycle: .stopped, at: 0)
        old.projectID = projectA
        var newer = makeTask("newer", activity: .idle(lastMessage: nil), at: 50)
        newer.projectID = projectA
        let all = [waiting, working, old, newer]

        #expect(Set(TaskGrouping.tasks(all, in: .active).map(\.title)) == ["waiting", "working"])
        #expect(TaskGrouping.tasks(all, in: .needsYou).map(\.title) == ["waiting"])
        #expect(TaskGrouping.tasks(all, in: .all).count == 4)
        #expect(Set(TaskGrouping.tasks(all, in: .project(projectA)).map(\.title)) == ["waiting", "old", "newer"])
        #expect(Set(TaskGrouping.tasks(all, in: .tag("auth")).map(\.title)) == ["waiting", "working"])

        let groups = TaskGrouping.group(TaskGrouping.tasks(all, in: .project(projectA)))
        #expect(groups.map(\.group) == [.needsYou, .recent])
        #expect(groups[1].tasks.map(\.title) == ["newer", "old"])

        #expect(TaskGrouping.filter(all, query: "OVERNIGHT") { _ in nil }.map(\.title) == ["working"])
        #expect(TaskGrouping.filter(all, query: "wait") { _ in nil }.map(\.title) == ["waiting"])
        #expect(TaskGrouping.tags(all) == ["auth", "overnight"])
    }

    @Test func projectsSortByActivity() {
        let quiet = Project(name: "Quiet", repoPath: "/r/a")
        let busy = Project(name: "Busy", repoPath: "/r/a")
        let empty = Project(name: "Alpha", repoPath: "/r/b")
        var task = makeTask("t", at: 10)
        task.projectID = busy.id
        #expect(TaskGrouping.sortedProjects([quiet, empty, busy], tasks: [task]).map(\.name) == ["Busy", "Alpha", "Quiet"])
    }
}

@Suite struct TagTests {
    @Test func normalize() {
        #expect(Tag.normalize("  Release 2.4 ") == "release-2.4")
        #expect(Tag.normalize("#Overnight") == "overnight")
        #expect(Tag.normalize("   ") == nil)
    }

    @Test func applyIsIdempotent() {
        var tags = Tag.apply([], add: ["Auth", "auth", "overnight"], remove: [])
        #expect(tags == ["auth", "overnight"])
        tags = Tag.apply(tags, add: ["auth"], remove: ["Overnight"])
        #expect(tags == ["auth"])
    }
}

@Suite struct SecretSanitizerTests {
    @Test func stripsWrappingAndPrefixes() {
        let key = SecretKey.claudeOAuthToken
        #expect(key.sanitize("sk-ant-oat01-abcdefghij\nklmnop\n") == "sk-ant-oat01-abcdefghijklmnop")
        #expect(key.sanitize("  \"sk-ant-oat01-abc def\"  ") == "sk-ant-oat01-abcdef")
        #expect(key.sanitize("export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xyz") == "sk-ant-oat01-xyz")
        #expect(key.sanitize("sk-ant-oat01-ends=") == "sk-ant-oat01-ends=")
    }

    @Test func validatesPrefix() {
        #expect(SecretKey.claudeOAuthToken.looksValid("sk-ant-oat01-x"))
        #expect(!SecretKey.claudeOAuthToken.looksValid("sk-ant-api03-x"))
        #expect(SecretKey.anthropicAPIKey.looksValid("sk-ant-api03-x"))
        #expect(SecretKey.githubToken.looksValid("anything"))
    }
}

@Suite struct ActivityReducerTests {
    func event(_ kind: AgentEvent.Kind, _ summary: String = "") -> AgentEvent {
        AgentEvent(id: 0, timestamp: .now, kind: kind, summary: summary)
    }

    @Test func turnCycle() {
        var a = Activity.unknown
        a = ActivityReducer.reduce(a, event(.sessionStart))
        #expect(a == .working(tool: nil))
        a = ActivityReducer.reduce(a, event(.prompt))
        #expect(a == .working(tool: nil))
        a = ActivityReducer.reduce(a, event(.toolStart, "Bash npm test"))
        #expect(a == .working(tool: "Bash npm test"))
        a = ActivityReducer.reduce(a, event(.compact))
        #expect(a == .working(tool: "Bash npm test"))
        a = ActivityReducer.reduce(a, event(.stop))
        #expect(a == .idle(lastMessage: nil))
        a = ActivityReducer.reduce(a, event(.notification, "Waiting for your input"))
        #expect(a == .needsInput(reason: "Waiting for your input"))
        a = ActivityReducer.reduce(a, event(.stopFailure, "Out of API credits"))
        #expect(a == .error(reason: "Out of API credits"))
        a = ActivityReducer.reduce(a, event(.sessionEnd))
        #expect(a == .exited)
    }

    @Test func notifiesWhenTheTurnEnds() {
        #expect(ActivityReducer.shouldNotify(event(.stop)))
        #expect(ActivityReducer.shouldNotify(event(.stopFailure)))
        #expect(ActivityReducer.shouldNotify(event(.notification)))
        #expect(!ActivityReducer.shouldNotify(event(.toolStart)))
    }

    @Test func currentMilestoneResetsOnPrompt() {
        var a = AgentEvent(id: 0, timestamp: .now, kind: .toolEnd, summary: "")
        a.milestone = "Writing tests (1/3 done)"
        let prompt = AgentEvent(id: 1, timestamp: .now, kind: .prompt, summary: "")
        let tool = AgentEvent(id: 2, timestamp: .now, kind: .toolStart, summary: "")
        #expect([a, tool].currentMilestone == "Writing tests (1/3 done)")
        #expect([a, prompt, tool].currentMilestone == nil)
    }
}

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(paths: Paths(root: root))
        var task = makeTask("Persist me", activity: .needsInput(reason: "Which DB?"))
        task.network = .restricted(extraDomains: ["pypi.org"])
        try store.save(task)
        let loaded = try store.loadAll()
        #expect(loaded == [task])
        try store.delete(task.id)
        #expect(try store.loadAll().isEmpty)
    }

    /// task.json files written before projects and tags existed still load.
    @Test func decodesOlderTasks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        let store = TaskStore(paths: paths)
        var task = makeTask("Old", activity: .idle(lastMessage: "hi"))
        task.tags = ["x"]
        task.projectID = UUID()
        try store.save(task)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.taskFile(task.id))) as! [String: Any]
        json["tags"] = nil
        json["projectID"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: paths.taskFile(task.id))
        let loaded = try #require(try store.loadAll().first)
        #expect(loaded.tags == [])
        #expect(loaded.projectID == nil)
        #expect(loaded.activity == .idle(lastMessage: "hi"))
    }

    @Test func projectsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(paths: Paths(root: root))
        #expect(try store.load().isEmpty)
        let project = Project(name: "Webapp redesign", repoPath: "/r/webapp", createdAt: Date(timeIntervalSince1970: 1_000_000))
        try store.save([project])
        #expect(try store.load() == [project])
    }

    @Test func inMemorySecrets() throws {
        let store = InMemorySecretStore()
        try store.set("x", for: .githubToken)
        #expect(try store.get(.githubToken) == "x")
        try store.set(nil, for: .githubToken)
        #expect(try store.get(.githubToken) == nil)
    }
}

@Suite struct PermissionTests {
    @Test func defaultSandboxIsNotElevated() {
        var task = makeTask("t")
        task.access = TaskAccess(credential: .claudeToken, github: false)
        #expect(!task.hasElevatedAccess)
        #expect(task.permissions.map(\.kind) == [.network, .files, .autonomy, .credential, .resources])
        #expect(task.permissions.first { $0.kind == .resources }?.detailOnly == true)
        // A worktree puts the task's files (and what it installs) on the Mac: beyond the sandbox.
        task.workspace.mode = .worktree
        #expect(task.hasElevatedAccess)
        #expect(task.permissions.first { $0.kind == .files }?.isElevated == true)
        #expect(task.permissions.first?.detail.contains("GitHub") == false)
    }

    @Test func githubOnlyWhenOptedIn() throws {
        var task = makeTask("t")
        task.githubAccess = true
        #expect(task.permissions.first?.detail.contains("GitHub") == true)
        #expect(task.permissions.first { $0.kind == .github }?.title == "Can reach GitHub")

        // Older records have no githubAccess key: they decode as opted out.
        var json = try #require(try JSONSerialization.jsonObject(with: TaskStore.encoder.encode(makeTask("old"))) as? [String: Any])
        json["githubAccess"] = nil
        let old = try TaskStore.decoder.decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.githubAccess)
    }

    @Test func elevatedItems() {
        var task = makeTask("t")
        task.network = .open
        task.access = TaskAccess(credential: .apiKey, github: true)
        #expect(task.permissions.filter(\.isElevated).map(\.kind) == [.network, .github, .credential])
    }

    @Test func unknownCredentialForOlderTasks() {
        let task = makeTask("t")
        #expect(task.permissions.first { $0.kind == .credential }?.title == "Credential unknown")
        #expect(!task.hasElevatedAccess)
    }
}

@Suite struct NetworkRulesTests {
    @Test func normalizesWhatPeoplePaste() throws {
        #expect(try NetworkRules.normalize("https://PyPI.org:443/simple/") == "pypi.org")
        #expect(try NetworkRules.normalize(" files.pythonhosted.org. ") == "files.pythonhosted.org")
        #expect(try NetworkRules.normalize("user@registry.example.com/path") == "registry.example.com")
        #expect(try NetworkRules.normalize("10.0.0.0/24") == "10.0.0.0/24")
        #expect(try NetworkRules.normalize("192.168.1.5") == "192.168.1.5")
        #expect(try NetworkRules.normalize("[2001:db8::1]:8080") == "2001:db8::1")
        #expect(try NetworkRules.normalize("2001:db8::/32") == "2001:db8::/32")
        #expect(try NetworkRules.normalize("*.amazonaws.com") == "amazonaws.com")
        #expect(throws: NetworkRuleError.self) { try NetworkRules.normalize("api.*.example.com") }
        #expect(throws: NetworkRuleError.self) { try NetworkRules.normalize("not a host") }
        #expect(throws: NetworkRuleError.self) { try NetworkRules.normalize("   ") }
        #expect(throws: NetworkRuleError.self) { try NetworkRules.normalize("-bad-.com") }
        #expect(NetworkRules.merge(["PyPI.org", "a.com"], ["pypi.org", "b.com", "x.*"]) == ["pypi.org", "a.com", "b.com"])
    }

    @Test func readsDNSLogAcrossChunksAndCNAMEs() {
        let log = """
        Oct  2 14:36:11 dnsmasq[482]: started, version 2.90 cachesize 150
        Oct  2 14:36:12 dnsmasq[482]: 1 127.0.0.1/52035 query[A] pypi.org from 127.0.0.1
        Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 query[A] www.python.org from 127.0.0.1
        Oct  2 14:36:12 dnsmasq[482]: 1 127.0.0.1/52035 forwarded pypi.org to 192.168.65.7
        Oct  2 14:36:12 dnsmasq[482]: 1 127.0.0.1/52035 reply pypi.org is 151.101.0.223
        Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 reply www.python.org is <CNAME>
        Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 reply dualstack.python.map.fastly.net is 151.101.192.223
        Oct  2 14:36:12 dnsmasq[482]: 3 127.0.0.1/44882 query[A] nope.invalid from 127.0.0.1
        Oct  2 14:36:12 dnsmasq[482]: 3 127.0.0.1/44882 reply nope.invalid is NXDOMAIN
        Oct  2 14:36:12 dnsmasq[482]: 4 127.0.0.1/60933 query[AAAA] PyPI.org from 127.0.0.1
        Oct  2 14:36:12 dnsmasq[482]: 4 127.0.0.1/60933 cached PyPI.org is 2a04:4e42::223
        Oct  2 16:50:25 dnsmasq[12]: 5 127.0.0.1/38087 query[A] example.com from 127.0.0.1
        Oct  2 16:50:25 dnsmasq[12]: 5 127.0.0.1/38087 config example.com is NXDOMAIN
        """ + "\n"
        var reader = DNSLogReader()
        // Split mid-line: the second half completes it.
        let cut = log.index(log.startIndex, offsetBy: 300)
        var lookups = reader.read(String(log[..<cut]))
        lookups += reader.read(String(log[cut...]))
        #expect(lookups == [
            .init(name: "pypi.org", addresses: ["151.101.0.223"]),
            .init(name: "www.python.org", addresses: ["151.101.192.223"]),
            .init(name: "pypi.org", addresses: ["2a04:4e42::223"]),
            .init(name: "example.com", addresses: [], refused: true),
        ])
    }

    @Test func blockedHostsNeedTheUserOnceTheTurnEnds() {
        var task = makeTask("t", activity: .idle(lastMessage: "Done"))
        #expect(task.status == .ready)
        task.blockedHosts = [BlockedHost(name: "pypi.org"), BlockedHost(name: "files.pythonhosted.org")]
        #expect(task.status == .needsInput)
        #expect(task.statusDetail == "Blocked pypi.org and 1 other")
        task.activity = .working(tool: "Bash pip install")
        #expect(task.status == .working)
    }

    @Test func projectsWithoutHostsStillDecode() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"p","repoPath":"/r","createdAt":"2026-10-01T10:00:00Z"}]"#
        let projects = try TaskStore.decoder.decode([Project].self, from: Data(json.utf8))
        #expect(projects.first?.allowedHosts == [])
    }
}

@Suite struct StackDetectorTests {
    func repo(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "airlock-stack-\(UUID().uuidString.prefix(8))")
        for (name, text) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func nodeAndPython() throws {
        let dir = try repo(["package.json": #"{"engines":{"node":"18.x"}}"#, "pnpm-lock.yaml": "", "pyproject.toml": "requires-python = \"~=3.11\"\n", "uv.lock": ""])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = StackDetector.detect(at: dir)
        #expect(stack.ecosystems == [.node, .python])
        #expect(stack.tools == ["node": "18", "pnpm": "latest", "python": "3.11", "uv": "latest"])
        #expect(stack.dependencyFolders == ["node_modules", ".venv"])
        #expect(stack.hosts.contains("pypi.org") && stack.hosts.contains("registry.npmjs.org"))
        #expect(stack.summary == "Node 18 · Python 3.11")
        #expect(!stack.heavy)
    }

    @Test func plainNodeNeedsNoTools() throws {
        let dir = try repo(["package.json": "{}"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = StackDetector.detect(at: dir)
        #expect(stack.tools.isEmpty && stack.packages.isEmpty && stack.ecosystems == [.node])
    }

    @Test func pinnedVersionsWin() throws {
        let dir = try repo([".tool-versions": "nodejs 20.11.0\ngolang 1.22.1\nterraform 1.9.0\n", "go.mod": "module x\n\ngo 1.21\n",
                            ".python-version": "3.12.4\n", "requirements.txt": "flask\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = StackDetector.detect(at: dir)
        #expect(stack.tools["go"] == "1.22.1")
        #expect(stack.tools["python"] == "3.12.4")
        #expect(stack.tools["terraform"] == "1.9.0")
        #expect(stack.tools["node"] == "20.11.0")
    }

    @Test func heavyStacksAndNotices() throws {
        let rust = try repo(["Cargo.toml": "[package]\n", "rust-toolchain.toml": "[toolchain]\nchannel = \"1.80\"\n"])
        let java = try repo(["pom.xml": "<project><properties><maven.compiler.release>17</maven.compiler.release></properties><dependency>testcontainers</dependency></project>"])
        let ios = try repo(["App.xcodeproj/project.pbxproj": ""])
        let php = try repo(["composer.json": "{}"])
        defer { [rust, java, ios, php].forEach { try? FileManager.default.removeItem(at: $0) } }
        let r = StackDetector.detect(at: rust)
        #expect(r.tools["rust"] == "1.80" && r.heavy)
        let j = StackDetector.detect(at: java)
        #expect(j.tools["java"] == "17" && j.tools["maven"] == "latest" && j.heavy)
        #expect(j.notices.contains { $0.contains("Testcontainers") })
        #expect(StackDetector.detect(at: ios).notices.first?.contains("Apple-platform") == true)
        let p = StackDetector.detect(at: php)
        #expect(p.packages.contains("php-cli") && p.tools.isEmpty)
    }

    @Test func nodeLowerBoundsKeepTheImagesNode() {
        #expect(StackDetector.enginesNode(#"{"engines":{"node":">=20"}}"#) == nil)
        #expect(StackDetector.enginesNode(#"{"engines":{"node":"^20.11"}}"#) == "20")
        #expect(StackDetector.enginesNode(#"{"engines":{"node":"20.x"}}"#) == "20")
    }

    @Test func goToolchainLine() {
        #expect(StackDetector.goVersion("module x\ngo 1.22\ntoolchain go1.22.5\n") == "1.22.5")
        #expect(StackDetector.requiresPython("requires-python = \">=3.10\"") == nil)
        #expect(StackDetector.miseTools("[env]\nA = \"1\"\n[tools]\npython = \"3.12\"\nnode = { version = \"22\" }\n") == ["python": "3.12", "node": "22"])
    }
}

/// What detection makes of each sample in TestProjects/Docker (the AIrlock checkout's own
/// test projects). Settings files (`.airlock/compose.yaml`) need Docker and are covered by
/// `airlock-cli detect` and the engine tests.
@Suite struct TestProjectDetectionTests {
    static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "TestProjects/Docker")

    func stack(_ name: String) throws -> ProjectStack {
        let dir = Self.samples.appending(path: name)
        try #require(FileManager.default.fileExists(atPath: dir.path), "missing sample \(name)")
        return StackDetector.detect(at: dir)
    }

    @Test func eachSampleIsDetected() throws {
        let expected: [(String, String?, [String: String])] = [
            // ">=20" is met by the image's Node 22: nothing to install.
            ("sample-app-multiple-containers", "Node", [:]),
            ("sample-python-notes", "Python 3.12", ["python": "3.12"]),
            ("sample-go-notes", "Go 1.22.5", ["go": "1.22.5"]),
            ("sample-rust-notes", "Rust 1.90", ["rust": "1.90"]),
            ("sample-java-notes", "Java 21", ["java": "21", "maven": "latest"]),
            ("sample-ruby-notes", "Ruby 3.3.6", ["ruby": "3.3.6"]),
            ("sample-php-notes", "PHP", [:]),
            ("sample-node-pnpm", "Node 20", ["node": "20", "pnpm": "9"]),
            ("sample-monorepo", "Node · Python 3.11 · Go 1.23", ["python": "3.11", "go": "1.23"]),
            ("sample-airlock-config", "Python", ["python": "latest"]),
            ("sample-ios-notes", "Swift", [:]),
        ]
        for (name, summary, tools) in expected {
            let detected = try stack(name)
            #expect(detected.summary == summary, "\(name): \(detected.summary ?? "nil")")
            #expect(detected.tools == tools, "\(name): \(detected.tools)")
        }
    }

    @Test func heavyStacksAndNotices() throws {
        #expect(try stack("sample-rust-notes").heavy && stack("sample-java-notes").heavy)
        #expect(try !stack("sample-python-notes").heavy)
        #expect(try stack("sample-ios-notes").notices.first?.contains("Apple-platform") == true)
        #expect(try stack("sample-php-notes").packages.contains("composer"))
        #expect(try stack("sample-ruby-notes").packages.contains("build-essential"))
    }

    @Test func monorepoFindsItsParts() throws {
        let mono = try stack("sample-monorepo")
        #expect(mono.ecosystems == [.node, .python, .go])
        #expect(mono.dependencyFolders == ["node_modules", "services/api/.venv"])
        #expect(mono.hosts.contains("pypi.org") && mono.hosts.contains("proxy.golang.org"))
    }
}

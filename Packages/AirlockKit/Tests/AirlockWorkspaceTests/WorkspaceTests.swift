import AirlockCore
import Foundation
import Testing
@testable import AirlockWorkspace
import CryptoKit

@Suite struct WorkspaceTests {
    @Test func branchNames() {
        var task = AgentTask(title: "Fix login: redirect loop!", prompt: "", repo: RepoRef(path: "/r", baseRef: "main"), workspace: .init(mode: .worktree, branch: ""))
        #expect(Workspaces.branchName(for: task, existing: []) == "airlock/fix-login-redirect-loop")
        #expect(Workspaces.branchName(for: task, existing: ["airlock/fix-login-redirect-loop"]) == "airlock/fix-login-redirect-loop-\(task.shortID)")
        task.title = "???"
        #expect(Workspaces.branchName(for: task, existing: []) == "airlock/\(task.shortID)")
    }

    @Test func worktreeLifecycleAndChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-ws-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = HostGit(repo)
        try await git.run("init", "-q", "-b", "main")
        try await git.run("config", "user.email", "t@example.invalid")
        try await git.run("config", "user.name", "T")
        try "a\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git.run("add", ".")
        try await git.run("commit", "-qm", "init")

        var task = AgentTask(title: "Add feature", prompt: "", repo: RepoRef(path: repo.path, baseRef: "main"), workspace: .init(mode: .worktree, branch: ""))
        let provisioner = WorktreeProvisioner.onHost(Paths(root: root.appending(path: "support")))
        let mounts = try await provisioner.prepare(&task)
        #expect(task.workspace.branch == "airlock/add-feature")
        #expect(task.workspace.baseCommit?.count == 40)
        let worktree = try #require(task.workspace.hostPath)
        #expect(mounts.first == .bind(hostPath: worktree, containerPath: "/workspace"))
        #expect(mounts.contains { if case .bind(_, let p, true) = $0 { p.hasSuffix(".git/hooks") } else { false } })

        // Preparing again (task restart) reuses the worktree.
        _ = try await provisioner.prepare(&task)

        let wt = HostGit(URL(fileURLWithPath: worktree))
        try "a\nb\n".write(to: URL(fileURLWithPath: worktree).appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: URL(fileURLWithPath: worktree).appending(path: "n.txt"), atomically: true, encoding: .utf8)
        try await wt.run("commit", "-qam", "change a")

        let changes = try await provisioner.changes(task)
        #expect(changes.files.map(\.path) == ["a.txt", "n.txt"])
        #expect(changes.files[0].kind == .modified && changes.files[0].additions == 1)
        #expect(changes.files[1].kind == .untracked)
        #expect(changes.commits.count == 1)
        #expect(changes.diff.contains("+b"))
        #expect(changes.diff.contains("+new"))

        // The engine brings the branch back while the container runs, then cleans up.
        try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
        try await provisioner.cleanup(task)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(try await git.run("rev-parse", "--verify", "airlock/add-feature").count == 40)
    }
}

extension WorktreeProvisioner {
    /// Git runs on the checkout directly, standing in for the container.
    static func onHost(_ paths: Paths) -> WorktreeProvisioner {
        WorktreeProvisioner(paths: paths) { HostGit(URL(fileURLWithPath: $0.workspace.hostPath ?? "/nonexistent")) }
    }
}

@Suite struct PlainFolderTests {
    struct Fixture {
        let root: URL
        let folder: URL
        let registry: ManagedFolders
        var git: HostGit { HostGit(folder) }
        var gitDir: String { folder.appending(path: ".git").path }

        init() throws {
            root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-plain-\(UUID())")
            folder = root.appending(path: "sample")
            registry = ManagedFolders(file: root.appending(path: "support/managed-folders.json"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("a.txt", "one\ntwo\n")
        }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String, in dir: URL? = nil) throws -> String {
            try String(contentsOf: (dir ?? folder).appending(path: name), encoding: .utf8)
        }

        /// A worktree task on the folder, with `edit` committed on its branch.
        func task(_ title: String, edit: (URL) throws -> Void) async throws -> (AgentTask, WorktreeProvisioner) {
            var task = AgentTask(title: title, prompt: "", repo: RepoRef(path: folder.path, baseRef: PlainFolder.branch, plainFolder: true),
                                 workspace: .init(mode: .worktree, branch: ""))
            let provisioner = WorktreeProvisioner.onHost(Paths(root: root.appending(path: "support")))
            _ = try await provisioner.prepare(&task)
            let worktree = URL(fileURLWithPath: try #require(task.workspace.hostPath))
            try edit(worktree)
            let wt = HostGit(worktree)
            try await wt.run("add", "-A")
            try await wt.run(PlainFolder.commitConfig + ["commit", "-qm", title])
            // What the engine does when the agent finishes a turn.
            try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
            return (task, provisioner)
        }
    }

    @Test func adoptsAppliesAndReleases() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(PlainFolder.isPlain(f.folder.path))

        #expect(try await PlainFolder.snapshot(f.folder.path, registry: f.registry))
        #expect(!PlainFolder.isPlain(f.folder.path))
        #expect(PlainFolder.isManaged(f.folder.path, registry: f.registry))
        #expect(try await f.git.run("symbolic-ref", "--short", "HEAD") == PlainFolder.branch)
        #expect(try await f.git.run("log", "--format=%an").split(separator: "\n") == ["AIrlock"])
        #expect(try await f.git.run("ls-files") == "a.txt")
        // Unchanged folder: no new commit.
        #expect(try await !PlainFolder.snapshot(f.folder.path, registry: f.registry))

        let (task, provisioner) = try await f.task("Add b") { wt in
            try "one\nTWO\n".write(to: wt.appending(path: "a.txt"), atomically: true, encoding: .utf8)
            try "bee\n".write(to: wt.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        }
        // The user edits a different file meanwhile; both survive the apply.
        try f.write("c.txt", "mine\n")
        try await PlainFolder.apply(f.folder.path, branch: task.workspace.branch, title: task.title, registry: f.registry)
        #expect(try f.read("a.txt") == "one\nTWO\n")
        #expect(try f.read("b.txt") == "bee\n")
        #expect(try f.read("c.txt") == "mine\n")
        #expect(try await f.git.run("status", "--porcelain").isEmpty)

        try await provisioner.cleanup(task)
        #expect(await PlainFolder.release(f.folder.path, registry: f.registry) == .removed)
        #expect(!FileManager.default.fileExists(atPath: f.gitDir))
        #expect(PlainFolder.isPlain(f.folder.path))
        #expect(f.registry.entry(for: f.folder.path) == nil)
        #expect(try f.read("b.txt") == "bee\n")
    }

    @Test func conflictLeavesFolderUntouched() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await PlainFolder.snapshot(f.folder.path, registry: f.registry)
        let (task, _) = try await f.task("Theirs") { wt in
            try "one\nagent\n".write(to: wt.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        }
        try f.write("a.txt", "one\nuser\n")
        await #expect(throws: PlainFolderError.self) {
            try await PlainFolder.apply(f.folder.path, branch: task.workspace.branch, title: task.title, registry: f.registry)
        }
        #expect(try f.read("a.txt") == "one\nuser\n")
        #expect(!FileManager.default.fileExists(atPath: f.gitDir + "/MERGE_HEAD"))
    }

    @Test func neverTouchesARepositoryItDidNotCreate() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.git.run("init", "-q")
        #expect(!PlainFolder.isPlain(f.folder.path))
        #expect(!PlainFolder.isManaged(f.folder.path, registry: f.registry))
        await #expect(throws: PlainFolderError.self) { try await PlainFolder.snapshot(f.folder.path, registry: f.registry) }
        #expect(await PlainFolder.release(f.folder.path, registry: f.registry) == .notManaged)
        #expect(FileManager.default.fileExists(atPath: f.gitDir))

        // A registry entry alone isn't enough: the marker and inode must match too.
        let inode = try #require(PlainFolder.inode(f.gitDir))
        try f.registry.add(.init(path: f.folder.path, token: "forged", inode: inode, createdAt: .now))
        #expect(!PlainFolder.isManaged(f.folder.path, registry: f.registry))
        guard case .kept = await PlainFolder.release(f.folder.path, registry: f.registry) else {
            Issue.record("expected the .git to be kept")
            return
        }
        #expect(FileManager.default.fileExists(atPath: f.gitDir))
        #expect(f.registry.entry(for: f.folder.path) == nil)

        // Subfolders of a repository are part of it, never adopted.
        let sub = f.folder.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(!PlainFolder.isPlain(sub.path))
        await #expect(throws: PlainFolderError.self) { try await PlainFolder.adopt(sub.path, registry: f.registry) }
    }

    @Test func keepsGitTheUserStartedUsing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await PlainFolder.snapshot(f.folder.path, registry: f.registry)
        try await f.git.run("branch", "my-work")
        guard case .kept(let reason) = await PlainFolder.release(f.folder.path, registry: f.registry) else {
            Issue.record("expected the .git to be kept")
            return
        }
        #expect(reason.contains("refs/heads/my-work"))
        #expect(FileManager.default.fileExists(atPath: f.gitDir))
        // Handed over: AIrlock treats it as an ordinary repository from now on.
        #expect(!PlainFolder.isManaged(f.folder.path, registry: f.registry))

        // A .git swapped for another one is never deleted either.
        let g = try Fixture()
        defer { try? FileManager.default.removeItem(at: g.root) }
        try await PlainFolder.snapshot(g.folder.path, registry: g.registry)
        let marker = try String(contentsOfFile: g.gitDir + "/airlock-managed", encoding: .utf8)
        try FileManager.default.removeItem(atPath: g.gitDir)
        try await g.git.run("init", "-q")
        try marker.write(toFile: g.gitDir + "/airlock-managed", atomically: true, encoding: .utf8)
        #expect(!PlainFolder.isManaged(g.folder.path, registry: g.registry))
        guard case .kept = await PlainFolder.release(g.folder.path, registry: g.registry) else {
            Issue.record("expected the .git to be kept")
            return
        }
        #expect(FileManager.default.fileExists(atPath: g.gitDir))
    }

    @Test func refusesTooBroadFolders() {
        #expect(throws: PlainFolderError.self) { try PlainFolder.checkAllowed("/") }
        #expect(throws: PlainFolderError.self) { try PlainFolder.checkAllowed(FileManager.default.homeDirectoryForCurrentUser.path) }
        #expect(throws: PlainFolderError.self) { try PlainFolder.checkAllowed("/nonexistent-\(UUID())") }
    }
}

@Suite struct TaskRepositoryTests {
    func makeRepo(_ root: URL) async throws -> URL {
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = HostGit(repo)
        try await git.run("init", "-q", "-b", "main")
        try "a\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git.run(PlainFolder.commitConfig + ["add", "."])
        try await git.run(PlainFolder.commitConfig + ["commit", "-qm", "init"])
        return repo
    }

    @Test func agentCannotMoveTheUsersBranches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-own-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await makeRepo(root)
        let mainBefore = try await HostGit(repo).run("rev-parse", "main")

        var task = AgentTask(title: "Own repo", prompt: "", repo: RepoRef(path: repo.path, baseRef: "main"), workspace: .init(mode: .worktree, branch: ""))
        let provisioner = WorktreeProvisioner.onHost(Paths(root: root.appending(path: "support")))
        let mounts = try await provisioner.prepare(&task)
        #expect(task.workspace.ownRepository == true)
        let checkout = URL(fileURLWithPath: try #require(task.workspace.hostPath))
        // The borrowed objects are mounted read-only; config and hooks too.
        #expect(mounts.contains { if case .bind(_, let p, true) = $0 { p == "/workspace/.git/config" } else { false } })
        #expect(mounts.contains { if case .bind(_, let p, true) = $0 { p.hasSuffix("/objects") } else { false } })

        // What a hostile agent would do: move `main` and commit on its branch.
        let wt = HostGit(checkout)
        try "b\n".write(to: checkout.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await wt.run(PlainFolder.commitConfig + ["commit", "-qam", "agent"])
        try await wt.run("update-ref", "refs/heads/main", "HEAD")
        #expect(try await HostGit(repo).run("rev-parse", "main") == mainBefore)

        try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
        #expect(try await HostGit(repo).run("log", "-1", "--format=%s", "airlock/own-repo") == "agent")
        #expect(try await HostGit(repo).run("rev-parse", "main") == mainBefore)
        try await provisioner.cleanup(task)
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
    }

    @Test func submodulesComeFromLocalCheckouts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "airlock-sub-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try await makeRepo(root.appending(path: "lib"))
        let repo = try await makeRepo(root)
        let git = HostGit(repo)
        try await git.run(PlainFolder.commitConfig + ["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.path, "vendor/lib"])
        try await git.run(PlainFolder.commitConfig + ["commit", "-qm", "submodule"])
        let base = try await git.run("rev-parse", "HEAD")
        let checkout = root.appending(path: "task")
        let notes = try await TaskRepository.create(from: repo, at: checkout, branch: "airlock/x", base: base, remoteURL: nil)
        #expect(notes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "vendor/lib/a.txt").path))
    }
}

@Suite struct PlainFolderExcludeTests {
    @Test func snapshotsLeaveOutDependenciesAndHugeFiles() async throws {
        let root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-excl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "f")
        try FileManager.default.createDirectory(at: folder.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        try "keep\n".write(to: folder.appending(path: "app.js"), atomically: true, encoding: .utf8)
        try "dep\n".write(to: folder.appending(path: "node_modules/x/index.js"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: folder.appending(path: "video.mov").path, contents: nil)
        let handle = try FileHandle(forWritingTo: folder.appending(path: "video.mov"))
        try handle.truncate(atOffset: UInt64(PlainFolder.largeFileBytes + 1))
        try handle.close()
        let registry = ManagedFolders(file: root.appending(path: "m.json"))
        try await PlainFolder.snapshot(folder.path, registry: registry)
        let tracked = try await HostGit(folder).run("ls-files")
        #expect(tracked == "app.js")
    }
}

/// What a hostile agent can do to its checkout, and what AIrlock does with it on the Mac.
@Suite struct HostileCheckoutTests {
    func prepared(_ root: URL) async throws -> (AgentTask, WorktreeProvisioner, URL, URL) {
        let repo = try await TaskRepositoryTests().makeRepo(root)
        var task = AgentTask(title: "Hostile", prompt: "", repo: RepoRef(path: repo.path, baseRef: "main"), workspace: .init(mode: .worktree, branch: ""))
        let provisioner = WorktreeProvisioner.onHost(Paths(root: root.appending(path: "support")))
        _ = try await provisioner.prepare(&task)
        return (task, provisioner, repo, URL(fileURLWithPath: try #require(task.workspace.hostPath)))
    }

    @Test func lfsCopiesOnlyVerifiedObjects() async throws {
        let root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-lfs-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, repo, checkout) = try await prepared(root)
        let objects = checkout.appending(path: ".git/lfs/objects")
        let good = Data("large file".utf8)
        let oid = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        let dir = objects.appending(path: "\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try good.write(to: dir.appending(path: oid))
        // Named like an object, but not its content; and a link to a file on the Mac.
        let fake = String(oid.prefix(4)) + String(repeating: "0", count: 60)
        try Data("not it".utf8).write(to: dir.appending(path: fake))
        let secret = root.appending(path: "secret")
        try Data("secret".utf8).write(to: secret)
        let linked = String(oid.prefix(4)) + String(repeating: "1", count: 60)
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: linked).path, withDestinationPath: secret.path)

        await TaskRepository.copyLFSObjects(from: checkout, into: repo)
        let store = repo.appending(path: ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))")
        #expect(try Data(contentsOf: store.appending(path: oid)) == good)
        #expect(!FileManager.default.fileExists(atPath: store.appending(path: fake).path))
        #expect(!FileManager.default.fileExists(atPath: store.appending(path: linked).path))

        // The whole store as a link to a folder on the Mac: nothing is copied from it.
        try FileManager.default.removeItem(at: objects)
        try FileManager.default.createSymbolicLink(atPath: objects.path, withDestinationPath: root.path)
        await TaskRepository.copyLFSObjects(from: checkout, into: repo)
    }

    @Test func alternatesOnlyMountTheUsersObjects() async throws {
        let root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-alt-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let (task, provisioner, repo, checkout) = try await prepared(root)
        let stores = await TaskRepository.objectStores(of: repo)
        #expect(stores == [Workspaces.realPath(repo.appending(path: ".git/objects").path)])
        // The agent lists the user's home folder as a store; it isn't mounted.
        let alternates = checkout.appending(path: ".git/objects/info/alternates")
        try (String(contentsOf: alternates, encoding: .utf8) + NSHomeDirectory() + "\n").write(to: alternates, atomically: true, encoding: .utf8)
        var again = task
        let mounts = try await provisioner.prepare(&again)
        let hosts = mounts.compactMap { if case .bind(let host, _, _) = $0 { host } else { nil } }
        #expect(!hosts.contains(NSHomeDirectory()))
        #expect(hosts.contains(stores[0]))
    }

    @Test func detectsChangedGitSettings() async throws {
        let root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-tamper-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let (task, _, _, checkout) = try await prepared(root)
        let trusted = Paths(root: root.appending(path: "support")).taskDir(task.id).appending(path: "git-config/config")
        #expect(TaskRepository.tamperedReason(checkout: checkout, trustedConfig: trusted) == nil)

        let git = checkout.appending(path: ".git")
        try "evil".write(to: git.appending(path: "commondir"), atomically: true, encoding: .utf8)
        #expect(TaskRepository.tamperedReason(checkout: checkout, trustedConfig: trusted)?.contains("commondir") == true)
        try FileManager.default.removeItem(at: git.appending(path: "commondir"))

        let config = git.appending(path: "config")
        try (String(contentsOf: config, encoding: .utf8) + "[core]\n\tfsmonitor = touch /tmp/pwned\n").write(to: config, atomically: true, encoding: .utf8)
        #expect(TaskRepository.tamperedReason(checkout: checkout, trustedConfig: trusted)?.contains("config") == true)
        // The copy the container sees stays AIrlock's.
        #expect(try !String(contentsOf: trusted, encoding: .utf8).contains("fsmonitor"))
    }

    @Test func bringBackUsesABundleNotTheCheckout() async throws {
        let root = URL(fileURLWithPath: Workspaces.realPath(FileManager.default.temporaryDirectory.path)).appending(path: "airlock-bundle-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let (task, provisioner, repo, checkout) = try await prepared(root)
        // A branch with no commits yet starts at the base.
        try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
        #expect(try await HostGit(repo).run("rev-parse", "airlock/hostile") == task.workspace.baseCommit)
        try "b\n".write(to: checkout.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try await HostGit(checkout).run("add", ".")
        try await HostGit(checkout).run(PlainFolder.commitConfig + ["commit", "-qm", "agent work"])
        try await provisioner.bringBack(task, into: URL(fileURLWithPath: task.repo.path))
        #expect(try await HostGit(repo).run("log", "-1", "--format=%s", "airlock/hostile") == "agent work")
        let changes = try await GitInspector.committedChanges(in: HostGit(repo), branch: "airlock/hostile", since: task.workspace.baseCommit!)
        #expect(changes.files.map(\.path) == ["b.txt"] && changes.commits.count == 1)
    }
}

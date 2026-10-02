import AirlockCore
import AirlockRuntime
import CryptoKit
import Foundation

/// A task's own git repository, made on the Mac from the user's: `git clone --shared`, so
/// objects are borrowed (read-only) while refs, index, config and hooks are the task's. The
/// task branch reaches the user's repository by fetching it back.
public enum TaskRepository {
    /// `git` options that keep checkouts from running the user's LFS filter, which may not be
    /// on a GUI app's PATH; LFS files are fetched explicitly afterwards.
    static let noLFS = ["-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false"]

    /// Clones `source` into `dir` with the task branch checked out at `base`, then brings in
    /// submodules and LFS files. Problems with those are returned as notes, not thrown.
    @discardableResult
    public static func create(from source: URL, at dir: URL, branch: String, base: String, remoteURL: String?) async throws -> [String] {
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(source.deletingLastPathComponent(), ["clone", "--shared", "--no-checkout", "--quiet", source.path, dir.path])
        try await git(dir, noLFS + ["checkout", "--quiet", "-b", branch, base])
        if let remoteURL, !remoteURL.isEmpty {
            try await git(dir, ["remote", "set-url", "origin", remoteURL])
        } else {
            try? await git(dir, ["remote", "remove", "origin"])
        }
        var notes: [String] = []
        if let note = await submodules(in: dir, source: source) { notes.append(note) }
        if let note = await lfs(in: dir, source: source) { notes.append(note) }
        return notes
    }

    /// Submodules from the user's own checkouts when they have them (no network), else from
    /// their configured URLs.
    static func submodules(in dir: URL, source: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: dir.appending(path: ".gitmodules").path) else { return nil }
        let paths = (try? await output(dir, ["config", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#])) ?? ""
        for line in paths.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].dropFirst("submodule.".count).dropLast(".path".count)
            let local = source.appending(path: String(parts[1]))
            if FileManager.default.fileExists(atPath: local.appending(path: ".git").path) {
                try? await git(dir, ["config", "submodule.\(name).url", local.path])
            }
        }
        do {
            try await git(dir, noLFS + ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive", "--quiet"])
            return nil
        } catch {
            return "Some submodules couldn't be checked out: \(error)"
        }
    }

    /// LFS files from the user's local LFS store first, then the network.
    static func lfs(in dir: URL, source: URL) async -> String? {
        guard let attributes = try? String(contentsOf: dir.appending(path: ".gitattributes"), encoding: .utf8),
              attributes.contains("filter=lfs") else { return nil }
        guard let gitLFS = lfsBinary() else {
            return "This repository uses Git LFS, but git-lfs isn't installed on this Mac, so large files are pointers."
        }
        let env = ["PATH": "\(URL(fileURLWithPath: gitLFS).deletingLastPathComponent().path):/usr/bin:/bin"]
        let common = (try? await output(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"])) ?? source.appending(path: ".git").path
        _ = try? await ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "-c", "lfs.storage=\(common)/lfs", "lfs", "checkout"], environment: env, check: false)
        let pull = try? await ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "lfs", "pull"], environment: env, check: false)
        return pull?.status == 0 ? nil : "Some Git LFS files couldn't be downloaded; they're pointers in the task."
    }

    static func lfsBinary() -> String? {
        ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs", "/usr/bin/git-lfs"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Copies the task branch into the user's repository. `sandbox` runs git where the task's
    /// repository is safe to use: inside its container. The agent controls that repository's
    /// config, hooks and layout, so git on the Mac only ever reads the bundle it produces.
    public static func bringBack(branch: String, base: String, from sandbox: some GitRunner, into repo: URL) async throws {
        let tip = try await sandbox.run("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}")
        guard tip.count == 40, tip.allSatisfy(\.isHexDigit) else { throw GitError(args: ["rev-parse", branch], message: "not a commit: \(tip.prefix(80))") }
        let host = HostGit(repo)
        if tip == base {
            // No commits yet: nothing to bundle, so the branch simply starts at the base.
            try await host.run("branch", "--force", "--no-track", branch, base)
            return
        }
        let (status, bundle) = try await sandbox.git(["bundle", "create", "--quiet", "-", "refs/heads/\(branch)", "^\(base)"])
        guard status == 0 else { throw GitError(args: ["bundle", "create"], message: String(decoding: bundle.prefix(400), as: UTF8.self)) }
        let file = FileManager.default.temporaryDirectory.appending(path: "airlock-\(UUID().uuidString.prefix(8)).bundle")
        try bundle.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await host.run("fetch", "--quiet", "--force", "--no-tags", file.path, "refs/heads/\(branch):refs/heads/\(branch)")
    }

    /// Copies LFS objects the task added from its checkout into the user's LFS store. The
    /// checkout is the agent's: only regular files named like LFS objects are read, no symlink
    /// is followed, and a file is kept only when its SHA-256 matches its name.
    public static func copyLFSObjects(from checkout: URL, into repo: URL) async {
        let fm = FileManager.default
        let objects = ".git/lfs/objects"
        guard isRealDirectory(checkout.appending(path: objects)),
              let common = try? await output(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return }
        let target = URL(fileURLWithPath: common).appending(path: "lfs/objects")
        func names(_ relative: String, _ pattern: String) -> [String] {
            let dir = checkout.appending(path: relative)
            guard isRealDirectory(dir) else { return [] }
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.range(of: pattern, options: .regularExpression) != nil }.prefix(10_000).map { $0 }
        }
        for a in names(objects, "^[0-9a-f]{2}$") {
            for b in names("\(objects)/\(a)", "^[0-9a-f]{2}$") {
                for oid in names("\(objects)/\(a)/\(b)", "^\(a)\(b)[0-9a-f]{60}$") {
                    let destination = target.appending(path: "\(a)/\(b)/\(oid)")
                    guard !fm.fileExists(atPath: destination.path),
                          let source = SafeFile.open("\(objects)/\(a)/\(b)/\(oid)", in: checkout) else { continue }
                    try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    copyVerified(source, sha256: oid, to: destination)
                }
            }
        }
    }

    /// Streams `source` to `destination`, keeping it only when its SHA-256 is `sha256`.
    static func copyVerified(_ source: SafeFile.Opened, sha256 expected: String, to destination: URL) {
        let temp = destination.deletingLastPathComponent().appending(path: ".airlock-\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: temp) else { return }
        var hasher = SHA256()
        var ok = true
        while ok, let chunk = try? source.handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            ok = (try? out.write(contentsOf: chunk)) != nil
        }
        try? out.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if ok, digest == expected, (try? FileManager.default.moveItem(at: temp, to: destination)) != nil { return }
        try? FileManager.default.removeItem(at: temp)
    }

    /// Why the checkout's git settings can't be trusted on the Mac, or nil when they're as
    /// AIrlock made them: `.git` a real folder, its config identical to `trustedConfig` (so no
    /// fsmonitor, includes or drivers), no `commondir` redirect and no hooks. Tools the user
    /// opens there (a shell prompt, an editor) run git with these settings.
    public static func tamperedReason(checkout: URL, trustedConfig: URL) -> String? {
        let git = checkout.appending(path: ".git")
        guard isRealDirectory(git) else { return "its .git isn't a plain folder any more" }
        guard let expected = try? Data(contentsOf: trustedConfig),
              let actual = SafeFile.read(".git/config", in: checkout, limit: 1 << 20), actual == expected else {
            return "its git config was changed"
        }
        for name in ["commondir", "config.worktree", "gitdir"] {
            var info = stat()
            if lstat(git.appending(path: name).path, &info) == 0 { return "it has a .git/\(name) file AIrlock didn't make" }
        }
        let hooks = (try? FileManager.default.contentsOfDirectory(atPath: git.appending(path: "hooks").path)) ?? []
        if hooks.contains(where: { !$0.hasSuffix(".sample") }) { return "it has git hooks AIrlock didn't make" }
        return nil
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// The object stores a task's `--shared` clone may borrow from, as real paths: the user's
    /// repository's, plus any its own `alternates` name. Read from the user's repository,
    /// never from the task's (the agent could list any folder there).
    public static func objectStores(of repo: URL) async -> [String] {
        guard let common = try? await output(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return [] }
        var found: [String] = []
        var queue = [common + "/objects"]
        while let next = queue.first, found.count < 16 {
            queue.removeFirst()
            let real = Workspaces.realPath(next)
            guard !found.contains(real) else { continue }
            found.append(real)
            queue += alternatesList(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: real).appending(path: "info/alternates"))) ?? Data(), as: UTF8.self))
        }
        return found
    }

    /// Absolute paths from an `alternates` file.
    static func alternatesList(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }

    /// Mounts for the object stores the checkout borrows: each path its `alternates` lists
    /// that resolves to one of `stores`, read-only, at that same path. Other entries are ignored.
    public static func borrowedObjectMounts(checkout: URL, stores: [String]) -> [MountSpec] {
        let listed = SafeFile.read(".git/objects/info/alternates", in: checkout, limit: 64 * 1024)
            .map { alternatesList(String(decoding: $0, as: UTF8.self)) } ?? []
        var mounts: [MountSpec] = []
        var seen: Set<String> = []
        // The user's own alternates chain is listed by path in trusted files; the checkout's entries are checked.
        for path in listed + stores where !seen.contains(path) {
            let real = Workspaces.realPath(path)
            guard stores.contains(real) else { continue }
            seen.insert(path)
            mounts.append(.bind(hostPath: real, containerPath: path, readOnly: true))
        }
        return mounts
    }

    static func git(_ dir: URL, _ args: [String]) async throws {
        _ = try await output(dir, args)
    }

    @discardableResult
    static func output(_ dir: URL, _ args: [String]) async throws -> String {
        try await HostGit(dir).run(args)
    }
}

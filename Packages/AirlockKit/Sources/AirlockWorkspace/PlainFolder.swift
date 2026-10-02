import AirlockCore
import Foundation

/// A folder that isn't a git repository. AIrlock gives it a temporary repository so tasks
/// can branch, diff and merge as usual, applies their results to the folder's files, and
/// deletes that repository once the folder's last task is gone.
///
/// AIrlock only ever deletes a `.git` it created itself. Creating one records a random
/// token in `.git/airlock-managed` and in AIrlock's own registry, along with the directory's
/// inode. Deleting needs all three to match, and the repository must still look like only
/// AIrlock used it: no remotes, tags, stash or branches of its own, and no extra worktrees.
/// Anything else and the `.git` is left alone and handed over to the user.
public enum PlainFolder {
    /// The folder's branch: each snapshot of its files, and each applied task, is a commit here.
    public static let branch = "airlock-base"
    static let markerName = "airlock-managed"
    /// Commits AIrlock makes: its own identity, no signing, no hooks.
    public static let commitConfig = [
        "-c", "user.name=AIrlock", "-c", "user.email=airlock@localhost",
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
    ]

    /// True when neither the folder nor any parent has a `.git`, so git wouldn't see a repository.
    public static func isPlain(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if lexists(url.appending(path: ".git").path) { return false }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return true }
            url = parent
        }
    }

    /// True when the folder has a `.git` that AIrlock created and still manages.
    public static func isManaged(_ path: String, registry: ManagedFolders) -> Bool {
        guard let entry = registry.entry(for: path) else { return false }
        return verifyOwnership(path, entry: entry) == nil
    }

    /// Folders too broad to snapshot into a repository.
    public static func checkAllowed(_ path: String) throws {
        let resolved = Workspaces.realPath(path)
        let home = Workspaces.realPath(FileManager.default.homeDirectoryForCurrentUser.path)
        guard resolved != "/", resolved != home else {
            throw PlainFolderError("\(path) is too broad to work on. Choose a project folder.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PlainFolderError("No folder at \(path).")
        }
    }

    /// Commits the folder's current files to `airlock-base`, creating the repository first
    /// if the folder is still plain. Returns whether a commit was made.
    @discardableResult
    public static func snapshot(_ path: String, registry: ManagedFolders, message: String = "Snapshot of the folder") async throws -> Bool {
        let git = HostGit(URL(fileURLWithPath: path))
        if isPlain(path) {
            try await adopt(path, registry: registry)
        } else {
            guard let entry = registry.entry(for: path) else {
                throw PlainFolderError("\(path) already has a git repository that AIrlock didn't create.")
            }
            if let problem = verifyOwnership(path, entry: entry) { throw PlainFolderError(problem) }
            let head = try? await git.run("symbolic-ref", "--short", "HEAD")
            guard head == branch else {
                throw PlainFolderError("The folder's repository is on \(head ?? "a detached HEAD"), not \(branch). It was changed outside AIrlock.")
            }
        }
        excludeLargeFiles(path)
        try await git.run("add", "-A")
        let hasHead = (try? await git.run("rev-parse", "--verify", "HEAD")) != nil
        let (staged, _) = try await git.git(["diff", "--cached", "--quiet"])
        guard !hasHead || staged != 0 else { return false }
        try await git.run(commitConfig + ["commit", "--quiet", "--no-verify", "--allow-empty", "-m", message])
        return true
    }

    /// Merges a task branch into the folder's files. Edits made in the folder since the task
    /// started are committed first, so a conflict never loses them: the merge is aborted and
    /// the folder is left exactly as it was.
    public static func apply(_ path: String, branch taskBranch: String, title: String, registry: ManagedFolders) async throws {
        try await snapshot(path, registry: registry, message: "Folder changes before applying “\(title)”")
        let git = HostGit(URL(fileURLWithPath: path))
        let (status, output) = try await git.git(commitConfig + ["merge", "--no-edit", "-m", "Apply “\(title)”", taskBranch])
        guard status != 0 else { return }
        let conflicts = (try? await git.run("diff", "--name-only", "--diff-filter=U")) ?? ""
        _ = try? await git.run("merge", "--abort")
        if conflicts.isEmpty {
            throw PlainFolderError("Couldn't apply “\(title)” to the folder: \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let files = conflicts.split(separator: "\n").joined(separator: ", ")
        throw PlainFolderError("“\(title)” conflicts with edits in the folder (\(files)). Nothing was changed.")
    }

    public enum Release: Equatable, Sendable {
        /// AIrlock's `.git` was deleted; the folder is plain again.
        case removed
        /// The `.git` was kept, and is no longer AIrlock's to delete.
        case kept(reason: String)
        /// AIrlock never created a `.git` here.
        case notManaged
    }

    /// Deletes the folder's `.git` if every safeguard agrees AIrlock created it and nobody
    /// else has used it. Call only once no task works on the folder any more.
    public static func release(_ path: String, registry: ManagedFolders) async -> Release {
        guard let entry = registry.entry(for: path) else { return .notManaged }
        if let reason = await reasonToKeep(path, entry: entry) {
            // Hand it over: from now on this folder is an ordinary repository.
            try? registry.remove(path)
            return .kept(reason: reason)
        }
        do {
            try FileManager.default.removeItem(atPath: gitDir(path))
        } catch {
            return .kept(reason: "Couldn't delete it: \(error.localizedDescription)")
        }
        try? registry.remove(path)
        return .removed
    }

    // MARK: Internals

    static func gitDir(_ path: String) -> String { URL(fileURLWithPath: path).appending(path: ".git").path }

    static func adopt(_ path: String, registry: ManagedFolders) async throws {
        try checkAllowed(path)
        guard isPlain(path) else { throw PlainFolderError("\(path) is already inside a git repository.") }
        let git = HostGit(URL(fileURLWithPath: path))
        // No template: nothing (hooks included) is copied in from the user's git setup.
        try await git.run("init", "--quiet", "--template=", "--initial-branch=\(branch)")
        let dir = gitDir(path)
        guard let inode = inode(dir) else { throw PlainFolderError("git init didn't create \(dir).") }
        let token = UUID().uuidString
        // Registry first: if writing the marker fails, the `.git` simply never counts as ours.
        try registry.add(ManagedFolders.Entry(path: path, token: token, inode: inode, createdAt: .now))
        try Data(token.utf8).write(to: URL(fileURLWithPath: dir).appending(path: markerName), options: .atomic)
        // A folder has no .gitignore of its own: leave out what never belongs in a snapshot.
        let info = URL(fileURLWithPath: dir).appending(path: "info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try Data((defaultExcludes.joined(separator: "\n") + "\n").utf8).write(to: info.appending(path: "exclude"))
    }

    /// Dependency folders, build output and OS clutter.
    static let defaultExcludes = [
        "node_modules/", ".venv/", "venv/", "__pycache__/", ".pytest_cache/", ".mypy_cache/",
        "dist/", "build/", "target/", ".next/", ".nuxt/", ".gradle/", ".DS_Store", "*.log",
    ]

    /// Files this big stay out of snapshots (and so out of tasks): a folder of videos or
    /// datasets shouldn't be copied into git.
    static let largeFileBytes = 50 * 1024 * 1024

    static func excludeLargeFiles(_ path: String) {
        let root = URL(fileURLWithPath: path)
        let skipped = Set(defaultExcludes.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) } + [".git"])
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return }
        var large: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if (values?.fileSize ?? 0) > largeFileBytes {
                large.append("/" + String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        guard !large.isEmpty else { return }
        let file = URL(fileURLWithPath: gitDir(path)).appending(path: "info/exclude")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let fresh = large.filter { !existing.split(separator: "\n").contains(Substring($0)) }
        guard !fresh.isEmpty else { return }
        try? Data((existing + fresh.joined(separator: "\n") + "\n").utf8).write(to: file)
    }

    /// Why the `.git` isn't provably AIrlock's, or nil when it is.
    static func verifyOwnership(_ path: String, entry: ManagedFolders.Entry) -> String? {
        let dir = gitDir(path)
        var info = stat()
        guard lstat(dir, &info) == 0 else { return "The folder no longer has a .git." }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return ".git isn't a plain directory." }
        guard UInt64(info.st_ino) == entry.inode else { return ".git was replaced since AIrlock created it." }
        let marker = URL(fileURLWithPath: dir).appending(path: markerName)
        guard let token = try? String(contentsOf: marker, encoding: .utf8), token == entry.token else {
            return ".git doesn't carry AIrlock's marker."
        }
        return nil
    }

    static func reasonToKeep(_ path: String, entry: ManagedFolders.Entry) async -> String? {
        if let problem = verifyOwnership(path, entry: entry) { return problem }
        let git = HostGit(URL(fileURLWithPath: path))
        _ = try? await git.run("worktree", "prune")
        guard let worktrees = try? await git.run("worktree", "list", "--porcelain") else { return "Couldn't read the repository." }
        if worktrees.split(separator: "\n").filter({ $0.hasPrefix("worktree ") }).count > 1 {
            return "The repository still has other worktrees."
        }
        guard let remotes = try? await git.run("remote") else { return "Couldn't read the repository." }
        if !remotes.isEmpty { return "The repository has remotes (\(remotes.split(separator: "\n").joined(separator: ", ")))." }
        guard let refs = try? await git.run("for-each-ref", "--format=%(refname)") else { return "Couldn't read the repository." }
        let foreign = refs.split(separator: "\n").filter { $0 != "refs/heads/\(branch)" && !$0.hasPrefix("refs/heads/airlock/") }
        if !foreign.isEmpty { return "The repository has refs AIrlock didn't make (\(foreign.prefix(3).joined(separator: ", ")))." }
        guard (try? await git.run("symbolic-ref", "HEAD")) == "refs/heads/\(branch)" else {
            return "The repository isn't on \(branch) any more."
        }
        return nil
    }

    static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }
}

public struct PlainFolderError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Folders whose `.git` AIrlock created, persisted in one JSON file next to the tasks.
public struct ManagedFolders: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var path: String
        /// Also written to `.git/airlock-managed`.
        public var token: String
        /// Inode of the `.git` directory as created.
        public var inode: UInt64
        public var createdAt: Date
    }

    public let file: URL
    public init(file: URL) { self.file = file }

    public func entry(for path: String) -> Entry? {
        let key = Workspaces.realPath(path)
        return load().first { Workspaces.realPath($0.path) == key }
    }

    func add(_ entry: Entry) throws {
        var list = load().filter { Workspaces.realPath($0.path) != Workspaces.realPath(entry.path) }
        list.append(entry)
        try save(list)
    }

    func remove(_ path: String) throws {
        let key = Workspaces.realPath(path)
        try save(load().filter { Workspaces.realPath($0.path) != key })
    }

    func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    func save(_ list: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: file, options: .atomic)
    }
}

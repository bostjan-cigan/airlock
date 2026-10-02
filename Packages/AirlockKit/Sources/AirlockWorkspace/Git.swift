import AirlockCore
import AirlockRuntime
import Foundation

/// Runs git somewhere: on the host, or inside a task's container.
public protocol GitRunner: Sendable {
    func git(_ args: [String]) async throws -> (status: Int, output: Data)
}

extension GitRunner {
    /// Runs git and returns trimmed stdout, throwing on non-zero exit.
    @discardableResult
    public func run(_ args: String...) async throws -> String {
        try await run(args)
    }

    @discardableResult
    public func run(_ args: [String]) async throws -> String {
        let (status, output) = try await git(args)
        let text = String(decoding: output, as: UTF8.self)
        guard status == 0 else { throw GitError(args: args, message: text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GitError: Error, CustomStringConvertible {
    public var args: [String]
    public var message: String
    public var description: String { "git \(args.joined(separator: " ")): \(message.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

public struct HostGit: GitRunner {
    public let directory: URL
    public init(_ directory: URL) { self.directory = directory }

    public func git(_ args: [String]) async throws -> (status: Int, output: Data) {
        let r = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path] + args, check: false)
        return (Int(r.status), r.status == 0 ? r.stdout : r.stderr + r.stdout)
    }
}

public struct ContainerGit: GitRunner {
    public let runtime: any ContainerRuntime
    public let containerID: String
    public let directory: String
    public let user: String

    public init(runtime: any ContainerRuntime, containerID: String, directory: String, user: String) {
        self.runtime = runtime
        self.containerID = containerID
        self.directory = directory
        self.user = user
    }

    public func git(_ args: [String]) async throws -> (status: Int, output: Data) {
        // By full path: the agent can put its own `git` first on its PATH (mise shims).
        let r = try await runtime.exec(containerID, ExecSpec(["/usr/bin/git", "-C", directory] + args, user: user))
        return (r.exitCode, r.exitCode == 0 ? r.stdout : r.stderr + r.stdout)
    }
}

/// One changed file relative to the task's base commit.
public struct FileChange: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case added, modified, deleted, renamed, untracked }
    public var path: String
    public var kind: Kind
    public var additions: Int?
    public var deletions: Int?
    public var id: String { path }
}

public struct WorkspaceChanges: Sendable {
    public var files: [FileChange]
    /// Unified diff of tracked changes plus new untracked files.
    public var diff: String
    /// Commits on the task branch since the base commit.
    public var commits: [String]

    public static let empty = WorkspaceChanges(files: [], diff: "", commits: [])
}

public enum GitInspector {
    /// The task branch's commits since `base`, read from the user's own repository, where
    /// AIrlock brought them back. Used when the task's container isn't running, so its
    /// uncommitted work can't be seen (and its repository isn't touched from the Mac).
    public static func committedChanges(in repo: HostGit, branch: String, since base: String) async throws -> WorkspaceChanges {
        let ref = "refs/heads/\(branch)"
        guard (try? await repo.run("rev-parse", "--verify", "--quiet", "\(ref)^{commit}")) != nil else { return .empty }
        let range = [base, ref]
        let numstat = try await repo.run(["diff", "--numstat", "-M", "--no-ext-diff", "--no-textconv"] + range)
        let nameStatus = try await repo.run(["diff", "--name-status", "-M", "--no-ext-diff"] + range)
        let diff = try await repo.run(["diff", "-M", "--no-ext-diff", "--no-textconv"] + range)
        let commits = try await repo.run("log", "--format=%h %s", "\(base)..\(ref)")
        return WorkspaceChanges(files: files(numstat: numstat, nameStatus: nameStatus).sorted { $0.path < $1.path },
                                diff: diff, commits: commits.split(separator: "\n").map(String.init))
    }

    static func files(numstat: String, nameStatus: String) -> [FileChange] {
        var counts: [String: (Int?, Int?)] = [:]
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            counts[String(parts.last!)] = (Int(parts[0]), Int(parts[1]))
        }
        var files: [FileChange] = []
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let code = parts.first?.first, let path = parts.last else { continue }
            let kind: FileChange.Kind = switch code {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            let c = counts[path]
            files.append(FileChange(path: path, kind: kind, additions: c?.0, deletions: c?.1))
        }
        return files
    }

    /// Everything that changed in the working tree since `base`, including uncommitted and untracked files.
    public static func changes(_ git: some GitRunner, since base: String) async throws -> WorkspaceChanges {
        let numstat = try await git.run("diff", "--numstat", "-M", base)
        let nameStatus = try await git.run("diff", "--name-status", "-M", base)
        let untracked = try await git.run("ls-files", "--others", "--exclude-standard")
        var diff = try await git.run("diff", "-M", base)
        let commits = try await git.run("log", "--format=%h %s", "\(base)..HEAD")

        var files = files(numstat: numstat, nameStatus: nameStatus)
        for path in untracked.split(separator: "\n").map(String.init).prefix(200) {
            let (_, out) = try await git.git(["diff", "--no-index", "--", "/dev/null", path])
            let patch = String(decoding: out, as: UTF8.self)
            let added = patch.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            files.append(FileChange(path: path, kind: .untracked, additions: added, deletions: 0))
            if !diff.isEmpty { diff += "\n" }
            diff += patch
        }

        return WorkspaceChanges(
            files: files.sorted { $0.path < $1.path },
            diff: diff,
            commits: commits.split(separator: "\n").map(String.init)
        )
    }
}

import Foundation

/// When a task's work last left the sandbox, and which commit it was.
public struct Handoff: Codable, Hashable, Sendable {
    public var at: Date
    public var commit: String

    public init(at: Date = .now, commit: String) {
        self.at = at
        self.commit = commit
    }
}

/// What handing a task off would bring into the user's repository. Shown to the outside agent
/// (the chat that reviews the work) and to the user, who both have to agree.
public struct HandoffReview: Codable, Sendable, Equatable {
    public var title: String
    public var branch: String
    public var commits: [String]
    public var files: Int
    public var additions: Int
    public var deletions: Int
    /// Changed files that run on the Mac, in CI or steer AI agents, with why.
    public var attention: [Attention]
    /// The sealed setup's one-line summary, and how many findings it had.
    public var setup: String?
    public var setupFindings: Int
    /// Files with changes that aren't committed: they stay behind.
    public var uncommitted: Int?
    /// Everything on the branch has been handed off already.
    public var nothingNew: Bool
    /// A plain folder: handing off applies the work to its files.
    public var plainFolder: Bool

    public init(title: String, branch: String, commits: [String], files: Int, additions: Int, deletions: Int, attention: [Attention],
                setup: String?, setupFindings: Int, uncommitted: Int?, nothingNew: Bool, plainFolder: Bool) {
        self.title = title
        self.branch = branch
        self.commits = commits
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.attention = attention
        self.setup = setup
        self.setupFindings = setupFindings
        self.uncommitted = uncommitted
        self.nothingNew = nothingNew
        self.plainFolder = plainFolder
    }

    public struct Attention: Codable, Hashable, Sendable {
        public var path: String
        public var reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// "3 commits · 7 files (+182 −40)"
    public var summary: String {
        "\(commits.count) commit\(commits.count == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s") (+\(additions) −\(deletions))"
    }

    /// Paths that deserve a look before the work is merged: they run on the user's Mac (on
    /// install, build, in the shell or editor), in CI, or tell AI agents what to do.
    public static func attention(for paths: [String]) -> [Attention] {
        paths.compactMap { path in reason(for: path).map { Attention(path: path, reason: $0) } }
    }

    static func reason(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let lower = path.lowercased()
        func under(_ prefixes: String...) -> Bool { prefixes.contains { lower.hasPrefix($0) || lower.contains("/" + $0) } }
        if under(".github/workflows/", ".circleci/", ".buildkite/", ".gitlab/") || ["Jenkinsfile", ".gitlab-ci.yml", "azure-pipelines.yml", "bitbucket-pipelines.yml"].contains(name) {
            return "runs in CI"
        }
        if under(".husky/", ".githooks/", ".git-hooks/") || ["lefthook.yml", ".pre-commit-config.yaml", ".gitattributes", ".gitmodules"].contains(name) {
            return "git hooks or settings"
        }
        if under(".claude/", ".cursor/") || ["CLAUDE.md", "AGENTS.md", ".mcp.json", ".cursorrules"].contains(name) {
            return "steers AI agents"
        }
        if under(".vscode/", ".idea/", ".devcontainer/") { return "runs in your editor" }
        if [".envrc", ".bashrc", ".zshrc", ".profile"].contains(name) { return "runs in your shell" }
        if under("node_modules/", "vendor/", "third_party/") { return "vendored code" }
        if ["package.json"].contains(name) { return "install scripts and dependencies" }
        if [".npmrc", ".yarnrc", ".yarnrc.yml", ".pnpmfile.cjs", "pip.conf", ".pypirc"].contains(name) || under(".cargo/") {
            return "package manager settings"
        }
        let lockOrManifest: Set<String> = [
            "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "requirements.txt", "requirements-dev.txt",
            "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "Pipfile.lock", "poetry.lock", "uv.lock", "Cargo.toml", "Cargo.lock",
            "go.mod", "go.sum", "Gemfile", "Gemfile.lock", "composer.json", "composer.lock", "pom.xml", "build.gradle", "build.gradle.kts",
            "Package.swift", "Package.resolved", "Podfile", "Podfile.lock",
        ]
        if lockOrManifest.contains(name) || name.hasSuffix(".csproj") { return "dependencies" }
        if ["Makefile", "build.rs", "Dockerfile", "Taskfile.yml", "justfile"].contains(name) || name.hasPrefix("docker-compose")
            || (name.hasPrefix("compose.") && (name.hasSuffix(".yml") || name.hasSuffix(".yaml"))) || under(".airlock/") {
            return "runs when you build"
        }
        return nil
    }
}

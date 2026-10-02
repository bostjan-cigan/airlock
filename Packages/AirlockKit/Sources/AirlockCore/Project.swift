import Foundation

/// A named group of tasks, linked to one repository. A repository can have several
/// projects; each task belongs to exactly one.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute path to the repository root on the host.
    public var repoPath: String
    public var createdAt: Date
    /// Hosts new restricted tasks in this project may also reach.
    public var allowedHosts: [String]
    /// Debian packages its agents installed with `airlock-install`; baked into the next image.
    public var packages: [String]
    /// The size new tasks start with, when the user chose one ("Remember for this project").
    public var resources: ResourceLimits?

    public init(id: UUID = UUID(), name: String, repoPath: String, createdAt: Date = .now, allowedHosts: [String] = [], packages: [String] = []) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.createdAt = createdAt
        self.allowedHosts = allowedHosts
        self.packages = packages
    }

    enum CodingKeys: String, CodingKey { case id, name, repoPath, createdAt, allowedHosts, packages, resources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repoPath = try c.decode(String.self, forKey: .repoPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
        resources = try? c.decodeIfPresent(ResourceLimits.self, forKey: .resources)
    }

    public var repoName: String { URL(fileURLWithPath: repoPath).lastPathComponent }

    /// The project a repository's tasks land in when no other project is chosen.
    public static func defaultName(forRepo path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}

/// Persists all projects in one JSON file.
public struct ProjectStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func load() throws -> [Project] {
        guard let data = try? Data(contentsOf: paths.projects) else { return [] }
        return try TaskStore.decoder.decode([Project].self, from: data)
    }

    public func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let sorted = projects.sorted { $0.createdAt < $1.createdAt }
        try TaskStore.encoder.encode(sorted).write(to: paths.projects, options: .atomic)
    }
}

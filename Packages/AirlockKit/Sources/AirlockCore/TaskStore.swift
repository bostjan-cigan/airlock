import Foundation

/// Persists tasks as one JSON file per task directory.
public struct TaskStore: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func loadAll() throws -> [AgentTask] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.tasks.path) else { return [] }
        return try fm.contentsOfDirectory(at: paths.tasks, includingPropertiesForKeys: nil)
            .compactMap { dir in
                let file = dir.appending(path: "task.json")
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try Self.decoder.decode(AgentTask.self, from: data)
            }
    }

    public func save(_ task: AgentTask) throws {
        let dir = paths.taskDir(task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(task).write(to: paths.taskFile(task.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let dir = paths.taskDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

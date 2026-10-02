import AirlockCore
import AirlockDocker
import AirlockProviders
import AirlockRuntime
import Foundation

/// Disk used by AIrlock, by kind.
public struct StorageUsage: Sendable, Equatable {
    /// Task checkouts on the Mac.
    public var workspaces: Int64
    /// Package caches (shared folders for Apple VMs, volumes for Docker).
    public var caches: Int64
    public var images: Int64
    /// Docker volumes other than caches: isolated clones, dependency folders, service data.
    public var volumes: Int64

    public var total: Int64 { workspaces + caches + images + volumes }
}

extension TaskEngine {
    /// Picks up a new Claude Code release: its version is part of the image tag, so the next
    /// task gets a fresh image. The image is built ahead, in the background, when Docker is idle.
    public func refreshAgentVersion() async {
        guard let latest = await AgentVersions.latestClaudeCode(), latest != AgentVersions.claudeCode else { return }
        AgentVersions.claudeCode = latest
        guard let docker = runtimes[.docker], !tasks.values.contains(where: { $0.lifecycle == .buildingImage }),
              let provider = Providers.all.first else { return }
        let recipe = provider.imageRecipe(base: Providers.baseRecipe())
        Task.detached(priority: .background) { _ = try? await docker.ensureImage(recipe) { _ in } }
    }

    /// Removes tasks marked done more than `days` ago. Their branches stay in the repository.
    /// Plain-folder tasks are left alone (removing one decides what happens to its work), and
    /// so are isolated clones that can't bring their commits back first.
    @discardableResult
    public func removeFinishedTasks(olderThan days: Int) async -> Int {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for task in tasks.values where task.isDone && task.updatedAt < cutoff && !task.repo.isPlainFolder {
            // Work nobody handed off isn't deleted behind the user's back.
            if await hasWorkToHandOff(task.id) { continue }
            if (try? await remove(task.id)) != nil { removed += 1 }
        }
        return removed
    }

    public func storageUsage() async -> StorageUsage {
        let workspaces = Self.size(of: paths.worktrees)
        var caches = Self.size(of: paths.root.appending(path: "caches"))
        var images: Int64 = 0
        var volumes: Int64 = 0
        if let docker = runtimes[.docker] as? DockerRuntime, let usage = try? await docker.diskUsage() {
            images = usage.images
            volumes = usage.volumes
            let cacheVolumes = await cacheVolumeSizes(docker)
            caches += cacheVolumes
            volumes -= cacheVolumes
        }
        return StorageUsage(workspaces: workspaces, caches: caches, images: images, volumes: max(volumes, 0))
    }

    /// Empties every project's package cache. Refused while tasks run, which use them.
    public func clearCaches() async throws {
        guard !tasks.values.contains(where: { $0.lifecycle.isActive }) else {
            throw EngineError("Stop running tasks first; they use the caches.")
        }
        try? FileManager.default.removeItem(at: paths.root.appending(path: "caches"))
        guard let docker = runtimes[.docker] as? DockerRuntime else { return }
        for name in await cacheVolumeNames(docker) { try? await docker.removeVolume(name) }
    }

    private func cacheVolumeNames(_ docker: DockerRuntime) async -> [String] {
        struct List: Decodable { struct Volume: Decodable { var Name: String }; var Volumes: [Volume]? }
        guard let data = try? await docker.client.request("GET", "/volumes"),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return (list.Volumes ?? []).map(\.Name).filter { $0.hasPrefix("airlock-cache-") }
    }

    private func cacheVolumeSizes(_ docker: DockerRuntime) async -> Int64 {
        struct DF: Decodable {
            struct Volume: Decodable { struct Usage: Decodable { var Size: Int64 }; var Name: String; var UsageData: Usage? }
            var Volumes: [Volume]?
        }
        guard let data = try? await docker.client.request("GET", "/system/df", query: ["type": "volume"]),
              let df = try? JSONDecoder().decode(DF.self, from: data) else { return 0 }
        return (df.Volumes ?? []).filter { $0.Name.hasPrefix("airlock-cache-") }.reduce(0) { $0 + max($1.UsageData?.Size ?? 0, 0) }
    }

    /// Bytes on disk under a folder.
    static func size(of dir: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

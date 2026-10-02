import AirlockCore
import AirlockDocker
import AirlockRuntime
import Foundation

extension TaskEngine {
    /// The size a new task in this repository would get, and why. The New Task sheet shows
    /// it before starting; `create` applies it.
    public func planResources(repoPath: String, projectID: UUID?, explicit: ResourceLimits? = nil, services: Bool = false) async -> ResourcePlan {
        let dir = URL(fileURLWithPath: repoPath)
        let stack = StackDetector.detect(at: dir)
        let config = (try? await ProjectConfig.load(repo: dir, dockerSocket: (runtimes[.docker] as? DockerRuntime)?.client.socketPath)) ?? nil
        let reserved = tasks.values.filter { $0.lifecycle.isActive }.reduce(0) { $0 + $1.resources.memoryMB }
        return ResourcePlanner.plan(
            explicit: explicit,
            projectDefault: project(projectID)?.resources,
            config: config.flatMap { config in config.resources.map { ($0, config.source) } },
            stack: stack,
            services: services ? 2 : 0,
            reservedMemoryMB: reserved
        )
    }

    /// The size new tasks in a project start with; nil goes back to automatic.
    public func setProjectResources(_ projectID: UUID, _ limits: ResourceLimits?) {
        guard let index = projectList.firstIndex(where: { $0.id == projectID }) else { return }
        projectList[index].resources = limits
        saveProjects()
    }

    public func usage(for id: UUID) -> [String: ResourceUsage] { usage[id] ?? [:] }

    /// Reads the agent's and its services' usage in the background, at most every 10 seconds.
    func startUsagePoll(_ id: UUID) {
        guard usagePolls[id] == nil, Date.now.timeIntervalSince(usageReadAt[id] ?? .distantPast) >= 10 else { return }
        usageReadAt[id] = .now
        usagePolls[id] = Task { [weak self] in
            await self?.pollUsage(id)
            await self?.finishUsagePoll(id)
        }
    }

    private func finishUsagePoll(_ id: UUID) { usagePolls[id] = nil }

    private func pollUsage(_ id: UUID) async {
        guard let task = tasks[id], let containerID = task.containerID, let runtime = runtimes[task.runtime] else { return }
        var containers = [("agent", containerID)]
        for service in task.services?.items ?? [] {
            if let container = service.containerID { containers.append((service.name, container)) }
        }
        var readings: [String: ResourceUsage] = [:]
        await withTaskGroup(of: (String, ResourceUsage?).self) { group in
            for (name, container) in containers {
                group.addTask { (name, try? await runtime.usage(container)) }
            }
            for await (name, reading) in group {
                if let reading { readings[name] = reading }
            }
        }
        guard tasks[id]?.lifecycle == .running else { return }
        usage[id] = readings
        updateSink.yield(.usage(id, readings))
    }
}

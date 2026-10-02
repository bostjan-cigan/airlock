import AirlockCore
import AirlockDocker
import AirlockProviders
import AirlockRuntime
import Foundation

/// Compose services next to the agent, and ports forwarded to localhost.
extension TaskEngine {
    // MARK: Services

    /// Reads the compose file in the user's repository, pulls images, and records what will run.
    func planServices(_ id: UUID, runtime: any ContainerRuntime) async throws -> ServicePlan {
        guard let task = tasks[id], let file = task.services?.composeFile else { return ServicePlan(services: [], skipped: [:]) }
        guard let runtime = runtime as? any ServiceRuntime else {
            throw EngineError("Services run on Docker only; this task uses \(task.runtime.displayName).")
        }
        // The compose file comes from the user's repository (see `settingsSource`). A worktree
        // task's files are on the Mac, so its binds point into the checkout; an isolated
        // clone's aren't, so it gets none.
        let dir = settingsSource(task)
        let project = try await ComposeServices.load(dir: dir, file: file, dockerSocket: (runtime as? DockerRuntime)?.client.socketPath)
        let checkout = task.workspace.mode == .worktree ? task.workspace.hostPath : nil
        var plan = ComposeServices.plan(project, volumePrefix: task.containerName,
                                        root: checkout == nil ? nil : ComposeServices.realPath(dir.path), checkout: checkout)

        // Pull on the host, before any network policy applies, and learn the ports images listen on.
        for index in plan.services.indices {
            let service = plan.services[index]
            log(id, "Pulling \(service.image) for \(service.name)…")
            try await runtime.pullImage(service.image) { [weak self] line in Task { await self?.log(id, line) } }
            let imagePorts = (try? await runtime.exposedPorts(image: service.image)) ?? []
            plan.services[index].ports = Array(Set(service.ports + imagePorts)).sorted()
        }
        let (kept, collisions) = ComposeServices.resolvePortCollisions(plan.services)
        plan.services = kept
        plan.skipped.merge(collisions) { a, _ in a }

        servicePlans[id] = plan
        update(id) {
            $0.services?.items = plan.services.map {
                ServiceInstance(name: $0.name, image: $0.image, ports: $0.ports, volumes: $0.volumes, dropped: $0.dropped)
            }
            $0.services?.skipped = plan.skipped
        }
        for service in plan.services where !service.dropped.isEmpty {
            log(id, "\(service.name): removed \(service.dropped.joined(separator: "; "))")
        }
        return plan
    }

    /// Starts every service in dependency order once the agent container (and its firewall) is up.
    /// Creates containers that don't exist yet. A failing service doesn't stop the task.
    func startServices(_ id: UUID) async {
        guard let task = tasks[id], let services = task.services, let agent = task.containerID,
              let runtime = runtimes[task.runtime] as? any ServiceRuntime else { return }
        var plan = servicePlans[id]
        if plan == nil, services.items.contains(where: { $0.containerID == nil }) {
            plan = try? await planServices(id, runtime: runtime)
        }
        for item in tasks[id]?.services?.items ?? [] {
            setService(id, item.name) { $0.state = .starting }
            do {
                var containerID = item.containerID
                var exists = false
                if let existing = containerID { exists = (try? await runtime.state(existing)) != .missing }
                if !exists {
                    guard let planned = plan?.services.first(where: { $0.name == item.name }) else {
                        throw EngineError("Not in the compose file anymore")
                    }
                    // Checked again right before Docker mounts them: the agent may have swapped a folder for a link since.
                    if let checkout = task.workspace.hostPath {
                        for case .bind(let host, _, _) in planned.mounts where ComposeServices.confined(host, to: checkout) == nil {
                            throw EngineError("A folder it mounts now leads outside the task's files")
                        }
                    }
                    for volume in planned.volumes {
                        try? await runtime.createVolume(volume, labels: ["airlock.task": id.uuidString])
                    }
                    containerID = try await runtime.create(planned.containerSpec(task: task, agentContainerID: agent))
                    let created = containerID
                    setService(id, item.name) { $0.containerID = created }
                }
                try await runtime.start(containerID!)
                let state = try await waitForService(runtime, containerID!)
                setService(id, item.name) {
                    $0.state = state
                    $0.startedAt = .now
                }
            } catch {
                setService(id, item.name) { $0.state = .failed(String(describing: error)) }
                log(id, "\(item.name) didn't start: \(error)")
            }
        }
    }

    /// Healthy when the healthcheck passes, running when there is none; up to two minutes.
    private func waitForService(_ runtime: any ServiceRuntime, _ id: String) async throws -> ServiceInstance.State {
        let deadline = ContinuousClock.now + .seconds(120)
        var runningSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            switch try await runtime.state(id) {
            case .stopped(let code):
                throw EngineError("Exited with code \(code.map(String.init) ?? "?")")
            case .missing:
                throw EngineError("Container disappeared")
            case .running:
                switch try await runtime.health(id) {
                case "healthy"?: return .healthy
                case "unhealthy"?: throw EngineError("Healthcheck failing")
                case nil:
                    runningSince = runningSince ?? .now
                    if ContinuousClock.now - runningSince! >= .seconds(2) { return .running }
                default: break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EngineError("Not healthy after two minutes")
    }

    func stopServices(_ id: UUID) async {
        guard let task = tasks[id], let runtime = runtimes[task.runtime] else { return }
        for item in (task.services?.items ?? []).reversed() {
            if let container = item.containerID { try? await runtime.stop(container, timeout: .seconds(5)) }
            setService(id, item.name) { $0.state = .stopped }
        }
    }

    /// Removes service containers (all carrying this task's label), and optionally their volumes.
    func removeServiceContainers(_ id: UUID, volumes: Bool = false) async {
        guard let task = tasks[id], let runtime = runtimes[task.runtime] else { return }
        var containers = (task.services?.items ?? []).compactMap(\.containerID)
        if let docker = runtime as? DockerRuntime, let labelled = try? await docker.containers(label: "airlock.task=\(id.uuidString)") {
            containers += labelled.filter { $0.labels["airlock.service"] != nil }.map(\.id)
        }
        for container in Set(containers) { try? await runtime.remove(container) }
        if volumes {
            for volume in Set((task.services?.items ?? []).flatMap(\.volumes)) { try? await runtime.removeVolume(volume) }
        }
        update(id) { task in
            guard task.services != nil else { return }
            for index in task.services!.items.indices {
                task.services!.items[index].containerID = nil
                task.services!.items[index].state = .pending
            }
        }
    }

    /// Syncs service states with their containers while the task runs.
    func refreshServices(_ id: UUID) async {
        guard let task = tasks[id], let runtime = runtimes[task.runtime] as? any ServiceRuntime else { return }
        for item in task.services?.items ?? [] {
            guard let container = item.containerID, item.state != .starting else { continue }
            let state: ServiceInstance.State
            switch try? await runtime.state(container) {
            case .running?:
                switch try? await runtime.health(container) {
                case "healthy"?: state = .healthy
                case "unhealthy"?: state = .failed("Healthcheck failing")
                case "starting"?: state = .starting
                default: state = .running
                }
            case .stopped(let code)?: state = .failed("Exited with code \(code.map(String.init) ?? "?")")
            case .missing?: state = .failed("Container removed")
            case nil: continue
            }
            if state != item.state { setService(id, item.name) { $0.state = state } }
        }
    }

    public func serviceLogs(_ id: UUID, service: String, tail: Int = 200) async throws -> String {
        let (runtime, container) = try serviceContainer(id, service)
        return try await runtime.logs(container, tail: tail)
    }

    public func restartService(_ id: UUID, service: String) async throws {
        let (runtime, container) = try serviceContainer(id, service)
        setService(id, service) { $0.state = .starting }
        try await runtime.restart(container)
        let state = (try? await waitForService(runtime, container)) ?? .failed("Didn't come back after a restart")
        setService(id, service) {
            $0.state = state
            $0.startedAt = .now
        }
    }

    private func serviceContainer(_ id: UUID, _ name: String) throws -> (any ServiceRuntime, String) {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard let item = task.services?.items.first(where: { $0.name == name }) else {
            let names = task.services?.items.map(\.name).joined(separator: ", ") ?? ""
            throw EngineError(names.isEmpty ? "This task runs no services." : "No service named \(name). Services: \(names).")
        }
        guard let container = item.containerID, let runtime = runtimes[task.runtime] as? any ServiceRuntime else {
            throw EngineError("\(name) has no container yet.")
        }
        return (runtime, container)
    }

    private func setService(_ id: UUID, _ name: String, _ change: (inout ServiceInstance) -> Void) {
        update(id) { task in
            guard let index = task.services?.items.firstIndex(where: { $0.name == name }) else { return }
            change(&task.services!.items[index])
        }
    }

    // MARK: Ports

    /// Forwards a port inside the task (the agent's or a service's; they share a network)
    /// to localhost on the Mac. `service` picks that service's first known port.
    @discardableResult
    public func expose(_ id: UUID, port: Int?, hostPort: Int? = nil, service: String? = nil) async throws -> PortForward {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        var containerPort = port
        if containerPort == nil, let service {
            guard let item = task.services?.items.first(where: { $0.name == service }) else {
                throw EngineError("No service named \(service).")
            }
            containerPort = item.ports.first
            if containerPort == nil { throw EngineError("\(service) doesn't declare a port; pass one.") }
        }
        guard let containerPort, (1...65535).contains(containerPort) else { throw EngineError("Give a port between 1 and 65535.") }
        guard task.lifecycle == .running, task.containerID != nil else { throw EngineError("The task isn't running.") }
        if let open = forwarders[id]?[containerPort], let existing = task.ports.first(where: { $0.containerPort == containerPort }),
           existing.hostPort == open.hostPort {
            return existing
        }
        let owner = service ?? task.services?.items.first(where: { $0.ports.contains(containerPort) })?.name
        let forwarder = try await openForwarder(id, containerPort: containerPort, preferredHostPort: hostPort ?? containerPort)
        let forward = PortForward(containerPort: containerPort, hostPort: forwarder.hostPort, service: owner)
        update(id) { task in
            task.ports.removeAll { $0.containerPort == containerPort }
            task.ports.append(forward)
            task.ports.sort { $0.containerPort < $1.containerPort }
        }
        return forward
    }

    public func unexpose(_ id: UUID, port: Int) {
        forwarders[id]?.removeValue(forKey: port)?.stop()
        update(id) { $0.ports.removeAll { $0.containerPort == port } }
    }

    private func openForwarder(_ id: UUID, containerPort: Int, preferredHostPort: Int) async throws -> PortForwarder {
        forwarders[id]?.removeValue(forKey: containerPort)?.stop()
        let forwarder = try await PortForwarder.start(preferred: preferredHostPort) { [weak self] in
            guard let self else { throw EngineError("AIrlock is shutting down.") }
            return try await self.openPortStream(id, containerPort)
        }
        forwarders[id, default: [:]][containerPort] = forwarder
        return forwarder
    }

    private func openPortStream(_ id: UUID, _ port: Int) async throws -> any TerminalSession {
        guard let task = tasks[id], let container = task.containerID, let runtime = runtimes[task.runtime] else {
            throw EngineError("The task isn't running.")
        }
        return try await runtime.openStream(container, ExecSpec(["socat", "-", "TCP:127.0.0.1:\(port)"], user: ContainerPaths.user))
    }

    /// Reopens the task's saved forwards, keeping their host ports when they're still free.
    func restoreForwards(_ id: UUID) async {
        for forward in tasks[id]?.ports ?? [] where forwarders[id]?[forward.containerPort] == nil {
            do {
                let forwarder = try await openForwarder(id, containerPort: forward.containerPort, preferredHostPort: forward.hostPort)
                if forwarder.hostPort != forward.hostPort {
                    update(id) { task in
                        if let index = task.ports.firstIndex(where: { $0.containerPort == forward.containerPort }) {
                            task.ports[index].hostPort = forwarder.hostPort
                        }
                    }
                }
            } catch {
                log(id, "Couldn't forward port \(forward.containerPort): \(error)")
            }
        }
    }

    func closeForwards(_ id: UUID) {
        for forwarder in forwarders.removeValue(forKey: id)?.values ?? [:].values { forwarder.stop() }
    }

    /// TCP ports something listens on inside the task (agent and services share the network).
    public func listeningPorts(_ id: UUID) async -> [Int] {
        guard let task = tasks[id], let container = task.containerID, task.lifecycle == .running,
              let runtime = runtimes[task.runtime] else { return [] }
        // State 0A is LISTEN; the local port is the hex after the colon.
        let script = "awk 'NR>1 && $4==\"0A\" {split($2,a,\":\"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null"
        guard let result = try? await runtime.exec(container, ExecSpec(["sh", "-c", script])) else { return [] }
        let ports = result.output.split(separator: "\n").compactMap { Int($0, radix: 16) }
        return Array(Set(ports)).sorted()
    }
}

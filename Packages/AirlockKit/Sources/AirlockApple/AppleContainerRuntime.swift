import AirlockCore
import AirlockDocker
import AirlockRuntime
import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationOS
import Foundation
import SystemPackage

/// Runs each container in its own lightweight Linux VM with Apple Containerization.
///
/// VMs live inside the app process, so they stop when AIrlock quits. Each
/// container's root filesystem is kept on disk, so starting it again picks up
/// where it left off.
public actor AppleContainerRuntime: ContainerRuntime {
    public nonisolated var kind: RuntimeKind { .apple }

    public let assets: AppleRuntimeAssets
    /// Builds images. Apple Containerization can run OCI images but not build them.
    private let builder: DockerRuntime?

    private var manager: ContainerManager?
    private var running: [String: RunningContainer] = [:]
    private var exits: [String: Int] = [:]
    /// The previous CPU reading per container, to turn cumulative time into a percentage.
    private var cpuSamples: [String: (usec: UInt64, at: ContinuousClock.Instant)] = [:]

    struct RunningContainer {
        let container: LinuxContainer
        let spec: ContainerSpec
        let waiter: Task<Void, Never>
    }

    public init(assets: AppleRuntimeAssets, builder: DockerRuntime?) {
        self.assets = assets
        self.builder = builder
    }

    public func availability() async -> RuntimeAvailability {
        guard AppleRuntimeAssets.hostSupported else {
            return .unavailable(reason: "Apple VMs need a Mac with Apple silicon.")
        }
        guard assets.hasKernel else {
            return .unavailable(reason: "Download the Linux kernel in Settings → Runtimes to use Apple VMs.")
        }
        guard builder != nil else {
            return .unavailable(reason: "Apple VMs use Docker to build agent images. Start Docker Desktop, OrbStack or Colima.")
        }
        return .available(version: "Containerization 0.47")
    }

    private func containerManager() async throws -> ContainerManager {
        if let manager { return manager }
        guard assets.hasKernel else { throw EngineAssetError("The Linux kernel for Apple VMs isn't installed.") }
        let manager = try await ContainerManager(
            kernel: Kernel(path: assets.kernel, platform: .linuxArm),
            initfsReference: AppleRuntimeAssets.initImage,
            root: assets.store,
            network: try VmnetNetwork()
        )
        self.manager = manager
        return manager
    }

    // MARK: Images

    public func ensureImage(_ recipe: ImageRecipe, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let builder else { throw EngineAssetError("Docker is needed to build images for Apple VMs.") }
        let manager = try await containerManager()
        let tag = try recipe.tag()
        let reference = "docker.io/\(tag)"
        if (try? await manager.imageStore.get(reference: reference)) != nil { return reference }

        let dockerTag = try await builder.ensureImage(recipe, progress: progress)
        progress("Importing \(dockerTag) into the Apple VM image store")
        let archive = try await builder.client.request("GET", "/images/\(dockerTag)/get")

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "airlock-oci-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tarFile = staging.appending(path: "image.tar")
        try archive.write(to: tarFile)
        let layout = staging.appending(path: "layout")
        try fm.createDirectory(at: layout, withIntermediateDirectories: true)
        try await ProcessRunner.run("/usr/bin/tar", ["-x", "-f", tarFile.path, "-C", layout.path])

        let images = try await manager.imageStore.load(from: layout)
        guard let image = images.first else { throw EngineAssetError("Docker exported \(dockerTag) without an image.") }
        if image.reference != reference {
            _ = try await manager.imageStore.tag(existing: image.reference, new: reference)
        }
        return reference
    }

    // MARK: Containers

    /// Records the spec; the VM boots on `start`.
    public func create(_ spec: ContainerSpec) async throws -> String {
        let id = spec.name
        try FileManager.default.createDirectory(at: assets.specs, withIntermediateDirectories: true)
        try JSONEncoder().encode(spec).write(to: specFile(id), options: .atomic)
        return id
    }

    public func start(_ id: String) async throws {
        guard running[id] == nil else { return }
        let spec = try JSONDecoder().decode(ContainerSpec.self, from: Data(contentsOf: specFile(id)))
        var manager = try await containerManager()
        let image = try await manager.imageStore.get(reference: spec.image)
        let mounts = try spec.mounts.map(vmMount)
        let configure: (inout LinuxContainer.Configuration) throws -> Void = { config in
            config.cpus = spec.resources.cpus
            config.memoryInBytes = UInt64(spec.resources.memoryMB) * 1024 * 1024
            config.hostname = spec.name
            config.useInit = true
            config.mounts.append(contentsOf: mounts)
            config.process.environmentVariables += spec.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            if !spec.command.isEmpty { config.process.arguments = spec.command }
            if let workdir = spec.workdir { config.process.workingDirectory = workdir }
            var caps = LinuxCapabilities.defaultOCICapabilities
            for name in spec.capAdd {
                guard let cap = try? CapabilityName(rawValue: "CAP_\(name)") else { continue }
                caps.bounding.append(cap)
                caps.effective.append(cap)
                caps.permitted.append(cap)
            }
            config.process.capabilities = caps
            config.process.noNewPrivileges = true
        }
        let vm = VMResources(
            cpus: spec.resources.cpus,
            memoryInBytes: UInt64(spec.resources.memoryMB) * 1024 * 1024 + VMResources.guestMemoryOverhead
        )

        let rootfs = assets.store.appending(path: "containers/\(id)/rootfs.ext4")
        let container: LinuxContainer
        if FileManager.default.fileExists(atPath: rootfs.path) {
            // Restart: boot the same root filesystem again.
            container = try await manager.create(
                id, image: image,
                rootfs: .block(format: "ext4", source: rootfs.path, destination: "/"),
                networking: true, vm: vm, configuration: configure
            )
        } else {
            container = try await manager.create(id, image: image, rootfsSizeInBytes: 16.gib(), networking: true, vm: vm, configuration: configure)
        }
        self.manager = manager

        try await container.create()
        try await container.start()
        exits[id] = nil
        let waiter = Task { [weak self] in
            let status = try? await container.wait()
            await self?.exited(id, code: Int(status?.exitCode ?? -1))
        }
        running[id] = RunningContainer(container: container, spec: spec, waiter: waiter)
    }

    private func exited(_ id: String, code: Int) async {
        guard let entry = running.removeValue(forKey: id) else { return }
        exits[id] = code
        try? await entry.container.stop()
        try? manager?.releaseNetwork(id)
    }

    public func stop(_ id: String, timeout: Duration) async throws {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.waiter.cancel()
        try? await entry.container.kill(.term)
        _ = try? await entry.container.wait(timeoutInSeconds: Int64(timeout.components.seconds))
        try await entry.container.stop()
        try? manager?.releaseNetwork(id)
        exits[id] = 0
    }

    /// Stops every VM. Call before the app quits.
    public func stopAll() async {
        for id in running.keys { try? await stop(id, timeout: .seconds(3)) }
    }

    public func remove(_ id: String) async throws {
        try await stop(id, timeout: .seconds(1))
        if var manager {
            try? manager.delete(id)
            self.manager = manager
        }
        try? FileManager.default.removeItem(at: specFile(id))
        exits[id] = nil
    }

    public func state(_ id: String) async throws -> AirlockRuntime.ContainerState {
        if running[id] != nil { return .running }
        guard FileManager.default.fileExists(atPath: specFile(id).path) else { return .missing }
        return .stopped(exitCode: exits[id])
    }

    // MARK: Exec

    public func exec(_ id: String, _ spec: ExecSpec) async throws -> ExecResult {
        let entry = try runningContainer(id)
        let stdout = CollectingWriter(), stderr = CollectingWriter()
        let config = processConfig(spec, container: entry, stdout: stdout, stderr: stderr)
        let process = try await entry.container.exec("exec-\(UUID().uuidString.prefix(8))", configuration: config)
        try await process.start()
        let status = try await process.wait()
        try? await process.delete()
        return ExecResult(exitCode: Int(status.exitCode), stdout: stdout.data, stderr: stderr.data)
    }

    public func openTerminal(_ id: String, _ spec: ExecSpec, size: TerminalSize) async throws -> any TerminalSession {
        let entry = try runningContainer(id)
        let session = AppleTerminalSession()
        var config = processConfig(spec, container: entry, stdout: session.writer, stderr: nil)
        config.terminal = true
        config.stdin = session.reader
        let process = try await entry.container.exec("tty-\(UUID().uuidString.prefix(8))", configuration: config)
        try await process.start()
        try? await process.resize(to: Terminal.Size(width: UInt16(size.cols), height: UInt16(size.rows)))
        session.attach(process)
        return session
    }

    public func openStream(_ id: String, _ spec: ExecSpec) async throws -> any TerminalSession {
        let entry = try runningContainer(id)
        let session = AppleTerminalSession()
        var config = processConfig(spec, container: entry, stdout: session.writer, stderr: nil)
        config.terminal = false
        config.stdin = session.reader
        let process = try await entry.container.exec("pipe-\(UUID().uuidString.prefix(8))", configuration: config)
        try await process.start()
        session.attach(process)
        return session
    }

    private func processConfig(_ spec: ExecSpec, container: RunningContainer, stdout: Writer, stderr: Writer?) -> LinuxProcessConfiguration {
        var config = LinuxProcessConfiguration()
        // Start from the container's environment, like `docker exec`.
        var env = Dictionary(
            container.container.config.process.environmentVariables.compactMap { line -> (String, String)? in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<eq]), String(line[line.index(after: eq)...]))
            },
            uniquingKeysWith: { _, new in new }
        )
        env.merge(spec.resolvedEnvironment) { _, new in new }
        config.arguments = spec.command
        config.workingDirectory = spec.workdir ?? container.spec.workdir ?? "/"
        config.stdout = stdout
        config.stderr = stderr
        config.noNewPrivileges = true
        // Like `docker exec`, root processes get the container's capability set.
        config.capabilities = container.container.config.process.capabilities
        if let user = spec.user, user != "root" {
            // The agent user (uid 1000 in the node base image) gets no capabilities at all.
            config.user = User(uid: 1000, gid: 1000, username: user)
            config.capabilities = LinuxCapabilities()
            env["HOME"] = "/home/\(user)"
            env["USER"] = user
        }
        config.environmentVariables = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return config
    }

    private func runningContainer(_ id: String) throws -> RunningContainer {
        guard let entry = running[id] else { throw EngineAssetError("Container \(id) isn't running.") }
        return entry
    }

    // MARK: Files and volumes

    public func copyIn(_ id: String, tar: Data, to path: String) async throws {
        let entry = try runningContainer(id)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "airlock-copy-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await ProcessRunner.run("/usr/bin/tar", ["-x", "-f", "-", "-C", staging.path], stdin: tar)
        for item in try fm.contentsOfDirectory(atPath: staging.path) {
            try await entry.container.copyIn(
                from: staging.appending(path: item),
                to: URL(fileURLWithPath: path).appending(path: item)
            )
        }
    }

    /// Volumes are ext4 disk images attached to the VM as block devices.
    public func usage(_ id: String) async throws -> ResourceUsage? {
        guard let entry = running[id] else { return nil }
        let stats = try await entry.container.statistics(categories: [.memory, .cpu])
        let now = ContinuousClock.now
        var cpu = 0.0
        if let usec = stats.cpu?.usageUsec {
            if let previous = cpuSamples[id], usec >= previous.usec {
                let elapsed = now - previous.at
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds > 0 { cpu = Double(usec - previous.usec) / 1e6 / seconds * 100 }
            }
            cpuSamples[id] = (usec, now)
        }
        let memory = stats.memory.map { $0.usageBytes - min($0.inactiveFile, $0.usageBytes) } ?? 0
        return ResourceUsage(cpuPercent: cpu, memoryBytes: memory)
    }

    public func createVolume(_ name: String, labels: [String: String]) async throws {
        try FileManager.default.createDirectory(at: assets.volumes, withIntermediateDirectories: true)
        let file = volumeFile(name)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let formatter = try EXT4.Formatter(FilePath(file.path), minDiskSize: 32.gib())
        try formatter.close()
    }

    public func removeVolume(_ name: String) async throws {
        try? FileManager.default.removeItem(at: volumeFile(name))
    }

    // MARK: Helpers

    private func vmMount(_ mount: MountSpec) throws -> Containerization.Mount {
        switch mount {
        case .bind(let host, let target, let readOnly):
            return .share(source: host, destination: target, options: readOnly ? ["ro"] : [])
        case .volume(let name, let target):
            return .block(format: "ext4", source: volumeFile(name).path, destination: target)
        }
    }

    private func specFile(_ id: String) -> URL { assets.specs.appending(path: "\(id).json") }
    private func volumeFile(_ name: String) -> URL { assets.volumes.appending(path: "\(name).ext4") }
}

/// Collects a process's output in memory.
final class CollectingWriter: Writer, @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    var data: Data { lock.withLock { buffer } }

    func write(_ data: Data) throws { lock.withLock { buffer.append(data) } }
    func close() throws {}
}

/// Interactive TTY process in an Apple VM.
final class AppleTerminalSession: TerminalSession, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let outputSink: AsyncStream<Data>.Continuation
    private let inputStream: AsyncStream<Data>
    private let inputSink: AsyncStream<Data>.Continuation
    private var process: LinuxProcess?
    private let lock = NSLock()

    init() {
        (output, outputSink) = AsyncStream<Data>.makeStream()
        (inputStream, inputSink) = AsyncStream<Data>.makeStream()
    }

    var writer: Writer { SinkWriter(sink: outputSink) }
    var reader: ReaderStream { StreamReader(source: inputStream) }

    func attach(_ process: LinuxProcess) {
        lock.withLock { self.process = process }
        Task { [outputSink] in
            _ = try? await process.wait()
            try? await process.delete()
            outputSink.finish()
        }
    }

    func write(_ data: Data) async throws { inputSink.yield(data) }

    func resize(_ size: TerminalSize) async throws {
        let process = lock.withLock { self.process }
        try await process?.resize(to: Terminal.Size(width: UInt16(size.cols), height: UInt16(size.rows)))
    }

    /// Detaches without stopping the agent: closing stdin ends `tmux attach` only.
    func close() async {
        inputSink.finish()
        let process = lock.withLock { self.process }
        try? await process?.kill(.hup)
    }

    struct SinkWriter: Writer {
        let sink: AsyncStream<Data>.Continuation
        func write(_ data: Data) throws { sink.yield(data) }
        func close() throws { sink.finish() }
    }

    struct StreamReader: ReaderStream {
        let source: AsyncStream<Data>
        func stream() -> AsyncStream<Data> { source }
    }
}

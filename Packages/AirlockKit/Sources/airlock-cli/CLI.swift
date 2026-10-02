import AirlockApple
import AirlockCore
import AirlockDocker
import AirlockEngine
import AirlockProviders
import AirlockRuntime
import Foundation

// Developer tool for exercising runtimes without the app.
//   airlock-cli docker-smoke     create alpine, exec, tear down
//   airlock-cli build-images     build the base + Claude Code images
//   airlock-cli e2e <scratch-dir> [worktree|volumeClone] [restricted|open] [docker|apple]
//   airlock-cli e2e-plain <scratch-dir> [worktree|volumeClone] [docker|apple]
//   airlock-cli e2e-services <scratch-dir>   compose services and port forwarding (Docker)
//   airlock-cli e2e-inspect <scratch-dir> [docker|apple]   inspect a sample repository
//                                run a full task against a throwaway repo with a dummy token

@main
struct CLI {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        guard let docker = DockerRuntime.discover() else { fatalError("No Docker socket found") }
        switch args.first {
        case "docker-smoke":
            print(await docker.availability())
            _ = try? await docker.client.request("POST", "/images/create", query: ["fromImage": "alpine", "tag": "3.20"])
            let id = try await docker.create(ContainerSpec(name: "airlock-smoke-\(Int.random(in: 1000...9999))", image: "alpine:3.20", command: ["sleep", "300"]))
            try await docker.start(id)
            let r = try await docker.exec(id, ExecSpec(["sh", "-c", "echo out; echo err >&2; exit 3"]))
            print("exit=\(r.exitCode) out=\(r.output.debugDescription) err=\(r.errorOutput.debugDescription)")
            print(try await docker.state(id))
            try await docker.remove(id)
            print(try await docker.state(id))
        case "apple-probe":
            // Boots a restricted Apple VM container and dumps firewall diagnostics.
            let apple = AppleContainerRuntime(assets: AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple")), builder: docker)
            let image = try await apple.ensureImage(ClaudeCodeProvider().imageRecipe(base: Providers.baseRecipe())) { _ in }
            let dir = FileManager.default.temporaryDirectory.appending(path: "airlock-probe-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let net = dir.appending(path: "network.json")
            try #"{"domains":["api.anthropic.com","claude.ai","registry.npmjs.org","sentry.io"],"github":true}"#.write(to: net, atomically: true, encoding: .utf8)
            let id = try await apple.create(ContainerSpec(
                name: "airlock-probe-\(Int.random(in: 1000...9999))", image: image,
                mounts: [.bind(hostPath: net.path, containerPath: "/airlock/network.json", readOnly: true)],
                environment: ["AIRLOCK_NETWORK": "restricted"], capAdd: ["NET_ADMIN", "NET_RAW"]
            ))
            try await apple.start(id)
            try await Task.sleep(for: .seconds(8))
            let script = args.dropFirst().first ?? "nft list ruleset | grep -v elements; for i in 1 2 3 4 5; do curl -s -m6 -o /dev/null -w '%{http_code} %{remote_ip} %{time_total}\\n' https://example.com || echo blocked $?; curl -s -m10 -o /dev/null -w 'anthropic %{http_code} %{time_appconnect}\\n' https://api.anthropic.com || echo anthropic-fail $?; done"
            let r = try await apple.exec(id, ExecSpec(["sh", "-c", script], user: "root"))
            print(r.output, r.errorOutput)
            try await apple.remove(id)
        case "apple-kernel":
            let assets = AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple"))
            try await assets.installKernel { print(String(format: "%.0f%%", $0 * 100)) }
            print("kernel at \(assets.kernel.path)")
        case "build-images":
            let recipe = ClaudeCodeProvider().imageRecipe(base: Providers.baseRecipe())
            let tag = try await docker.ensureImage(recipe) { print("  \($0)") }
            print("built \(tag)")
        case "e2e":
            let args = Array(args.dropFirst())
            let kind = args.count > 3 ? RuntimeKind(rawValue: args[3]) ?? .docker : .docker
            let runtime: any ContainerRuntime = kind == .docker ? docker : AppleContainerRuntime(
                assets: AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple")),
                builder: docker
            )
            try await EndToEnd.run(
                runtime: runtime,
                scratch: URL(fileURLWithPath: args.first ?? NSTemporaryDirectory()),
                mode: args.count > 1 ? WorkspaceSpec.Mode(rawValue: args[1]) ?? .worktree : .worktree,
                restricted: args.count > 2 ? args[2] != "open" : true
            )
        case "e2e-plain":
            let args = Array(args.dropFirst())
            let kind = args.count > 2 ? RuntimeKind(rawValue: args[2]) ?? .docker : .docker
            let runtime: any ContainerRuntime = kind == .docker ? docker : AppleContainerRuntime(
                assets: AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple")),
                builder: docker
            )
            try await EndToEndPlainFolder.run(
                runtime: runtime,
                scratch: URL(fileURLWithPath: args.first ?? NSTemporaryDirectory()),
                mode: args.count > 1 ? WorkspaceSpec.Mode(rawValue: args[1]) ?? .worktree : .worktree
            )
        case "detect":
            // What AIrlock would set up for a folder: tools, packages, hosts, notices, size.
            for path in args.dropFirst() {
                let dir = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/")).standardizedFileURL
                var stack = StackDetector.detect(at: dir)
                let config = try? await ProjectConfig.load(repo: dir, dockerSocket: DockerClient.discoverSocket())
                if let config = config ?? nil {
                    stack.apply(tools: config.tools, packages: config.packages,
                                allow: config.allow.compactMap { try? NetworkRules.normalize($0) }, source: config.source)
                }
                let plan = ResourcePlanner.plan(explicit: nil, projectDefault: nil,
                                                config: (config ?? nil).flatMap { c in c.resources.map { ($0, c.source) } },
                                                stack: stack, services: 0, reservedMemoryMB: 0)
                print("\(dir.lastPathComponent)")
                print("  tools:    \(stack.summary ?? "none")  \(stack.tools.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: " "))")
                if !stack.packages.isEmpty { print("  packages: \(stack.packages.joined(separator: " "))") }
                print("  hosts:    \(stack.hosts.joined(separator: " "))")
                if !stack.dependencyFolders.isEmpty { print("  folders:  \(stack.dependencyFolders.joined(separator: " "))") }
                if let source = stack.configSource { print("  settings: \(source)") }
                print("  size:     \(plan.limits.summary) (\(plan.reason))")
                for notice in stack.notices { print("  notice:   \(notice)") }
            }
        case "e2e-stacks":
            let args = Array(args.dropFirst())
            let kind = args.count > 1 ? RuntimeKind(rawValue: args[1]) ?? .docker : .docker
            let runtime: any ContainerRuntime = kind == .docker ? docker : AppleContainerRuntime(
                assets: AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple")),
                builder: docker
            )
            try await EndToEndStacks.run(runtime: runtime, scratch: URL(fileURLWithPath: args.first ?? NSTemporaryDirectory()))
        case "e2e-inspect":
            let args = Array(args.dropFirst())
            let kind = args.count > 1 ? RuntimeKind(rawValue: args[1]) ?? .docker : .docker
            let runtime: any ContainerRuntime = kind == .docker ? docker : AppleContainerRuntime(
                assets: AppleRuntimeAssets(root: Paths.default.root.appending(path: "apple")),
                builder: docker
            )
            try await EndToEndInspect.run(runtime: runtime, scratch: URL(fileURLWithPath: args.first ?? NSTemporaryDirectory()))
        case "e2e-services":
            try await EndToEndServices.run(runtime: docker, scratch: URL(fileURLWithPath: args.dropFirst().first ?? NSTemporaryDirectory()))
        default:
            print("usage: airlock-cli docker-smoke | build-images | apple-kernel | e2e <dir> [worktree|volumeClone] [restricted|open] [docker|apple] | e2e-plain <dir> [worktree|volumeClone] [docker|apple] | detect <dir>… | e2e-stacks <dir> [docker|apple] | e2e-services <dir> | e2e-inspect <dir> [docker|apple]")
        }
    }
}

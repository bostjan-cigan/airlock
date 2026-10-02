import AirlockCore
import AirlockRuntime
import Foundation

/// An AI coding agent that can run inside an AIrlock container.
///
/// Adding a provider means supplying an image layer on top of the shared base
/// image, the domains it needs on a restricted network, the secrets it reads,
/// how to launch it, and how to decode its hook events.
public protocol AgentProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }

    /// Image layer built on top of the shared base image.
    func imageRecipe(base: ImageRecipe) -> ImageRecipe

    /// Secrets the provider can use, in order of preference; any one is enough.
    var acceptedSecrets: [SecretKey] { get }

    /// Domains the agent needs on a restricted network.
    var defaultAllowlist: [String] { get }

    /// The API host behind `airlock-proxy`. Only the proxy's user may reach it on a
    /// restricted network; the agent talks to the proxy.
    var proxyHosts: [String] { get }

    /// The real credential for `airlock-proxy` to add to the agent's requests. The agent's
    /// own environment only has a placeholder, so nothing it runs can read the real one.
    func proxyCredential(secrets: [SecretKey: String]) -> String?

    /// Hosts the agent looks up in the background (updates, plugin catalogs), not for the
    /// task. Being refused them isn't worth reporting.
    var backgroundHosts: [String] { get }

    /// Path inside the container where the agent keeps its config.
    var configMountPath: String { get }

    /// Writes config (onboarding state, trust, credential approval) into the host
    /// directory that gets mounted at `configMountPath`. Called on every launch.
    func seedConfig(at directory: URL, for task: AgentTask, secrets: [SecretKey: String]) throws

    /// Environment for the agent process: the proxy's address and placeholders, never the
    /// real API credential (see `proxyCredential`). A GitHub token, when opted in, does go here.
    func environment(for task: AgentTask, secrets: [SecretKey: String]) -> [String: String]

    /// Command that starts the agent (`resume` continues the previous conversation).
    func launchCommand(for task: AgentTask, resume: Bool) -> [String]

    /// Decoder for the lines the provider's hooks write to the task's event log.
    /// `hostPath` maps container paths to host paths.
    func eventDecoder(hostPath: @escaping @Sendable (String) -> String?) -> any AgentEventDecoder

    /// Everything the agent said in its last message, from (the end of) its transcript.
    /// The engine reads the file; it's in the agent's folder, so never by a path it gave.
    func lastMessageText(transcript: Data) -> String?
}

extension AgentProvider {
    /// Context every agent gets about where it runs and who it reports to.
    public func environmentBriefing(for task: AgentTask) -> String {
        if task.isInspection {
            return [
                "You are inside an AIrlock inspection VM: an isolated Linux environment with an untrusted repository at /workspace.",
                "Its code may be malicious. Read it to understand it; run it only when you need to see what it does.",
                "The network is closed on purpose and stays closed. There are no credentials here; files that look like credentials are decoys.",
                "You report back in your reply. Nothing you change here leaves the VM, and there is no branch to commit to.",
            ].joined(separator: "\n")
        }
        var lines = [
            "You are running inside an AIrlock container: an isolated Linux environment with its own copy of the repository at /workspace.",
            "You are on the git branch \(task.workspace.branch). Commit your work to this branch locally.",
        ]
        if task.githubAccess {
            lines.append("You have GitHub access for this task. Still don't push or open pull requests unless the task asks you to.")
        } else {
            lines.append("Don't push, pull or open pull requests: there are no credentials for that here, on purpose. The user reviews your commits and pushes them.")
        }
        if let summary = task.stack?.summary {
            lines.append("The project's tools are installed: \(summary). Package caches live in ~/.cache and are kept between tasks.")
        }
        lines.append("You don't have root or sudo. To install a Debian package (a library or command-line tool), run `airlock-install <package>…`, e.g. `airlock-install libpq-dev`.")
        if task.isSealed {
            lines.append("The project's dependencies are installed and the network is closed on purpose: only your API is reachable. If you need a new package or host, try it once; the user is asked and may allow it, then try again. Don't work around it.")
            lines.append("Files like ~/.npmrc or ~/.ssh/id_rsa here are decoys, not credentials; leave them alone.")
        } else if task.network.isRestricted {
            let allowed = task.githubAccess ? "your API, GitHub and package registries" : "your API and package registries"
            lines.append("Outbound network access is limited to an allowlist (\(allowed)). Other hosts are blocked on purpose; don't try to work around it.")
        }
        if let services = task.services {
            let up = services.items.filter(\.state.isUp)
            if !up.isEmpty {
                let list = up.map { "\($0.name) (\($0.image)) at \($0.address)" }.joined(separator: ", ")
                lines.append("The project's services are running alongside you and share your network: \(list). You can't manage their containers; ask in your reply if one needs restarting.")
            }
            let down = services.items.filter { !$0.state.isUp }.map(\.name) + services.skipped.keys.sorted()
            if !down.isEmpty {
                lines.append("These services from \(services.composeFile ?? "the compose file") are not running: \(down.joined(separator: ", ")).")
            }
        }
        if task.origin?.isChat == true {
            lines.append("This task was handed off from another Claude session. The final message of each of your turns is relayed back to it, and its replies arrive as user messages. When you finish or need a decision, end your turn with a clear, self-contained summary or question.")
        } else {
            lines.append("When you finish or need a decision, end your turn with a clear summary or question; the user is notified.")
        }
        return lines.joined(separator: " ")
    }
}

public enum Providers {
    public static let all: [any AgentProvider] = [ClaudeCodeProvider()]

    public static func provider(for id: ProviderID) -> (any AgentProvider)? {
        all.first { $0.id == id }
    }

    /// Recipe for the image every provider builds on.
    /// The base image, on `fromImage` when a project brings its own agent image.
    public static func baseRecipe(from fromImage: String? = nil) -> ImageRecipe {
        ImageRecipe(name: "base", contextDirectory: imagesDirectory.appending(path: "base"),
                    buildArgs: fromImage.map { ["FROM_IMAGE": $0] } ?? [:])
    }

    /// The inspection toolbox (Python, pip, Cargo) on top of an agent image.
    public static func inspectionRecipe(parent: ImageRecipe) -> ImageRecipe {
        ImageRecipe(name: "inspect", contextDirectory: imagesDirectory.appending(path: "inspect"), parent: parent)
    }

    static var imagesDirectory: URL {
        Bundle.module.resourceURL!.appending(path: "images", directoryHint: .isDirectory)
    }
}

/// Container paths shared by every provider.
public enum ContainerPaths {
    public static let workspace = "/workspace"
    /// Package caches, on a per-project volume.
    public static let cache = "/home/node/.cache"
    public static let events = "/airlock/events"
    public static let networkConfig = "/airlock/network.json"
    /// Written by `airlock-init` once the network policy is applied.
    public static let readyMarker = "/run/airlock-ready"
    public static let user = "node"
    public static let home = "/home/node"
    public static let tmuxSession = "agent"
    /// `airlock-proxy` listens here, on loopback, inside the container.
    public static let proxyPort = 8119
    /// Only `airlock-proxy` can read this folder; the real credential is written into it.
    public static let proxyDirectory = "/run/airlock-proxy"
}

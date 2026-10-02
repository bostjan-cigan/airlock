import Foundation

/// One thing a task's agent is allowed to do, in plain words.
public struct Permission: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case network, files, autonomy, github, credential, services, ports, resources
    }

    public var kind: Kind
    /// SF Symbol name.
    public var symbol: String
    public var title: String
    public var detail: String
    /// More access than the default sandbox gives.
    public var isElevated: Bool
    /// Shown only in the details, not in the compact icon strip.
    public var detailOnly: Bool

    public var id: Kind { kind }
}

extension AgentTask {
    private var plainFolderNote: String {
        repo.isPlainFolder
            ? " The folder isn't a git repository: AIrlock added a temporary .git, applies the result to the folder's files, and deletes that .git with the folder's last task."
            : ""
    }

    public var permissions: [Permission] {
        var list: [Permission] = []

        switch network {
        case .restricted(let extra):
            let allowed = ["the agent's API"] + (githubAccess ? ["GitHub"] : []) + ["package registries"] + extra
            list.append(Permission(kind: .network, symbol: "lock.shield", title: "Restricted network",
                                   detail: "Only \(allowed.joined(separator: ", ")). Runs on \(runtime.displayName).",
                                   isElevated: false, detailOnly: false))
        case .open:
            list.append(Permission(kind: .network, symbol: "globe", title: "Open network",
                                   detail: "Can reach any host on the internet. Runs on \(runtime.displayName).",
                                   isElevated: true, detailOnly: false))
        }

        switch workspace.mode {
        case .worktree:
            let path = workspace.hostPath.map { " at \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
            list.append(Permission(kind: .files, symbol: "folder", title: "Writes to a folder on your Mac",
                                   detail: "Its own checkout\(path), including packages it installs and build output. Your working copy isn't touched.\(plainFolderNote)",
                                   isElevated: true, detailOnly: false))
        case .volumeClone:
            list.append(Permission(kind: .files, symbol: "shippingbox", title: "Works in an isolated clone",
                                   detail: "Nothing on your Mac changes until you bring its commits back.\(plainFolderNote)",
                                   isElevated: false, detailOnly: false))
        }

        list.append(Permission(kind: .autonomy, symbol: "hand.raised.slash", title: "Runs every tool without asking",
                               detail: "Inside the container only, as a non-root user with no Linux capabilities.",
                               isElevated: false, detailOnly: false))

        if access?.github == true {
            list.append(Permission(kind: .github, symbol: "arrow.triangle.pull", title: "Can push and open pull requests",
                                   detail: "Your GitHub token is available to it as GH_TOKEN.",
                                   isElevated: true, detailOnly: false))
        } else if githubAccess {
            list.append(Permission(kind: .github, symbol: "arrow.triangle.pull", title: "Can reach GitHub",
                                   detail: "GitHub is allowed on its network, but no GitHub token is set in Settings.",
                                   isElevated: true, detailOnly: false))
        }

        switch access?.credential {
        case .claudeToken?:
            list.append(Permission(kind: .credential, symbol: "key", title: "Uses your Claude token",
                                   detail: "Through a proxy: the agent and what it runs never see the token. Your subscription's usage limits apply.",
                                   isElevated: false, detailOnly: false))
        case .apiKey?:
            list.append(Permission(kind: .credential, symbol: "creditcard", title: "Uses your API key",
                                   detail: "Through a proxy: the agent and what it runs never see the key. Usage is billed to your Anthropic account.",
                                   isElevated: true, detailOnly: false))
        case nil:
            list.append(Permission(kind: .credential, symbol: "key", title: "Credential unknown",
                                   detail: "Recorded the next time the task starts.", isElevated: false, detailOnly: false))
        }

        if let services = self.services, !services.items.isEmpty {
            list.append(Permission(kind: .services, symbol: "shippingbox", title: "Runs \(services.items.count) service\(services.items.count == 1 ? "" : "s"): \(services.items.map(\.name).joined(separator: ", "))",
                                   detail: "They share the agent's network and allowlist; none are exposed on your Mac unless you forward a port.",
                                   isElevated: false, detailOnly: true))
        }
        if !ports.isEmpty {
            list.append(Permission(kind: .ports, symbol: "network", title: "Forwards \(ports.map { String($0.containerPort) }.joined(separator: ", ")) to localhost",
                                   detail: "Reachable from this Mac only, not from your network.", isElevated: false, detailOnly: true))
        }

        let memory = resources.memoryMB % 1024 == 0 ? "\(resources.memoryMB / 1024) GB" : "\(resources.memoryMB) MB"
        list.append(Permission(kind: .resources, symbol: "cpu", title: "\(resources.cpus) CPU · \(memory) memory",
                               detail: "Container limits.", isElevated: false, detailOnly: true))
        return list
    }

    public var hasElevatedAccess: Bool { permissions.contains(where: \.isElevated) }
}

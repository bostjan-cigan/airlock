import Foundation

/// A task that checks whether an untrusted repository is safe, instead of working on it.
///
/// The repository is copied into a VM, its dependencies are downloaded without running any of
/// their code, then the network closes and its install scripts (or a command) run. AIrlock
/// records what that code did. Nothing comes back out: no branch, no files.
public struct Inspection: Codable, Hashable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        /// Cloned inside the VM; the repository never exists on the Mac.
        case url(String)
        /// A folder on the Mac, copied in as files (its git settings are never used on the Mac).
        case folder(String)

        public var label: String {
            switch self {
            case .url(let url): url.replacingOccurrences(of: "https://", with: "")
            case .folder(let path): (path as NSString).abbreviatingWithTildeInPath
            }
        }

        /// The repository's name: the last part of the URL or folder.
        public var name: String {
            let raw = switch self {
            case .url(let url): url
            case .folder(let path): path
            }
            let last = raw.split(separator: "/").last.map(String.init) ?? raw
            return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        }
    }

    public enum Phase: String, Codable, Sendable {
        /// Building the image and the VM.
        case preparing
        /// Copying the repository in and downloading its dependencies (scripts off).
        case downloading
        /// The network is closed; its code runs next.
        case sealed
        /// Install scripts or the chosen command are running.
        case running
        /// Claude is looking into what happened (only when asked to).
        case investigating
        case finished
        case failed

        public var title: String {
            switch self {
            case .preparing: "Preparing the VM"
            case .downloading: "Downloading packages"
            case .sealed: "Network closed"
            case .running: "Running its code"
            case .investigating: "Claude is investigating"
            case .finished: "Report ready"
            case .failed: "Couldn't finish"
            }
        }
    }

    public var source: Source
    /// Run after the network closes; nil runs install scripts for what was downloaded.
    public var command: String?
    /// Claude looks into the result, inside the VM, through the credential proxy.
    public var investigate: Bool
    public var phase: Phase
    /// When the network closed: everything recorded after this is the repository's doing.
    public var sealedAt: Date?
    public var report: InspectionReport?

    public init(source: Source, command: String? = nil, investigate: Bool = false) {
        self.source = source
        self.command = command.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.investigate = investigate
        self.phase = .preparing
    }

    /// Before the network closes, these may be reached: package registries and the
    /// repository's own host. Nothing from the repository runs while they're open.
    public static let downloadHosts = [
        "registry.npmjs.org", "registry.yarnpkg.com",
        "pypi.org", "files.pythonhosted.org",
        "index.crates.io", "static.crates.io", "crates.io",
    ]
}

/// What the repository's code did once the network closed. Every string comes from inside the
/// VM (file names, hosts, commands), so it's cleaned before it's stored.
public struct InspectionReport: Codable, Hashable, Sendable {
    /// What was downloaded, and how ("npm ci --ignore-scripts").
    public var downloads: [String] = []
    public var downloadFailed = false
    /// What ran after the network closed.
    public var command = ""
    public var exitCode: Int?
    /// The end of what it printed.
    public var output = ""
    /// Names it looked up (refused: nothing resolves once the network is closed).
    public var triedHosts: [String] = []
    /// Addresses it tried to connect to directly, as "1.2.3.4:443".
    public var triedAddresses: [String] = []
    /// Decoy credential files it read, like "~/.ssh/id_rsa".
    public var credentialReads: [String] = []
    /// Packages with install scripts ("left-pad (postinstall)").
    public var installScripts: [String] = []
    /// Files created or changed outside the repository and the package folders.
    public var changedOutside: [String] = []
    /// Files created or changed in the repository itself.
    public var changedInRepo: [String] = []
    /// Its processes still running afterwards.
    public var processes: [String] = []

    public init() {}

    /// Signs of behaviour an install shouldn't have.
    public var findings: Int {
        triedHosts.count + triedAddresses.count + credentialReads.count + changedOutside.count + processes.count
    }

    /// One line for lists and notifications.
    public var summary: String {
        var parts: [String] = []
        let tried = triedHosts.count + triedAddresses.count
        if tried > 0 { parts.append("tried to reach \(tried) host\(tried == 1 ? "" : "s")") }
        if !credentialReads.isEmpty { parts.append("read \(credentialReads.count) credential file\(credentialReads.count == 1 ? "" : "s")") }
        if !changedOutside.isEmpty { parts.append("changed \(changedOutside.count) file\(changedOutside.count == 1 ? "" : "s") outside the repository") }
        if !processes.isEmpty { parts.append("left \(processes.count) process\(processes.count == 1 ? "" : "es") running") }
        guard !parts.isEmpty else { return "Nothing suspicious seen" }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }
}

/// A coding task whose network closes before any dependency code runs. Its dependencies are
/// downloaded with install scripts off, the network closes (only the credential proxy may
/// reach the agent's API), then the install scripts run, recorded like an inspection's.
/// Hosts the user allows later open as usual.
public struct Sealing: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Dependencies download; nothing of theirs runs.
        case downloading
        /// The network is closed; install scripts run next, then the agent.
        case sealed

        public var title: String {
            switch self {
            case .downloading: "Downloading packages"
            case .sealed: "Network closed"
            }
        }
    }

    public var phase: Phase
    public var sealedAt: Date?
    /// What the install scripts did, and decoy reads since.
    public var report: InspectionReport?

    public init() { phase = .downloading }
}

extension AgentTask {
    public var isInspection: Bool { inspection != nil }
    public var isSealed: Bool { sealing != nil }
}

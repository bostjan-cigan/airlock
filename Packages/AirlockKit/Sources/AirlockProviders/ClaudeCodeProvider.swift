import AirlockCore
import AirlockRuntime
import Foundation

public struct ClaudeCodeProvider: AgentProvider {
    public init() {}

    public var id: ProviderID { .claudeCode }
    public var displayName: String { "Claude Code" }

    public func imageRecipe(base: ImageRecipe) -> ImageRecipe {
        // The version is part of the image's tag, so a new release means a new image.
        ImageRecipe(
            name: "claude-code",
            contextDirectory: Providers.imagesDirectory.appending(path: "claude"),
            parent: base,
            buildArgs: ["CLAUDE_CODE_VERSION": AgentVersions.claudeCode]
        )
    }

    public var acceptedSecrets: [SecretKey] { [.claudeOAuthToken, .anthropicAPIKey] }

    public var defaultAllowlist: [String] {
        // The API isn't here: only `airlock-proxy` may reach it (`proxyHosts`). No sentry.io:
        // error reports are off (nonessential traffic), and anyone can receive data there.
        ["registry.npmjs.org"]
    }

    public var proxyHosts: [String] { ["api.anthropic.com"] }

    public var backgroundHosts: [String] {
        ["downloads.claude.ai", "storage.googleapis.com", "raw.githubusercontent.com", "statsig.com", "http-intake.logs.datadoghq.com",
         "api.anthropic.com", "claude.ai", "console.anthropic.com", "statsig.anthropic.com"]
    }

    /// What the agent holds instead of the real credential. Claude Code only needs the kind
    /// (subscription token or API key) to pick the right headers; the proxy swaps the value.
    static let placeholderToken = "sk-ant-oat01-airlock-proxy-placeholder"
    static let placeholderKey = "sk-ant-api03-airlock-proxy-placeholder"

    public func proxyCredential(secrets: [SecretKey: String]) -> String? {
        secrets[.claudeOAuthToken] ?? secrets[.anthropicAPIKey]
    }

    public var configMountPath: String { "\(ContainerPaths.home)/.claude" }

    /// The folder is mounted read-write in the container, so the agent may have left symlinks
    /// or odd files in it: files are read with `SafeFile` and replaced, never written through.
    public func seedConfig(at directory: URL, for task: AgentTask, secrets: [SecretKey: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // CLAUDE_CONFIG_DIR points here, so .claude.json lives inside the mount.
        // Merge into what's there: Claude Code keeps its own state in this file.
        var state = SafeFile.read(".claude.json", in: directory, limit: 32 << 20)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        state["hasCompletedOnboarding"] = true
        state["bypassPermissionsModeAccepted"] = true
        var projects = state["projects"] as? [String: Any] ?? [:]
        var workspace = projects[ContainerPaths.workspace] as? [String: Any] ?? [:]
        workspace["hasTrustDialogAccepted"] = true
        projects[ContainerPaths.workspace] = workspace
        state["projects"] = projects
        // Without this, Claude Code asks whether to use an API key found in the environment.
        if secrets[.claudeOAuthToken] == nil, secrets[.anthropicAPIKey] != nil {
            var responses = state["customApiKeyResponses"] as? [String: Any] ?? [:]
            var approved = responses["approved"] as? [String] ?? []
            let suffix = String(Self.placeholderKey.suffix(20))
            if !approved.contains(suffix) { approved.append(suffix) }
            responses["approved"] = approved
            responses["rejected"] = responses["rejected"] ?? [String]()
            state["customApiKeyResponses"] = responses
        }
        try SafeFile.write(JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]), to: ".claude.json", in: directory)

        // An untrusted repository gets nothing of the user's: no instructions, no skills.
        if AgentVersions.shareUserSetup, !task.isInspection { try copyUserSetup(into: directory) }

        if !SafeFile.isRegularFile("settings.json", in: directory) {
            let json: [String: Any] = ["skipDangerousModePermissionPrompt": true]
            try SafeFile.write(JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), to: "settings.json", in: directory)
        }
    }

    public func environment(for task: AgentTask, secrets: [SecretKey: String]) -> [String: String] {
        // No auto-updates, telemetry or error reporting from inside a sandbox: the image pins
        // the version, and the firewall would refuse that traffic anyway.
        var env: [String: String] = [
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            // API requests go to `airlock-proxy`, which adds the real credential.
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(ContainerPaths.proxyPort)",
        ]
        if secrets[.claudeOAuthToken] != nil {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = Self.placeholderToken
        } else if secrets[.anthropicAPIKey] != nil {
            env["ANTHROPIC_API_KEY"] = Self.placeholderKey
        }
        if let gh = secrets[.githubToken] { env["GH_TOKEN"] = gh }
        return env
    }

    public func launchCommand(for task: AgentTask, resume: Bool) -> [String] {
        var cmd = ["claude", "--dangerously-skip-permissions", "--append-system-prompt", environmentBriefing(for: task)]
        if resume {
            cmd.append("--continue")
        } else if !task.prompt.isEmpty {
            cmd.append(task.prompt)
        }
        return cmd
    }

    public func eventDecoder(hostPath: @escaping @Sendable (String) -> String?) -> any AgentEventDecoder {
        ClaudeHookDecoder(hostPath: hostPath)
    }

    public func lastMessageText(transcript: Data) -> String? {
        ClaudeHookDecoder.lastAssistantText(transcript: transcript)
    }

    /// The user's own instructions and skills, so the agent works the way their Claude does.
    /// MCP servers aren't copied: they'd need access to the Mac.
    func copyUserSetup(into directory: URL) throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appending(path: ".claude")
        for name in ["CLAUDE.md", "skills"] {
            let source = home.appending(path: name)
            let target = directory.appending(path: name)
            // Removes a symlink itself, never what it points to; the copy then makes a new item.
            try? fm.removeItem(at: target)
            if fm.fileExists(atPath: source.path) { try? fm.copyItem(at: source, to: target) }
        }
    }
}

/// Agent versions and the user's choices about what agents get, kept in UserDefaults.
public enum AgentVersions {
    static let claudeCodeKey = "claudeCodeVersion"
    public static let shareUserSetupKey = "shareClaudeSetup"

    /// The Claude Code release images are built with; "latest" until the first check.
    public static var claudeCode: String {
        get { UserDefaults.standard.string(forKey: claudeCodeKey) ?? "latest" }
        set { UserDefaults.standard.set(newValue, forKey: claudeCodeKey) }
    }

    /// Copy `~/.claude/CLAUDE.md` and skills into tasks (on unless turned off in Settings).
    public static var shareUserSetup: Bool {
        UserDefaults.standard.object(forKey: shareUserSetupKey) as? Bool ?? true
    }

    /// The newest Claude Code release on npm.
    public static func latestClaudeCode() async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              version.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }) else { return nil }
        return version
    }
}

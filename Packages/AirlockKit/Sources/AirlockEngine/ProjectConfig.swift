import AirlockCore
import AirlockRuntime
import Foundation

/// What a project says about its environment when auto-detection isn't enough, in compose
/// syntax: `.airlock/compose.yaml`, or an `x-airlock` block and/or an `agent` service in the
/// project's own compose file. Everything in it is optional.
///
///     x-airlock:
///       tools: { python: "3.12" }        # mise tools
///       packages: [libpq-dev]            # Debian packages baked into the image
///       allow: [api.stripe.com]          # hosts the agent may also reach
///       resources: { cpus: 4, memory: 8g }
///     services:
///       agent:                           # the agent's own environment (image or build)
///         image: python:3.12-bookworm    # or build: { context: .., dockerfile: …, target: … }
public struct ProjectConfig: Sendable, Equatable {
    public struct Build: Sendable, Equatable {
        public var context: String
        public var dockerfile: String?
        public var target: String?
    }

    /// The file it came from, relative to the repository.
    public var source: String
    public var tools: [String: String] = [:]
    public var packages: [String] = []
    public var allow: [String] = []
    public var agentImage: String?
    public var agentBuild: Build?
    /// Literal `environment:` values of the agent service (no `.env` files).
    public var environment: [String: String] = [:]
    public var resources: ResourceLimits?

    public static let fileName = ".airlock/compose.yaml"

    /// The compose files to read for a repository: its own, then AIrlock's on top.
    public static func files(in dir: URL) -> [String] {
        var files: [String] = []
        if let main = ComposeServices.detect(in: dir), main != fileName { files.append(main) }
        if FileManager.default.fileExists(atPath: dir.appending(path: fileName).path) { files.append(fileName) }
        return files
    }

    /// Nil when the repository has no AIrlock settings anywhere.
    public static func load(repo dir: URL, dockerSocket: String?) async throws -> ProjectConfig? {
        let files = files(in: dir)
        guard !files.isEmpty else { return nil }
        let hasOwnFile = files.contains(fileName)
        let data: Data
        do {
            data = try await ComposeServices.configJSON(dir: dir, files: files, dockerSocket: dockerSocket)
        } catch {
            // Without our file, a compose file AIrlock can't read just means no settings.
            if hasOwnFile { throw error }
            return nil
        }
        return try parse(data, source: hasOwnFile ? fileName : files[0])
    }

    static func parse(_ data: Data, source: String) throws -> ProjectConfig? {
        let document = try JSONDecoder().decode(Document.self, from: data)
        let agent = document.services?["agent"]
        guard document.airlock != nil || agent != nil else { return nil }
        var config = ProjectConfig(source: source)
        config.tools = document.airlock?.tools ?? [:]
        config.packages = document.airlock?.packages ?? []
        config.allow = document.airlock?.allow ?? []
        config.agentImage = agent?.image.flatMap { $0.isEmpty ? nil : $0 }
        if let build = agent?.build {
            config.agentBuild = Build(context: build.context ?? ".", dockerfile: build.dockerfile, target: build.target)
            config.agentImage = nil
        }
        config.environment = (agent?.environment ?? [:]).compactMapValues { $0 }
        if let size = document.airlock?.resources, size.cpus != nil || size.memoryMB != nil {
            config.resources = ResourceLimits(cpus: max(size.cpus ?? ResourceLimits.default.cpus, 1),
                                              memoryMB: max(size.memoryMB ?? ResourceLimits.default.memoryMB, 512))
        } else if let limits = agent?.deploy?.resources?.limits {
            let cpus = limits.cpus.map { Int($0.rounded(.up)) }
            let memory = limits.memory.flatMap { Int($0) }.map { $0 / 1_048_576 }
            if cpus != nil || memory != nil {
                config.resources = ResourceLimits(cpus: max(cpus ?? ResourceLimits.default.cpus, 1),
                                                  memoryMB: max(memory ?? ResourceLimits.default.memoryMB, 512))
            }
        }
        return config
    }

    /// A starting point for `.airlock/compose.yaml`, filled in from what was detected.
    public static func template(for stack: ProjectStack) -> String {
        let tools = stack.tools.isEmpty ? "    # python: \"3.12\"\n" : stack.tools.sorted { $0.key < $1.key }.map { "    \($0.key): \"\($0.value)\"\n" }.joined()
        let packages = stack.packages.isEmpty ? "    # - libpq-dev\n" : stack.packages.map { "    - \($0)\n" }.joined()
        return """
        # AIrlock settings for this project. Only needed when automatic detection
        # isn't enough; everything here is optional. https://github.com/bostjan-cigan/airlock

        x-airlock:
          # Tools to install with mise (https://mise.jdx.dev), by version.
          tools:
        \(tools)  # Debian packages to add to the agent's image.
          packages:
        \(packages)  # Hosts the agent may reach on a restricted network.
          allow: []
          # The container's size, when the automatic one doesn't fit.
          # resources: { cpus: 4, memory: 8g }

        # services:
        #   agent:                           # replace the agent's environment entirely
        #     image: python:3.12-bookworm     # a Debian or Ubuntu based image
        #     # build: { context: .., dockerfile: .airlock/Dockerfile }

        """
    }

    // MARK: Decoding

    struct Document: Decodable {
        var airlock: Airlock?
        var services: [String: AgentService]?

        enum CodingKeys: String, CodingKey {
            case airlock = "x-airlock"
            case services
        }
    }

    struct Airlock: Decodable {
        var tools: [String: String]?
        var packages: [String]?
        var allow: [String]?
        var resources: Size?

        enum CodingKeys: String, CodingKey { case tools, packages, allow, resources }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Versions may be written as numbers (python: 3.12).
            tools = (try? c.decodeIfPresent([String: Version].self, forKey: .tools))?.compactMapValues(\.text)
            packages = try? c.decodeIfPresent([String].self, forKey: .packages)
            allow = try? c.decodeIfPresent([String].self, forKey: .allow)
            resources = try? c.decodeIfPresent(Size.self, forKey: .resources)
        }
    }

    /// `x-airlock.resources`: `cpus: 4`, `memory: 8g` (or "8GB", "512m", or a number of GB).
    /// Compose leaves `x-` blocks as written, so this reads them as people write them.
    struct Size: Decodable {
        var cpus: Int?
        var memoryMB: Int?

        enum CodingKeys: String, CodingKey { case cpus, memory }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decodeIfPresent(Double.self, forKey: .cpus) {
                cpus = Int(number.rounded(.up))
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .cpus), let number = Double(text) {
                cpus = Int(number.rounded(.up))
            }
            if let gigabytes = try? c.decodeIfPresent(Double.self, forKey: .memory) {
                memoryMB = Int(gigabytes * 1024)
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .memory) {
                memoryMB = Self.megabytes(text)
            }
        }

        static func megabytes(_ text: String) -> Int? {
            let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
            let digits = lower.prefix { $0.isNumber || $0 == "." }
            guard let value = Double(digits) else { return nil }
            switch lower.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
            case "", "g", "gb", "gi", "gib": return Int(value * 1024)
            case "m", "mb", "mi", "mib": return Int(value)
            default: return nil
            }
        }
    }

    /// A version written as a string or a number.
    struct Version: Decodable {
        var text: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let string = try? c.decode(String.self) {
                text = string
            } else if let number = try? c.decode(Double.self) {
                text = number == number.rounded() ? String(Int(number)) : String(number)
            }
        }
    }

    struct AgentService: Decodable {
        var image: String?
        var build: BuildSpec?
        var environment: [String: String?]?
        var deploy: Deploy?
    }

    struct BuildSpec: Decodable {
        var context: String?
        var dockerfile: String?
        var target: String?
    }

    struct Deploy: Decodable {
        struct Resources: Decodable { var limits: Limits? }
        struct Limits: Decodable {
            var cpus: Double?
            var memory: String?

            enum CodingKeys: String, CodingKey { case cpus, memory }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                cpus = (try? c.decodeIfPresent(Double.self, forKey: .cpus)) ?? (try? c.decodeIfPresent(String.self, forKey: .cpus)).flatMap { $0.flatMap(Double.init) }
                memory = (try? c.decodeIfPresent(String.self, forKey: .memory)) ?? (try? c.decodeIfPresent(Int.self, forKey: .memory)).flatMap { $0.map(String.init) }
            }
        }
        var resources: Resources?
    }
}

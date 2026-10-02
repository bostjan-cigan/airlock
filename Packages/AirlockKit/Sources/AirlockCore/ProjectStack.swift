import Foundation

/// What a repository needs to build and run, worked out from its files. AIrlock bakes
/// the tools into a cached image (with mise), allows the ecosystems' package hosts and
/// points their caches at a per-project volume, so most projects need no configuration.
public struct ProjectStack: Codable, Hashable, Sendable {
    public enum Ecosystem: String, Codable, Hashable, Sendable, CaseIterable {
        case node, python, go, rust, ruby, java, php, dotnet, deno, swift

        public var displayName: String {
            switch self {
            case .node: "Node"
            case .python: "Python"
            case .go: "Go"
            case .rust: "Rust"
            case .ruby: "Ruby"
            case .java: "Java"
            case .php: "PHP"
            case .dotnet: ".NET"
            case .deno: "Deno"
            case .swift: "Swift"
            }
        }

        /// Where its packages come from, allowed on a restricted network.
        public var hosts: [String] {
            switch self {
            case .node: ["registry.npmjs.org", "registry.yarnpkg.com"]
            case .python: ["pypi.org", "files.pythonhosted.org"]
            case .go: ["proxy.golang.org", "sum.golang.org"]
            case .rust: ["crates.io", "static.crates.io", "index.crates.io"]
            case .ruby: ["rubygems.org", "index.rubygems.org"]
            case .java: ["repo.maven.apache.org", "repo1.maven.org", "plugins.gradle.org", "services.gradle.org", "downloads.gradle.org"]
            case .php: ["packagist.org", "repo.packagist.org"]
            case .dotnet: ["api.nuget.org"]
            case .deno: ["deno.land", "jsr.io"]
            case .swift: []
            }
        }
    }

    /// mise tools and versions to install, e.g. `["python": "3.12", "go": "1.22"]`.
    /// "latest" when the repository doesn't pin one.
    public var tools: [String: String]
    public var ecosystems: [Ecosystem]
    /// Debian packages the stack needs beyond the tools (PHP comes from Debian).
    public var packages: [String]
    /// Things the user should know before starting, e.g. that Xcode projects can't build here.
    public var notices: [String]
    /// Needs more memory than usual (JVM, Rust, .NET, C++ builds).
    public var heavy: Bool
    /// Folders at the repository root that hold installed dependencies (Linux-specific).
    public var dependencyFolders: [String]
    /// Hosts the project's settings allow (`x-airlock.allow`).
    public var allow: [String]
    /// The settings file that adjusted this stack, e.g. `.airlock/compose.yaml`.
    public var configSource: String?

    public init(tools: [String: String] = [:], ecosystems: [Ecosystem] = [], packages: [String] = [],
                notices: [String] = [], heavy: Bool = false, dependencyFolders: [String] = []) {
        self.tools = tools
        self.ecosystems = ecosystems
        self.packages = packages
        self.notices = notices
        self.heavy = heavy
        self.dependencyFolders = dependencyFolders
        self.allow = []
    }

    enum CodingKeys: String, CodingKey { case tools, ecosystems, packages, notices, heavy, dependencyFolders, allow, configSource }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([String: String].self, forKey: .tools) ?? [:]
        ecosystems = (try? c.decodeIfPresent([Ecosystem].self, forKey: .ecosystems)) ?? []
        packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
        notices = try c.decodeIfPresent([String].self, forKey: .notices) ?? []
        heavy = try c.decodeIfPresent(Bool.self, forKey: .heavy) ?? false
        dependencyFolders = try c.decodeIfPresent([String].self, forKey: .dependencyFolders) ?? []
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        configSource = try c.decodeIfPresent(String.self, forKey: .configSource)
    }

    /// Adds a subfolder's stack: the root's pins win, a pinned version beats "latest", and
    /// the subfolder's dependency folders are named from the root.
    public mutating func merge(_ other: ProjectStack, prefix: String) {
        for ecosystem in other.ecosystems where !ecosystems.contains(ecosystem) { ecosystems.append(ecosystem) }
        for (tool, version) in other.tools where tools[tool] == nil || (tools[tool] == "latest" && version != "latest") {
            tools[tool] = version
        }
        packages += other.packages.filter { !packages.contains($0) }
        notices += other.notices.filter { !notices.contains($0) }
        heavy = heavy || other.heavy
        for folder in other.dependencyFolders {
            // npm workspaces install into the root's node_modules.
            if folder == "node_modules", dependencyFolders.contains("node_modules") { continue }
            let path = "\(prefix)/\(folder)"
            if !dependencyFolders.contains(path), dependencyFolders.count < 8 { dependencyFolders.append(path) }
        }
    }

    /// The project's own settings on top of what was detected: its tools win.
    public mutating func apply(tools: [String: String], packages: [String], allow: [String], source: String) {
        self.tools.merge(tools) { _, setting in setting }
        self.packages += packages.filter { !self.packages.contains($0) }
        self.allow = allow
        configSource = source
    }

    public var hosts: [String] {
        var out: [String] = []
        for host in ecosystems.flatMap(\.hosts) + allow where !out.contains(host) { out.append(host) }
        return out
    }

    /// "Python 3.12 · Go 1.22", or nil for a plain Node or empty project.
    public var summary: String? {
        let names = ecosystems.map { ecosystem -> String in
            let tool = Self.tool(for: ecosystem)
            guard let tool, let version = tools[tool], version != "latest" else { return ecosystem.displayName }
            return "\(ecosystem.displayName) \(version)"
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    static func tool(for ecosystem: Ecosystem) -> String? {
        switch ecosystem {
        case .node: "node"
        case .python: "python"
        case .go: "go"
        case .rust: "rust"
        case .ruby: "ruby"
        case .java: "java"
        case .dotnet: "dotnet"
        case .deno: "deno"
        case .php, .swift: nil
        }
    }

    /// Where package managers keep their caches: all under the per-project volume at
    /// `~/.cache`, so a second task doesn't download everything again.
    public static let cacheEnvironment: [String: String] = [
        "npm_config_cache": "/home/node/.cache/npm",
        "npm_config_store_dir": "/home/node/.cache/pnpm-store",
        "YARN_CACHE_FOLDER": "/home/node/.cache/yarn",
        "BUN_INSTALL_CACHE_DIR": "/home/node/.cache/bun",
        "PIP_CACHE_DIR": "/home/node/.cache/pip",
        "UV_CACHE_DIR": "/home/node/.cache/uv",
        "GOMODCACHE": "/home/node/.cache/go-mod",
        "GOCACHE": "/home/node/.cache/go-build",
        "GRADLE_USER_HOME": "/home/node/.cache/gradle",
        "MAVEN_OPTS": "-Dmaven.repo.local=/home/node/.cache/m2",
        "COMPOSER_CACHE_DIR": "/home/node/.cache/composer",
        "BUNDLE_PATH": "/home/node/.cache/bundle",
        "NUGET_PACKAGES": "/home/node/.cache/nuget",
        "DENO_DIR": "/home/node/.cache/deno",
        // Rust builds stay off the workspace, which may be a folder on the Mac.
        "CARGO_TARGET_DIR": "/home/node/.cache/cargo-target",
    ]
}

/// Reads a repository's version and manifest files: at its root, and in project folders up
/// to two levels down (a monorepo's `services/api`, `apps/web`, `workers/indexer`).
public enum StackDetector {
    /// Folders that hold other people's code, build output or examples, not the project's own.
    static let skippedFolders: Set<String> = [
        "node_modules", "vendor", "dist", "build", "target", "out", "venv", "Pods", "DerivedData",
        "examples", "example", "samples", "fixtures", "testdata", "test", "tests", "docs", "third_party",
    ]

    public static func detect(at root: URL) -> ProjectStack {
        var stack = detectFolder(at: root)
        for (folder, relative) in projectFolders(in: root) {
            let sub = detectFolder(at: folder)
            stack.merge(sub, prefix: relative)
        }
        return stack
    }

    /// Subfolders (two levels at most) that look like projects of their own.
    static func projectFolders(in root: URL) -> [(URL, String)] {
        let fm = FileManager.default
        var found: [(URL, String)] = []
        func visit(_ dir: URL, _ relative: String, depth: Int) {
            guard depth <= 2, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !skippedFolders.contains(name) {
                let child = dir.appending(path: name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                if manifests.contains(where: { fm.fileExists(atPath: child.appending(path: $0).path) }) {
                    found.append((child, path))
                }
                visit(child, path, depth: depth + 1)
            }
        }
        visit(root, "", depth: 1)
        return found
    }

    /// Files that mark a folder as a project.
    static let manifests = [
        "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "go.mod", "Cargo.toml",
        "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "deno.json", ".tool-versions",
        "mise.toml", ".python-version", ".nvmrc",
    ]

    static func detectFolder(at root: URL) -> ProjectStack {
        let files = Files(root: root)
        var tools: [String: String] = [:]
        var ecosystems: [ProjectStack.Ecosystem] = []
        var packages: [String] = []
        var notices: [String] = []
        var heavy = false
        var dependencyFolders: [String] = []

        func use(_ ecosystem: ProjectStack.Ecosystem, tool: String? = nil, version: String? = nil) {
            if !ecosystems.contains(ecosystem) { ecosystems.append(ecosystem) }
            guard let tool else { return }
            if let version, !version.isEmpty { tools[tool] = version } else if tools[tool] == nil { tools[tool] = "latest" }
        }

        // Explicit tool lists first: they win over anything inferred below.
        var pinned: [String: String] = [:]
        if let text = files.read(".tool-versions") {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
                pinned[toolName(String(parts[0]))] = String(parts[1])
            }
        }
        for name in ["mise.toml", ".mise.toml", ".config/mise.toml"] {
            guard let text = files.read(name) else { continue }
            pinned.merge(miseTools(text)) { _, new in new }
        }

        // Node
        if files.exists("package.json") || files.exists(".nvmrc") || files.exists(".node-version") {
            let version = pinned["node"]
                ?? files.firstLine(".nvmrc").map(nodeVersion)
                ?? files.firstLine(".node-version").map(nodeVersion)
                ?? files.read("package.json").flatMap(enginesNode)
            // The image already has Node 22; only a pinned other version needs mise.
            use(.node, tool: version.map { _ in "node" }, version: version)
            if files.exists("package.json") { dependencyFolders.append("node_modules") }
            if files.exists("pnpm-lock.yaml") { tools["pnpm"] = pinned["pnpm"] ?? "latest" }
            if files.exists("bun.lockb") || files.exists("bun.lock") { tools["bun"] = pinned["bun"] ?? "latest" }
        }
        if files.exists("deno.json") || files.exists("deno.jsonc") { use(.deno, tool: "deno", version: pinned["deno"]) }

        // Python
        let pyproject = files.read("pyproject.toml")
        if pyproject != nil || files.exists("requirements.txt") || files.exists(".python-version") || files.exists("setup.py") || files.exists("Pipfile") {
            let version = pinned["python"]
                ?? files.firstLine(".python-version")
                ?? pyproject.flatMap(requiresPython)
            use(.python, tool: "python", version: version)
            if files.exists("uv.lock") { tools["uv"] = pinned["uv"] ?? "latest" }
            dependencyFolders.append(".venv")
        }

        // Go
        if let mod = files.read("go.mod") {
            use(.go, tool: "go", version: pinned["go"] ?? goVersion(mod))
        }

        // Rust
        if files.exists("Cargo.toml") || files.exists("rust-toolchain") || files.exists("rust-toolchain.toml") {
            let version = pinned["rust"]
                ?? files.read("rust-toolchain.toml").flatMap { tomlValue($0, key: "channel") }
                ?? files.firstLine("rust-toolchain")
            use(.rust, tool: "rust", version: version)
            heavy = true
        }

        // Ruby
        if files.exists("Gemfile") || files.exists(".ruby-version") {
            let version = pinned["ruby"] ?? files.firstLine(".ruby-version")?.replacingOccurrences(of: "ruby-", with: "")
                ?? files.read("Gemfile").flatMap(gemfileRuby)
            use(.ruby, tool: "ruby", version: version)
            // mise builds Ruby from source.
            packages += ["build-essential", "libssl-dev", "libyaml-dev", "zlib1g-dev", "libffi-dev", "libreadline-dev"]
        }

        // Java
        let pom = files.read("pom.xml")
        let gradle = files.read("build.gradle") ?? files.read("build.gradle.kts")
        if pom != nil || gradle != nil || files.exists(".java-version") {
            let version = pinned["java"] ?? files.firstLine(".java-version")
                ?? pom.flatMap(pomJava) ?? gradle.flatMap(gradleJava) ?? "21"
            use(.java, tool: "java", version: version)
            if pom != nil, !files.exists("mvnw") { tools["maven"] = pinned["maven"] ?? "latest" }
            if gradle != nil, !files.exists("gradlew") { tools["gradle"] = pinned["gradle"] ?? "latest" }
            heavy = true
        }

        // PHP: from Debian, as mise would compile it.
        if files.exists("composer.json") {
            use(.php)
            packages += ["php-cli", "php-xml", "php-mbstring", "php-curl", "php-zip", "unzip", "composer"]
        }

        // .NET
        if files.anyFile(withExtension: "csproj") || files.anyFile(withExtension: "sln") || files.exists("global.json") {
            use(.dotnet, tool: "dotnet", version: pinned["dotnet"])
            heavy = true
        }

        // Swift: Apple platforms can't build in Linux.
        if files.anyFile(withExtension: "xcodeproj") || files.anyFile(withExtension: "xcworkspace")
            || (files.read("Package.swift").map { $0.contains(".iOS(") || $0.contains(".macOS(") || $0.contains(".visionOS(") } ?? false) {
            use(.swift)
            notices.append("This is an Apple-platform project. The agent can read and edit the code, but can’t build or test it inside a Linux container.")
        }

        if files.exists("CMakeLists.txt") || files.exists("Makefile") && files.anyFile(withExtension: "cpp") { heavy = true }

        // Testcontainers and friends need a Docker daemon, which a task doesn't have.
        let manifests = [files.read("package.json"), pom, gradle, files.read("go.mod"), pyproject, files.read("requirements.txt")].compactMap { $0 }
        if manifests.contains(where: { $0.lowercased().contains("testcontainers") }) {
            notices.append("Tests that start Docker containers (Testcontainers) can’t run inside a task; it has no Docker daemon.")
        }

        // Anything else pinned (e.g. terraform, kubectl) goes in as is.
        for (tool, version) in pinned where tools[tool] == nil {
            tools[tool] = version
        }

        return ProjectStack(tools: tools, ecosystems: ecosystems, packages: unique(packages), notices: notices,
                            heavy: heavy, dependencyFolders: dependencyFolders)
    }

    // MARK: Version parsing

    static func toolName(_ name: String) -> String {
        switch name {
        case "nodejs": "node"
        case "golang": "go"
        default: name
        }
    }

    /// `[tools]` entries of a mise.toml: `python = "3.12"`, `node = { version = "20" }`.
    static func miseTools(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var inTools = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTools = line == "[tools]"; continue }
            guard inTools, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{"), let version = tomlValue(value, key: "version") { value = version }
            if value.hasPrefix("[") { value = value.dropFirst().split(separator: ",").first.map(String.init) ?? "" }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ]"))
            if !key.isEmpty, !value.isEmpty { out[toolName(key)] = value }
        }
        return out
    }

    static func nodeVersion(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("lts") { return "lts" }
        return text.hasPrefix("v") ? String(text.dropFirst()) : text
    }

    /// The major version `engines.node` asks for: "20.x" or "^20" give "20". A lower bound
    /// (">=18") is met by the image's own Node, so it pins nothing.
    static func enginesNode(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engines = object["engines"] as? [String: Any], let node = engines["node"] as? String,
              !node.trimmingCharacters(in: .whitespaces).hasPrefix(">") else { return nil }
        return firstVersion(node, components: 1)
    }

    /// "==3.11.*" or "~=3.11" pin 3.11; ">=3.10" leaves the newest Python.
    static func requiresPython(_ toml: String) -> String? {
        guard let spec = tomlValue(toml, key: "requires-python") else { return nil }
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") { return nil }
        return firstVersion(trimmed, components: 2)
    }

    static func goVersion(_ mod: String) -> String? {
        var version: String?
        for line in mod.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "toolchain" { return String(parts[1].dropFirst(2)) }
            if parts.count >= 2, parts[0] == "go" { version = String(parts[1]) }
        }
        return version
    }

    static func gemfileRuby(_ gemfile: String) -> String? {
        for line in gemfile.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("ruby ") {
            return firstVersion(String(line), components: 3)
        }
        return nil
    }

    static func pomJava(_ pom: String) -> String? {
        for tag in ["maven.compiler.release", "java.version", "maven.compiler.source", "release"] {
            if let range = pom.range(of: "<\(tag)>"), let end = pom.range(of: "</\(tag)>", range: range.upperBound..<pom.endIndex) {
                let value = pom[range.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
                if let version = firstVersion(value, components: 1), !value.contains("$") { return version == "1" ? "8" : version }
            }
        }
        return nil
    }

    static func gradleJava(_ gradle: String) -> String? {
        for marker in ["JavaLanguageVersion.of(", "JavaVersion.VERSION_", "jvmToolchain("] {
            if let range = gradle.range(of: marker) {
                return firstVersion(String(gradle[range.upperBound...].prefix(8)).replacingOccurrences(of: "_", with: "."), components: 1)
            }
        }
        return nil
    }

    /// `key = "value"` anywhere in a TOML document or inline table.
    static func tomlValue(_ text: String, key: String) -> String? {
        guard let range = text.range(of: "\(key)") else { return nil }
        let rest = text[range.upperBound...].drop { $0 == " " || $0 == "=" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst().prefix { $0 != quote }
        return value.isEmpty ? nil : String(value)
    }

    /// The first run of digits and dots, cut to `components` parts: ">=18.2" gives "18" for one.
    static func firstVersion(_ text: String, components: Int) -> String? {
        guard let start = text.firstIndex(where: \.isNumber) else { return nil }
        let run = text[start...].prefix { $0.isNumber || $0 == "." }
        let parts = run.split(separator: ".").prefix(components)
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    static func unique(_ list: [String]) -> [String] {
        var out: [String] = []
        for item in list where !out.contains(item) { out.append(item) }
        return out
    }

    struct Files {
        let root: URL

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: name).path) }

        func read(_ name: String) -> String? {
            let url = root.appending(path: name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        func firstLine(_ name: String) -> String? {
            read(name)?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Top-level entries only: a repository's own projects, not its dependencies.
        func anyFile(withExtension ext: String) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.contains { $0.hasSuffix(".\(ext)") }
        }
    }
}

import CryptoKit
import Foundation

/// A Dockerfile plus its build context, layered on an optional parent recipe.
///
/// Images are tagged by content hash so an unchanged recipe is never rebuilt.
public struct ImageRecipe: Sendable {
    public var name: String
    /// Directory containing `Dockerfile` and any files it copies.
    public var contextDirectory: URL
    /// Recipe this one builds on. Its tag is passed as the `BASE_IMAGE` build arg.
    public var parent: Box?
    public var buildArgs: [String: String]

    public final class Box: Sendable {
        public let recipe: ImageRecipe
        public init(_ recipe: ImageRecipe) { self.recipe = recipe }
    }

    public init(name: String, contextDirectory: URL, parent: ImageRecipe? = nil, buildArgs: [String: String] = [:]) {
        self.name = name
        self.contextDirectory = contextDirectory
        self.parent = parent.map(Box.init)
        self.buildArgs = buildArgs
    }

    /// `airlock/<name>:<hash>` where the hash covers the context files, build args and parent tag.
    public func tag() throws -> String {
        "airlock/\(name):\(try contentHash().prefix(12))"
    }

    func contentHash() throws -> String {
        var hasher = SHA256()
        if let parent { hasher.update(data: Data(try parent.recipe.tag().utf8)) }
        for (k, v) in buildArgs.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("\(k)=\(v)\n".utf8))
        }
        for file in try Self.files(in: contextDirectory) {
            hasher.update(data: Data(file.relative.utf8))
            hasher.update(data: try Data(contentsOf: file.url))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func files(in dir: URL) throws -> [(relative: String, url: URL)] {
        let base = dir.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, URL)] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out.append((rel, url))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

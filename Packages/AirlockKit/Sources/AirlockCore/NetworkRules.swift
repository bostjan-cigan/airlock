import Foundation

/// A host the agent looked up but couldn't reach, because nothing it resolves to is allowed.
public struct BlockedHost: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Lookups seen for it.
    public var attempts: Int
    public var lastSeen: Date

    public init(name: String, attempts: Int = 1, lastSeen: Date = .now) {
        self.name = name
        self.attempts = attempts
        self.lastSeen = lastSeen
    }

    public var id: String { name }
}

public struct NetworkRuleError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// What a restricted network allowlist may contain: hostnames, or IP addresses and CIDRs.
public enum NetworkRules {
    /// Debian and Ubuntu package mirrors, for `airlock-install`.
    public static let systemPackageHosts = [
        "deb.debian.org", "security.debian.org", "archive.ubuntu.com", "security.ubuntu.com", "ports.ubuntu.com",
    ]

    /// What a task with GitHub access may also reach (mirrors `airlock-firewall`).
    public static let githubHosts = [
        "github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com",
        "raw.githubusercontent.com", "uploads.github.com", "ghcr.io", "pkg-containers.githubusercontent.com",
    ]

    /// Cleans up what people paste ("https://PyPI.org:443/simple/" becomes "pypi.org").
    /// A host also covers its subdomains, so "*.amazonaws.com" becomes "amazonaws.com".
    /// Throws for things that aren't a host or an address.
    public static func normalize(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let slash = text.firstIndex(of: "/"), !isCIDRPrefix(text, slash: slash) { text = String(text[..<slash]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1 {
            text = String(text[..<text.firstIndex(of: ":")!])
        }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { throw NetworkRuleError("Enter a host, like pypi.org.") }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.contains("*") {
            throw NetworkRuleError("Write a wildcard as *.example.com, or just example.com: a host covers its subdomains.")
        }
        if isAddress(text) { return text }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        let valid = text.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        guard valid else { throw NetworkRuleError("“\(raw.trimmingCharacters(in: .whitespaces))” isn't a host name or an IP address.") }
        return text
    }

    /// IPv4 or IPv6 address, optionally with a /prefix.
    public static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = parts.first else { return false }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]) else { return false }
            if prefix < 0 || prefix > (address.contains(":") ? 128 : 32) { return false }
        }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
    }

    /// Normalizes and de-duplicates a list, keeping order.
    public static func merge(_ lists: [String]...) -> [String] {
        var out: [String] = []
        for entry in lists.joined() {
            guard let host = try? normalize(entry), !out.contains(host) else { continue }
            out.append(host)
        }
        return out
    }

    private static func isCIDRPrefix(_ text: String, slash: String.Index) -> Bool {
        isAddress(String(text[..<slash])) && Int(text[text.index(after: slash)...]) != nil
    }
}

/// Reads dnsmasq's `--log-queries=extra` log incrementally. Each lookup carries a serial,
/// so a CNAME chain's final addresses are attributed to the name that was asked for:
///
///     Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 query[A] www.python.org from 127.0.0.1
///     Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 reply www.python.org is <CNAME>
///     Oct  2 14:36:12 dnsmasq[482]: 2 127.0.0.1/40596 reply dualstack.python.map.fastly.net is 151.101.0.223
public struct DNSLogReader: Sendable {
    public struct Lookup: Hashable, Sendable {
        public var name: String
        public var addresses: [String]
        /// The resolver refused the name: it isn't on the allowlist.
        public var refused: Bool

        public init(name: String, addresses: [String], refused: Bool = false) {
            self.name = name
            self.addresses = addresses
            self.refused = refused
        }
    }

    /// Names asked for, by serial, for lookups whose answers may still arrive.
    private var names: [Int: String] = [:]
    private var order: [Int] = []
    /// A line cut off at the end of the last chunk.
    private var partial = ""

    public init() {}

    /// Feeds the next chunk of the log; returns the addresses each name resolved to.
    public mutating func read(_ chunk: String) -> [Lookup] {
        var text = partial + chunk
        if let lastNewline = text.lastIndex(of: "\n") {
            partial = String(text[text.index(after: lastNewline)...])
            text = String(text[...lastNewline])
        } else {
            partial = text
            return []
        }
        var found: [Int: Lookup] = [:]
        var foundOrder: [Int] = []
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let dnsmasq = words.firstIndex(where: { $0.hasPrefix("dnsmasq[") }),
                  words.count > dnsmasq + 4, let serial = Int(words[dnsmasq + 1]) else { continue }
            let verb = words[dnsmasq + 3]
            if verb.hasPrefix("query[") {
                let type = verb.dropFirst(6).dropLast()
                guard type == "A" || type == "AAAA" else { continue }
                remember(serial, String(words[dnsmasq + 4]).lowercased())
            } else if verb == "config", words.count > dnsmasq + 6, words[dnsmasq + 6] == "NXDOMAIN", let name = names[serial] {
                // "config <name> is NXDOMAIN": the allowlist policy answered, not a real resolver.
                if found[serial] == nil { foundOrder.append(serial) }
                found[serial] = Lookup(name: name, addresses: [], refused: true)
            } else if verb == "reply" || verb == "cached", words.count > dnsmasq + 6, words[dnsmasq + 5] == "is" {
                let value = String(words[dnsmasq + 6])
                guard NetworkRules.isAddress(value), let name = names[serial] else { continue }
                if found[serial] == nil {
                    found[serial] = Lookup(name: name, addresses: [])
                    foundOrder.append(serial)
                }
                found[serial]!.addresses.append(value)
            }
        }
        return foundOrder.compactMap { found[$0] }
    }

    private mutating func remember(_ serial: Int, _ name: String) {
        if names[serial] == nil { order.append(serial) }
        names[serial] = name
        // Answers follow their query within moments; keep only recent serials.
        if order.count > 512 {
            for old in order.prefix(order.count - 512) { names[old] = nil }
            order.removeFirst(order.count - 512)
        }
    }
}

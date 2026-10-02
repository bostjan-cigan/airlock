import Foundation
import Security

public struct SecretKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Long-lived token from `claude setup-token`.
    public static let claudeOAuthToken: SecretKey = "claude.oauthToken"
    public static let anthropicAPIKey: SecretKey = "anthropic.apiKey"
    public static let githubToken: SecretKey = "github.token"
}

public protocol SecretStore: Sendable {
    func get(_ key: SecretKey) throws -> String?
    func set(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Generic-password items in the login keychain.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.bostjancigan.AIrlock") { self.service = service }

    private func query(_ key: SecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    public func get(_ key: SecretKey) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretStoreError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String?, for key: SecretKey) throws {
        let q = query(key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String]
    private let lock = NSLock()

    public init(_ values: [SecretKey: String] = [:]) { self.values = values }

    public func get(_ key: SecretKey) throws -> String? { lock.withLock { values[key] } }
    public func set(_ value: String?, for key: SecretKey) throws { lock.withLock { values[key] = value } }
}

extension SecretKey {
    /// What a value for this key starts with, when the format is known.
    public var expectedPrefix: String? {
        switch self {
        case .claudeOAuthToken: "sk-ant-oat01-"
        case .anthropicAPIKey: "sk-ant-api"
        default: nil
        }
    }

    /// Cleans a pasted secret: drops an `export NAME=` prefix, surrounding quotes, and all
    /// whitespace. Terminals wrap long tokens, and the line break comes along when copied.
    public func sanitize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("export ") { value = String(value.dropFirst("export ".count)) }
        if let equals = value.firstIndex(of: "="), value[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
           value[..<equals].contains(where: \.isLetter) {
            value = String(value[value.index(after: equals)...])
        }
        value.removeAll { $0.isWhitespace }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        return value
    }

    /// Whether a sanitized value has the format this key expects (true when unknown).
    public func looksValid(_ value: String) -> Bool {
        expectedPrefix.map { value.hasPrefix($0) } ?? true
    }
}

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Where the private key lives.
public enum SSHKeyKind: String, Codable, Sendable {
    /// Generated inside the Secure Enclave; the private key never leaves the chip.
    case secureEnclave
    /// A plain P-256 key stored in the Keychain. Fallback for the simulator.
    case software
}

/// Public facts about a stored key. Safe to show and pass around.
public struct SSHKeyInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public let kind: SSHKeyKind
    public let requiresBiometry: Bool
    public let createdAt: Date
    /// Uncompressed public point (0x04 || X || Y).
    public let publicKeyX963: Data

    public var publicKey: P256.Signing.PublicKey {
        // Only ever written from a valid key, so this cannot fail.
        try! P256.Signing.PublicKey(x963Representation: publicKeyX963)
    }

    /// Paste this into `~/.ssh/authorized_keys` on the server.
    public var authorizedKeysLine: String {
        OpenSSH.authorizedKeysLine(publicKey, comment: label)
    }

    public var fingerprint: String {
        OpenSSH.sha256Fingerprint(blob: OpenSSH.publicKeyBlob(publicKey))
    }
}

/// A private key ready to sign an SSH login.
public enum SigningKey: @unchecked Sendable {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    public var publicKey: P256.Signing.PublicKey {
        switch self {
        case .secureEnclave(let key): key.publicKey
        case .software(let key): key.publicKey
        }
    }
}

public enum KeyStoreError: Error, LocalizedError {
    case notFound(UUID)
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case accessControl(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "No key with id \(id)."
        case .secureEnclaveUnavailable: "This device has no Secure Enclave."
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .accessControl(let message): "Could not set up key access control: \(message)"
        }
    }
}

/// Creates, lists and loads SSH keys.
///
/// Secure Enclave keys are stored as their `dataRepresentation`: an opaque
/// handle that only this device's Secure Enclave can use.
public final class KeyStore: Sendable {
    private let storage: any KeyStorage

    public init(storage: any KeyStorage = KeychainKeyStorage()) {
        self.storage = storage
    }

    public static var isSecureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    public func keys() throws -> [SSHKeyInfo] {
        try records().map(\.info).sorted { $0.createdAt < $1.createdAt }
    }

    /// Creates a key in the Secure Enclave, or a software key where there is none
    /// (the simulator) and `allowSoftwareFallback` is set.
    @discardableResult
    public func generateKey(
        label: String,
        requireBiometry: Bool = false,
        allowSoftwareFallback: Bool = true
    ) throws -> SSHKeyInfo {
        let record: StoredKey
        if Self.isSecureEnclaveAvailable {
            let flags: SecAccessControlCreateFlags =
                requireBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error
            ) else {
                throw KeyStoreError.accessControl(
                    error.map { "\($0.takeRetainedValue())" } ?? "unknown")
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            record = StoredKey(
                info: SSHKeyInfo(
                    id: UUID(), label: label, kind: .secureEnclave, requiresBiometry: requireBiometry,
                    createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
                keyData: key.dataRepresentation)
        } else if allowSoftwareFallback {
            let key = P256.Signing.PrivateKey()
            record = StoredKey(
                info: SSHKeyInfo(
                    id: UUID(), label: label, kind: .software, requiresBiometry: false,
                    createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
                keyData: key.rawRepresentation)
        } else {
            throw KeyStoreError.secureEnclaveUnavailable
        }
        try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
        return record.info
    }

    /// Loads the private key for signing.
    ///
    /// For a key that requires biometry, pass an `LAContext` that already passed
    /// `evaluatePolicy`, so signing does not prompt in the middle of the SSH handshake.
    public func signingKey(for id: UUID, authenticationContext: LAContext? = nil) throws -> SigningKey {
        guard let record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        switch record.info.kind {
        case .secureEnclave:
            return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: record.keyData, authenticationContext: authenticationContext))
        case .software:
            return .software(try P256.Signing.PrivateKey(rawRepresentation: record.keyData))
        }
    }

    public func rename(id: UUID, to label: String) throws {
        guard var record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        record.info.label = label
        try storage.save(try JSONEncoder().encode(record), account: id.uuidString)
    }

    public func deleteKey(id: UUID) throws {
        try storage.delete(account: id.uuidString)
    }

    private func records() throws -> [StoredKey] {
        // Skip entries we cannot read rather than hiding every key.
        try storage.loadAll().compactMap { try? JSONDecoder().decode(StoredKey.self, from: $0) }
    }
}

struct StoredKey: Codable {
    var info: SSHKeyInfo
    /// Secure Enclave handle or raw software key.
    var keyData: Data
}

// MARK: - Storage

/// Persists opaque key records.
public protocol KeyStorage: Sendable {
    func loadAll() throws -> [Data]
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// Generic-password items in the data protection keychain, never synced off the device.
public struct KeychainKeyStorage: KeyStorage {
    public let service: String
    /// Readable only while the device is unlocked, not from its first unlock on.
    private let whenUnlockedOnly: Bool

    public init(service: String = "hirte.ssh-keys", whenUnlockedOnly: Bool = false) {
        self.service = service
        self.whenUnlockedOnly = whenUnlockedOnly
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func loadAll() throws -> [Data] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecValueData as String] as? Data }
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return result as? Data
    }

    public func save(_ data: Data, account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = whenUnlockedOnly
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func delete(account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
    }
}

/// For tests and previews.
public final class InMemoryKeyStorage: KeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func loadAll() throws -> [Data] { lock.withLock { Array(items.values) } }
    public func load(account: String) throws -> Data? { lock.withLock { items[account] } }
    public func save(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}

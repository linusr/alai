import Foundation
import Security

/// Server credentials in the keychain, shared with the notification service extension via the app group.
/// Synchronizable items travel through iCloud Keychain, so signing in on one device signs in the others.
public struct CredentialStore: Sendable {
    private let service = "ntfy.server-credential"
    private let accessGroup: String?
    private let synchronizable: Bool

    public init(accessGroup: String? = SharedContainer.appGroup, synchronizable: Bool = false) {
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    /// This device's own credential first, then one synced from another device.
    public func credential(for baseURL: URL) -> ServerCredential? {
        read(baseURL, synchronizable: false) ?? read(baseURL, synchronizable: true)
    }

    private func read(_ baseURL: URL, synchronizable: Bool) -> ServerCredential? {
        var query = baseQuery(baseURL)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredential.self, from: data)
    }

    /// Replaces the server's credential. A synchronizable store replaces it on every device; a device-only
    /// store leaves synced copies alone.
    public func save(_ credential: ServerCredential?, for baseURL: URL) throws {
        var existing = baseQuery(baseURL)
        existing[kSecAttrSynchronizable as String] = synchronizable ? kSecAttrSynchronizableAny : false
        SecItemDelete(existing as CFDictionary)
        guard let credential else { return }
        try add(credential, for: baseURL, synchronizable: synchronizable)
    }

    /// Moves this device's own credential into iCloud Keychain. The synced copy is added before the local one
    /// is deleted, so a failure leaves the local credential in place. When another device already synced a
    /// credential for the server, that one is kept and the local copy dropped, so later changes reach every device.
    public func makeSynchronizable(for baseURL: URL) {
        guard synchronizable, let credential = read(baseURL, synchronizable: false) else { return }
        if read(baseURL, synchronizable: true) == nil {
            guard (try? add(credential, for: baseURL, synchronizable: true)) != nil else { return }
        }
        var local = baseQuery(baseURL)
        local[kSecAttrSynchronizable as String] = false
        SecItemDelete(local as CFDictionary)
    }

    private func add(_ credential: ServerCredential, for baseURL: URL, synchronizable: Bool) throws {
        var item = baseQuery(baseURL)
        item[kSecValueData as String] = try JSONEncoder().encode(credential)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrSynchronizable as String] = synchronizable
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func baseQuery(_ baseURL: URL) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: baseURL.absoluteString,
            // The file-based macOS keychain neither syncs nor honors app group access groups
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

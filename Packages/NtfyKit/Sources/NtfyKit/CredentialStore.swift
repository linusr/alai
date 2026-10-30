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

    /// The synced credential first, so a change made on another device takes effect here, then this device's copy.
    public func credential(for baseURL: URL) -> ServerCredential? {
        read(baseURL, synchronizable: true) ?? read(baseURL, synchronizable: false)
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

    /// Replaces the server's credential. A synchronizable store replaces it on every device and also keeps a
    /// device copy, which survives signing out of iCloud; a device-only store leaves synced copies alone.
    public func save(_ credential: ServerCredential?, for baseURL: URL) throws {
        var existing = baseQuery(baseURL)
        existing[kSecAttrSynchronizable as String] = synchronizable ? kSecAttrSynchronizableAny : false
        SecItemDelete(existing as CFDictionary)
        guard let credential else { return }
        if synchronizable { try add(credential, for: baseURL, synchronizable: true) }
        try add(credential, for: baseURL, synchronizable: false)
    }

    /// Deletes only this device's copy, for a removal that another device already applied to the synced one.
    public func deleteDeviceCopy(for baseURL: URL) {
        var local = baseQuery(baseURL)
        local[kSecAttrSynchronizable as String] = false
        SecItemDelete(local as CFDictionary)
    }

    /// Copies this device's credential into iCloud Keychain unless another device already synced one.
    public func makeSynchronizable(for baseURL: URL) {
        guard synchronizable, read(baseURL, synchronizable: true) == nil, let credential = read(baseURL, synchronizable: false) else { return }
        try? add(credential, for: baseURL, synchronizable: true)
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

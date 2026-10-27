import Foundation
import Security

/// Server credentials in the keychain, shared with the notification service extension via the app group.
/// Synchronizable items travel through iCloud Keychain, so signing in on one device signs in the others.
public struct CredentialStore: Sendable {
    private let service = "ntfy.server-credential"
    private let accessGroup: String?
    private let synchronizable: Bool

    public init(accessGroup: String? = SharedContainer.appGroup, synchronizable: Bool = true) {
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    /// This device's own credential first, then one synced from another device.
    public func credential(for baseURL: URL) -> ServerCredential? {
        read(baseURL, synchronizable: false) ?? read(baseURL, synchronizable: true)
    }

    private func read(_ baseURL: URL, synchronizable: Any) -> ServerCredential? {
        var query = baseQuery(baseURL)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredential.self, from: data)
    }

    public func save(_ credential: ServerCredential?, for baseURL: URL) throws {
        var existing = baseQuery(baseURL)
        existing[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(existing as CFDictionary)
        guard let credential else { return }
        var item = baseQuery(baseURL)
        item[kSecValueData as String] = try JSONEncoder().encode(credential)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrSynchronizable as String] = synchronizable
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Re-saves this device's own credential as synchronizable, replacing any synced one for the same server.
    public func makeSynchronizable(for baseURL: URL) {
        guard synchronizable, let credential = read(baseURL, synchronizable: false) else { return }
        try? save(credential, for: baseURL)
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

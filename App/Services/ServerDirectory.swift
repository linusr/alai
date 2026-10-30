import Foundation
import Observation
import NtfyKit

/// Servers the user has added, with credentials in the shared keychain. The first server is the default.
@Observable
@MainActor
final class ServerDirectory {
    private static let serversKey = "servers"
    private static let addedKey = "serverAddedDates"
    private let defaults = SharedContainer.defaults
    private let credentials: CredentialStore = {
        #if DEBUG
        // Devices holding demo data must neither put demo passwords in iCloud Keychain nor delete real ones from it
        if DebugSeed.holdsDemoData { return CredentialStore() }
        #endif
        return CredentialStore(synchronizable: true)
    }()

    private(set) var servers: [URL]

    init() {
        servers = (defaults.stringArray(forKey: Self.serversKey) ?? []).compactMap(URL.init(string:))
    }

    var defaultServer: URL? { servers.first }

    func add(_ url: URL, credential: ServerCredential?) throws {
        try credentials.save(credential, for: url)
        if !servers.contains(url) {
            servers.append(url)
            setAddedDate(.now, for: url)
        }
        persist()
    }

    /// When this device added or adopted the server; servers from before this was recorded count as long ago.
    func addedDate(_ url: URL) -> Date {
        (defaults.dictionary(forKey: Self.addedKey)?[url.absoluteString] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
    }

    private func setAddedDate(_ date: Date?, for url: URL) {
        var dates = defaults.dictionary(forKey: Self.addedKey) ?? [:]
        dates[url.absoluteString] = date?.timeIntervalSince1970
        defaults.set(dates, forKey: Self.addedKey)
    }

    /// Adds a server another device synced; its credential arrives through iCloud Keychain.
    func adopt(_ url: URL) {
        guard !servers.contains(url) else { return }
        servers.append(url)
        setAddedDate(.now, for: url)
        persist()
    }

    /// Moves credentials saved before iCloud Keychain syncing into the synced keychain.
    func syncCredentials() {
        servers.forEach(credentials.makeSynchronizable)
    }

    /// Removes the server; `everywhere` also deletes its synced credential, which a removal arriving from
    /// another device leaves to that device.
    func remove(_ url: URL, everywhere: Bool = true) {
        if everywhere {
            try? credentials.save(nil, for: url)
        } else {
            credentials.deleteDeviceCopy(for: url)
        }
        servers.removeAll { $0 == url }
        setAddedDate(nil, for: url)
        persist()
    }

    func makeDefault(_ url: URL) {
        guard let index = servers.firstIndex(of: url) else { return }
        servers.insert(servers.remove(at: index), at: 0)
        persist()
    }

    func credential(for url: URL) -> ServerCredential? {
        credentials.credential(for: url)
    }

    func client(for url: URL) -> NtfyClient {
        NtfyClient(baseURL: url, credential: credential(for: url))
    }

    private func persist() {
        defaults.set(servers.map(\.absoluteString), forKey: Self.serversKey)
    }
}

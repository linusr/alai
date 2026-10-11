import Foundation

/// Hand-off of pushed messages from the notification service extension to the app. Each message is
/// its own file, so the extension never writes to the app's database and needs no locking.
public struct Inbox: Sendable {
    public struct Item: Codable, Sendable, Equatable {
        public let baseURL: URL
        public let message: Message
    }

    public let directory: URL

    public init(directory: URL = SharedContainer.url.appending(path: "Inbox", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    public func deposit(_ message: Message, baseURL: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Item(baseURL: baseURL, message: message))
        try data.write(to: directory.appending(path: "\(message.time)-\(message.id).json"), options: .atomic)
    }

    /// Messages waiting for the app to import them.
    public var count: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.count { $0.pathExtension == "json" }
    }

    /// Returns deposited items oldest first and deletes them.
    public func drain() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                defer { try? FileManager.default.removeItem(at: file) }
                return (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Item.self, from: $0) }
            }
    }
}

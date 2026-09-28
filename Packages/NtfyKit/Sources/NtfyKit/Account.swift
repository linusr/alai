import Foundation

/// Access granted to users other than the owner of a reserved topic.
public enum TopicAccess: String, Codable, CaseIterable, Sendable, Identifiable {
    case readWrite = "read-write"
    case readOnly = "read-only"
    case writeOnly = "write-only"
    case denyAll = "deny-all"

    public var id: Self { self }

    /// Describes the access given to everyone else on a reserved topic.
    public var label: String {
        switch self {
        case .denyAll: "Private"
        case .readOnly: "Anyone can read"
        case .writeOnly: "Anyone can publish"
        case .readWrite: "Public"
        }
    }

    /// Describes the access a grant gives its user.
    public var grantLabel: String {
        switch self {
        case .denyAll: "No access"
        case .readOnly: "Read"
        case .writeOnly: "Publish"
        case .readWrite: "Read and publish"
        }
    }
}

/// The signed-in user as returned by `GET /v1/account`.
public struct Account: Codable, Sendable, Equatable {
    public struct Reservation: Codable, Sendable, Equatable, Hashable {
        public let topic: String
        public let everyone: TopicAccess
    }

    /// Subscriptions synced from the ntfy web app.
    public struct SyncedSubscription: Codable, Sendable, Equatable, Hashable {
        public let baseURL: String
        public let topic: String
        public let displayName: String?

        enum CodingKeys: String, CodingKey {
            case topic
            case baseURL = "base_url"
            case displayName = "display_name"
        }
    }

    public struct Token: Codable, Sendable, Equatable, Hashable, Identifiable {
        public let token: String
        public let label: String?
        public let lastAccess: Int64?
        public let lastOrigin: String?
        public let expires: Int64?
        public let provisioned: Bool?

        enum CodingKeys: String, CodingKey {
            case token, label, expires, provisioned
            case lastAccess = "last_access"
            case lastOrigin = "last_origin"
        }

        public var id: String { token }
        public var expiryDate: Date? { expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
        public var lastAccessDate: Date? { lastAccess.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
    }

    public struct Limits: Codable, Sendable, Equatable {
        /// Seconds the server keeps this account's messages; its tier's value or the server's cache duration.
        public let messagesExpiryDuration: Int64?

        enum CodingKeys: String, CodingKey {
            case messagesExpiryDuration = "messages_expiry_duration"
        }
    }

    public let username: String
    public let role: String?
    public let subscriptions: [SyncedSubscription]?
    public let reservations: [Reservation]?
    /// The account's own access grants, reservations included. Only the Alai server sends it.
    public let access: [ServerUser.Grant]?
    public let tokens: [Token]?
    public let limits: Limits?

    public var isAdmin: Bool { role == "admin" }
    /// Anonymous visitors get a placeholder account named "*".
    public var isAnonymous: Bool { username == "*" }
}

/// A user and their access grants, as returned to admins by `GET /v1/users`.
public struct ServerUser: Codable, Sendable, Equatable {
    public struct Grant: Codable, Sendable, Equatable, Hashable {
        /// May be a pattern such as `backups_*`.
        public let topic: String
        public let permission: TopicAccess
    }

    public let username: String
    public let role: String
    public let grants: [Grant]?
}

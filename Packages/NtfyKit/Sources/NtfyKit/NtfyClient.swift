import Foundation

public enum ServerCredential: Codable, Hashable, Sendable {
    case basic(username: String, password: String)
    case token(String)

    public var authorizationHeader: String {
        switch self {
        case let .basic(username, password):
            "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case let .token(token):
            "Bearer " + token
        }
    }
}

public enum NtfyError: LocalizedError, Equatable {
    /// `code` is ntfy's error code from the JSON body, e.g. 40010, when the server sent one.
    case http(status: Int, message: String?, code: Int?)
    /// The server does not accept APNs registrations: not the APNs fork, or APNs not configured.
    case apnsUnavailable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .http(status, message?, _):
            "\(message) (HTTP \(status))"
        case let .http(status, nil, _):
            HTTPURLResponse.localizedString(forStatusCode: status).capitalized + " (HTTP \(status))"
        case .apnsUnavailable:
            "This server does not support APNs push."
        case .invalidResponse:
            "The server sent an unexpected response."
        }
    }
}

/// APNs gateway a device token belongs to. Xcode debug builds get sandbox tokens.
public enum PushEnvironment: String, Codable, Sendable {
    case production, sandbox
}

/// Client for one ntfy server.
public struct NtfyClient: Sendable {
    public let baseURL: URL
    public let credential: ServerCredential?
    private let session: URLSession

    public init(baseURL: URL, credential: ServerCredential? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credential = credential
        self.session = session
    }

    /// Cached messages for a topic, oldest first. `since` is a message ID, or nil for everything the server has cached.
    public func poll(topic: String, since: String? = nil) async throws -> [Message] {
        let data = try await get(topic: topic, query: [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since ?? "all"),
        ])
        return Message.decodeLines(data).filter { $0.kind == .message }
    }

    /// A single cached message, used to resolve poll requests.
    public func message(topic: String, id: String) async throws -> Message? {
        let data = try await get(topic: topic, query: [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "id", value: id),
        ])
        return Message.decodeLines(data).first { $0.id == id && $0.kind == .message }
    }

    @discardableResult
    public func publish(topic: String, message: String, title: String? = nil, priority: Priority? = nil, tags: [String] = []) async throws -> Message {
        var request = makeRequest(url: baseURL.appending(path: topic), method: "POST")
        request.httpBody = Data(message.utf8)
        if let title, !title.isEmpty { request.setValue(title, forHTTPHeaderField: "X-Title") }
        if let priority { request.setValue(String(priority.rawValue), forHTTPHeaderField: "X-Priority") }
        if !tags.isEmpty { request.setValue(tags.joined(separator: ","), forHTTPHeaderField: "X-Tags") }
        let data = try await send(request)
        return try JSONDecoder().decode(Message.self, from: data)
    }

    /// Registers the device for APNs delivery of the given topics, replacing any earlier topic list.
    /// Throws `apnsUnavailable` for servers without APNs support.
    public func registerDevice(token: String, environment: PushEnvironment, topics: [String]) async throws {
        struct Body: Encodable { let token: String; let environment: PushEnvironment; let topics: [String] }
        var request = makeRequest(url: baseURL.appending(path: "v1/apns"), method: "POST")
        request.httpBody = try JSONEncoder().encode(Body(token: token, environment: environment, topics: topics))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            try await send(request)
        } catch NtfyError.http(status: 404, _, _) {
            // The APNs fork answers 404 when apns-key-file is not set
            throw NtfyError.apnsUnavailable
        } catch NtfyError.http(status: 400, _, code: Self.topicDisallowedCode) {
            // Stock ntfy routes POST /v1/apns as a message update in the reserved topic "v1"
            throw NtfyError.apnsUnavailable
        }
    }

    private static let topicDisallowedCode = 40010

    public func unregisterDevice(token: String) async throws {
        struct Body: Encodable { let token: String }
        var request = makeRequest(url: baseURL.appending(path: "v1/apns"), method: "DELETE")
        request.httpBody = try JSONEncoder().encode(Body(token: token))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await send(request)
    }

    /// Checks that the server is reachable and, if a credential is set, that it is accepted.
    public func verify() async throws {
        let path = credential == nil ? "v1/health" : "v1/account"
        try await send(makeRequest(url: baseURL.appending(path: path), method: "GET"))
    }

    public func account() async throws -> Account {
        try await JSONDecoder().decode(Account.self, from: send(makeRequest(url: baseURL.appending(path: "v1/account"), method: "GET")))
    }

    /// All users and their grants. Requires an admin account.
    public func users() async throws -> [ServerUser] {
        try await JSONDecoder().decode([ServerUser].self, from: send(makeRequest(url: baseURL.appending(path: "v1/users"), method: "GET")))
    }

    /// Topics that currently have cached messages. Requires an admin account on an Alai server.
    public func activeTopics() async throws -> [String] {
        struct Response: Decodable { let topics: [String] }
        return try await JSONDecoder().decode(Response.self, from: send(makeRequest(url: baseURL.appending(path: "v1/topics"), method: "GET"))).topics
    }

    /// Reserves a topic for the signed-in user; `everyone` is the access left to all other users.
    public func reserve(topic: String, everyone: TopicAccess) async throws {
        struct Body: Encodable { let topic: String; let everyone: TopicAccess }
        var request = makeRequest(url: baseURL.appending(path: "v1/account/reservation"), method: "POST")
        request.httpBody = try JSONEncoder().encode(Body(topic: topic, everyone: everyone))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await send(request)
    }

    /// Creates an access token on the signed-in account; it carries all of the account's permissions.
    /// A nil `expires` creates a token that never expires.
    public func createToken(label: String, expires: Date?) async throws -> Account.Token {
        struct Body: Encodable { let label: String; let expires: Int64 }
        var request = makeRequest(url: baseURL.appending(path: "v1/account/token"), method: "POST")
        // The server treats 0 as "never" but applies a 72-hour default when the field is absent
        request.httpBody = try JSONEncoder().encode(Body(label: label, expires: expires.map { Int64($0.timeIntervalSince1970) } ?? 0))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await JSONDecoder().decode(Account.Token.self, from: send(request))
    }

    public func deleteToken(_ token: String) async throws {
        var request = makeRequest(url: baseURL.appending(path: "v1/account/token"), method: "DELETE")
        request.setValue(token, forHTTPHeaderField: "X-Token")
        try await send(request)
    }

    /// Streams new messages for the topics until cancelled. The server sends keepalives, so a
    /// stalled connection surfaces as a timeout error for the caller to reconnect.
    public func stream(topics: [String], since: String?) -> AsyncThrowingStream<Message, Error> {
        var query = [URLQueryItem]()
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        var request = makeRequest(url: baseURL.appending(path: "\(topics.joined(separator: ","))/json").appending(queryItems: query), method: "GET")
        request.timeoutInterval = 90
        let streamRequest = request
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: streamRequest)
                    guard let http = response as? HTTPURLResponse else { throw NtfyError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else { throw NtfyError.http(status: http.statusCode, message: nil, code: nil) }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if let message = try? decoder.decode(Message.self, from: Data(line.utf8)), message.kind == .message {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Performs an ntfy "http" action button.
    public func perform(_ action: Action) async throws {
        guard let urlString = action.url, let url = URL(string: urlString) else { throw NtfyError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = action.method ?? "POST"
        request.httpBody = action.body.map { Data($0.utf8) }
        action.headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        try await send(request)
    }

    private func get(topic: String, query: [URLQueryItem]) async throws -> Data {
        let url = baseURL.appending(path: "\(topic)/json").appending(queryItems: query)
        return try await send(makeRequest(url: url, method: "GET"))
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let credential { request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization") }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NtfyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ServerError: Decodable { let error: String; let code: Int? }
            let body = try? JSONDecoder().decode(ServerError.self, from: data)
            throw NtfyError.http(status: http.statusCode, message: body?.error, code: body?.code)
        }
        return data
    }
}

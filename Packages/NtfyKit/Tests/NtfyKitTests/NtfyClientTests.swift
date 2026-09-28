import Foundation
import Testing
@testable import NtfyKit

/// Serves canned responses and records requests. Tests using it run serially.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            recorded.httpBody = body
        }
        Self.requests.append(recorded)
        let (status, data) = Self.handler?(request) ?? (200, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct NtfyClientTests {
    let client: NtfyClient

    init() {
        StubProtocol.requests = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = NtfyClient(baseURL: URL(string: "https://ntfy.example.com")!, credential: .basic(username: "ben", password: "pw"), session: URLSession(configuration: config))
    }

    @Test func pollKeepsOnlyMessages() async throws {
        StubProtocol.handler = { _ in (200, Data("""
        {"id":"o","time":1,"event":"open","topic":"t"}
        {"id":"a","time":2,"event":"message","topic":"t","message":"hi"}
        """.utf8)) }
        let messages = try await client.poll(topic: "t", since: "xyz")
        #expect(messages.map(\.id) == ["a"])
        let url = try #require(StubProtocol.requests.first?.url)
        #expect(url.path() == "/t/json")
        #expect(url.query()?.contains("since=xyz") == true)
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Basic YmVuOnB3")
    }

    @Test func registerDeviceSendsJSON() async throws {
        try await client.registerDevice(token: "abcd", environment: .sandbox, topics: ["a", "b"])
        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/apns")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["token"] as? String == "abcd")
        #expect(body?["environment"] as? String == "sandbox")
        #expect(body?["topics"] as? [String] == ["a", "b"])
    }

    @Test func serverErrorIsSurfaced() async {
        StubProtocol.handler = { _ in (403, Data(#"{"code":40301,"http":403,"error":"forbidden"}"#.utf8)) }
        await #expect(throws: NtfyError.http(status: 403, message: "forbidden", code: 40301)) {
            try await client.poll(topic: "t")
        }
    }

    @Test(arguments: [
        (404, #"{"code":40401,"http":404,"error":"page not found"}"#),
        (400, #"{"code":40010,"http":400,"error":"invalid request: topic name is not allowed"}"#),
    ])
    func registerDeviceDetectsServersWithoutAPNs(status: Int, body: String) async {
        StubProtocol.handler = { _ in (status, Data(body.utf8)) }
        await #expect(throws: NtfyError.apnsUnavailable) {
            try await client.registerDevice(token: "abcd", environment: .production, topics: ["a"])
        }
    }

    @Test func registerDeviceSurfacesOtherErrors() async {
        StubProtocol.handler = { _ in (403, Data(#"{"code":40301,"http":403,"error":"forbidden"}"#.utf8)) }
        await #expect(throws: NtfyError.http(status: 403, message: "forbidden", code: 40301)) {
            try await client.registerDevice(token: "abcd", environment: .production, topics: ["a"])
        }
    }

    @Test func publishSetsHeaders() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"id":"n","time":3,"event":"message","topic":"t","message":"hello"}"#.utf8)) }
        let message = try await client.publish(topic: "t", message: "hello", title: "Hi", priority: .high, tags: ["tada"])
        #expect(message.id == "n")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Priority") == "4")
        #expect(request.value(forHTTPHeaderField: "X-Tags") == "tada")
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == "hello")
    }

    @Test func accountDecodes() async throws {
        StubProtocol.handler = { _ in (200, Data("""
        {"username":"ben","role":"admin","sync_topic":"st","subscriptions":[{"base_url":"https://ntfy.example.com","topic":"backups","display_name":null}],
         "reservations":[{"topic":"alerts","everyone":"deny-all"}],"access":[{"topic":"garage","permission":"read-only"}],"limits":{"basis":"tier","messages_expiry_duration":2592000},"tokens":[{"token":"tk_abc","label":"garage","last_access":1727200000,"expires":0}]}
        """.utf8)) }
        let account = try await client.account()
        #expect(account.isAdmin)
        #expect(account.reservations == [Account.Reservation(topic: "alerts", everyone: .denyAll)])
        #expect(account.subscriptions?.first?.topic == "backups")
        #expect(account.access == [ServerUser.Grant(topic: "garage", permission: .readOnly)])
        #expect(account.limits?.messagesExpiryDuration == 2_592_000)
        #expect(account.tokens?.first?.label == "garage")
        #expect(account.tokens?.first?.expiryDate == nil)
        #expect(account.tokens?.first?.lastAccessDate != nil)
    }

    @Test func activeTopicsDecodes() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"topics":["alerts","weather"]}"#.utf8)) }
        #expect(try await client.activeTopics() == ["alerts", "weather"])
        #expect(StubProtocol.requests.first?.url?.path() == "/v1/topics")
    }

    @Test func reserveSendsAccessLevel() async throws {
        try await client.reserve(topic: "alerts", everyone: .writeOnly)
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.path() == "/v1/account/reservation")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["everyone"] as? String == "write-only")
    }

    @Test func createAndDeleteToken() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"token":"tk_new","label":"garage","expires":1800000000}"#.utf8)) }
        let token = try await client.createToken(label: "garage", expires: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(token.token == "tk_new")
        let body = try JSONSerialization.jsonObject(with: try #require(StubProtocol.requests.first?.httpBody)) as? [String: Any]
        #expect(body?["expires"] as? Int == 1_800_000_000)

        _ = try await client.createToken(label: "forever", expires: nil)
        let neverBody = try JSONSerialization.jsonObject(with: try #require(StubProtocol.requests.last?.httpBody)) as? [String: Any]
        #expect(neverBody?["expires"] as? Int == 0)

        try await client.deleteToken("tk_new")
        let delete = try #require(StubProtocol.requests.last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.value(forHTTPHeaderField: "X-Token") == "tk_new")
    }

    @Test func usersDecodeGrants() async throws {
        StubProtocol.handler = { _ in (200, Data(#"[{"username":"ben","role":"user","grants":[{"topic":"backups_*","permission":"read-only"}]},{"username":"*","role":"anonymous"}]"#.utf8)) }
        let users = try await client.users()
        #expect(users.count == 2)
        #expect(users[0].grants == [ServerUser.Grant(topic: "backups_*", permission: .readOnly)])
        #expect(users[1].grants == nil)
    }

    @Test func streamYieldsMessages() async throws {
        StubProtocol.handler = { _ in (200, Data("""
        {"id":"o","time":1,"event":"open","topic":"a,b"}
        {"id":"m1","time":2,"event":"message","topic":"a","message":"one"}
        {"id":"k","time":3,"event":"keepalive","topic":"a,b"}
        {"id":"m2","time":4,"event":"message","topic":"b","message":"two"}

        """.utf8)) }
        var ids: [String] = []
        for try await message in client.stream(topics: ["a", "b"], since: "xyz") {
            ids.append(message.id)
        }
        #expect(ids == ["m1", "m2"])
        #expect(StubProtocol.requests.first?.url?.path() == "/a,b/json")
    }
}

import XCTest
@testable import Spotified

private final class APIFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class SpotifiedAPITests: XCTestCase {
    private let state = #"{"account":{"status":"connected","message":"Spotify connected"},"jobs":[],"server":"Fixture server","destination":"/music","csrf_token":"fixture-csrf"}"#
    private let settings = #"{"layout":"albums","playlist_layout":"library","format":"copy","quality":"auto","bitrate":"best","music_path":"/music","podcast_path":"/podcasts","FETCH_DELAY":2,"BULK_WAIT_TIME":30,"RETRY_DELAY":30,"RETRY_ATTEMPTS":3,"ESCALATING_DELAY":true,"ALBUM_ART_TO_FILE":true,"EXPORT_M3U8":true,"M3U8_REL_PATHS":true,"LYRICS_TO_METADATA":true,"LYRICS_TO_FILE":true,"SKIP_EXISTING":true}"#
    private func client() -> SpotifiedAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIFixture.self]
        return SpotifiedAPI(address: ServerAddress("https://fixture.test:8443")!, configuration: configuration)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func testQueueSendsAuthenticatedCommandAndNeverFetchesAudio() async throws {
        var paths: [String] = []
        var queued: [String: Any] = [:]
        let state = self.state
        APIFixture.handler = { request in
            let path = request.url!.path; paths.append(path)
            XCTAssertEqual(request.url!.host, "fixture.test")
            if path == "/api/health" { return (200, [:], Data(#"{"service":"spotified","status":"ok"}"#.utf8)) }
            if path == "/api/session" {
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Set-Cookie":"spotified_session=fixture-cookie; Path=/; Secure; HttpOnly"], Data("{}".utf8))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "spotified_session=fixture-cookie")
            if path == "/api/state" { return (200, [:], Data(state.utf8)) }
            XCTAssertEqual(path, "/api/jobs")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Spotified-Token"), "fixture-csrf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://fixture.test:8443")
            queued = try self.body(request)
            return (201, [:], Data("{}".utf8))
        }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        try await api.login(username: "fixture", password: "fixture-password")
        try await api.queue(urls: "https://open.spotify.com/track/fixture", format: "copy", quality: "auto", bitrate: "best", preview: false)
        XCTAssertEqual(paths, ["/api/health", "/api/session", "/api/state", "/api/jobs"])
        XCTAssertEqual(queued["format"] as? String, "copy")
        XCTAssertEqual(queued["preview"] as? Bool, false)
        XCTAssertEqual(queued["urls"] as? String, "https://open.spotify.com/track/fixture")
    }
    func testSpotifySelectionUsesServerQueueAndCSRF() async throws {
        let state = self.state
        var paths: [String] = []
        APIFixture.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.url!.host, "fixture.test")
            if request.url!.path == "/api/state" { return (200, [:], Data(state.utf8)) }
            XCTAssertEqual(request.url!.path, "/api/spotify/import")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Spotified-Token"), "fixture-csrf")
            let body = try self.body(request)
            XCTAssertEqual(body["uris"] as? [String], ["spotify:track:aaaaaaaaaaaaaaaaaaaaaa"])
            XCTAssertEqual(body["format"] as? String, "mp3")
            return (201, [:], Data(#"{"jobs":[]}"#.utf8))
        }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        try await api.saveSpotify(uris: ["spotify:track:aaaaaaaaaaaaaaaaaaaaaa"], format: "mp3", quality: "auto", bitrate: "best")
        XCTAssertEqual(paths, ["/api/state", "/api/spotify/import"])
    }
    func testSettingsDiffPreservesUneditedServerValuesAndZero() throws {
        let original = try JSONDecoder().decode(ServerSettings.self, from: Data(settings.utf8))
        var draft = original; draft.fetchDelay = 0; draft.albumArt = false
        let changes = try draft.changes(from: original)
        XCTAssertEqual(Set(changes.keys), ["FETCH_DELAY", "ALBUM_ART_TO_FILE"])
        XCTAssertEqual(changes["FETCH_DELAY"] as? Double, 0)
        XCTAssertEqual(changes["ALBUM_ART_TO_FILE"] as? Bool, false)
        XCTAssertTrue(try original.changes(from: original).isEmpty)
    }
    func testRejectedMutationIsNotAutomaticallyRetried() async throws {
        var posts = 0
        let state = self.state
        APIFixture.handler = { request in
            if request.url!.path == "/api/state" { return (200, [:], Data(state.utf8)) }
            posts += 1; return (503, [:], Data(#"{"error":"Server busy"}"#.utf8))
        }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        do { try await api.jobAction(id: String(repeating: "a", count: 32), action: "restart"); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Server busy") }
        XCTAssertEqual(posts, 1)
    }
    func testArtworkCannotFetchMediaOrOtherOrigins() async throws {
        var requests = 0
        APIFixture.handler = { _ in requests += 1; return (200, [:], Data()) }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        for path in ["/media?root=music&path=song.ogg", "https://other.test/artwork?a=b", "//other.test/artwork?a=b"] {
            do { _ = try await api.artwork(path); XCTFail("Unsafe artwork URL accepted") } catch {}
        }
        XCTAssertEqual(requests, 0)
    }
    func testExpiredSessionRequiresLogin() async throws {
        APIFixture.handler = { _ in (401, [:], Data("{}".utf8)) }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        do { _ = try await api.state(); XCTFail("Expected expired session") }
        catch ClientError.signedOut {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testSpotifyLoginAndCallbackAreAuthenticatedServerCommands() async throws {
        let state = self.state
        let id = String(repeating: "a", count: 32)
        var writes: [String] = []
        APIFixture.handler = { request in
            let path = request.url!.path
            if path == "/api/health" { return (200, [:], Data(#"{"service":"spotified","status":"ok"}"#.utf8)) }
            if path == "/api/session" { return (200, ["Set-Cookie":"spotified_session=fixture-cookie; Path=/; Secure; HttpOnly"], Data("{}".utf8)) }
            if path == "/api/state" { return (200, [:], Data(state.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "spotified_session=fixture-cookie")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Spotified-Token"), "fixture-csrf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://fixture.test:8443")
            writes.append(path)
            if path == "/api/login" {
                let body = try self.body(request)
                XCTAssertEqual(body["mode"] as? String, "client")
                XCTAssertEqual(body["callback_port"] as? Int, 4381)
                return (201, [:], try JSONSerialization.data(withJSONObject: ["job": ["id": id, "urls": [], "status": "queued", "message": "Waiting", "logs": [], "total": 0, "completed": 0, "kind": "login"]]))
            }
            XCTAssertEqual(try self.body(request)["url"] as? String, "http://127.0.0.1:4381/login?state=state&code=code")
            return (200, [:], Data("{}".utf8))
        }
        let api = client(); defer { api.invalidate(); APIFixture.handler = nil }
        try await api.login(username: "fixture", password: "fixture-password")
        let job = try await api.spotifyLogin(check: false)
        XCTAssertEqual(job.id, id)
        try await api.spotifyCallback(id: job.id, url: "http://127.0.0.1:4381/login?state=state&code=code")
        XCTAssertEqual(writes, ["/api/login", "/api/jobs/\(id)/spotify-callback"])
    }
}

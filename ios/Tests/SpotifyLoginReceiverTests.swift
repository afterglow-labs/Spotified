import XCTest
@testable import Spotified

@MainActor final class SpotifyLoginReceiverTests: XCTestCase {
    func testLoopbackCallbackRejectsWrongStateThenReceivesValidCallback() async throws {
        let receiver = SpotifyLoginReceiver()
        let port = try await receiver.start(port: 0)
        defer { receiver.stop() }
        var authorization = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorization.queryItems = [URLQueryItem(name: "state", value: "fixture-state"), URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)/login")]
        try receiver.configure(authorizationURL: authorization.url!)
        let invalid = URL(string: "http://127.0.0.1:\(port)/login?state=wrong&code=fixture")!
        let (_, rejected) = try await URLSession.shared.data(from: invalid)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertNil(receiver.callbackURL)
        let valid = URL(string: "http://127.0.0.1:\(port)/login?state=fixture-state&code=fixture")!
        let (_, accepted) = try await URLSession.shared.data(from: valid)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(receiver.callbackURL, valid.absoluteString)
        XCTAssertFalse(receiver.accepts(URL(string: "http://127.0.0.1:\(port)/login?state=fixture-state&state=wrong&code=fixture")!))
        XCTAssertFalse(receiver.accepts(URL(string: "http://attacker.test:\(port)/login?state=fixture-state&code=fixture")!))
    }

    func testAuthorizationURLMustMatchSpotifyAndLocalReceiver() async throws {
        let receiver = SpotifyLoginReceiver()
        for url in ["https://attacker.test/authorize?state=s&redirect_uri=http://127.0.0.1:4381/login",
                    "https://accounts.spotify.com/authorize?state=s&redirect_uri=http://attacker.test:4381/login",
                    "https://accounts.spotify.com/authorize?redirect_uri=http://127.0.0.1:4381/login"] {
            XCTAssertThrowsError(try receiver.configure(authorizationURL: URL(string: url)!))
        }
    }
}

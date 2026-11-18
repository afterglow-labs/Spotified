import XCTest
@testable import Spotified

final class ServerAddressTests: XCTestCase {
    func testNormalizesOriginAndPreservesServerPort() {
        XCTAssertEqual(ServerAddress("  https://Example.com:8443/\n")?.origin, "https://example.com:8443")
        XCTAssertEqual(ServerAddress("https://example.com:443")?.origin, "https://example.com")
    }
    func testRejectsUnsafeOrigins() {
        for value in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=secret", "https://example.com#x", "https://example.com:99999", "javascript:alert(1)", ""] {
            XCTAssertNil(ServerAddress(value), value)
        }
    }
    func testOriginBoundaryUsesSchemeHostAndPort() {
        let address = ServerAddress("https://example.com:8443")!
        XCTAssertTrue(address.contains(URL(string: "https://example.com:8443/api/state")!))
        for value in ["https://example.com/api/state", "http://example.com:8443", "https://example.com.attacker.test:8443"] {
            XCTAssertFalse(address.contains(URL(string: value)!))
        }
        XCTAssertTrue(ServerAddress("https://example.com")!.contains(URL(string: "https://example.com:443/")!))
    }
    func testKeychainRoundTripIsScopedToServerAndUser() throws {
        let origin = "https://" + UUID().uuidString.lowercased() + ".test"
        defer { LoginStore.delete(origin: origin, username: "test") }
        try LoginStore.save("temporary-test-password", origin: origin, username: "test")
        XCTAssertEqual(LoginStore.read(origin: origin, username: "test"), "temporary-test-password")
        XCTAssertNil(LoginStore.read(origin: origin, username: "other"))
        try LoginStore.save("updated-test-password", origin: origin, username: "test")
        XCTAssertEqual(LoginStore.read(origin: origin, username: "test"), "updated-test-password")
        LoginStore.delete(origin: origin, username: "test")
        XCTAssertNil(LoginStore.read(origin: origin, username: "test"))
    }
}

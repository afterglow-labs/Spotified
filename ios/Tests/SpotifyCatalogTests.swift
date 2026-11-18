import XCTest
@testable import Spotified

final class SpotifyCatalogTests: XCTestCase {
    func testSearchQueryCannotChangeServerParameters() throws {
        let value = SpotifyCatalogRequest(view: "search", query: "R&B + café #1?view=liked", kind: "track")
        let components = try XCTUnwrap(URLComponents(string: value.path(offset: 20)))
        XCTAssertEqual(components.path, "/api/spotify")
        XCTAssertNil(components.host)
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["q"], "R&B + café #1?view=liked")
        XCTAssertEqual(query["view"], "search")
        XCTAssertEqual(query["offset"], "20")
    }
    func testUnavailableCatalogItemsAndFinalPageDecode() throws {
        let json = #"{"items":[{"uri":"spotify:playlist:aaaaaaaaaaaaaaaaaaaaaa","kind":"playlist","name":"Unavailable playlist","subtitle":"Playlist","artwork":"https://untrusted.test/image","available":false}],"total":75,"offset":60,"next_offset":null,"title":"Your playlists"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(SpotifyCatalogPage.self, from: Data(json.utf8))
        XCTAssertNil(page.nextOffset)
        XCTAssertFalse(page.items[0].canSave)
        XCTAssertNil(page.items[0].imageURL)
    }
}

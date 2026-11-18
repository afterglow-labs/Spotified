import XCTest
@testable import Spotified

final class LibraryIndexTests: XCTestCase {
    private func track(_ id: String, artist: String = "Artist", albumArtist: String = "", album: String = "Album", disc: Int = 1, number: Int = 1, year: String = "2000", modified: Double = 1) throws -> MusicTrack {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "name": id, "title": id, "artist": artist, "album_artist": albumArtist, "album": album, "genre": "", "duration": 20, "track_number": number, "disc_number": disc, "year": year, "modified": modified, "folder": "", "size": 1, "artwork": ""])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MusicTrack.self, from: data)
    }
    func testArtistAlbumsStaySeparateFromOtherArtistsAndFeaturedPerformers() throws {
        let tracks = try [track("one", artist: "Artist featuring Guest", albumArtist: "Artist", album: "First"), track("two", artist: "artist", album: "Second"), track("three", artist: "Other", album: "First")]
        let artists = LibraryIndex.groups(tracks, artists: true)
        XCTAssertEqual(artists.count, 2)
        let selected = try XCTUnwrap(artists.first { $0.id == "artist" })
        XCTAssertEqual(LibraryIndex.groups(selected.tracks, artists: false).map(\.name), ["First", "Second"])
        XCTAssertEqual(LibraryIndex.groups(tracks, artists: false).count, 3)
    }
    func testAlbumsSortByReleaseYearAndRecentlyAddedWithUnknownYearsLast() throws {
        let tracks = try [track("a", album: "Old", year: "1999", modified: 20), track("b", album: "New", year: "2024", modified: 10), track("c", album: "Unknown", year: "", modified: 30)]
        XCTAssertEqual(LibraryIndex.groups(tracks, artists: false, sort: .newest).map(\.name), ["New", "Old", "Unknown"])
        XCTAssertEqual(LibraryIndex.groups(tracks, artists: false, sort: .oldest).map(\.name), ["Old", "New", "Unknown"])
        XCTAssertEqual(LibraryIndex.groups(tracks, artists: false, sort: .recent).map(\.name), ["Unknown", "Old", "New"])
    }
    func testAlbumOrderUsesDiscThenTrackAndSearchFindsArtistThroughSong() throws {
        let tracks = try [track("Disc 2", disc: 2, number: 1), track("Second song", number: 2), track("First song", number: 1)]
        XCTAssertEqual(LibraryIndex.orderedTracks(tracks).map(\.title), ["First song", "Second song", "Disc 2"])
        XCTAssertEqual(LibraryIndex.groups(tracks, artists: true, query: "second").count, 1)
        XCTAssertTrue(LibraryIndex.groups(tracks, artists: true, query: "absent").isEmpty)
    }
}

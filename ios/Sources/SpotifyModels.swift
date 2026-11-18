import Foundation

struct SpotifyCatalogItem: Decodable, Identifiable, Hashable {
    let uri: String
    let kind: String
    let name: String
    let subtitle: String
    let artwork: String
    let available: Bool
    var id: String { uri }
    var isCollection: Bool { ["album", "playlist", "artist"].contains(kind) }
    var canSave: Bool { available && kind != "artist" }
    var imageURL: URL? {
        guard let url = URL(string: artwork), url.scheme == "https",
              ["i.scdn.co", "mosaic.scdn.co"].contains(url.host ?? "") else { return nil }
        return url
    }
}

struct SpotifyCatalogPage: Decodable {
    let items: [SpotifyCatalogItem]
    let total: Int
    let offset: Int
    let nextOffset: Int?
    let title: String
}

struct SpotifyCatalogRequest: Equatable {
    var view = "playlists"
    var query = ""
    var kind = "track"
    var uri = ""
    func path(offset: Int = 0, refresh: Bool = false) -> String {
        var components = URLComponents()
        components.path = "/api/spotify"
        components.queryItems = [URLQueryItem(name: "view", value: view), URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "refresh", value: refresh ? "1" : "0")]
        return components.string!
    }
}

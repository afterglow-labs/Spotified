import Foundation

enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "Name A–Z", reverseName = "Name Z–A", newest = "Newest release", oldest = "Oldest release", recent = "Recently added"
    var id: String { rawValue }
}
struct MusicGroup: Identifiable {
    let id: String
    let name: String
    let detail: String
    let tracks: [MusicTrack]
    var year: Int? { tracks.compactMap { Int($0.year ?? "") }.max() }
    var modified: Double { tracks.compactMap(\.modified).max() ?? 0 }
}
enum LibraryIndex {
    static func orderedTracks(_ tracks: [MusicTrack]) -> [MusicTrack] {
        tracks.sorted {
            let a = ($0.discNumber ?? 1, $0.trackNumber == 0 ? Int.max : $0.trackNumber)
            let b = ($1.discNumber ?? 1, $1.trackNumber == 0 ? Int.max : $1.trackNumber)
            if a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    static func groups(_ tracks: [MusicTrack], artists: Bool, query: String = "", sort: LibrarySort = .name) -> [MusicGroup] {
        Dictionary(grouping: tracks, by: { artists ? $0.artistID : $0.albumID }).compactMap { key, items in
            guard let first = items.first else { return nil }
            let name = artists ? first.artistName : first.album
            let count = Set(items.map(\.albumID)).count
            let detail = artists ? "\(count) \(count == 1 ? "album" : "albums")" : first.artistName
            guard query.isEmpty || "\(name) \(detail)".localizedCaseInsensitiveContains(query)
                    || items.contains(where: { "\($0.title) \($0.album)".localizedCaseInsensitiveContains(query) }) else { return nil }
            return MusicGroup(id: key, name: name, detail: detail, tracks: orderedTracks(items))
        }.sorted { a, b in
            switch sort {
            case .recent: if a.modified != b.modified { return a.modified > b.modified }
            case .newest, .oldest:
                if a.year != b.year {
                    guard let first = a.year else { return false }
                    guard let second = b.year else { return true }
                    return sort == .newest ? first > second : first < second
                }
            default: break
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison == .orderedSame { return a.id < b.id }
            return comparison == (sort == .reverseName ? .orderedDescending : .orderedAscending)
        }
    }
}

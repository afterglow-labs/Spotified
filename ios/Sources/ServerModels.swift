import Foundation

struct ServerState: Decodable {
    struct Account: Decodable { let status: String; let message: String }
    let account: Account
    let jobs: [DownloadJob]
    let server: String
    let destination: String
    let csrfToken: String
}

struct DownloadJob: Decodable, Identifiable {
    let id: String
    let urls: [String]
    let status: String
    let message: String
    let logs: [String]
    let names: [String]?
    let total: Int
    let completed: Int
    let kind: String?
    let format: String?
    let preview: Bool?
    let createdAt: String?
    let restartOf: String?
    let loginUrl: String?
    let loginMode: String?
    var isActive: Bool { !["completed", "previewed", "partial", "failed", "cancelled", "interrupted"].contains(status) }
    var canRestart: Bool { kind != "login" && !urls.isEmpty && ["partial", "failed", "cancelled", "interrupted"].contains(status) }
    var title: String { names?.first ?? (kind == "login" ? "Spotify connection" : urls.first ?? "Download") }
}

struct MusicLibrary: Decodable {
    var tracks: [MusicTrack]
    var playlists: [MusicPlaylist]
    var truncated: Bool
    static let empty = MusicLibrary(tracks: [], playlists: [], truncated: false)
}

struct MusicTrack: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let genre: String
    let duration: Double
    let trackNumber: Int
    let discNumber: Int?
    let year: String?
    let modified: Double?
    let folder: String
    let name: String
    let size: Int64
    let artwork: String
    var artistName: String { (albumArtist.isEmpty ? artist : albumArtist).trimmingCharacters(in: .whitespacesAndNewlines) }
    var artistID: String { artistName.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    var albumID: String { artistID + "\u{0}" + album.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    var durationLabel: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}

struct MusicPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let tracks: [String]
    let unavailable: Int
}

struct ServerSettings: Codable, Equatable {
    var layout: String
    var playlistLayout: String
    var format: String
    var quality: String
    var bitrate: String
    var musicPath: String
    var podcastPath: String
    var fetchDelay: Double
    var bulkWait: Double
    var retryDelay: Double
    var retryAttempts: Int
    var escalatingDelay: Bool
    var albumArt: Bool
    var exportM3U8: Bool
    var relativePlaylists: Bool
    var lyricsMetadata: Bool
    var lyricsFile: Bool
    var skipExisting: Bool

    enum CodingKeys: String, CodingKey {
        case layout, format, quality, bitrate
        case playlistLayout = "playlist_layout", musicPath = "music_path", podcastPath = "podcast_path"
        case fetchDelay = "FETCH_DELAY", bulkWait = "BULK_WAIT_TIME", retryDelay = "RETRY_DELAY", retryAttempts = "RETRY_ATTEMPTS"
        case escalatingDelay = "ESCALATING_DELAY", albumArt = "ALBUM_ART_TO_FILE", exportM3U8 = "EXPORT_M3U8"
        case relativePlaylists = "M3U8_REL_PATHS", lyricsMetadata = "LYRICS_TO_METADATA", lyricsFile = "LYRICS_TO_FILE", skipExisting = "SKIP_EXISTING"
    }

    func changes(from original: ServerSettings) throws -> [String: Any] {
        let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: NSObject]
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: NSObject]
        return data.filter { !["music_path", "podcast_path"].contains($0.key) && old[$0.key] != $0.value }
    }
}

enum AudioChoices {
    static let formats = [("copy", "Original source"), ("mp3", "MP3"), ("aac", "AAC"), ("opus", "Opus")]
    static let qualities = [("auto", "Best available"), ("very_high", "Very high"), ("high", "High"), ("normal", "Normal")]
    static let bitrates = [("best", "Best for format"), ("auto", "Match source"), ("320k", "320 kbps"), ("256k", "256 kbps"), ("192k", "192 kbps"), ("160k", "160 kbps"), ("128k", "128 kbps"), ("96k", "96 kbps")]
}

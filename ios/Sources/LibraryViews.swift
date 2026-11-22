import SwiftUI

struct CoverView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let path: String
    var size: CGFloat = 48
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            theme.accent.opacity(0.12)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.title2).foregroundStyle(theme.accent) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: server.origin + path) { image = await server.artwork(path) }
    }
}

struct TrackRow: View {
    let track: MusicTrack
    var body: some View {
        HStack(spacing: 12) {
            CoverView(path: track.artwork)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.body.weight(.medium)).lineLimit(2)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if track.duration > 0 { Text(track.durationLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}

struct LibraryView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @State private var query = ""
    @AppStorage("artistSort") private var sort = LibrarySort.name.rawValue
    private var artists: [MusicGroup] { LibraryIndex.groups(server.library.tracks, artists: true, query: query, sort: LibrarySort(rawValue: sort) ?? .name) }
    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(server.state?.server ?? "Music server", systemImage: "server.rack").font(.subheadline.weight(.medium))
                        Text("\(server.library.tracks.count) songs · \(server.library.playlists.count) playlists").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.listRowBackground(theme.panel)
                Section("Browse") {
                    NavigationLink { CollectionBrowser(mode: .artists) } label: { Label("Artists", systemImage: "person.2") }.accessibilityIdentifier("browseArtists")
                    NavigationLink { CollectionBrowser(mode: .albums) } label: { Label("Albums", systemImage: "square.stack") }.accessibilityIdentifier("browseAlbums")
                    NavigationLink { TrackListView(title: "Songs", tracks: server.library.tracks, preserveOrder: true) } label: { Label("Songs", systemImage: "music.note") }.accessibilityIdentifier("browseSongs")
                    NavigationLink { PlaylistBrowser() } label: { Label("Playlists", systemImage: "music.note.list") }.accessibilityIdentifier("browsePlaylists")
                }.listRowBackground(theme.panel)
            }
            Section(query.isEmpty ? "Artists" : "Matching artists and collections") {
                if artists.isEmpty { ContentUnavailableView(query.isEmpty ? "Your library is ready" : "No matches", systemImage: "music.note", description: Text(query.isEmpty ? "Add a Spotify link to download music to your server." : "Try a song, artist, or album name.")) }
                ForEach(artists) { group in
                    NavigationLink { CollectionBrowser(mode: .albums, artistID: group.id, title: group.name) } label: { CollectionRow(group: group) }
                        .accessibilityIdentifier("artist-" + group.id)
                }
            }.listRowBackground(theme.panel)
            if server.library.truncated { Text("Showing the first 20,000 library files.").font(.caption) }
        }.navigationTitle("Library").appSurface()
            .searchable(text: $query, prompt: "Songs, artists, albums")
            .refreshable { await server.refresh() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LibrarySortMenu(selection: $sort, artists: true) } }
    }
}

enum CollectionMode: String { case albums = "Albums", artists = "Artists" }
struct LibrarySortMenu: View {
    @Binding var selection: String
    var artists = false
    var body: some View {
        Menu {
            Picker("Sort by", selection: $selection) {
                ForEach(LibrarySort.allCases.filter { !artists || ![.newest, .oldest].contains($0) }) { Text($0.rawValue).tag($0.rawValue) }
            }
        } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort library").accessibilityIdentifier("sortLibrary")
    }
}
struct CollectionRow: View {
    let group: MusicGroup
    var body: some View {
        HStack(spacing: 12) {
            CoverView(path: group.tracks.first?.artwork ?? "")
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).fontWeight(.medium)
                Text("\(group.detail) · \(group.tracks.count) \(group.tracks.count == 1 ? "song" : "songs")").font(.caption).foregroundStyle(.secondary)
                if let year = group.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
}
struct CollectionBrowser: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let mode: CollectionMode
    var artistID: String? = nil
    var title: String? = nil
    @State private var query = ""
    @AppStorage("albumSort") private var albumSort = LibrarySort.name.rawValue
    @AppStorage("artistSort") private var artistSort = LibrarySort.name.rawValue
    private var groups: [MusicGroup] {
        LibraryIndex.groups(server.library.tracks.filter { artistID == nil || $0.artistID == artistID }, artists: mode == .artists,
                            query: query, sort: LibrarySort(rawValue: mode == .artists ? artistSort : albumSort) ?? .name)
    }
    var body: some View {
        List(groups) { group in
            NavigationLink {
                if mode == .artists { CollectionBrowser(mode: .albums, artistID: group.id, title: group.name) }
                else { TrackListView(title: group.name, tracks: group.tracks, isAlbum: true) }
            } label: { CollectionRow(group: group) }.listRowBackground(theme.panel)
                .accessibilityIdentifier((mode == .artists ? "artist-" : "album-") + group.id)
        }.navigationTitle(title ?? mode.rawValue).appSurface().searchable(text: $query, prompt: mode == .artists ? "Find an artist" : "Find an album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LibrarySortMenu(selection: mode == .artists ? $artistSort : $albumSort, artists: mode == .artists) } }
    }
}

struct PlaylistBrowser: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    var body: some View {
        List {
            ForEach(server.library.playlists) { playlist in
                NavigationLink {
                    TrackListView(title: playlist.name, tracks: playlist.tracks.compactMap { id in server.library.tracks.first { $0.id == id } }, unavailable: playlist.unavailable, preserveOrder: true, playlistID: playlist.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(playlist.name, systemImage: "music.note.list")
                        Text("\(playlist.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listRowBackground(theme.panel)
            }
            if server.library.playlists.isEmpty { ContentUnavailableView("No playlists yet", systemImage: "music.note.list", description: Text("Playlist exports saved on the server appear here.")) }
        }.navigationTitle("Playlists").appSurface()
    }
}

private struct LibraryDeletion {
    let title: String
    let ids: [String]
    var playlist = false
    var collection = false

    var message: String {
        if playlist { return "This removes the local playlist file. Its songs stay in your library." }
        let files = ids.count == 1 ? "the audio file" : "\(ids.count) audio files"
        return "This permanently deletes \(files) from this Spotified server."
    }
}

private struct DeleteLibraryItem: ViewModifier {
    @Environment(ServerController.self) private var server
    @Binding var target: LibraryDeletion?
    var didDelete: (LibraryDeletion) -> Void
    @State private var failure: String?

    func body(content: Content) -> some View {
        content.alert("Delete \(target?.title ?? "item")?", isPresented: Binding(
            get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { item in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        do { try await server.deleteLibraryFiles(item.ids); didDelete(item) }
                        catch { failure = error.localizedDescription }
                    }
                }
            } message: { Text($0.message) }
            .alert("Deletion failed", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(failure ?? "") }
    }
}

struct TrackListView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let title: String
    let tracks: [MusicTrack]
    var unavailable = 0
    var preserveOrder = false
    var isAlbum = false
    var playlistID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var deletion: LibraryDeletion?
    @State private var alphabetically = false
    @State private var detail: MusicTrack?
    private var ordered: [MusicTrack] {
        let available = Set(server.library.tracks.map(\.id))
        let songs = tracks.filter { available.contains($0.id) }
        if alphabetically { return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        return preserveOrder ? songs : LibraryIndex.orderedTracks(songs)
    }
    var body: some View {
        let songs = ordered
        List {
            if unavailable > 0 { Text("\(unavailable) playlist files are unavailable on the server.").foregroundStyle(.orange) }
            if !songs.isEmpty {
                Section {
                    HStack {
                        Button { server.play(songs) } label: { Label("Play", systemImage: "play.fill") }.accessibilityIdentifier("playCollection")
                        Spacer()
                        Button { server.play(songs.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }.buttonStyle(.borderless)
                }.listRowBackground(theme.panel)
            }
            ForEach(Array(songs.enumerated()), id: \.offset) { index, track in
                HStack {
                    Button { server.play(songs, startingAt: index) } label: { TrackRow(track: track).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).accessibilityLabel("Play " + track.title).accessibilityIdentifier("play-track-" + track.id)
                    Button { detail = track } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Details for " + track.title)
                }.listRowBackground(theme.panel)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deletion = LibraryDeletion(title: track.title, ids: [track.id])
                        }.disabled(server.busy)
                    }
            }
            if isAlbum || playlistID != nil {
                Section {
                    Button(role: .destructive) {
                        deletion = LibraryDeletion(title: title, ids: playlistID.map { [$0] } ?? songs.map(\.id),
                                                   playlist: playlistID != nil, collection: true)
                    } label: { Label(playlistID == nil ? "Delete album" : "Delete playlist", systemImage: "trash") }
                        .disabled(server.busy || (playlistID == nil && songs.isEmpty))
                }.listRowBackground(theme.panel)
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).appSurface()
            .modifier(DeleteLibraryItem(target: $deletion) { item in if item.collection { dismiss() } })
            .sheet(item: $detail) { track in
                NavigationStack { TrackDetailView(track: track, play: {
                    if let index = songs.firstIndex(where: { $0.id == track.id }) { server.play(songs, startingAt: index) }
                }, didDelete: { detail = nil }).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } } }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu { Picker("Song order", selection: $alphabetically) { Text(preserveOrder ? "Original order" : "Disc and track order").tag(false); Text("Title A–Z").tag(true) } }
                label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort songs")
            } }
    }
}

struct TrackDetailView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let track: MusicTrack
    let play: () -> Void
    let didDelete: () -> Void
    @State private var deletion: LibraryDeletion?
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    CoverView(path: track.artwork, size: 220)
                    Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(track.artist).foregroundStyle(.secondary)
                    Button { play() } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            }.listRowBackground(Color.clear)
            Section("In your server library") {
                LabeledContent("Album", value: track.album)
                LabeledContent("Artist", value: track.artist)
                if !track.genre.isEmpty { LabeledContent("Genre", value: track.genre) }
                LabeledContent("Duration", value: track.durationLabel)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: track.size, countStyle: .file))
            }.listRowBackground(theme.panel)
            Section("Server file") { Text(track.folder + "/" + track.name).font(.caption).textSelection(.enabled) }.listRowBackground(theme.panel)
            Section {
                Button(role: .destructive) { deletion = LibraryDeletion(title: track.title, ids: [track.id]) }
                    label: { Label("Delete from server", systemImage: "trash") }
                    .disabled(server.busy)
            }.listRowBackground(theme.panel)
        }.modifier(DeleteLibraryItem(target: $deletion) { _ in didDelete() })
            .navigationTitle("Song details").navigationBarTitleDisplayMode(.inline).appSurface()
    }
}

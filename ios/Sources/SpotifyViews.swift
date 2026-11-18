import SwiftUI

struct SpotifyView: View {
    @State private var view = "playlists"
    @State private var search = ""
    @State private var submitted = ""
    @State private var kind = "track"
    private var request: SpotifyCatalogRequest { .init(view: view, query: submitted, kind: kind) }
    var body: some View {
        SpotifyPageView(request: request) {
            Section {
                Picker("Browse Spotify", selection: $view) {
                    Text("Your playlists").tag("playlists")
                    Text("Liked songs").tag("liked")
                    Text("Saved albums").tag("albums")
                    Text("Followed artists").tag("artists")
                    Text("Search Spotify").tag("search")
                }.accessibilityIdentifier("spotifyBrowse")
                if view == "search" {
                    TextField("Song, album, playlist, or artist", text: $search)
                        .submitLabel(.search).autocorrectionDisabled()
                        .accessibilityIdentifier("spotifySearch")
                        .onSubmit { submitted = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
                    Picker("Search type", selection: $kind) {
                        Text("Songs").tag("track"); Text("Albums").tag("album")
                        Text("Playlists").tag("playlist"); Text("Artists").tag("artist")
                    }
                    Button("Search Spotify", systemImage: "magnifyingglass") {
                        submitted = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    }.disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.navigationTitle("Spotify")
    }
}

private struct SpotifySelection: Identifiable {
    let id = UUID()
    let items: [SpotifyCatalogItem]
}

struct SpotifyPageView<Controls: View>: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let request: SpotifyCatalogRequest
    var collection: SpotifyCatalogItem? = nil
    @ViewBuilder var controls: () -> Controls
    @State private var items: [SpotifyCatalogItem] = []
    @State private var page: SpotifyCatalogPage?
    @State private var selected: [String: SpotifyCatalogItem] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var failedOffset = 0
    @State private var message: String?
    @State private var review: SpotifySelection?
    @State private var generation = UUID()

    var body: some View {
        List {
            controls().listRowBackground(theme.panel)
            if let collection, collection.canSave {
                Section {
                    Button(selected[collection.uri] == nil ? "Select whole \(collection.kind)" : "Deselect collection",
                           systemImage: selected[collection.uri] == nil ? "plus.circle" : "checkmark.circle.fill") { toggle(collection) }
                        .disabled(selected.count >= 200 && selected[collection.uri] == nil)
                }.listRowBackground(theme.panel)
            }
            if let message { Section { Label(message, systemImage: "checkmark.circle") }.listRowBackground(theme.panel) }
            if let error {
                Section { ErrorNotice(message: error); Button("Retry") { Task { await load(offset: failedOffset, fresh: true) } } }.listRowBackground(theme.panel)
            }
            Section {
                HStack {
                    Text("\(selected.count) selected").font(.subheadline)
                    Spacer()
                    Button("Select loaded") {
                        for item in items where item.canSave && selected.count < 200 { selected[item.uri] = item }
                    }.disabled(items.isEmpty).buttonStyle(.borderless)
                    if !selected.isEmpty { Button("Clear") { selected = [:] }.buttonStyle(.borderless) }
                }
                if selected.count >= 200 { Text("Save this selection before choosing more items.").font(.caption).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        if item.kind != "artist" {
                            Button { toggle(item) } label: {
                                Image(systemName: selected[item.uri] == nil ? "circle" : "checkmark.circle.fill")
                                    .font(.title2).foregroundStyle(selected[item.uri] == nil ? theme.foreground.opacity(0.55) : theme.accent)
                            }.buttonStyle(.borderless).accessibilityLabel("Select \(item.name)").accessibilityIdentifier("selectSpotify-" + item.uri)
                                .disabled(!item.canSave || (selected.count >= 200 && selected[item.uri] == nil))
                        }
                        if item.isCollection && item.available {
                            NavigationLink {
                                SpotifyPageView<EmptyView>(request: .init(view: "contents", uri: item.uri), collection: item) { EmptyView() }
                                    .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
                            } label: { SpotifyItemLabel(item: item) }
                        } else { SpotifyItemLabel(item: item) }
                    }.padding(.vertical, 4)
                }
                if loading { HStack { ProgressView(); Text("Loading Spotify…") } }
                if !loading && error == nil && items.isEmpty {
                    Text(request.view == "search" && request.query.isEmpty ? "Search Spotify, then choose what to save locally." : "No items found.").foregroundStyle(.secondary)
                }
                if let next = page?.nextOffset {
                    Button("Load more") { Task { await load(offset: next) } }.disabled(loading)
                }
            } header: { Text(page.map { "\($0.total.formatted()) items" } ?? "Your Spotify account") }
                .listRowBackground(theme.panel)
        }.appSurface()
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button {
                        server.error = nil
                        review = SpotifySelection(items: selected.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                    } label: { Label("Save \(selected.count) locally", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).padding(12).background(theme.panel)
                }
            }
            .task(id: request.path()) {
                items = []; page = nil; selected = [:]; message = nil
                await load()
            }
            .refreshable { await load(fresh: true) }
            .sheet(item: $review) { selection in
                NavigationStack {
                    SaveSpotifyView(items: selection.items) { selected = [:]; message = "Added to Downloads. Your server will save the selected music." }
                }
            }
    }

    private func toggle(_ item: SpotifyCatalogItem) {
        if selected[item.uri] != nil { selected.removeValue(forKey: item.uri) }
        else if selected.count < 200 { selected[item.uri] = item }
    }

    private func load(offset: Int = 0, fresh: Bool = false) async {
        let current = UUID(); generation = current; error = nil; failedOffset = offset
        guard let api = server.api, request.view != "search" || !request.query.isEmpty else { loading = false; return }
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let result = try await api.spotify(request, offset: offset, refresh: fresh)
            guard generation == current, !Task.isCancelled else { return }
            page = result
            var seen = Set<String>()
            items = ((offset == 0 ? [] : items) + result.items).filter { seen.insert($0.uri).inserted }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if case ClientError.signedOut = error { server.disconnect() }
            self.error = error.localizedDescription
        }
    }
}

private struct SpotifyItemLabel: View {
    let item: SpotifyCatalogItem
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.imageURL) { image in image.resizable().scaledToFill() }
                placeholder: { Image(systemName: item.kind == "artist" ? "person.fill" : "music.note").foregroundStyle(.secondary) }
                .frame(width: 44, height: 44).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body).lineLimit(2)
                Text(item.available ? item.subtitle : "Unavailable on Spotify").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct SaveSpotifyView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let items: [SpotifyCatalogItem]
    let queued: () -> Void
    @State private var format = "copy"
    @State private var quality = "auto"
    @State private var bitrate = "best"
    var body: some View {
        Form {
            Section("Save on your server") {
                Text("Playlists and albums include their songs. Downloads continue when you close Spotified.")
                Text(server.settings?.musicPath ?? "").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            Section("Audio") { AudioPickers(format: $format, quality: $quality, bitrate: $bitrate) }.listRowBackground(theme.panel)
            Section("\(items.count) selected") { ForEach(items) { Text($0.name) } }.listRowBackground(theme.panel)
            if let error = server.error { Section { ErrorNotice(message: error) }.listRowBackground(theme.panel) }
            Section {
                Button {
                    Task {
                        if await server.saveSpotify(uris: items.map(\.uri), format: format, quality: quality, bitrate: bitrate) { queued(); dismiss() }
                    }
                } label: { HStack { if server.busy { ProgressView() }; Text(server.busy ? "Adding to queue…" : "Add to download queue") } }
                    .disabled(server.busy).accessibilityIdentifier("saveSpotifySelection")
            }.listRowBackground(theme.panel)
        }.appSurface().navigationTitle("Save locally").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(server.busy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(server.busy) } }
            .onAppear { if let settings = server.settings { format = settings.format; quality = settings.quality; bitrate = settings.bitrate } }
    }
}

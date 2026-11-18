import SwiftUI

enum SettingsGroup: String, CaseIterable, Identifiable {
    case audio = "Audio quality", folders = "Folders and playlists", metadata = "Artwork and lyrics", pacing = "Request pacing"
    var id: String { rawValue }
    var icon: String {
        switch self { case .audio: return "waveform"; case .folders: return "folder"; case .metadata: return "photo.on.rectangle"; case .pacing: return "timer" }
    }
}
struct SettingsView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @AppStorage("appearance") private var appearance = AppTheme.afterglow.rawValue
    var body: some View {
        List {
            Section("Server settings") {
                if let settings = server.settings {
                    ForEach(SettingsGroup.allCases) { group in
                        NavigationLink { SettingsEditor(group: group, settings: settings) } label: { Label(group.rawValue, systemImage: group.icon) }
                            .accessibilityIdentifier("settings-" + group.id)
                    }
                }
            }.listRowBackground(theme.panel)
            Section("Storage on server") {
                LabeledContent("Music", value: server.settings?.musicPath ?? "")
                LabeledContent("Podcasts", value: server.settings?.podcastPath ?? "")
                Text("These paths belong to the server. Music is organized using the folder layout above.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            Section("Appearance") {
                Picker("Theme", selection: $appearance) { ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) } }
            }.listRowBackground(theme.panel)
            Section("Spotify") {
                Label(server.state?.account.message ?? "Checking connection", systemImage: server.state?.account.status == "connected" ? "checkmark.shield" : "exclamationmark.shield")
                NavigationLink { SpotifyConnectionView() } label: { Label("Manage Spotify connection", systemImage: "person.crop.circle.badge.checkmark") }
                    .accessibilityIdentifier("manageSpotify")
                Text("Spotify credentials are stored on your server.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            Section("Spotified by Afterglow Labs") { VersionLabel() }.listRowBackground(theme.panel)
        }.navigationTitle("Settings").appSurface().refreshable { await server.refresh() }
    }
}

struct SettingsEditor: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let group: SettingsGroup
    @State private var original: ServerSettings
    @State private var draft: ServerSettings
    init(group: SettingsGroup, settings: ServerSettings) {
        self.group = group; _original = State(initialValue: settings); _draft = State(initialValue: settings)
    }
    var body: some View {
        Form {
            switch group {
            case .audio:
                Section {
                    AudioPickers(format: $draft.format, quality: $draft.quality, bitrate: $draft.bitrate)
                } footer: { Text("Original source preserves the encoded audio. Best available uses the highest source quality your account supports. Conversion cannot add quality beyond the source.") }
                .listRowBackground(theme.panel)
            case .folders:
                Section("Music folders") {
                    Picker("Layout", selection: $draft.layout) {
                        Text("Artist / Album").tag("albums"); Text("Artist").tag("artists"); Text("One folder").tag("flat")
                        if draft.layout == "custom" { Text("Custom server layout").tag("custom") }
                    }
                    Toggle("Skip existing files", isOn: $draft.skipExisting)
                    Text("Applies to future downloads. Existing files stay where they are.").font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(theme.panel)
                Section("Playlists") {
                    Picker("Playlist tracks", selection: $draft.playlistLayout) {
                        Text("Shared artist / album library").tag("library"); Text("Separate playlist folders").tag("separate")
                    }
                    Toggle("Create M3U8 playlists", isOn: $draft.exportM3U8)
                    Toggle("Relative playlist paths", isOn: $draft.relativePlaylists)
                }.listRowBackground(theme.panel)
            case .metadata:
                Section("Artwork") { Toggle("Save cover art beside files", isOn: $draft.albumArt) }.listRowBackground(theme.panel)
                Section("Lyrics") {
                    Toggle("Embed lyrics in metadata", isOn: $draft.lyricsMetadata)
                    Toggle("Save lyrics beside files", isOn: $draft.lyricsFile)
                    Text("Lyrics depend on availability from the source.").font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(theme.panel)
            case .pacing:
                Section {
                    Stepper(value: $draft.fetchDelay, in: 0...60, step: 0.5) { LabeledContent("Between requests", value: draft.fetchDelay.formatted() + " s") }
                    Stepper(value: $draft.bulkWait, in: 0...600, step: 5) { LabeledContent("Between tracks", value: draft.bulkWait.formatted() + " s") }
                    Stepper(value: $draft.retryDelay, in: 1...600, step: 5) { LabeledContent("Retry delay", value: draft.retryDelay.formatted() + " s") }
                    Stepper("Retries: \(draft.retryAttempts)", value: $draft.retryAttempts, in: 0...10)
                    Toggle("Increase delay after failures", isOn: $draft.escalatingDelay)
                } header: { Text("Delays on the server") } footer: { Text("Longer Retry-After responses take priority. Request pacing reduces bursts; it cannot guarantee Spotify will accept a request.") }
                .listRowBackground(theme.panel)
            }
            if let error = server.error { Section { ErrorNotice(message: error) }.listRowBackground(theme.panel) }
        }.navigationTitle(group.rawValue).navigationBarTitleDisplayMode(.inline).appSurface()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await server.save(draft, original: original) { dismiss() } } }
                        .disabled(server.busy || draft == original).accessibilityIdentifier("saveSettings")
                }
            }
    }
}

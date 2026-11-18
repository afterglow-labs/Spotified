import SwiftUI

@main struct SpotifiedApp: App {
    @State private var server = ServerController()
    @AppStorage("appearance") private var appearance = AppTheme.afterglow.rawValue
    init() { AppTheme.migrateSavedAppearance() }
    var body: some Scene {
        WindowGroup {
            let theme = AppTheme(rawValue: appearance) ?? .afterglow
            RootView().environment(server).environment(\.spotifiedTheme, theme)
                .preferredColorScheme(theme.scheme).tint(theme.accent)
                .task { await server.start() }
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case library = "Library", spotify = "Spotify", downloads = "Downloads", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .library: return "music.note.house"; case .spotify: return "magnifyingglass"; case .downloads: return "arrow.down.circle"; case .settings: return "slider.horizontal.3" } }
}
private enum AppSheet: String, Identifiable { case account, download, player; var id: String { rawValue } }

struct RootView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var tab = AppTab.library
    @State private var sheet: AppSheet?

    var body: some View {
        Group {
            if server.connected {
                if sizeClass == .regular {
                    NavigationSplitView {
                        List(AppTab.allCases) { item in
                            Button { tab = item } label: { Label(item.rawValue, systemImage: item.icon) }
                                .listRowBackground(tab == item ? theme.accent.opacity(0.15) : theme.panel)
                        }.navigationTitle("Spotified").appSurface()
                    } detail: { NavigationStack { screen(tab) } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer { sheet = .player } }
                } else {
                    TabView(selection: $tab) {
                        ForEach(AppTab.allCases) { item in
                            NavigationStack { screen(item) }
                                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer { sheet = .player } }
                                .tabItem { Label(item.rawValue, systemImage: item.icon) }.tag(item)
                        }
                    }.toolbarBackground(theme.panel, for: .tabBar)
                }
            } else { NavigationStack { ConnectionView() } }
        }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .account: AccountView()
                case .download: AddDownloadView { tab = .downloads }
                case .player: NowPlayingView()
                }
            }
        }
        .onChange(of: server.connected) { _, connected in if !connected { sheet = nil } }
        .task(id: "\(phase)-\(server.connected)-\(server.origin)") {
            if phase == .active && server.connected { await server.monitor() }
        }
    }

    @ViewBuilder private func screen(_ item: AppTab) -> some View {
        Group {
            switch item {
            case .library: LibraryView()
            case .spotify: SpotifyView()
            case .downloads: DownloadsView()
            case .settings: SettingsView()
            }
        }
        .navigationTitle(item.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .account } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel("Connection and account").accessibilityIdentifier("accountButton")
            }
            if item != .settings && item != .spotify {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { server.error = nil; sheet = .download } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add download").accessibilityIdentifier("addDownload")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = server.error { ErrorNotice(message: error).padding(12).frame(maxWidth: .infinity).background(theme.panel) }
        }
    }
}

struct ConnectionView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 58)).foregroundStyle(theme.accent)
                    Text("Spotified").font(.largeTitle.weight(.semibold)).foregroundStyle(theme.accent)
                    Text("by Afterglow Labs").font(.subheadline)
                    VersionLabel()
                    Text("Connect to your music server.").font(.title3)
                    Text("Your library and downloads stay on your server.").foregroundStyle(.secondary)
                }.padding(.vertical, 14)
            }.listRowBackground(Color.clear)
            Section("Music server") {
                TextField("HTTPS server address", text: $origin, axis: .vertical)
                    .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("serverAddress")
                Text("Connect Tailscale to reach Nibiru.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            Section("Account") {
                TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverUsername")
                SecureField("Password", text: $password).textContentType(.password).accessibilityIdentifier("serverPassword")
                Toggle("Remember this connection", isOn: $remember)
            }.listRowBackground(theme.panel)
            if let error = server.error { Section { ErrorNotice(message: error) }.listRowBackground(theme.panel) }
            Section {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await server.connect(origin: origin, username: username, password: password, remember: remember); if server.connected { password = "" } }
                } label: {
                    HStack { Spacer(); if server.connecting { ProgressView() }; Text(server.connecting ? "Connecting…" : "Connect"); Spacer() }
                }.disabled(server.connecting || password.isEmpty).accessibilityIdentifier("connectButton")
            }.listRowBackground(theme.panel)
        }.appSurface().navigationTitle("Welcome").navigationBarTitleDisplayMode(.inline)
            .onAppear { origin = server.origin; username = server.username }
    }
}

struct AccountView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppTheme.afterglow.rawValue
    var body: some View {
        Form {
            Section("Spotified by Afterglow Labs") { VersionLabel() }.listRowBackground(theme.panel)
            Section("Connected server") {
                Text(server.state?.server ?? "Spotified server").font(.headline)
                Text(server.origin).font(.caption).textSelection(.enabled)
                Label(server.username, systemImage: "person.crop.circle")
                Label(server.state?.account.message ?? "", systemImage: "checkmark.shield")
            }.listRowBackground(theme.panel)
            Section("Appearance") {
                Picker("Theme", selection: $appearance) { ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) } }
            }.listRowBackground(theme.panel)
            Section("Server storage") {
                LabeledContent("Music", value: server.settings?.musicPath ?? "")
                Text("Downloads continue on this server when you close Spotified.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            if let notice = server.notice { Section { Text(notice) }.listRowBackground(theme.panel) }
            Section {
                Button("Switch server or account") { server.disconnect(); dismiss() }
                Button("Forget saved login", role: .destructive) { server.disconnect(forget: true); dismiss() }
            }.listRowBackground(theme.panel)
        }.appSurface().navigationTitle("Connection and account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

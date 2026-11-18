import SwiftUI
import SafariServices

private struct SpotifyBrowser: Identifiable { let id = UUID(); let url: URL }
private struct SpotifyAuthorizationSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct SpotifyConnectionView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @State private var receiver = SpotifyLoginReceiver()
    @State private var browser: SpotifyBrowser?
    @State private var ownedJobID: String?
    @State private var openedURL: String?
    @State private var localError: String?
    @State private var starting = false
    @State private var callbackSent = false

    private var active: DownloadJob? { server.state?.jobs.first { $0.kind == "login" && $0.isActive } }
    private var latest: DownloadJob? { server.state?.jobs.first { $0.kind == "login" } }
    private var ownJob: DownloadJob? { server.state?.jobs.first { $0.id == ownedJobID } }

    var body: some View {
        List {
            Section("Spotify on your server") {
                Label(server.state?.account.message ?? "Checking connection", systemImage: server.state?.account.status == "connected" ? "checkmark.shield" : "exclamationmark.shield")
                Text(server.state?.server ?? server.origin).font(.caption).foregroundStyle(.secondary)
                Text("Sign in to Spotify to connect this server, or choose another Spotify account. Downloads and Spotify credentials stay on the server.").font(.callout)
            }.listRowBackground(theme.panel)
            Section {
                Button { Task { await begin() } } label: { Label(starting ? "Preparing sign-in…" : "Sign in / switch Spotify account", systemImage: "person.crop.circle.badge.plus") }
                    .disabled(starting || server.busy || active != nil).accessibilityIdentifier("spotifySignIn")
                Button { Task { _ = await server.spotifyLogin(check: true) } } label: { Label("Check Spotify connection", systemImage: "arrow.clockwise") }
                    .disabled(starting || server.busy || active != nil).accessibilityIdentifier("spotifyCheck")
            }.listRowBackground(theme.panel)
            if let active {
                Section("Pending connection") {
                    Text(active.message).accessibilityIdentifier("spotifyConnectionMessage")
                    if active.id == ownedJobID, let text = active.loginUrl, let url = URL(string: text) {
                        Button("Continue Spotify sign-in") { open(url) }.accessibilityIdentifier("spotifyContinue")
                    } else if active.loginMode == "client", active.id != ownedJobID {
                        Text("This sign-in started on another screen or device. Finish it there, or cancel it and sign in here.").font(.caption)
                    }
                    Button("Cancel pending connection", role: .destructive) {
                        Task { await server.jobAction(active, action: "cancel"); receiver.stop(); browser = nil }
                    }.disabled(server.busy).accessibilityIdentifier("spotifyCancel")
                }.listRowBackground(theme.panel)
            } else if let latest {
                Section("Last connection attempt") { Text(latest.message).accessibilityIdentifier("spotifyConnectionMessage") }.listRowBackground(theme.panel)
            }
            if let error = localError ?? receiver.error ?? server.error {
                Section { ErrorNotice(message: error) }.listRowBackground(theme.panel)
            }
        }
        .navigationTitle("Spotify connection").navigationBarTitleDisplayMode(.inline).appSurface()
        .refreshable { await server.refresh() }
        .sheet(item: $browser) { SpotifyAuthorizationSheet(url: $0.url).ignoresSafeArea() }
        .onChange(of: ownJob?.loginUrl) { _, value in
            if let value, value != openedURL, let url = URL(string: value) { open(url) }
        }
        .onChange(of: ownJob?.isActive) { _, value in
            if value == false { receiver.stop(); browser = nil }
        }
        .onChange(of: receiver.callbackURL) { _, callback in
            guard let callback, let id = ownedJobID else { return }
            browser = nil
            Task {
                callbackSent = await server.spotifyCallback(id: id, url: callback)
                if !callbackSent { localError = server.error ?? "Could not send sign-in to the server. Cancel this attempt and try again." }
            }
        }
        .onDisappear {
            receiver.stop()
            if !callbackSent, let job = ownJob, job.isActive { Task { await server.jobAction(job, action: "cancel") } }
        }
    }

    private func begin() async {
        starting = true; localError = nil; openedURL = nil; callbackSent = false
        defer { starting = false }
        do {
            var requestedPort: UInt16 = 4381
            #if DEBUG
            if server.testing { requestedPort = UInt16(ProcessInfo.processInfo.environment["SPOTIFIED_TEST_CALLBACK_PORT"] ?? "4381") ?? 4381 }
            #endif
            let port = try await receiver.start(port: requestedPort)
            guard let job = await server.spotifyLogin(check: false, callbackPort: Int(port)) else { receiver.stop(); return }
            ownedJobID = job.id
            if let text = job.loginUrl, let url = URL(string: text) { open(url) }
        } catch { receiver.stop(); localError = error.localizedDescription }
    }
    private func open(_ url: URL) {
        do { try receiver.configure(authorizationURL: url); openedURL = url.absoluteString; browser = SpotifyBrowser(url: url) }
        catch { localError = error.localizedDescription }
    }
}

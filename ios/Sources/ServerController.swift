import Foundation
import Observation
import UIKit

@MainActor @Observable final class ServerController {
    let player = MusicPlayer()
    var origin = UserDefaults.standard.string(forKey: "server") ?? ServerAddress.defaultOrigin
    var username = UserDefaults.standard.string(forKey: "username") ?? "corey"
    var connected = false
    var connecting = false
    var busy = false
    var error: String?
    var notice: String?
    var state: ServerState?
    var library = MusicLibrary.empty
    var settings: ServerSettings?
    private(set) var api: SpotifiedAPI?
    private var generation = UUID()
    private var refreshing = false
    private var refreshGeneration = UUID()
    private let images = NSCache<NSString, UIImage>()
    private(set) var testing = false

    init() {
        images.countLimit = 150
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        if testing {
            origin = ProcessInfo.processInfo.environment["SPOTIFIED_TEST_ORIGIN"] ?? ServerAddress.defaultOrigin
            username = ProcessInfo.processInfo.environment["SPOTIFIED_TEST_USERNAME"] ?? "test-user"
        }
        #endif
    }

    func start() async {
        guard !testing, !connected, !connecting, let password = LoginStore.read(origin: origin, username: username) else { return }
        await connect(origin: origin, username: username, password: password, remember: true)
    }

    func connect(origin rawOrigin: String, username rawUsername: String, password: String, remember: Bool) async {
        guard !connecting else { return }
        guard let address = ServerAddress(rawOrigin), !rawUsername.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            error = "Enter a valid HTTPS address, username, and password."; return
        }
        disconnect()
        let current = generation
        origin = address.origin; username = rawUsername.trimmingCharacters(in: .whitespaces)
        connecting = true; error = nil; notice = nil
        let client = SpotifiedAPI(address: address); api = client
        do {
            try await client.login(username: username, password: password)
            let newState = try await client.state()
            let newLibrary = try await client.library()
            let newSettings = try await client.settings()
            try Task.checkCancellation()
            guard generation == current else { return }
            state = newState; library = newLibrary; settings = newSettings
            if !testing {
                if remember {
                    do { try LoginStore.save(password, origin: origin, username: username) }
                    catch { notice = "Connected for this session. Your login could not be saved in Keychain." }
                } else { LoginStore.delete(origin: origin, username: username) }
                UserDefaults.standard.set(origin, forKey: "server")
                UserDefaults.standard.set(username, forKey: "username")
            }
            connected = true; connecting = false
        } catch {
            guard current == generation else { return }
            connecting = false; client.invalidate(); api = nil
            if !Task.isCancelled { self.error = error.localizedDescription + " For Nibiru, make sure Tailscale is connected." }
        }
    }

    func disconnect(forget: Bool = false) {
        player.stop()
        if forget { LoginStore.delete(origin: origin, username: username) }
        generation = UUID(); api?.invalidate(); api = nil
        connected = false; connecting = false; busy = false; refreshing = false
        state = nil; library = .empty; settings = nil; images.removeAllObjects()
    }

    func refresh(full: Bool = true, force: Bool = false) async {
        guard let api, connected, force || (!refreshing && !busy) else { return }
        let current = generation
        let refreshID = UUID(); refreshGeneration = refreshID; refreshing = true
        defer { if current == generation && refreshID == refreshGeneration { refreshing = false } }
        do {
            let updated = try await api.state()
            guard current == generation && refreshID == refreshGeneration else { return }
            let changed = updated.jobs.map { $0.id + $0.status } != state?.jobs.map { $0.id + $0.status }
            state = updated
            if full || changed {
                let updatedLibrary = try await api.library()
                guard current == generation && refreshID == refreshGeneration else { return }
                library = updatedLibrary
            }
            if full {
                let updatedSettings = try await api.settings()
                guard current == generation && refreshID == refreshGeneration else { return }
                settings = updatedSettings
            }
            error = nil
        } catch { if current == generation && refreshID == refreshGeneration { report(error) } }
    }

    func monitor() async {
        while connected && !Task.isCancelled {
            await refresh(full: false)
            do { try await Task.sleep(for: .seconds(error == nil ? 4 : 20)) } catch { return }
        }
    }

    func queue(urls: String, format: String, quality: String, bitrate: String, preview: Bool) async -> Bool {
        guard let api, !busy else { return false }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            try await api.queue(urls: urls, format: format, quality: quality, bitrate: bitrate, preview: preview)
            guard current == generation else { return false }
            await refresh(force: true); return true
        } catch { if current == generation { report(error) }; return false }
    }

    func saveSpotify(uris: [String], format: String, quality: String, bitrate: String) async -> Bool {
        guard let api, !busy else { return false }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            try await api.saveSpotify(uris: uris, format: format, quality: quality, bitrate: bitrate)
            guard current == generation else { return false }
            await refresh(force: true); return true
        } catch { if current == generation { report(error) }; return false }
    }

    func deleteLibraryFiles(_ ids: [String]) async throws {
        guard let api else { throw ClientError.signedOut }
        guard !busy else { throw ClientError.message("Another request is in progress. Try again in a moment.") }
        let current = generation
        busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        let result = try await api.deleteLibraryFiles(ids)
        guard current == generation else { throw CancellationError() }
        let removed = Set(result.removed)
        player.removeDeleted(removed)
        library.tracks.removeAll { removed.contains($0.id) }
        library.playlists.removeAll { removed.contains($0.id) }
        await refresh(force: true)
        if !result.failed.isEmpty {
            throw ClientError.message("Could not delete \(result.failed.count) of \(ids.count) files. Check the server’s library permissions.")
        }
    }

    func jobAction(_ job: DownloadJob, action: String) async {
        guard let api, !busy else { return }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            try await api.jobAction(id: job.id, action: action)
            if current == generation { await refresh(force: true) }
        } catch { if current == generation { report(error) } }
    }

    func save(_ draft: ServerSettings, original: ServerSettings) async -> Bool {
        guard let api, !busy else { return false }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            let changes = try draft.changes(from: original)
            if changes.isEmpty { return true }
            let updated = try await api.saveSettings(changes)
            guard current == generation else { return false }
            settings = updated; return true
        } catch { if current == generation { report(error) }; return false }
    }

    func spotifyLogin(check: Bool, callbackPort: Int = 4381) async -> DownloadJob? {
        guard let api, !busy else { return nil }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            let job = try await api.spotifyLogin(check: check, callbackPort: callbackPort)
            guard current == generation else { return nil }
            await refresh(force: true); return job
        } catch { if current == generation { report(error) }; return nil }
    }

    func spotifyCallback(id: String, url: String) async -> Bool {
        guard let api, !busy else { return false }
        let current = generation; busy = true; error = nil; refreshGeneration = UUID(); refreshing = false
        defer { if current == generation { busy = false } }
        do {
            try await api.spotifyCallback(id: id, url: url)
            guard current == generation else { return false }
            await refresh(force: true); return true
        } catch { if current == generation { report(error) }; return false }
    }

    func artwork(_ path: String) async -> UIImage? {
        if let image = images.object(forKey: path as NSString) { return image }
        guard let api else { return nil }
        let current = generation
        guard let data = try? await api.artwork(path), current == generation, let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: path as NSString); return image
    }

    func play(_ tracks: [MusicTrack], startingAt index: Int = 0) {
        player.play(tracks, startingAt: index) { [weak self] track in
            guard let self, self.connected, let api = self.api else { throw ClientError.signedOut }
            return try await api.playbackItem(track)
        }
    }

    private func report(_ error: Error) {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
        if case ClientError.signedOut = error { disconnect() }
        self.error = error.localizedDescription
    }
}

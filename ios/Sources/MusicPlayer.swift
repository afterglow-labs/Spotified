import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable final class MusicPlayer {
    private(set) var queue: [MusicTrack] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    var current: MusicTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 || elapsed > 3 }
    @ObservationIgnored private let engine = AVPlayer()
    @ObservationIgnored private var provider: ((MusicTrack) async throws -> AVPlayerItem)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var interruptedPlayback = false
    @ObservationIgnored private var wantsPlayback = false

    init() {
        playbackObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
                if player.timeControlStatus == .playing { self?.isLoading = false }
                self?.updateNowPlaying()
            }
        }
        timeObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite { self.elapsed = max(0, time.seconds) }
                if let seconds = self.engine.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 { self.duration = seconds }
                self.updateNowPlaying()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.engine.currentItem else { return }
                if self.hasNext { self.next() } else { self.pause(); self.elapsed = self.duration }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.interruptedPlayback = self.isPlaying; self.pause() }
                else if let value = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                        AVAudioSession.InterruptionOptions(rawValue: value).contains(.shouldResume), self.interruptedPlayback { self.resume() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }; return .success
        }
        updateNowPlaying()
    }

    func play(_ tracks: [MusicTrack], startingAt index: Int, provider: @escaping (MusicTrack) async throws -> AVPlayerItem) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks; self.index = index; self.provider = provider
        load()
    }
    private func load() {
        loadTask?.cancel(); generation = UUID(); wantsPlayback = true
        let token = generation
        engine.pause(); VorbisAsset.cancel(engine.currentItem); engine.replaceCurrentItem(with: nil)
        elapsed = 0; duration = current?.duration ?? 0; error = nil; isLoading = true; isPlaying = false
        updateNowPlaying()
        guard let track = current, let provider else { isLoading = false; return }
        loadTask = Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let item = try await provider(track)
                try Task.checkCancellation()
                guard token == generation else { return }
                itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if item.status == .failed {
                            self.isLoading = false
                            self.wantsPlayback = false
                            self.error = item.error?.localizedDescription ?? "Playback failed. Check the server connection and try again."
                        }
                    }
                }
                engine.replaceCurrentItem(with: item)
                if wantsPlayback { engine.play() } else { isLoading = false }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                isLoading = false; wantsPlayback = false; self.error = error.localizedDescription
            }
        }
    }
    func removeDeleted(_ ids: Set<String>) {
        guard let current, queue.contains(where: { ids.contains($0.id) }) else { return }
        if ids.contains(current.id) { stop(); return }
        index = queue.prefix(index).filter { !ids.contains($0.id) }.count
        queue.removeAll { ids.contains($0.id) }
        updateNowPlaying()
    }

    func toggle() { wantsPlayback ? pause() : resume() }
    func pause() { wantsPlayback = false; engine.pause(); isPlaying = false; isLoading = false; updateNowPlaying() }
    func resume() {
        guard current != nil else { return }
        wantsPlayback = true
        if error != nil || engine.currentItem == nil { load(); return }
        if duration > 0 && elapsed >= duration - 0.5 { seek(to: 0) }
        do { try AVAudioSession.sharedInstance().setActive(true); engine.play() }
        catch { self.error = error.localizedDescription }
    }
    func next() { guard hasNext else { return }; index += 1; load() }
    func previous() { if elapsed > 3 { seek(to: 0) } else if index > 0 { index -= 1; load() } }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let value = max(0, min(seconds, duration))
        elapsed = value
        engine.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }
    func stop() {
        loadTask?.cancel(); generation = UUID(); itemObservation = nil; wantsPlayback = false
        engine.pause(); VorbisAsset.cancel(engine.currentItem); engine.replaceCurrentItem(with: nil)
        queue = []; provider = nil; index = 0; isPlaying = false; isLoading = false; elapsed = 0; duration = 0; error = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        updateNowPlaying()
    }
    private func updateNowPlaying() {
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = hasPrevious
        commands.changePlaybackPositionCommand.isEnabled = current != nil && duration > 0
        guard let track = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index, MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
    }
}

import SwiftUI
import AVKit

struct MiniPlayer: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let open: () -> Void
    var body: some View {
        if let track = server.player.current {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        CoverView(path: track.artwork, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(server.player.error == nil ? track.artist : "Playback needs attention").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Now playing").accessibilityValue(track.title).accessibilityIdentifier("nowPlaying")
                if server.player.isLoading { ProgressView().accessibilityLabel("Preparing playback") }
                Button { server.player.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 32, height: 44) }
                    .disabled(!server.player.hasPrevious).accessibilityLabel("Previous song").accessibilityIdentifier("miniPrevious")
                Button { server.player.toggle() } label: { Image(systemName: server.player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 40, height: 44) }
                    .accessibilityLabel(server.player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("miniPlayPause")
                Button { server.player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 32, height: 44) }
                    .disabled(!server.player.hasNext).accessibilityLabel("Next song").accessibilityIdentifier("miniNext")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(theme.panel)
        }
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct NowPlayingView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var seeking = false
    @State private var position: Double = 0
    private var player: MusicPlayer { server.player }
    var body: some View {
        ScrollView {
            if let track = player.current {
                VStack(spacing: 22) {
                    CoverView(path: track.artwork, size: 260).padding(.top, 12)
                    VStack(spacing: 6) {
                        Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(track.artist).foregroundStyle(.secondary)
                        Text(track.album).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { seeking ? position : player.elapsed }, set: { position = $0 }), in: 0...max(1, player.duration), onEditingChanged: { editing in
                            seeking = editing
                            if !editing { player.seek(to: position) }
                        }).disabled(player.duration <= 0).accessibilityLabel("Playback position")
                        HStack { Text(time(seeking ? position : player.elapsed)).accessibilityIdentifier("playbackElapsed"); Spacer(); Text(time(player.duration)) }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 38) {
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title) }.disabled(!player.hasPrevious).accessibilityLabel("Previous song").accessibilityIdentifier("playerPrevious")
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("playerPlayPause")
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title) }.disabled(!player.hasNext).accessibilityLabel("Next song").accessibilityIdentifier("playerNext")
                    }
                    if player.isLoading { ProgressView("Preparing song on server…") }
                    if let error = player.error { ErrorNotice(message: error) }
                    HStack {
                        Label("Streaming from your server", systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("Audio output")
                    }
                    if player.queue.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Up next").font(.headline)
                            ForEach(Array(player.queue.enumerated()).filter { $0.offset > player.index }, id: \.offset) { index, item in
                                Button { server.play(player.queue, startingAt: index) } label: { TrackRow(track: item) }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(24)
            }
        }.appSurface().navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(max(0, value)) / 60, Int(max(0, value)) % 60) }
}

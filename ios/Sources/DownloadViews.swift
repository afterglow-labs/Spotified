import SwiftUI

struct DownloadsView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    private var jobs: [DownloadJob] { server.state?.jobs ?? [] }
    var body: some View {
        List {
            Section {
                Label("Downloads run on your server", systemImage: "server.rack").font(.headline)
                Text(server.state?.server ?? "").font(.caption).foregroundStyle(.secondary)
                Text("You can close this app while your queue keeps running.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            if jobs.isEmpty { ContentUnavailableView("Nothing queued", systemImage: "arrow.down.circle", description: Text("Tap + to send a Spotify link to your server.")) }
            jobSection("Active", jobs.filter(\.isActive))
            jobSection("History", jobs.filter { !$0.isActive })
        }.navigationTitle("Downloads").appSurface().refreshable { await server.refresh() }
    }
    @ViewBuilder private func jobSection(_ title: String, _ items: [DownloadJob]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { job in
                    VStack(alignment: .leading, spacing: 12) {
                          VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(job.status.capitalized).font(.caption.weight(.semibold)).foregroundStyle(theme.accent); Spacer(); if job.preview == true { Text("Preview").font(.caption) } }
                            Text(job.title).font(.body.weight(.medium)).lineLimit(2)
                            Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            if job.isActive && job.total > 0 { ProgressView(value: Double(job.completed), total: Double(max(job.total, job.completed))) }
                          }.padding(.vertical, 6)
                        SourceLinksView(urls: job.urls)
                        HStack {
                            NavigationLink("View details") { JobDetailView(id: job.id) }.buttonStyle(.bordered)
                            if job.canRestart { RestartJobButton(job: job) }
                        }
                    }.listRowBackground(theme.panel)
                }
            }
        }
    }
}

struct JobDetailView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    let id: String
    @State private var confirmCancel = false
    private var job: DownloadJob? { server.state?.jobs.first { $0.id == id } }
    var body: some View {
        List {
            if let job {
                Section("Server activity") {
                    LabeledContent("Status", value: job.status.capitalized)
                    Text(job.message).textSelection(.enabled)
                    if job.total > 0 { LabeledContent("Tracks", value: "\(job.completed) of \(job.total)") }
                    if let format = job.format { LabeledContent("Format", value: format == "copy" ? "Original source" : format.uppercased()) }
                    if job.isActive { Button("Cancel download", role: .destructive) { confirmCancel = true }.disabled(server.busy).accessibilityIdentifier("cancelJob") }
                    if job.canRestart {
                        RestartJobButton(job: job)
                        Text("Already saved tracks are skipped.").font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground(theme.panel)
                Section("Source links") {
                    SourceLinksView(urls: job.urls)
                    if job.urls.isEmpty { Text("No source link was recorded for this job.").foregroundStyle(.secondary) }
                }.listRowBackground(theme.panel)
                Section("Activity log") {
                    if job.logs.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                    ForEach(Array(job.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }.listRowBackground(theme.panel)
            } else { ContentUnavailableView("Job unavailable", systemImage: "clock.arrow.circlepath") }
        }.navigationTitle("Download details").navigationBarTitleDisplayMode(.inline).appSurface()
            .refreshable { await server.refresh() }
            .confirmationDialog("Cancel this download on the server?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { if let job { Task { await server.jobAction(job, action: "cancel") } } }
            }
            .safeAreaInset(edge: .bottom) { if let error = server.error { ErrorNotice(message: error).padding().background(theme.panel) } }
    }
}

private struct RestartJobButton: View {
    @Environment(ServerController.self) private var server
    let job: DownloadJob
    private var alreadyQueued: Bool { server.state?.jobs.contains { $0.restartOf == job.id && $0.isActive } == true }
    var body: some View {
        Button(alreadyQueued ? "Restart queued" : "Restart on server", systemImage: "arrow.clockwise") {
            Task { await server.jobAction(job, action: "restart") }
        }.buttonStyle(.bordered).disabled(server.busy || alreadyQueued).accessibilityIdentifier("restartJob")
    }
}

private struct SourceLinksView: View {
    let urls: [String]
    @State private var copied: String?
    var body: some View {
        ForEach(Array(urls.enumerated()), id: \.offset) { index, source in
            VStack(alignment: .leading, spacing: 6) {
                Text(urls.count == 1 ? "Source link" : "Source link \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let url = URL(string: source), url.scheme == "https", url.host == "open.spotify.com", url.user == nil, url.password == nil {
                    Link(source, destination: url).buttonStyle(.borderless).font(.caption).lineLimit(3).accessibilityIdentifier("source-link-\(index)")
                } else { Text(source).font(.caption).textSelection(.enabled) }
                Button {
                    UIPasteboard.general.string = source; copied = source
                } label: { Label(copied == source ? "Copied" : "Copy link", systemImage: copied == source ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.bordered).font(.caption).accessibilityIdentifier("copy-source-\(index)")
            }
        }
    }
}

struct AudioPickers: View {
    @Binding var format: String
    @Binding var quality: String
    @Binding var bitrate: String
    var body: some View {
        Picker("File format", selection: $format) { ForEach(AudioChoices.formats, id: \.0) { Text($0.1).tag($0.0) } }
        Picker("Source quality", selection: $quality) { ForEach(AudioChoices.qualities, id: \.0) { Text($0.1).tag($0.0) } }
        if format != "copy" { Picker("Conversion quality", selection: $bitrate) { ForEach(AudioChoices.bitrates, id: \.0) { Text($0.1).tag($0.0) } } }
    }
}

struct AddDownloadView: View {
    @Environment(ServerController.self) private var server
    @Environment(\.spotifiedTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let queued: () -> Void
    @State private var urls = ""
    @State private var format = "copy"
    @State private var quality = "auto"
    @State private var bitrate = "best"
    @State private var preview = false
    var body: some View {
        Form {
            Section("Spotify links") {
                TextField("Track, album, artist, or playlist links", text: $urls, axis: .vertical)
                    .lineLimit(4...8).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("downloadLinks")
            }.listRowBackground(theme.panel)
            Section("Audio") { AudioPickers(format: $format, quality: $quality, bitrate: $bitrate) }.listRowBackground(theme.panel)
            Section {
                Toggle("Preview track list only", isOn: $preview)
                Label(server.state?.server ?? "Music server", systemImage: "server.rack")
                Text("Files are saved on the server. This app sends the links and your selected settings.").font(.caption).foregroundStyle(.secondary)
            }.listRowBackground(theme.panel)
            if let error = server.error { Section { ErrorNotice(message: error) }.listRowBackground(theme.panel) }
            Section {
                Button {
                    Task {
                        if await server.queue(urls: urls, format: format, quality: quality, bitrate: bitrate, preview: preview) { queued(); dismiss() }
                    }
                } label: {
                    HStack { Spacer(); if server.busy { ProgressView() }; Text(preview ? "Preview on server" : "Download on server"); Spacer() }
                }.disabled(server.busy || urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("submitDownload")
            }.listRowBackground(theme.panel)
        }.navigationTitle("Add download").navigationBarTitleDisplayMode(.inline).appSurface()
            .interactiveDismissDisabled(server.busy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(server.busy) } }
            .onAppear {
                if let settings = server.settings { format = settings.format; quality = settings.quality; bitrate = settings.bitrate }
            }
    }
}

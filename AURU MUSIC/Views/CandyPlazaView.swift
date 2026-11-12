import SwiftUI
import PhotosUI

struct CandyPlazaView: View {
    @EnvironmentObject private var plaza: CandyPlazaService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var library: LocalMusicLibrary
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selectedFile: CandyPlazaFile?
    @State private var selectedPlace: String?
    @State private var zoom: Double = 1
    @State private var importing: Set<UUID> = []
    @State private var showsProfile = false

    private var visibleListeners: [CandyPlazaListening] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return plaza.listeners.filter { listener in
            search.isEmpty || listener.title.localizedCaseInsensitiveContains(search)
                || listener.artist.localizedCaseInsensitiveContains(search)
                || listener.ownerName.localizedCaseInsensitiveContains(search)
                || (listener.region ?? "").localizedCaseInsensitiveContains(search)
        }
        .sorted { lhs, rhs in
            if lhs.isOffline != rhs.isOffline { return !lhs.isOffline }
            return lhs.ownerName < rhs.ownerName
        }
    }

    private var markers: [CandyGlobeMarker] {
        var places: [String: CandyGlobeMarker] = [:]
        for listener in visibleListeners {
            guard let key = Self.placeKey(listener), let lat = listener.latitude, let lon = listener.longitude else { continue }
            var marker = places[key] ?? CandyGlobeMarker(id: key, latitude: lat, longitude: lon, online: false, count: 0)
            marker.count += 1
            marker.online = marker.online || !listener.isOffline
            marker.playing = marker.playing || (!listener.isOffline && listener.isPlaying)
            places[key] = marker
        }
        return places.values.sorted { $0.id < $1.id }
    }

    private var listedListeners: [CandyPlazaListening] {
        guard let selectedPlace else { return visibleListeners }
        return visibleListeners.filter { Self.placeKey($0) == selectedPlace }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                searchBar
                globeCard
                CandyPreviewBar(preview: plaza.preview)
                listenerList
                transferTasks
                receiveHistory
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 130)
        }
        .scrollIndicators(.hidden)
        .task { plaza.start() }
        .onChange(of: player.isPlaying) { playing in
            // The library player and the preview never talk over each other.
            if playing { plaza.preview.pause() }
        }
        .onChange(of: markers.map(\.id)) { ids in
            if let selectedPlace, !ids.contains(selectedPlace) { self.selectedPlace = nil }
        }
        .sheet(isPresented: $showsProfile) { CandyProfileView() }
        .confirmationDialog(
            "歌曲",
            isPresented: Binding(
                get: { selectedFile != nil },
                set: { if !$0 { selectedFile = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let selectedFile {
                Button("下载") {
                    plaza.download(selectedFile)
                    self.selectedFile = nil
                }
                Button("取消", role: .cancel) { self.selectedFile = nil }
            }
        } message: {
            if let selectedFile {
                Text("是否接收来自「\(selectedFile.ownerName)」的文件「\(selectedFile.name)」（\(Self.formatSize(selectedFile.size))）？")
            }
        }
        .alert("广场", isPresented: Binding(
            get: { plaza.errorMessage != nil },
            set: { if !$0 { plaza.dismissError() } }
        )) {
            Button(settings.text("ok")) { plaza.dismissError() }
        } message: {
            Text(plaza.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("🍬")
                .font(.system(size: 27))
            Text("Candy广场")
                .font(.title3.weight(.heavy))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .purple, .orange], startPoint: .leading, endPoint: .trailing)
                )
            Spacer()
            Button { showsProfile = true } label: {
                Image(systemName: "person.crop.circle")
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(plaza.connectionState == .connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(plaza.connectionState.title)
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索歌曲、艺人、用户或地区…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
    }

    // MARK: Globe

    private var globeCard: some View {
        let dark = colorScheme == .dark
        let places = markers
        return ZStack {
            // Soft rim glow behind the sphere, as in the reference artwork.
            Circle()
                .fill(dark ? Color.white.opacity(0.06) : Color(red: 1, green: 0.98, blue: 0.9))
                .padding(18)
                .shadow(color: dark ? Color.white.opacity(0.12) : Color(red: 1, green: 0.93, blue: 0.7).opacity(0.9), radius: 22)
            CandyGlobeView(markers: places, selectedID: selectedPlace, dark: dark, zoom: zoom,
                           onZoom: { zoom = $0 }) { id in
                withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = id }
            }
            .padding(18)
            zoomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
            if let selectedPlace {
                placeChip(selectedPlace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
            }
            if visibleListeners.isEmpty {
                Text(plaza.connectionState == .connected ? "暂时没有人在线" : plaza.connectionState.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(dark ? Color(white: 0.08) : Color(red: 0.965, green: 0.965, blue: 0.955),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button {
                zoom = min(CandyGlobeView.maxZoom, zoom * 1.6)
            } label: {
                Image(systemName: "plus").frame(width: 34, height: 34)
            }
            .disabled(zoom >= CandyGlobeView.maxZoom - 0.01)
            Divider().frame(width: 20)
            Button {
                zoom = zoom / 1.6 < 1.05 ? 1 : zoom / 1.6
            } label: {
                Image(systemName: "minus").frame(width: 34, height: 34)
            }
            .disabled(zoom <= 1.001)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("缩放地球")
    }

    private func placeChip(_ key: String) -> some View {
        let people = visibleListeners.filter { Self.placeKey($0) == key }
        let playing = people.contains { !$0.isOffline && $0.isPlaying }
        return HStack(spacing: 6) {
            Circle()
                .fill(playing ? Color.orange : Color.gray)
                .frame(width: 7, height: 7)
            Text(people.first?.region ?? "所选地点").font(.caption.weight(.semibold)).lineLimit(1)
            Text("\(people.count)人").font(.caption2).foregroundStyle(.secondary)
            Button {
                withAnimation { selectedPlace = nil }
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消选择地点")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Users

    private var listenerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if selectedPlace != nil {
                    Label(listedListeners.first?.region ?? "所选地点", systemImage: "mappin.and.ellipse").font(.headline)
                    Spacer()
                    Button("全部") { withAnimation { selectedPlace = nil } }
                        .font(.caption.weight(.semibold))
                } else {
                    Text("在线用户").font(.headline)
                    Spacer()
                    Text("\(visibleListeners.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if listedListeners.isEmpty {
                Text(query.isEmpty ? "还没有人在广场分享歌曲" : "没有匹配的用户")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(listedListeners) { listener in
                CandyListenerRow(
                    listener: listener,
                    transfer: listener.file.flatMap { plaza.downloads[$0.id] },
                    preview: plaza.preview,
                    locate: Self.placeKey(listener).map { key -> () -> Void in { withAnimation { selectedPlace = key } } },
                    listen: {
                        guard let file = listener.file else { return }
                        player.pause()
                        plaza.listen(file)
                    },
                    download: { selectedFile = listener.file }
                )
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var receiveHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("接收记录").font(.headline)
                Spacer()
                if !plaza.receiveHistory.isEmpty {
                    Button("清除记录") { plaza.clearReceiveHistory() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if plaza.receiveHistory.isEmpty {
                Text("还没有接收过文件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(plaza.receiveHistory) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("来自 \(entry.fromName ?? "匿名访客") · \(Self.formatSize(entry.size)) · \(entry.time.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let url = entry.localURL, FileManager.default.fileExists(atPath: url.path) {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            importButton(entry, url: url)
                        } else {
                            Text("文件已移除")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(11)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    /// Received songs live in Documents/Candy Downloads; importing copies one into the music library.
    @ViewBuilder
    private func importButton(_ entry: CandyPlazaHistory, url: URL) -> some View {
        if isInLibrary(url) {
            Text("已导入")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.13), in: Capsule())
        } else if importing.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            Button {
                importing.insert(entry.id)
                Task { @MainActor in
                    await library.importFiles(from: [url])
                    importing.remove(entry.id)
                }
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(library.isImporting || !LocalMusicLibrary.supportedAudioExtensions.contains(url.pathExtension.lowercased()))
        }
    }

    /// The library either indexed the received file itself or holds an imported copy of it.
    private func isInLibrary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let name = url.deletingPathExtension().lastPathComponent
        return library.tracks.contains { track in
            track.fileURL.standardizedFileURL.path == path
                || track.fileURL.deletingPathExtension().lastPathComponent == name
        }
    }

    private var transferTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(plaza.downloads.values.sorted { $0.id < $1.id }) { download in
                if !download.state.isComplete {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(download.file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(download.status).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            switch download.state {
                            case .downloading:
                                ProgressView(value: download.progress)
                                Text("\(Int(download.progress * 100))%").font(.caption.monospacedDigit())
                                Button("取消") { plaza.cancelDownload(download.id) }
                            case .failed:
                                Button("重试") { plaza.retryDownload(download.file) }
                                Button("清除断点") { plaza.clearDownloadPartial(download.file) }
                            case .complete:
                                EmptyView()
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    /// Users whose coarse location rounds to the same 0.1° share one lit dot.
    static func placeKey(_ listener: CandyPlazaListening) -> String? {
        guard let lat = listener.latitude, let lon = listener.longitude else { return nil }
        return String(format: "%.1f,%.1f", lat, lon)
    }

    fileprivate static func formatSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct CandyListenerRow: View {
    let listener: CandyPlazaListening
    let transfer: CandyPlazaDownload?
    let preview: CandyPreviewPlayer
    let locate: (() -> Void)?
    let listen: () -> Void
    let download: () -> Void

    private var isDownloading: Bool {
        if case .downloading = transfer?.state { return true }
        return false
    }

    private var isDownloaded: Bool { transfer?.state.isComplete == true }

    var body: some View {
        HStack(spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(listener.ownerName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Button { locate?() } label: {
                        Text(listener.region ?? "地区未知").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(locate == nil)
                }
                Text(listener.artist.isEmpty ? listener.title : "\(listener.title) · \(listener.artist)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isDownloading, let transfer {
                    ProgressView(value: transfer.progress).tint(.purple).frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 4)
            CandyListenButton(
                preview: preview,
                fileID: listener.file?.id,
                enabled: listener.file != nil && (!listener.isOffline || isDownloaded),
                listen: listen
            )
            Button(action: download) {
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(isDownloaded ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(listener.file == nil || listener.isOffline || isDownloading || isDownloaded)
            .accessibilityLabel("下载")
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .opacity(listener.isOffline ? 0.5 : 1)
    }

    @ViewBuilder private var avatar: some View {
        if let encoded = listener.avatar, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) { onlineDot }
        } else {
            Circle()
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(Text(String(listener.ownerName.prefix(1))).font(.subheadline.weight(.bold)).foregroundStyle(.white))
                .overlay(alignment: .bottomTrailing) { onlineDot }
        }
    }

    private var onlineDot: some View {
        Circle()
            .fill(listener.isOffline ? Color.gray : Color.green)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
    }
}

/// "听听看" until tapped; then an equalizer that dances while the preview plays.
/// Tapping it again pauses or resumes that preview.
private struct CandyListenButton: View {
    @ObservedObject var preview: CandyPreviewPlayer
    let fileID: String?
    let enabled: Bool
    let listen: () -> Void

    private var isCurrent: Bool { fileID != nil && preview.file?.id == fileID }

    private var isFailed: Bool {
        if case .failed = preview.phase { return true }
        return false
    }

    var body: some View {
        Button {
            if isCurrent { preview.toggle() } else { listen() }
        } label: {
            Group {
                if isCurrent && isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else if isCurrent {
                    CandyEqualizer(animating: preview.phase == .playing)
                } else {
                    Label("听听看", systemImage: "play.fill")
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(isCurrent ? Color.pink : Color.primary)
            .frame(minWidth: isCurrent ? 44 : nil, minHeight: 16)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((isCurrent ? Color.pink : Color.purple).opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !isCurrent)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .accessibilityLabel(isCurrent ? (preview.phase == .playing ? "暂停试听" : "继续试听") : "听听看")
    }
}

private struct CandyEqualizer: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { bar in
                    let level = animating ? (sin(t * (6 + Double(bar) * 1.9) + Double(bar) * 1.3) + 1) / 2 : 0.3
                    Capsule().frame(width: 3, height: 4 + 11 * level)
                }
            }
            .frame(height: 15, alignment: .bottom)
        }
    }
}

private struct CandyPreviewBar: View {
    @ObservedObject var preview: CandyPreviewPlayer

    var body: some View {
        if preview.isActive { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button { preview.toggle() } label: {
                    Image(systemName: preview.phase == .playing || preview.phase == .buffering ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                        .background(Color.purple.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isFailed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(isFailed ? Color.red : Color.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { preview.stop() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止试听")
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let played = preview.duration > 0 ? min(1, preview.currentTime / preview.duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: width * preview.buffered)
                    Capsule().fill(Color.purple).frame(width: width * played)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    preview.seek(to: max(0, min(1, value.location.x / max(1, width))))
                })
            }
            .frame(height: 5)
            HStack {
                Text(Self.time(preview.currentTime))
                Spacer()
                Text(preview.duration > 0 ? Self.time(preview.duration) : "--:--")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var isFailed: Bool {
        if case .failed = preview.phase { return true }
        return false
    }

    private var title: String {
        guard let file = preview.file else { return "" }
        return URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
    }

    private var subtitle: String {
        let owner = preview.file.map { "来自 \($0.ownerName)" } ?? ""
        switch preview.phase {
        case .failed(let message): return message
        case .buffering:
            let detail = preview.status.isEmpty ? "缓冲中" : preview.status
            return "\(owner) · \(detail) · 已接收 \(Int(preview.buffered * 100))%"
        case .playing, .paused:
            return preview.buffered < 1 ? "\(owner) · 边下边播 \(Int(preview.buffered * 100))%" : "\(owner) · 已完整接收"
        case .idle: return owner
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension CandyPlazaDownload.State {
    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

private struct CandyProfileView: View {
    @EnvironmentObject private var plaza: CandyPlazaService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var removesAvatar = false
    @State private var loading = false
    @State private var profileError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("昵称", text: $name)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("选择头像", systemImage: "photo")
                }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(height: 100)
                } else if !removesAvatar, let encoded = plaza.avatar,
                          let data = Data(base64Encoded: encoded), let avatar = UIImage(data: data) {
                    Image(uiImage: avatar).resizable().scaledToFit().frame(height: 100)
                }
                Button("移除头像", role: .destructive) {
                    image = nil
                    photo = nil
                    removesAvatar = true
                }
                if loading { ProgressView() }
                if let profileError { Text(profileError).foregroundStyle(.red) }
            }
            .navigationTitle("广场资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if plaza.updateProfile(name: name, image: image, removeAvatar: removesAvatar) {
                            dismiss()
                        } else {
                            profileError = plaza.errorMessage
                        }
                    }
                    .disabled(loading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40)
                }
            }
        }
        .onAppear { name = plaza.nickname }
        .onChange(of: photo) { item in
            guard let item else { return }
            loading = true
            Task { @MainActor in
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          data.count <= 10_000_000, let loaded = UIImage(data: data) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard photo == item else { return }
                    image = loaded
                    removesAvatar = false
                    profileError = nil
                } catch {
                    guard photo == item else { return }
                    profileError = "无法加载头像：\(error.localizedDescription)"
                }
                loading = false
            }
        }
    }
}

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
    /// 0 shows the first page in the usual order; any other value is a random draw.
    @State private var shuffleSeed = 0

    private static let pageSize = 10
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
        var shownRank: [String: Int] = [:]
        for listener in visibleListeners {
            guard let key = Self.placeKey(listener), let lat = listener.latitude, let lon = listener.longitude else { continue }
            var marker = places[key] ?? CandyGlobeMarker(id: key, latitude: lat, longitude: lon, online: false, count: 0)
            marker.count += 1
            marker.online = marker.online || !listener.isOffline
            marker.playing = marker.playing || (!listener.isOffline && listener.isPlaying)
            // The zoomed-in bubble shows someone playing, else someone online.
            let rank = listener.isOffline ? 0 : (listener.isPlaying ? 2 : 1)
            if rank > shownRank[key, default: -1] {
                shownRank[key] = rank
                marker.name = listener.ownerName
                marker.song = listener.artist.isEmpty ? listener.title : "\(listener.title) · \(listener.artist)"
                marker.avatar = listener.avatar
            }
            places[key] = marker
        }
        return places.values.sorted { $0.id < $1.id }
    }

    private var listedListeners: [CandyPlazaListening] {
        guard let selectedPlace else { return visibleListeners }
        return visibleListeners.filter { Self.placeKey($0) == selectedPlace }
    }

    /// At most 10 rows. With more users, 随机 draws another 10 (online users first);
    /// the draw is stable between redraws until the button is tapped again.
    private var shownListeners: [CandyPlazaListening] {
        let all = listedListeners
        guard all.count > Self.pageSize else { return all }
        guard shuffleSeed != 0 else { return Array(all.prefix(Self.pageSize)) }
        let seed = shuffleSeed
        func draw(_ listener: CandyPlazaListening) -> Int {
            var hasher = Hasher()
            hasher.combine(seed)
            hasher.combine(listener.clientId)
            return hasher.finalize()
        }
        let picked = all.sorted { lhs, rhs in
            if lhs.isOffline != rhs.isOffline { return !lhs.isOffline }
            return draw(lhs) < draw(rhs)
        }
        return Array(picked.prefix(Self.pageSize))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                searchBar
                globeCard
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
                let smaller: Double = zoom / 1.6
                zoom = smaller < 1.05 ? 1.0 : smaller
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
                .fill(playing ? Color.purple : Color.gray)
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
                    shuffleButton
                    Button("全部") { withAnimation { selectedPlace = nil } }
                        .font(.caption.weight(.semibold))
                } else {
                    Text("在线用户").font(.headline)
                    Spacer()
                    shuffleButton
                    Text("\(visibleListeners.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if listedListeners.isEmpty {
                Text(query.isEmpty ? "还没有人在广场分享歌曲" : "没有匹配的用户")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(shownListeners) { listener in
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

    @ViewBuilder
    private var shuffleButton: some View {
        if listedListeners.count > Self.pageSize {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { shuffleSeed = Int.random(in: 1...Int.max) }
            } label: {
                Label("随机", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("随机显示另外 \(Self.pageSize) 位用户")
        }
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
                    _ = importing.remove(entry.id)
                }
            } label: {
                Label("导入", systemImage: "folder.badge.plus")
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
                isSong: listener.file.map { CandyListenButton.isSong($0.name) } ?? true,
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
    /// False for files that are not audio (video, documents…): the button is greyed out.
    let isSong: Bool
    let enabled: Bool
    let listen: () -> Void

    static func isSong(_ name: String) -> Bool {
        LocalMusicLibrary.supportedAudioExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private var usable: Bool { isSong && (enabled || isCurrent) }

    private var isCurrent: Bool { fileID != nil && preview.file?.id == fileID }

    @State private var failure: String?

    private var isFailed: Bool {
        if case .failed = preview.phase { return true }
        return false
    }

    var body: some View {
        Button {
            // A failed preview is retried; otherwise the button pauses/resumes the current one.
            if isCurrent && !isFailed { preview.toggle() } else { listen() }
        } label: {
            Group {
                if isCurrent && isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else if isCurrent && preview.phase == .buffering {
                    ProgressView().controlSize(.mini).tint(.purple)
                } else if isCurrent {
                    CandyEqualizer(animating: preview.phase == .playing)
                } else {
                    Label("听听看", systemImage: "play.fill")
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(!usable ? Color.white.opacity(0.3) : (isCurrent ? Color.purple : Color.primary))
            .frame(minWidth: isCurrent ? CGFloat(44) : nil, minHeight: CGFloat(16))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(usable ? Color.purple.opacity(isCurrent ? 0.24 : 0.16) : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .accessibilityLabel(isCurrent ? (preview.phase == .playing ? "暂停试听" : "继续试听") : "听听看")
        .onChange(of: preview.phase) { phase in
            // With no progress panel, a failed preview (e.g. Ogg, checksum mismatch) is explained once here.
            guard isCurrent, case .failed(let message) = phase else { return }
            failure = message
        }
        .alert("听听看", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }
}

private struct CandyEqualizer: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { bar in
                    Capsule().frame(width: 3, height: Self.height(bar: bar, time: context.date, animating: animating))
                }
            }
            .frame(height: 15, alignment: .bottom)
        }
    }

    private static func height(bar: Int, time: Date, animating: Bool) -> CGFloat {
        guard animating else { return 7 }
        let index = Double(bar)
        let speed: Double = 6.0 + index * 1.9
        let angle: Double = time.timeIntervalSinceReferenceDate * speed + index * 1.3
        let level: Double = (Foundation.sin(angle) + 1.0) / 2.0
        return CGFloat(4.0 + 11.0 * level)
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

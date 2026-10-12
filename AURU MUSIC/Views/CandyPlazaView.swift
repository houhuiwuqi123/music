import SwiftUI
import PhotosUI

struct CandyPlazaView: View {
    @EnvironmentObject private var plaza: CandyPlazaService
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var selectedFile: CandyPlazaFile?
    @State private var showsProfile = false

    private var visibleListeners: [CandyPlazaListening] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return plaza.listeners.filter { listener in
            search.isEmpty || listener.title.localizedCaseInsensitiveContains(search)
                || listener.artist.localizedCaseInsensitiveContains(search)
                || listener.ownerName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                searchBar
                starField
                    .frame(height: 455)
                transferTasks
                receiveHistory
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 130)
        }
        .scrollIndicators(.hidden)
        .task { plaza.start() }
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
            TextField("搜索歌曲、艺人或用户…", text: $query)
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

    private var starField: some View {
        GeometryReader { geometry in
            ZStack {
                Image(plaza.listeners.contains { !$0.isOffline } ? "PlazaOnline" : "PlazaEmpty")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                    .clipped()
                    .allowsHitTesting(false)

                if !visibleListeners.isEmpty {
                    ForEach(visibleListeners) { listener in
                        let index = visibleListeners.firstIndex(where: { $0.id == listener.id }) ?? 0
                        CandyFileStar(
                            listener: listener,
                            download: listener.file.flatMap { plaza.downloads[$0.id] },
                            fieldSize: geometry.size,
                            slotIndex: index,
                            totalSlots: max(1, visibleListeners.count),
                            action: { selectedFile = listener.file }
                        )
                        .id(listener.id)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }
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
                        }
                        Text("已完成")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.13), in: Capsule())
                    }
                    .padding(11)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
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

    fileprivate static func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    fileprivate static func formatSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct CandyFileStar: View {
    let listener: CandyPlazaListening
    let download: CandyPlazaDownload?
    let fieldSize: CGSize
    let slotIndex: Int
    let totalSlots: Int
    let action: () -> Void
    @State private var flightStartedAt = Date()
    @State private var frozenDate: Date?
    @State private var successGlow = false

    private var hash: UInt32 { CandyPlazaView.stableHash(listener.id) }
    private var starSize: CGFloat {
        let logarithm = log10(Double(max(listener.file?.size ?? 0, 1_024)))
        let fraction = min(1, max(0, (logarithm - 3) / 6))
        return CGFloat(16 + fraction * 18)
    }
    private var isDownloading: Bool {
        guard let download else { return false }
        if case .downloading = download.state { return true }
        return false
    }
    private var isComplete: Bool { download?.state.isComplete == true && successGlow }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: listener.isOffline)) { timeline in
            let date = listener.isOffline ? (frozenDate ?? timeline.date) : timeline.date
            let time = max(0, date.timeIntervalSince(flightStartedAt) - Double(hash % 1000) / 1000 * 3) / 14
            let cycle = Int(time.rounded(.down))
            let progress = time - Double(cycle)
            let seed = hash &+ UInt32(truncatingIfNeeded: cycle) &* 2_654_435_761
            let startX = 0.86 + Double(seed % 100) / 100 * 0.10
            let endX = 0.10 + Double((seed >> 8) % 100) / 100 * 0.12
            let y = 0.88 - progress * 0.73
            let scale = 1.15 - progress * 0.70
            // 空间位置分散：通过用户唯一哈希与 slotIndex 在右下角随机分配非重叠区域（左右偏移 ±28pt，上下偏移 ±18pt）
            let userOffsetX = totalSlots > 1 ? (Double((hash ^ (UInt32(slotIndex) &* 31)) % 100) / 100.0 - 0.5) * 56.0 : 0
            let userOffsetY = totalSlots > 1 ? (Double(((hash >> 8) ^ (UInt32(slotIndex) &* 17)) % 100) / 100.0 - 0.5) * 36.0 : 0
            let x = startX + (endX - startX) * progress
            Button(action: action) {
                VStack(spacing: 5) {
                    ZStack {
                        if !listener.isOffline {
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, .purple.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: 65, height: 2)
                                .rotationEffect(.degrees(40))
                                .offset(x: 23, y: 23)
                        }
                        if let encoded = listener.avatar, let data = Data(base64Encoded: encoded),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 38, height: 38)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "star.fill")
                                .font(.system(size: starSize))
                                .foregroundStyle(
                                    LinearGradient(colors: [.pink, .purple, Color(red: 1, green: 0.82, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .shadow(color: (isComplete ? Color.green : Color.pink).opacity(0.75), radius: isComplete ? 18 : 9)
                        }
                        if isDownloading {
                            Text("\(Int((download?.progress ?? 0) * 100))%")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .frame(width: 54, height: 42)
                    .shadow(color: isComplete ? .green : .clear, radius: 16)
                    VStack(spacing: 2) {
                        Text("\(listener.ownerName) · \(listener.region ?? "地区未知")")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(listener.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 144)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDownloading || listener.file == nil || listener.isOffline)
            .saturation(listener.isOffline ? 0 : 1)
            .opacity(listener.isOffline ? 0.45 : max(0, min(1, sin(progress * .pi) * 3)))
            .scaleEffect(scale)
            .position(
                x: min(max(fieldSize.width * 0.12, fieldSize.width * x + userOffsetX), fieldSize.width * 0.94),
                y: min(max(fieldSize.height * 0.12, fieldSize.height * y + userOffsetY), fieldSize.height * 0.94)
            )
        }
        .onAppear {
            if download?.state.isComplete == true { showSuccessGlow() }
            if listener.isOffline { frozenDate = Date() }
        }
        .onChange(of: download?.state.isComplete) { completed in
            if completed == true { showSuccessGlow() }
        }
        .onChange(of: listener.file?.id) { _ in successGlow = false }
        .onChange(of: listener.isOffline) { offline in
            if offline {
                frozenDate = Date()
            } else {
                if let frozenDate {
                    flightStartedAt = flightStartedAt.addingTimeInterval(Date().timeIntervalSince(frozenDate))
                }
                frozenDate = nil
            }
        }
    }

    private func showSuccessGlow() {
        successGlow = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            successGlow = false
        }
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

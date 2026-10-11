import SwiftUI
import UniformTypeIdentifiers

struct CandyPlazaView: View {
    @EnvironmentObject private var plaza: CandyPlazaService
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var showsPublishPanel = false
    @State private var selectedFile: CandyPlazaFile?

    private var visibleFiles: [CandyPlazaFile] {
        let ownIDs = Set(plaza.shares.keys)
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return plaza.files.filter { file in
            !ownIDs.contains(file.id)
                && file.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let connectionError = plaza.connectionError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(connectionError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("重新连接") { plaza.retryConnection() }
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                searchBar
                starField
                    .frame(height: 455)
                receiveHistory
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 130)
        }
        .scrollIndicators(.hidden)
        .task { plaza.start() }
        .sheet(isPresented: $showsPublishPanel) {
            CandyPublishPanelView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "接收文件",
            isPresented: Binding(
                get: { selectedFile != nil },
                set: { if !$0 { selectedFile = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let selectedFile {
                Button("确认接收") {
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
            Button { showsPublishPanel = true } label: {
                Label("发布", systemImage: "plus")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索文件名…", text: $query)
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
                RadialGradient(
                    colors: [Color(red: 0.16, green: 0.10, blue: 0.34), Color(red: 0.035, green: 0.035, blue: 0.10), .black],
                    center: .topLeading,
                    startRadius: 8,
                    endRadius: max(geometry.size.width, geometry.size.height) * 1.1
                )
                .overlay { CandyAmbientStars() }

                if visibleFiles.isEmpty {
                    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(search.isEmpty ? "夜空中还没有人分享文件…" : "没有找到包含「\(search)」的文件")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else {
                    ForEach(visibleFiles) { file in
                        let point = Self.position(for: file.id, size: geometry.size)
                        CandyFileStar(
                            file: file,
                            download: plaza.downloads[file.id],
                            action: { selectedFile = file }
                        )
                        .position(point)
                        .id(file.id)
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

    private static func position(for id: String, size: CGSize) -> CGPoint {
        let hash = stableHash(id)
        let x = 0.12 + Double(hash & 0xffff) / 65_535 * 0.76
        let y = 0.17 + Double((hash >> 16) & 0xffff) / 65_535 * 0.66
        let width = max(0, size.width - 140)
        return CGPoint(x: 70 + width * (x - 0.12) / 0.76, y: size.height * y)
    }

    fileprivate static func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    fileprivate static func formatSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct CandyFileStar: View {
    let file: CandyPlazaFile
    let download: CandyPlazaDownload?
    let action: () -> Void
    @State private var pulsing = false
    @State private var drifting = false
    @State private var successGlow = false

    private var hash: UInt32 { CandyPlazaView.stableHash(file.id) }
    private var starSize: CGFloat {
        let logarithm = log10(Double(max(file.size, 1_024)))
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
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Image(systemName: "star.fill")
                        .font(.system(size: starSize))
                        .foregroundStyle(
                            LinearGradient(colors: [.pink, .purple, Color(red: 1, green: 0.82, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .shadow(color: (isComplete ? Color.green : Color.pink).opacity(0.75), radius: isComplete ? 18 : 9)
                        .scaleEffect(pulsing ? 1.12 : 0.82)
                        .opacity(pulsing ? 1 : 0.55)
                    if isDownloading {
                        Text("\(Int((download?.progress ?? 0) * 100))%")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
                .frame(width: 54, height: 42)
                VStack(spacing: 1) {
                    Text(file.ownerName)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.42))
                        .lineLimit(1)
                    Text(file.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 132)
            }
            .offset(
                x: drifting ? CGFloat(Int(hash % 15) - 7) : CGFloat(7 - Int(hash % 15)),
                y: drifting ? CGFloat(Int((hash >> 5) % 13) - 6) : CGFloat(6 - Int((hash >> 5) % 13))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
        .onAppear {
            if download?.state.isComplete == true { showSuccessGlow() }
            withAnimation(.easeInOut(duration: 1.4 + Double(hash % 13) / 10).repeatForever(autoreverses: true).delay(Double((hash >> 3) % 18) / 10)) {
                pulsing = true
            }
            withAnimation(.easeInOut(duration: 16 + Double((hash >> 9) % 140) / 10).repeatForever(autoreverses: true).delay(Double((hash >> 12) % 60) / 10)) {
                drifting = true
            }
        }
        .onChange(of: download?.state.isComplete) { completed in
            if completed == true { showSuccessGlow() }
        }
        .onChange(of: isDownloading) { downloading in
            withAnimation(
                .easeInOut(duration: downloading ? 0.48 : 1.4 + Double(hash % 13) / 10)
                    .repeatForever(autoreverses: true)
            ) {
                pulsing.toggle()
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

private struct CandyAmbientStars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<90 {
                    let seed = UInt32(index + 1) &* 2_654_435_761
                    let x = CGFloat(seed % 10_000) / 10_000 * size.width
                    let y = CGFloat((seed >> 8) % 10_000) / 10_000 * size.height
                    let phase = Double(seed % 31) / 5
                    let opacity = 0.15 + (sin(time * (0.5 + Double(index % 5) * 0.13) + phase) + 1) * 0.22
                    let rect = CGRect(x: x, y: y, width: 1.4, height: 1.4)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CandyPublishPanelView: View {
    @EnvironmentObject private var plaza: CandyPlazaService
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showsFileImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showsFileImporter = true } label: {
                        Label("选择文件发布", systemImage: "doc.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                } footer: {
                    Text("文件会复制到本机的 Candy Shares 文件夹；只有你在线时，其他用户才能接收。")
                }

                Section("我的分享") {
                    if plaza.shares.isEmpty {
                        Text("还没有发布任何文件").foregroundStyle(.secondary)
                    } else {
                        ForEach(plaza.shares.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name).lineLimit(1)
                                    Text(CandyPlazaView.formatSize(file.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("撤回", role: .destructive) { plaza.unpublish(file.id) }
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }

                Section {
                    if plaza.publishHistory.isEmpty {
                        Text("还没有发布记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(plaza.publishHistory) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1)
                                Text("\(CandyPlazaView.formatSize(entry.size)) · \(entry.time.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("发布记录")
                        Spacer()
                        if !plaza.publishHistory.isEmpty {
                            Button("清除记录") { plaza.clearPublishHistory() }
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("发布文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.text("done")) { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await plaza.publishFiles(urls) }
            case .failure(let error):
                // The picker cancellation is also returned as a failure.
                if (error as NSError).code != NSUserCancelledError {
                    plaza.reportImportError(error.localizedDescription)
                }
            }
        }
    }
}

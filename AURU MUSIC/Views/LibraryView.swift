import SwiftUI

/// The Library tab: a large title over a list of sections (Playlists, Artists, Songs,
/// Recognize Music). Picking a section swaps in that screen with a back header. The
/// section screens keep their own NavigationStacks, so they are shown in place rather
/// than pushed onto another stack.
struct LibraryView: View {
    enum Entry: Hashable, CaseIterable {
        case playlists, artists, songs, recognize

        var titleKey: String {
            switch self {
            case .playlists: return "playlists"
            case .artists: return "artists"
            case .songs: return "librarySongs"
            case .recognize: return "recognizeMusic"
            }
        }

        var icon: String {
            switch self {
            case .playlists: return "music.note.list"
            case .artists: return "music.mic"
            case .songs: return "music.note"
            case .recognize: return "shazam.logo"
            }
        }
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalMusicLibrary
    /// Index this tab has in the tab bar; reselecting it returns to the list.
    let tabIndex: Int
    let onImport: () -> Void

    @State private var section: Entry?
    @State private var showsRecognition = false

    var body: some View {
        ZStack {
            if let section {
                detail(section)
                    .transition(.move(edge: .trailing))
            } else {
                list
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: section)
        .fullScreenCover(isPresented: $showsRecognition) { SongRecognitionView() }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { notification in
            guard notification.object as? Int == tabIndex else { return }
            section = nil
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 14)
                ForEach(Entry.allCases, id: \.self) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(LibraryRowStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(settings.text("library"))
                .font(.system(size: 34, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button(action: onImport) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(library.isImporting)
            .accessibilityLabel(settings.text("import"))
        }
    }

    private func row(_ item: Entry) -> some View {
        HStack(spacing: 18) {
            Image(systemName: item.icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 34)
            VStack(spacing: 0) {
                HStack {
                    Text(settings.text(item.titleKey))
                        .font(.system(size: 21))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 62)
                // Separator starts under the text, as in iOS list rows.
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 0.5)
            }
        }
        .contentShape(Rectangle())
    }

    private func open(_ item: Entry) {
        if item == .recognize {
            showsRecognition = true
        } else {
            section = item
        }
    }

    // MARK: Detail

    private func detail(_ item: Entry) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    section = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        Text(settings.text("library"))
                    }
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(settings.text(item.titleKey)).font(.headline)
                Spacer()
                // Balances the back button so the title stays centred.
                Color.clear.frame(width: 70, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            switch item {
            case .playlists: PlaylistsView()
            case .artists: ArtistsView()
            case .songs: SongsView()
            case .recognize: EmptyView()
            }
        }
        .gesture(
            // Edge swipe right goes back, like a navigation pop.
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.startLocation.x < 30 && value.translation.width > 80 { section = nil }
            }
        )
    }
}

private struct LibraryRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
    }
}

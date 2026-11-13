import SwiftUI

/// The Library tab: a plain list of sections (Playlists, Artists, Songs, Recognize Music).
/// The page title, back button and import button live in RootView's top bar, which reads
/// `section`. The section screens keep their own NavigationStacks, so they are shown in
/// place rather than pushed onto another stack.
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
    /// The open section, nil for the list. Owned by RootView so its top bar can show a back button.
    @Binding var section: Entry?
    /// Index this tab has in the tab bar; reselecting it returns to the list.
    let tabIndex: Int

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

    /// Laid out like the iOS Music library list: no card, icon column on the left, and a
    /// hairline under each row that starts at the text and runs to the right edge.
    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Entry.allCases, id: \.self) { item in
                    Button { open(item) } label: { row(item) }
                        .buttonStyle(LibraryRowStyle())
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ item: Entry) -> some View {
        HStack(spacing: 16) {
            Image(systemName: item.icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.purple)
                .frame(width: 34)
            VStack(spacing: 0) {
                HStack {
                    Text(settings.text(item.titleKey))
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.trailing, 6)
                }
                .frame(height: 52)
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(height: 0.5)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
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

    @ViewBuilder
    private func detail(_ item: Entry) -> some View {
        Group {
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
            .background(Color.purple.opacity(configuration.isPressed ? 0.16 : 0))
    }
}

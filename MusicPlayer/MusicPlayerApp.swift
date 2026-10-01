import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var library = LocalMusicLibrary()
    @StateObject private var player = MusicPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(nil)
        }
    }
}

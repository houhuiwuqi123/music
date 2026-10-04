import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var library = LocalMusicLibrary()
    @StateObject private var player = MusicPlayerViewModel()
    @StateObject private var dataStore = MusicDataStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(dataStore)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

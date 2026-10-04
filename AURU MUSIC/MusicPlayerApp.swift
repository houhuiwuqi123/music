import SwiftUI
import UIKit

@main
struct MusicPlayerApp: App {
    @StateObject private var library = LocalMusicLibrary()
    @StateObject private var player = MusicPlayerViewModel()
    @StateObject private var dataStore = MusicDataStore()
    @StateObject private var settings = AppSettings()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.025, green: 0.03, blue: 0.055, alpha: 1)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

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

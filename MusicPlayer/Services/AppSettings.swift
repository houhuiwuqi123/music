import Combine
import Foundation
import UserNotifications

@MainActor
final class AppSettings: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case chinese = "zh"
        case english = "en"

        var id: String { rawValue }
        var title: String { self == .chinese ? "中文" : "English" }
    }

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "app-language") }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications-enabled")
            if notificationsEnabled { requestNotificationPermission() }
        }
    }

    init() {
        language = Language(rawValue: UserDefaults.standard.string(forKey: "app-language") ?? "en") ?? .english
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications-enabled")
    }

    func text(_ key: String) -> String {
        let translations: [String: (zh: String, en: String)] = [
            "home": ("首页", "Home"), "songs": ("音乐库", "Songs"), "artists": ("艺人", "Artists"),
            "playlists": ("歌单", "Playlists"), "search": ("搜索歌曲、艺人、歌单", "Search songs, artists, playlists"),
            "recent": ("最近播放", "Recently Played"), "top": ("播放排行", "Top Played"),
            "allSongs": ("全部歌曲", "All Songs"), "settings": ("设置", "Settings"),
            "language": ("语言", "Language"), "notifications": ("通知", "Notifications"),
            "about": ("关于", "About"), "version": ("版本", "Version"), "policy": ("隐私政策", "Privacy Policy"),
            "support": ("支持", "Support"), "import": ("导入本地音乐", "Import Local Music"),
            "newPlaylist": ("新建歌单", "New Playlist"), "playlistName": ("歌单名称", "Playlist Name"),
            "cancel": ("取消", "Cancel"), "create": ("创建", "Create"), "tracks": ("首歌曲", "tracks"),
            "songsSection": ("歌曲", "Songs"), "videos": ("视频", "Videos"),
            "noVideos": ("暂无本地视频", "No local videos"), "noMusic": ("暂无本地音乐", "No Local Music"),
            "importHint": ("本应用只支持本地音乐播放，需要从“文件”导入音乐或视频", "This app only plays local media. Import music or video from Files."),
            "addPlaylist": ("添加到歌单", "Add to Playlist"), "removePlaylist": ("从歌单移除", "Remove from Playlist"),
            "plays": ("次播放", "plays"), "nowPlaying": ("正在播放", "Now Playing"),
            "playAll": ("播放全部", "Play All"), "shufflePlay": ("随机播放", "Shuffle Play"),
            "delete": ("删除", "Delete"), "deletePlaylist": ("删除歌单", "Delete Playlist"),
            "musicVideos": ("音乐视频", "Music Videos"), "importComplete": ("导入完成", "Import Complete"),
            "itemsImported": ("个本地媒体文件已加入资料库。", "local media items were added to your library."),
            "unknownArtist": ("未知艺人", "Unknown Artist"), "noResults": ("没有搜索结果", "No Results"),
            "done": ("完成", "Done"), "importFailed": ("导入失败", "Import Failed"), "ok": ("好", "OK"),
            "privacyBody": ("音乐文件、歌单和播放历史仅保存在本机。本应用不会上传或分享本地媒体。通知权限为可选项，可随时在 iOS 设置中更改。", "Your music files, playlists, and playback history stay on this device. The app does not upload or share your local media. Notification permission is optional and can be changed in iOS Settings at any time."),
            "video": ("视频", "Video"), "importing": ("正在导入媒体…", "Importing media…"),
            "details": ("详情", "Details"), "changeCover": ("上传封面", "Upload Cover"),
            "addSongs": ("添加音乐", "Add Songs"), "manageSongs": ("管理音乐", "Manage Songs"),
            "album": ("专辑", "Album"), "duration": ("时长", "Duration"),
            "file": ("本地文件", "Local File"), "added": ("已添加", "Added"),
            "playNext": ("下一首播放", "Play Next"), "rename": ("修改名称", "Rename"),
            "songName": ("歌曲名称", "Song Name"), "save": ("保存", "Save"),
            "lyrics": ("歌词", "Lyrics"), "noLyrics": ("暂无歌词", "No Lyrics"),
            "uploadLyrics": ("上传歌词", "Upload Lyrics"),
            "deleteSongTitle": ("如何删除这首歌曲？", "How would you like to remove this song?"),
            "removeFromLibrary": ("仅从音乐库移除", "Remove from Library Only"),
            "deleteLocalFile": ("删除本地文件", "Delete Local File"),
            "deleteLocalMessage": ("删除本地文件后无法恢复；仅从音乐库移除会保留设备中的文件。", "Deleting the local file cannot be undone. Removing it from the library keeps the file on this device."),
            "deletePlaylistTitle": ("删除歌单", "Delete Playlist"),
            "playlistOnly": ("保留音乐，仅删歌单", "Keep Music, Delete Playlist"),
            "playlistAndLibrary": ("移出音乐库并删歌单", "Remove Songs and Playlist"),
            "playlistAndFiles": ("删除本地歌曲和歌单", "Delete Local Songs and Playlist"),
            "deletePlaylistMessage": ("请选择是否同时处理歌单中的歌曲。", "Choose whether to also remove the songs in this playlist.")
        ]
        guard let value = translations[key] else { return key }
        return language == .chinese ? value.zh : value.en
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard !granted else { return }
            Task { @MainActor [weak self] in self?.notificationsEnabled = false }
        }
    }

    func notifyImportCompleted(count: Int) {
        guard notificationsEnabled, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = text("importComplete")
        content.body = "\(count) \(text("itemsImported"))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "import-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

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
    @Published var showsNotificationSettingsPrompt = false

    init() {
        language = Language(rawValue: UserDefaults.standard.string(forKey: "app-language") ?? "en") ?? .english
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications-enabled")
        refreshNotificationAuthorization()
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
            "noPlaylists": ("暂无歌单", "No Playlists"),
            "sortBy": ("排序方式", "Sort By"), "sortTitle": ("标题", "Title"),
            "sortArtist": ("艺人", "Artist"), "sortNewestAdded": ("最新添加", "Newest Added"),
            "sortRecentlyPlayed": ("最新播放", "Recently Played"), "sortMostPlayed": ("播放次数", "Play Count"),
            "plays": ("次播放", "plays"), "nowPlaying": ("正在播放", "Now Playing"),
            "playAll": ("播放全部", "Play All"), "shufflePlay": ("随机播放", "Shuffle Play"),
            "delete": ("删除", "Delete"), "deletePlaylist": ("删除歌单", "Delete Playlist"),
            "musicVideos": ("音乐视频", "Music Videos"), "importComplete": ("导入完成", "Import Complete"),
            "itemsImported": ("个本地媒体文件已加入资料库。", "local media items were added to your library."),
            "unknownArtist": ("未知艺人", "Unknown Artist"), "noResults": ("没有搜索结果", "No Results"),
            "done": ("完成", "Done"), "importFailed": ("导入失败", "Import Failed"), "ok": ("好", "OK"),
                "privacyBody": ("AURU MUSIC 隐私政策\n\n生效日期：2026年10月5日\n\n1. 数据收集\n本应用不收集、存储、出售或向任何第三方提供您的个人信息、设备信息、使用记录或其他数据。\n\n2. 本地媒体\n应用中显示和播放的歌曲、视频、歌词、封面及其他音频文件内容均来自您主动导入的本地文件。媒体文件、歌单、播放次数和设置只保存在您的设备上，不会上传到开发者或任何第三方服务器。\n\n3. 麦克风\n仅当您主动使用听歌识曲时，应用才申请麦克风权限，并截取短时音频提交给 ACRCloud 完成识别。该功能不会访问您的本地媒体文件。您可以随时在系统设置中关闭麦克风权限。\n\n4. 通知与网络\n通知权限为可选项。除听歌识曲及加载识别结果所需网络请求外，本应用不会传输您的内容。\n\n5. 您的控制权\n删除应用将同时删除应用保存的本地索引、歌单和播放记录。删除本地媒体文件前，应用会要求确认。\n\n6. 政策更新\n如隐私政策发生变化，新版本将在应用中更新本文档。", "AURU MUSIC Privacy Policy\n\nEffective: October 5, 2026\n\n1. Data Collection\nThis app does not collect, store, sell, or provide personal information, device information, usage records, or other data to any third party.\n\n2. Local Media\nAll songs, videos, lyrics, artwork, and audio content displayed or played by the app come from local files that you choose to import. Media files, playlists, play counts, and settings remain on your device and are not uploaded to the developer or any third-party server.\n\n3. Microphone\nMicrophone access is requested only when you choose music recognition. A short audio sample is sent to ACRCloud solely to identify the music; this feature does not access your local media files. Permission can be disabled in iOS Settings.\n\n4. Notifications and Network\nNotifications are optional. Apart from requests required for music recognition and its result artwork, the app does not transmit your content.\n\n5. Your Control\nRemoving the app also removes its local index, playlists, and play history. The app asks for confirmation before deleting local media files.\n\n6. Policy Updates\nIf this policy changes, the revised document will be included in a future app version."),
                "termsOfService": ("服务条款", "Terms of Service"),
                "termsBody": ("AURU MUSIC 服务条款\n\n生效日期：2026年10月5日\n\n1. 接受条款\n使用本应用即表示您同意本条款。如不同意，请停止使用本应用。\n\n2. 应用用途\n本应用用于管理和播放您合法持有的本地音频及视频文件。您应确保导入、复制和播放相关内容符合所在地法律及权利人的授权要求。\n\n3. 本地内容\n本应用不提供、托管或销售音乐和视频内容。所有媒体均由用户从本地文件导入，用户自行负责文件来源、备份和合法使用。\n\n4. 第三方服务\n听歌识曲由 ACRCloud 提供。使用该功能时，应同时遵守其服务规则。第三方服务的可用性可能发生变化。\n\n5. 文件操作\n应用提供从资料库移除或删除本地文件的选项。删除本地文件可能无法恢复，请在操作前自行备份。\n\n6. 免责声明\n应用按现状提供。在法律允许的范围内，开发者不对设备故障、误删除、第三方服务中断或其他不可控原因造成的损失负责。\n\n7. 条款更新\n条款如有调整，将随应用版本更新并在设置中提供最新文本。", "AURU MUSIC Terms of Service\n\nEffective: October 5, 2026\n\n1. Acceptance\nBy using this app, you agree to these terms. If you disagree, stop using the app.\n\n2. Purpose\nThe app manages and plays local audio and video files that you lawfully possess. You are responsible for ensuring that importing, copying, and playing content complies with applicable law and permissions.\n\n3. Local Content\nThe app does not provide, host, or sell music or video. All media is imported by the user from local files, and the user is responsible for its source, backup, and lawful use.\n\n4. Third-Party Services\nMusic recognition is provided by ACRCloud and is also subject to its service terms. Availability of third-party services may change.\n\n5. File Operations\nThe app can remove library entries or delete local files. Deleted local files may be unrecoverable; maintain your own backups.\n\n6. Disclaimer\nThe app is provided as-is. To the extent permitted by law, the developer is not responsible for loss caused by device failure, accidental deletion, third-party interruption, or events outside the developer's control.\n\n7. Updates\nRevised terms will be delivered with an app update and displayed in Settings."),
                "emailFeedback": ("邮件反馈", "Email Feedback"),
                "feedbackSubject": ("意见反馈", "Feedback"),
                "feedbackContent": ("内容", "Message"),
                "sendEmail": ("打开邮件", "Open Mail"),
                "mailUnavailable": ("无法启动邮件应用，请确认设备已安装邮件客户端。", "Unable to open a mail app. Make sure an email client is installed."),
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
            "deletePlaylistMessage": ("请选择是否同时处理歌单中的歌曲。", "Choose whether to also remove the songs in this playlist."),
            "renamePlaylist": ("修改歌单名称", "Rename Playlist"),
            "editSongInfo": ("修改歌曲信息", "Edit Song Info"), "artistName": ("艺人名称", "Artist Name"),
            "notificationDenied": ("通知权限已在系统中关闭，请前往系统设置开启。", "Notifications are disabled in system settings. Open Settings to enable them."),
            "openSettings": ("打开设置", "Open Settings"),
            "songTab": ("歌曲", "Songs"), "videoTab": ("视频", "Videos"),
            "editVideoInfo": ("修改视频信息", "Edit Video Info"), "videoName": ("视频名称", "Video Name"),
            "deleteVideoTitle": ("如何删除这个视频？", "How would you like to remove this video?"),
            "recognizeMusic": ("听歌识曲", "Recognize Music"),
            "recognizing": ("正在聆听…", "Listening…"),
            "recognizeHint": ("靠近正在播放的音乐，点击开始识别", "Move closer to the music and tap to identify it"),
            "startRecognizing": ("开始识别", "Start Listening"),
            "stopRecognizing": ("停止识别", "Stop Listening"),
            "noRecognition": ("暂未识别到歌曲，请重试", "No song identified yet. Try again."),
            "microphoneDenied": ("需要麦克风权限才能听歌识曲", "Microphone access is required to recognize music"),
            "recognitionDevelopmentDisabled": ("开发测试阶段暂未启用听歌识曲。", "Music recognition is temporarily disabled in development builds.")
        ]
        guard let value = translations[key] else { return key }
        return language == .chinese ? value.zh : value.en
    }

    func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            guard notificationSettings.authorizationStatus == .denied else { return }
            Task { @MainActor [weak self] in self?.notificationsEnabled = false }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard !granted else { return }
                    Task { @MainActor [weak self] in self?.notificationsEnabled = false }
                }
            case .denied:
                Task { @MainActor [weak self] in
                    self?.notificationsEnabled = false
                    self?.showsNotificationSettingsPrompt = true
                }
            @unknown default:
                Task { @MainActor [weak self] in self?.notificationsEnabled = false }
            }
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

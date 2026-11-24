import SwiftUI

@main
struct MainApp: App {
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
        }
    }
}

/// 底部两个分页：「下载」和「剪辑转换」
enum AppTab: Hashable {
    case download, editor
}

/// 两个分页之间互相传东西（下载好的视频送去剪辑、外面打开的链接 / 文件）
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .download
    /// 等着交给「下载」页处理的 ytdl:// 链接
    @Published var pendingLink: URL?
    /// 等着交给「剪辑转换」页载入的文件
    @Published var pendingEdit: PendingEdit?

    struct PendingEdit: Equatable {
        let url: URL
        /// true：从别的 App 传来的，要先复制一份；false：App 自己的文件，直接用
        let external: Bool
        let id = UUID()
    }

    /// 把 App 里的文件（例如刚下载的视频）送去剪辑
    func edit(_ url: URL) {
        pendingEdit = PendingEdit(url: url, external: false)
        tab = .editor
    }

    func handleOpenURL(_ url: URL) {
        if url.scheme?.lowercased() == "ytdl" {
            pendingLink = url
            tab = .download
        } else if url.isFileURL {
            pendingEdit = PendingEdit(url: url, external: true)
            tab = .editor
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.tab) {
            DownloaderView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(AppTab.download)
            EditorView()
                .tabItem { Label("剪辑转换", systemImage: "scissors") }
                .tag(AppTab.editor)
        }
        .onOpenURL { router.handleOpenURL($0) }
    }
}

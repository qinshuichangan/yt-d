import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @State private var link = ""
    @State private var photoMessage: String?
    @FocusState private var linkFocused: Bool
    @AppStorage(Clipboard.autoCopyKey) private var autoCopy = false
    @AppStorage(DownloadManager.qualityKey) private var playlistQuality: DownloadManager.Quality = .best
    @AppStorage(DownloadManager.autoDownloadKey) private var autoDownload = false
    @AppStorage(DownloadManager.autoSavePhotosKey) private var autoSavePhotos = false
    @AppStorage(DownloadManager.autoReadClipboardKey) private var autoReadClipboard = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastPasteboardChange = -1
    @State private var showPlaylistItems = true

    var body: some View {
        NavigationStack {
            Form {
                inputSection

                if manager.isFetching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在解析…").foregroundStyle(.secondary)
                        }
                    }
                }

                if let playlist = manager.playlist {
                    playlistSection(playlist)
                }

                if let info = manager.info {
                    infoSection(info)
                    optionsSection(info)
                }

                if manager.isDownloading {
                    progressSection
                }

                if let url = manager.finishedURL {
                    finishedSection(url)
                }

                if let message = manager.batchMessage {
                    Section {
                        Label(message, systemImage: manager.failedDownloads.isEmpty
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(manager.failedDownloads.isEmpty ? .green : .orange)
                        NavigationLink {
                            LibraryView()
                        } label: {
                            Label("去「已下载」查看", systemImage: "folder")
                        }
                    }

                    if !manager.failedDownloads.isEmpty {
                        Section {
                            ForEach(manager.failedDownloads) { failed in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failed.item.title).font(.callout).lineLimit(2)
                                    Text(failed.reason).font(.caption).foregroundStyle(.red).lineLimit(3)
                                }
                            }
                            let retryCount = manager.failedDownloads.filter(\.retryable).count
                            if retryCount > 0 {
                                Button {
                                    manager.retryFailed(playlistQuality)
                                } label: {
                                    Label("重试这 \(retryCount) 个", systemImage: "arrow.clockwise")
                                }
                                .disabled(manager.isBusy)
                            }
                        } header: {
                            Text("下载失败的视频")
                        } footer: {
                            Text("会员专享、私人、已删除的视频重试也没用，不会参与重试。其他的重试会用上面选的画质，一直失败的话可以换「快速」再试。")
                        }
                    }
                }

                if let message = manager.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("自动读取剪贴板里的链接", isOn: $autoReadClipboard)
                    Toggle("粘贴链接后自动下载", isOn: $autoDownload)
                    Picker("默认画质", selection: $playlistQuality) {
                        ForEach(DownloadManager.Quality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Toggle("下载完成后自动保存到相册", isOn: $autoSavePhotos)
                    Toggle("下载完成后自动复制到剪贴板", isOn: $autoCopy)
                } header: {
                    Text("设置")
                } footer: {
                    Text("自动读取剪贴板：打开 App 时，如果剪贴板里是 YouTube 或抖音链接，就自动填进来。iOS 每次会问「允许粘贴吗」，不想被问可以去 设置 → 视频下载 → 从其他 App 粘贴 → 允许。\n自动下载：点「粘贴」或从分享菜单打开后，按默认画质直接下载单个视频（抖音下载无水印版）。播放列表仍会先列出来让你勾选。\n自动保存到相册：音频文件不会存进相册。")
                }
            }
            .navigationTitle("视频下载")
            .onOpenURL(perform: handleIncoming)
            .onAppear(perform: checkClipboard)
            .onChange(of: scenePhase) { phase in
                if phase == .active { checkClipboard() }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        LibraryView()
                    } label: {
                        Label("已下载", systemImage: "folder")
                    }
                }
            }
        }
    }

    // MARK: 自动读取剪贴板

    private func checkClipboard() {
        guard autoReadClipboard, !manager.isBusy else { return }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastPasteboardChange else { return }  // 同一次复制只处理一次

        // 先判断是不是网址（这一步不会触发系统的粘贴提示）
        pasteboard.detectPatterns(for: [.probableWebURL]) { result in
            DispatchQueue.main.async {
                lastPasteboardChange = count
                guard case .success(let patterns) = result, patterns.contains(.probableWebURL),
                      let text = pasteboard.string,
                      let url = DownloadManager.extractURL(from: text),
                      DownloadManager.isSupportedLink(url),
                      !manager.isBusy else { return }
                link = text
                linkFocused = false
                photoMessage = nil
                manager.fetch(text, autoDownload: autoDownload)
            }
        }
    }

    // MARK: 从快捷指令打开（ytdl://download?url=...）

    private func handleIncoming(_ url: URL) {
        guard url.scheme?.lowercased() == "ytdl" else { return }
        var text: String?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = comps.queryItems?.first(where: { $0.name == "url" })?.value,
           !value.isEmpty {
            text = value
        } else {
            // 兼容 ytdl://https://... 这种直接拼接的写法
            let raw = url.absoluteString.dropFirst("ytdl://".count)
            text = String(raw).removingPercentEncoding ?? String(raw)
        }
        guard let text, !text.isEmpty else { return }
        link = text
        linkFocused = false
        photoMessage = nil
        // 正在下载时只填入链接，不打断当前下载
        if !manager.isDownloading {
            manager.fetch(text, autoDownload: autoDownload)
        }
    }

    // MARK: 输入链接

    private var inputSection: some View {
        Section {
            TextField("粘贴 YouTube 或抖音链接", text: $link, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($linkFocused)
            HStack {
                Button {
                    if let text = UIPasteboard.general.string {
                        link = text
                        if autoDownload {
                            linkFocused = false
                            photoMessage = nil
                            manager.fetch(text, autoDownload: true)
                        }
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("解析") {
                    linkFocused = false
                    photoMessage = nil
                    manager.fetch(link, autoDownload: autoDownload)
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isBusy)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("在 YouTube 或抖音里点「分享」→「复制链接」，再回来点「粘贴」。")
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
            }
        }
    }

    // MARK: 播放列表

    private func playlistSection(_ playlist: PlaylistInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title).font(.headline)
                Text("\(playlist.items.count) 个视频" + (playlist.isMix ? "（YouTube 自动合辑）" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $showPlaylistItems) {
                HStack {
                    Button("全选") { manager.selectAll(true) }
                    Spacer()
                    Button("全不选") { manager.selectAll(false) }
                }
                .buttonStyle(.borderless)
                .font(.callout)

                ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        manager.toggleSelection(item)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: manager.selectedIDs.contains(item.videoID)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(manager.selectedIDs.contains(item.videoID)
                                                 ? Color.accentColor : Color.secondary)
                            Text("\(index + 1). \(item.title)")
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .disabled(manager.isBusy)
                }
            } label: {
                Text("选择要下载的视频（已选 \(manager.selectedIDs.count)/\(playlist.items.count)）")
            }

            Picker("画质", selection: $playlistQuality) {
                ForEach(DownloadManager.Quality.allCases) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }

            Button {
                photoMessage = nil
                manager.downloadPlaylist(playlistQuality)
            } label: {
                Label("下载选中的（\(manager.selectedIDs.count) 个）", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(manager.isBusy || manager.selectedIDs.isEmpty)
        } header: {
            Text("播放列表")
        } footer: {
            Text("会一个接一个依次下载，下载时请留在 App 里。失败的会先跳过，最后可以重试。")
        }
    }

    // MARK: 视频信息

    private func infoSection(_ info: VideoInfo) -> some View {
        Section {
            if let thumb = info.thumbnail {
                AsyncImage(url: thumb) { image in
                    image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15).aspectRatio(16 / 9, contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            }
            Text(info.title).font(.headline)
        }
    }

    private func optionsSection(_ info: VideoInfo) -> some View {
        Section("选择格式") {
            ForEach(info.options) { option in
                Button {
                    photoMessage = nil
                    manager.download(option)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).foregroundStyle(.primary)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(manager.isBusy)
            }
        }
    }

    // MARK: 进度

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(manager.statusText)
                    Spacer()
                    Text("\(Int(manager.progress * 100))%").monospacedDigit()
                }
                ProgressView(value: manager.progress)
                if !manager.sizeText.isEmpty {
                    Text(manager.sizeText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("取消", role: .destructive) { manager.cancel() }
        } footer: {
            Text("下载时请不要切到别的 App，否则可能会中断。")
        }
    }

    // MARK: 完成

    private func finishedSection(_ url: URL) -> some View {
        Section {
            Label("下载完成", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)

            if url.pathExtension.lowercased() != "m4a" {
                Button {
                    Task { photoMessage = await PhotoSaver.save(url) }
                } label: {
                    Label("存到相册", systemImage: "photo.badge.plus")
                }
            }
            Button {
                photoMessage = Clipboard.copyFile(url) ? "已复制到剪贴板，去微信里粘贴就行" : "复制失败"
            } label: {
                Label("复制到剪贴板", systemImage: "doc.on.doc")
            }
            ShareLink(item: url) {
                Label("分享 / 存到其他地方", systemImage: "square.and.arrow.up")
            }
            if let saved = manager.photoSaveMessage, photoMessage == nil {
                Text(saved).font(.callout)
            }
            if manager.copiedToClipboard && photoMessage == nil {
                Text("已自动复制到剪贴板，去微信里粘贴就行").font(.callout)
            }
            if let photoMessage {
                Text(photoMessage).font(.callout)
            }
        } footer: {
            Text("文件也在「文件」App →「我的 iPhone」→「视频下载」里。")
        }
    }
}

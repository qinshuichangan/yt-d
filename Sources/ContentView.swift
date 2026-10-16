import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @State private var link = ""
    @State private var photoMessage: String?
    @FocusState private var linkFocused: Bool

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

                if let message = manager.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("视频下载")
            .onOpenURL(perform: handleIncoming)
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
            manager.fetch(text)
        }
    }

    // MARK: 输入链接

    private var inputSection: some View {
        Section {
            TextField("粘贴 YouTube 链接", text: $link, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($linkFocused)
            HStack {
                Button {
                    if let text = UIPasteboard.general.string { link = text }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("解析") {
                    linkFocused = false
                    photoMessage = nil
                    manager.fetch(link)
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isBusy)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("在 YouTube App 里点「分享」→「复制链接」，再回来点「粘贴」。")
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
            }
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
            ShareLink(item: url) {
                Label("分享 / 存到其他地方", systemImage: "square.and.arrow.up")
            }
            if let photoMessage {
                Text(photoMessage).font(.callout)
            }
        } footer: {
            Text("文件也在「文件」App →「我的 iPhone」→「视频下载」里。")
        }
    }
}

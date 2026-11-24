import AVKit
import SwiftUI

/// 「已导出」列表
struct ExportLibraryView: View {
    /// 选「再剪一次」时调用
    var onEdit: (URL) -> Void

    @State private var files: [URL] = []

    static let videoExtensions = ["mp4", "mov", "m4v"]
    static let audioExtensions = ["m4a", "aac", "mp3", "ogg", "wav"]

    var body: some View {
        List {
            if files.isEmpty {
                Text("还没有导出的文件").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                NavigationLink {
                    ExportPlayerView(url: url, onEdit: onEdit)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Self.isAudio(url) ? "music.note" : "film")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(2)
                            Text(Self.sizeText(url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button {
                        Clipboard.copyFile(url)
                    } label: {
                        Label("复制到剪贴板", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: url)
                    Button {
                        onEdit(url)
                    } label: {
                        Label("再剪一次 / 再转换", systemImage: "scissors")
                    }
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: url)
                        reload()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for i in indexSet {
                    try? FileManager.default.removeItem(at: files[i])
                }
                reload()
            }
        }
        .navigationTitle("已导出")
        .onAppear(perform: reload)
    }

    private func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: EditorModel.outputFolder(),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        files = urls
            .filter { Self.isAudio($0) || Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { Self.modified($0) > Self.modified($1) }
    }

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func sizeText(_ url: URL) -> String {
        totalSizeText([url])
    }

    /// 几个文件加起来的大小
    static func totalSizeText(_ urls: [URL]) -> String {
        let bytes = urls.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ExportPlayerView: View {
    let url: URL
    var onEdit: (URL) -> Void
    @State private var player: AVPlayer?
    @State private var message: String?

    private var isOgg: Bool { url.pathExtension.lowercased() == "ogg" }

    var body: some View {
        VStack(spacing: 12) {
            if isOgg {
                Text("iPhone 自带的播放器不能播放 OGG。可以点右上角分享到支持 OGG 的 App（例如 VLC）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if let player {
                VideoPlayer(player: player)
                    .frame(maxHeight: ExportLibraryView.isAudio(url) ? 120 : .infinity)
            }
            Text(ExportLibraryView.sizeText(url)).font(.caption).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).padding(.horizontal)
            }
            Button {
                player?.pause()
                onEdit(url)
            } label: {
                Label("再剪一次 / 再转换", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !ExportLibraryView.isAudio(url) {
                    Button {
                        Task { message = await PhotoSaver.save(url) }
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                Button {
                    message = Clipboard.copyFile(url) ? "已复制到剪贴板" : "复制失败"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                ShareLink(item: url)
            }
        }
        .onAppear {
            guard !isOgg else { return }
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

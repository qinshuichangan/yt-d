import SwiftUI
import AVKit

struct LibraryView: View {
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty {
                Text("还没有下载的文件").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { url in
                NavigationLink {
                    PlayerView(url: url)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Self.isAudio(url) ? "music.note" : "film")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(2)
                            Text(Self.sizeText(url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { indexSet in
                for i in indexSet { try? FileManager.default.removeItem(at: files[i]) }
                reload()
            }
        }
        .navigationTitle("已下载")
        .onAppear(perform: reload)
    }

    private func reload() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let urls = (try? fm.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        files = urls
            .filter { ["mp4", "m4a", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { Self.modified($0) > Self.modified($1) }
    }

    static func isAudio(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m4a"
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func sizeText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                VideoPlayer(player: player)
                    .frame(maxHeight: LibraryView.isAudio(url) ? 120 : .infinity)
            }
            if let message {
                Text(message).font(.callout).padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !LibraryView.isAudio(url) {
                    Button {
                        Task { message = await PhotoSaver.save(url) }
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                ShareLink(item: url)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

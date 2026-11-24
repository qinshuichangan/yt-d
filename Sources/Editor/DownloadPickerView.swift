import SwiftUI

/// 从「下载」页下好的文件里选一个来剪辑（直接用原文件，不复制）
struct DownloadPickerView: View {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("还没有下载的文件").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    Button {
                        onPick(url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: LibraryView.isAudio(url) ? "music.note" : "film")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(ExportLibraryView.sizeText(url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选一个已下载的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
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
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        files = urls
            .filter { ["mp4", "m4a", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
    }
}

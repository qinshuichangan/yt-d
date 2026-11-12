import SwiftUI
import AVKit

struct LibraryView: View {
    @State private var files: [URL] = []
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<URL> = []
    @State private var confirmDelete = false
    @State private var showExporter = false
    @State private var busyText: String?
    @State private var message: String?

    private var isSelecting: Bool { editMode.isEditing }
    /// 按列表顺序排好的选中文件
    private var selectedFiles: [URL] { files.filter(selected.contains) }

    var body: some View {
        List(selection: $selected) {
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
                delete(indexSet.map { files[$0] })
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(isSelecting ? "已选 \(selected.count) 个" : "已下载")
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSelecting ? "完成" : "选择") {
                    withAnimation {
                        editMode = isSelecting ? .inactive : .active
                        selected = []
                    }
                }
                .disabled(files.isEmpty && !isSelecting)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    let all = !files.isEmpty && selected.count == files.count
                    Button(all ? "全不选" : "全选") {
                        selected = all ? [] : Set(files)
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    barButton("删除", "trash", role: .destructive) { confirmDelete = true }
                    Spacer()
                    barButton("存到相册", "photo.badge.plus") { Task { await saveToPhotos() } }
                    Spacer()
                    barButton("存到文件", "folder.badge.plus") { showExporter = true }
                    Spacer()
                    ShareLink(items: selectedFiles) {
                        barLabel("分享", "square.and.arrow.up")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .confirmationDialog("删除选中的 \(selected.count) 个文件？", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete(selectedFiles) }
        } message: {
            Text("同名的作品说明（.txt）也会一起删除，删除后不能恢复。")
        }
        .sheet(isPresented: $showExporter) {
            FileExporter(urls: selectedFiles) { count in
                showExporter = false
                if count > 0 { message = "已保存 \(count) 个文件到「文件」" }
            }
            .ignoresSafeArea()
        }
        .overlay {
            if let busyText {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(busyText).font(.callout)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        }
        .disabled(busyText != nil)
        .onAppear(perform: reload)
    }

    private func barButton(_ title: String, _ icon: String, role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { barLabel(title, icon) }
            .disabled(selected.isEmpty)
    }

    private func barLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            Text(title).font(.caption2)
        }
    }

    // MARK: 批量操作

    private func delete(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            try? fm.removeItem(at: url)
            // 一起删掉同名的作品说明
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("txt"))
        }
        selected.subtract(urls)
        reload()
        if files.isEmpty { editMode = .inactive }
    }

    private func saveToPhotos() async {
        let targets = selectedFiles
        let videos = targets.filter { !Self.isAudio($0) }
        var saved = 0
        var failures: [String] = []
        for (index, url) in videos.enumerated() {
            busyText = "正在存到相册（\(index + 1)/\(videos.count)）…"
            let result = await PhotoSaver.save(url)
            if result.hasPrefix("已存到相册") {
                saved += 1
            } else {
                failures.append(result)
                if result.contains("权限") { break }  // 没权限就不用继续了
            }
        }
        busyText = nil
        var text = "已存到相册 \(saved) 个"
        if targets.count > videos.count { text += "\n音频 \(targets.count - videos.count) 个不能存进相册，已跳过" }
        if let first = failures.first { text += "\n失败 \(failures.count) 个：\(first)" }
        message = text
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
                Button {
                    message = Clipboard.copyFile(url) ? "已复制到剪贴板" : "复制失败"
                } label: {
                    Image(systemName: "doc.on.doc")
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

/// 系统的「存储到文件」界面（选文件夹，复制过去）
private struct FileExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: (Int) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Int) -> Void
        init(onFinish: @escaping (Int) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.count)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(0)
        }
    }
}

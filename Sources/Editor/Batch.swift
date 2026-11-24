import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 批量用的相册视频：复制到单独的文件夹（不会被单个编辑时的清理删掉）
struct BatchMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let target = try EditorModel.makeImportURL(name: received.file.lastPathComponent,
                                                       folder: BatchModel.importFolderName)
            try FileManager.default.copyItem(at: received.file, to: target)
            return BatchMovie(url: target)
        }
    }
}

@MainActor
final class BatchModel: ObservableObject {
    static let importFolderName = "BatchImported"

    enum Status: Equatable {
        case waiting
        case running(Double)
        case done([URL])     // 分割时有好几个文件
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL          // 导入到 App 里的副本
        let name: String
        var status: Status = .waiting

        var isRunning: Bool {
            if case .running = status { return true }
            return false
        }
    }

    private enum StopReason { case none, user, system }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var importingCount = 0
    @Published private(set) var overallProgress = 0.0
    @Published private(set) var runIndex = 0      // 这一轮做到第几个（从 1 开始）
    @Published private(set) var runTotal = 0
    @Published var message: String?

    private var choice: OutputChoice?
    private var runTask: Task<Void, Never>?
    private var currentExport: Task<[URL], Error>?
    private var stopReason = StopReason.none
    private var resumeWhenActive = false
    private var runDone = 0

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        }
    }

    var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    var doneCount: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }

    // MARK: - 添加 / 删除

    func addPhotoItems(_ picked: [PhotosPickerItem]) async {
        importingCount += picked.count
        for item in picked {
            do {
                if let movie = try await item.loadTransferable(type: BatchMovie.self) {
                    append(movie.url)
                } else {
                    message = "有视频没能从相册读取"
                }
            } catch {
                message = "读取相册视频失败：\(error.localizedDescription)"
            }
            importingCount -= 1
        }
    }

    func addFiles(_ urls: [URL]) async {
        importingCount += urls.count
        for url in urls {
            let copied = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let target = try EditorModel.makeImportURL(name: url.lastPathComponent,
                                                               folder: BatchModel.importFolderName)
                    try FileManager.default.copyItem(at: url, to: target)
                    return .success(target)
                } catch {
                    return .failure(error)
                }
            }.value
            switch copied {
            case .success(let target): append(target)
            case .failure(let error): message = "读取文件失败：\(error.localizedDescription)"
            }
            importingCount -= 1
        }
    }

    private func append(_ url: URL) {
        items.append(Item(url: url, name: url.deletingPathExtension().lastPathComponent))
    }

    func remove(at offsets: IndexSet) {
        let removable = offsets.filter { !items[$0].isRunning }
        for index in removable { deleteImport(items[index]) }
        items.remove(atOffsets: IndexSet(removable))
    }

    func clearFinished() {
        items.removeAll { if case .done = $0.status { return true }; return false }
    }

    func retryFailed() {
        for i in items.indices {
            if case .failed = items[i].status { items[i].status = .waiting }
        }
    }

    /// 删掉导入的副本（导出的结果不删）
    private func deleteImport(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
    }

    // MARK: - 运行

    func start() {
        guard !isRunning, waitingCount > 0 else { return }
        choice = OutputChoice.current()
        run()
    }

    func stop() {
        stopReason = .user
        currentExport?.cancel()
        runTask?.cancel()
    }

    private func run() {
        isRunning = true
        message = nil
        stopReason = .none
        resumeWhenActive = false
        runDone = 0
        runIndex = 0
        runTotal = waitingCount
        overallProgress = 0
        WorkSession.shared.begin(title: "剪辑转换：批量处理") { [weak self] in
            self?.stopReason = .system
            self?.currentExport?.cancel()
            self?.runTask?.cancel()
        }
        runTask = Task { await processQueue() }
    }

    private func resumeIfNeeded() {
        guard resumeWhenActive, !isRunning, choice != nil, waitingCount > 0 else { return }
        run()
    }

    private func processQueue() async {
        guard let choice else { return }
        var allOK = true

        while !Task.isCancelled, let index = items.firstIndex(where: { $0.status == .waiting }) {
            let item = items[index]
            runIndex = runDone + 1
            setStatus(item.id, .running(0))
            let mark = WorkSession.shared.backgroundCount
            do {
                let outputs = try await convert(item, choice: choice)
                setStatus(item.id, .done(outputs))
                deleteImport(item)
                runDone += 1
            } catch {
                let interrupted = stopReason == .system
                    || (stopReason == .none && WorkSession.shared.backgroundCount != mark)
                if interrupted {
                    // 被系统打断：放回队列，回到 App 后自动接着做
                    setStatus(item.id, .waiting)
                    resumeWhenActive = true
                    break
                } else if stopReason == .user || error is CancellationError {
                    setStatus(item.id, .waiting)
                    break
                } else {
                    setStatus(item.id, .failed(error.localizedDescription))
                    allOK = false
                    runDone += 1
                }
            }
            overallProgress = runTotal > 0 ? Double(runDone) / Double(runTotal) : 1
        }

        WorkSession.shared.end(success: allOK && !resumeWhenActive && stopReason == .none)
        isRunning = false
        runTask = nil
        currentExport = nil

        if resumeWhenActive {
            message = "切到后台时被系统暂停了，回到 App 后会自动接着做。"
            if UIApplication.shared.applicationState == .active { resumeIfNeeded() }
        } else if stopReason == .user {
            message = "已停止，剩下的还在队列里。"
        } else {
            message = failedCount > 0 ? "完成了，有 \(failedCount) 个失败。" : "全部完成！"
        }
    }

    private func setStatus(_ id: UUID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    private func progressChanged(_ id: UUID, _ value: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isRunning else { return }
        items[i].status = .running(value)
        overallProgress = runTotal > 0 ? (Double(runDone) + value) / Double(runTotal) : value
        WorkSession.shared.update(progress: overallProgress)
    }

    private func convert(_ item: Item, choice: OutputChoice) async throws -> [URL] {
        let asset = AVURLAsset(url: item.url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0 else { throw AppError("读不出长度，可能不是视频或音频") }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw AppError("没有画面也没有声音") }

        let format = choice.format(hasVideo: !videoTracks.isEmpty)
        if format.isAudio && audioTracks.isEmpty { throw AppError("这个文件里没有声音") }

        let source = videoTracks.isEmpty
            ? nil
            : await EditorModel.describeVideo(videoTracks.first, file: item.url).video
        let compress = choice.compressSettings(source: source, seconds: duration)
        let name = format == .compressed ? item.name + "_压缩" : item.name
        let segments = Exporter.segments(base: name, start: 0, end: duration, fullFile: true,
                                         split: choice.split, ext: format.fileExtension)
        let job = Exporter.Job(format: format, precise: choice.precise,
                               audioBitrate: choice.audioBitrate, compress: compress)
        let source0 = item.url
        let id = item.id
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.progressChanged(id, value) }
        }

        let task = Task.detached(priority: .userInitiated) { () async throws -> [URL] in
            try await Exporter.run(job, source: source0, segments: segments, progress: report)
        }
        currentExport = task
        if stopReason != .none { task.cancel() }
        return try await task.value
    }
}

// MARK: - 界面

struct BatchView: View {
    @ObservedObject var batch: BatchModel
    /// 单个文件正在导出时不能开始批量
    let editorBusy: Bool

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @FocusState private var targetFocused: Bool

    var body: some View {
        Form {
            addSection
            queueSection
            OutputSettingsSection(header: "3. 输出（所有文件共用）", splitHeader: "4. 分割（所有文件共用）",
                                  allowVideo: true,
                                  source: nil, seconds: nil, targetFocus: $targetFocused)
                .disabled(batch.isRunning)
            runSection
            if let message = batch.message {
                Section {
                    Text(message)
                }
            }
        }
        .navigationTitle("批量处理")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { targetFocused = false }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audiovisualContent],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await batch.addFiles(urls) }
            case .failure(let error): batch.message = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: photoItems) { picked in
            guard !picked.isEmpty else { return }
            photoItems = []
            Task { await batch.addPhotoItems(picked) }
        }
    }

    private var addSection: some View {
        Section {
            PhotosPicker(selection: $photoItems, maxSelectionCount: nil, matching: .videos,
                         preferredItemEncoding: .current) {
                Label("从相册多选视频", systemImage: "photo.on.rectangle")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("从「文件」多选视频或音频", systemImage: "folder")
            }
            if batch.importingCount > 0 {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在导入 \(batch.importingCount) 个…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("1. 添加文件")
        } footer: {
            Text("批量处理是整段转换，不剪（可以在「4. 分割」里设置切成几段）。处理完的原文件副本会自动删掉，不占空间。")
        }
    }

    private var queueSection: some View {
        Section {
            if batch.items.isEmpty {
                Text("队列是空的").foregroundStyle(.secondary)
            }
            ForEach(batch.items) { item in
                row(item)
            }
            .onDelete { batch.remove(at: $0) }

            if !batch.isRunning && (batch.doneCount > 0 || batch.failedCount > 0) {
                HStack {
                    if batch.doneCount > 0 {
                        Button("清除已完成") { batch.clearFinished() }
                    }
                    Spacer()
                    if batch.failedCount > 0 {
                        Button("重试失败的") { batch.retryFailed() }
                    }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("2. 队列（\(batch.items.count) 个）")
        } footer: {
            if !batch.items.isEmpty {
                Text("向左滑可以从队列里删掉。")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: BatchModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).lineLimit(2)
            switch item.status {
            case .waiting:
                Text("等待中").font(.caption).foregroundStyle(.secondary)
            case .running(let p):
                ProgressView(value: p)
                Text("处理中 \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            case .done(let urls):
                HStack {
                    Label(urls.count > 1
                          ? "完成 · 分成 \(urls.count) 段 · \(ExportLibraryView.totalSizeText(urls))"
                          : "完成 · \(ExportLibraryView.totalSizeText(urls))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    ShareLink(items: urls) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            case .failed(let reason):
                Text("失败：\(reason)").font(.caption).foregroundStyle(.red)
            }
        }
        .deleteDisabled(item.isRunning)
    }

    private var runSection: some View {
        Section {
            if batch.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: batch.overallProgress)
                    Text("第 \(batch.runIndex) / \(batch.runTotal) 个 · 总进度 \(Int(batch.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("停止", role: .destructive) { batch.stop() }
            } else {
                Button {
                    targetFocused = false
                    batch.start()
                } label: {
                    Label("开始批量处理（\(batch.waitingCount) 个）", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(batch.waitingCount == 0 || batch.importingCount > 0 || editorBusy)
            }
            DimToggle()
        } footer: {
            if editorBusy && !batch.isRunning {
                Text("单个文件正在导出，等它结束后再开始。")
            } else {
                Text("可以切到别的 App：系统允许的话会在后台继续，锁屏和灵动岛上能看到进度。万一被系统暂停，回到 App 会自动接着做。结果都在右上角「已导出」里。")
            }
        }
    }
}

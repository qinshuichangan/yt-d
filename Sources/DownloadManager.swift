import Foundation
import UIKit
import YouTubeKit

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct FailedDownload: Identifiable {
    let item: PlaylistItem
    let reason: String
    /// 重试有没有意义（会员专享、私人视频等重试也没用）
    let retryable: Bool
    var id: String { item.id }
}

struct VideoInfo {
    let title: String
    let thumbnail: URL?
    let options: [DownloadOption]
    /// 和视频一起保存的文字说明（抖音作品用）
    var note: String? = nil
    /// 分P 列表（B站多P 视频）
    var parts: PlaylistInfo? = nil
}

struct DownloadOption: Identifiable {
    enum Kind {
        case single(YouTubeKit.Stream, ext: String)
        case merge(video: YouTubeKit.Stream, audio: YouTubeKit.Stream)
        /// 直接下载一个地址（抖音等）
        case direct(URL, ext: String, headers: [String: String])
        /// 画面和声音是两个地址，下载后合并（B站高画质等）
        case mergeDirect(video: URL, audio: URL, headers: [String: String])
    }
    let id = UUID()
    let label: String
    let detail: String
    let kind: Kind
}

@MainActor
final class DownloadManager: ObservableObject {
    enum Phase {
        case idle
        case fetching
        case ready
        case downloading
        case finished(URL)
        case batchDone(String)
        case failed(String)
    }

    /// 批量下载时的画质选择
    enum Quality: String, CaseIterable, Identifiable {
        case best = "最高画质"
        case hd720 = "720p"
        case fast = "快速（直接下载）"
        case audio = "仅音频（m4a）"
        var id: String { rawValue }
    }

    @Published var phase: Phase = .idle {
        didSet { phaseChanged() }
    }
    @Published var info: VideoInfo?
    @Published var playlist: PlaylistInfo?
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var sizeText = ""
    /// 下载速度（KB/s 或 MB/s）
    @Published var speedText = ""
    @Published var copiedToClipboard = false
    @Published var selectedIDs: Set<String> = []
    @Published var failedDownloads: [FailedDownload] = []
    @Published var photoSaveMessage: String?

    static let autoDownloadKey = "autoDownload"
    static let autoSavePhotosKey = "autoSaveToPhotos"
    static let qualityKey = "playlistQuality"
    static let autoReadClipboardKey = "autoReadClipboard"
    static let queueModeKey = "queueMode"
    static var queueMode: Bool { UserDefaults.standard.bool(forKey: queueModeKey) }

    // MARK: 队列模式

    struct QueueItem: Identifiable {
        let id = UUID()
        let text: String
        let url: URL
        let label: String
    }

    struct QueueRecord: Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool
        let message: String
    }

    /// 等待下载的链接
    @Published var queue: [QueueItem] = []
    /// 正在处理的队列项目
    @Published var currentJob: QueueItem?
    /// 处理完的记录（新的在前）
    @Published var queueRecords: [QueueRecord] = []
    /// 「已加入队列」之类的提示
    @Published var queueNotice: String?
    private var holdingKeeper = false

    /// 设置里选的默认画质
    static var defaultQuality: Quality {
        Quality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .best
    }
    private static var autoSavePhotos: Bool { UserDefaults.standard.bool(forKey: autoSavePhotosKey) }

    private var task: Task<Void, Never>?
    private var speed = SpeedMeter()
    private var speedTicker: Task<Void, Never>?
    /// 每开始下载一个文件 +1，旧文件迟到的进度回报会被忽略
    private var fileToken = 0
    /// 正在传输数据（解析、合并时为 false，不显示速度）
    private var measuring = false

    // MARK: 给界面用的状态

    var isFetching: Bool { if case .fetching = phase { return true }; return false }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }
    var isBusy: Bool { isFetching || isDownloading }
    var finishedURL: URL? { if case .finished(let url) = phase { return url }; return nil }
    var batchMessage: String? { if case .batchDone(let msg) = phase { return msg }; return nil }
    var errorMessage: String? { if case .failed(let msg) = phase { return msg }; return nil }

    /// 新链接进来：队列模式下，正在忙就排队，否则马上开始
    func submit(_ text: String, autoDownload: Bool) {
        guard Self.queueMode else {
            fetch(text, autoDownload: autoDownload)
            return
        }
        let busy = isBusy || currentJob != nil
        guard let url = Self.extractURL(from: text) else {
            if busy {
                queueNotice = "没认出链接，没有加入队列"
            } else {
                fetch(text, autoDownload: true)  // 显示错误
            }
            return
        }
        let key = url.absoluteString
        if currentJob?.url.absoluteString == key || queue.contains(where: { $0.url.absoluteString == key }) {
            queueNotice = "这个链接已经在队列里了"
            return
        }
        let item = QueueItem(text: text, url: url, label: Self.queueLabel(url))
        if busy {
            queue.append(item)
            queueNotice = "已加入队列：\(item.label)（排在第 \(queue.count) 个）"
        } else {
            queueNotice = nil
            startJob(item)
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        if queue.isEmpty && currentJob == nil { releaseKeeper() }
    }

    func clearQueue() {
        queue.removeAll()
        queueNotice = nil
        if currentJob == nil { releaseKeeper() }
    }

    var queueSuccessCount: Int { queueRecords.filter(\.ok).count }

    func clearQueueRecords() {
        queueRecords.removeAll()
    }

    private func startJob(_ item: QueueItem) {
        currentJob = item
        // 两个视频之间（解析时）也要保持后台运行
        if !holdingKeeper {
            holdingKeeper = true
            BackgroundKeeper.shared.begin()
        }
        fetch(item.text, autoDownload: true)
    }

    private func releaseKeeper() {
        guard holdingKeeper else { return }
        holdingKeeper = false
        BackgroundKeeper.shared.end()
    }

    private func phaseChanged() {
        switch phase {
        case .finished, .failed, .batchDone, .ready: break
        default: return
        }
        guard currentJob != nil || !queue.isEmpty else { return }
        // 解析完成（.ready）后通常马上开始下载，等这一轮结束再判断是不是真的空闲了
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.jobMaybeEnded()
        }
    }

    private func jobMaybeEnded() {
        guard !isBusy else { return }
        if let job = currentJob {
            queueRecords.insert(record(for: job), at: 0)
            currentJob = nil
        }
        if !queue.isEmpty {
            startJob(queue.removeFirst())
        } else {
            releaseKeeper()
        }
    }

    private func record(for job: QueueItem) -> QueueRecord {
        let title = info?.title ?? playlist?.title ?? job.label
        switch phase {
        case .finished(let url):
            return QueueRecord(title: url.deletingPathExtension().lastPathComponent, ok: true, message: "下载完成")
        case .failed(let message):
            return QueueRecord(title: job.label, ok: false, message: message)
        case .batchDone(let message):
            return QueueRecord(title: title, ok: failedDownloads.isEmpty, message: message)
        default:
            if playlist != nil && info == nil {
                return QueueRecord(title: title, ok: false, message: "播放列表需要手动勾选，队列里已跳过")
            }
            return QueueRecord(title: title, ok: false, message: "没有下载（已取消，或需要手动选择格式）")
        }
    }

    /// 队列里显示的名字，例如「抖音 · v.douyin.com/abc」
    static func queueLabel(_ url: URL) -> String {
        let site = Site.detect(url)?.rawValue ?? "YouTube"
        let short = (url.host ?? "") + url.path
        return "\(site) · \(short.count > 40 ? String(short.prefix(40)) + "…" : short)"
    }

    // MARK: 解析链接

    func fetch(_ text: String, autoDownload: Bool = false) {
        guard let url = Self.extractURL(from: text) else {
            phase = .failed("没认出链接，请粘贴完整的视频链接")
            return
        }
        let ids = Self.parseIDs(url)
        AppLog.add("解析：\(AppLog.short(url))，网站：\(Site.detect(url)?.rawValue ?? "YouTube")")
        task?.cancel()
        info = nil
        playlist = nil
        selectedIDs = []
        failedDownloads = []
        photoSaveMessage = nil
        phase = .fetching

        if let site = Site.detect(url) {
            fetchSite(site, url, autoDownload: autoDownload)
            return
        }

        task = Task {
            var lastError: Error?
            var autoKind: DownloadOption.Kind?

            // 链接里有 list= 就读取播放列表
            if let listID = ids.listID {
                do {
                    let loaded = try await PlaylistFetcher.fetch(listID: listID, seedVideoID: ids.videoID)
                    playlist = loaded
                    selectedIDs = Set(loaded.items.map(\.videoID))  // 默认全选
                } catch {
                    lastError = error
                }
            }

            // 有单个视频（或者根本不是列表链接）就解析这个视频
            if ids.videoID != nil || ids.listID == nil {
                do {
                    // 先在本机解析，失败时再用 YouTubeKit 作者提供的远程服务器
                    let video = ids.videoID.map { YouTube(videoID: $0, methods: [.local, .remote]) }
                        ?? YouTube(url: url, methods: [.local, .remote])
                    let streams = try await video.streams
                    let metadata = try? await video.metadata
                    let options = Self.buildOptions(from: streams)
                    if autoDownload { autoKind = Self.pick(Self.defaultQuality, from: streams) }
                    if options.isEmpty {
                        lastError = AppError("没有找到可以下载的格式")
                    } else {
                        info = VideoInfo(
                            title: metadata?.title ?? video.videoID,
                            thumbnail: metadata?.thumbnail?.url,
                            options: options
                        )
                    }
                } catch {
                    lastError = error
                }
            }

            if Task.isCancelled { return }
            if info != nil || playlist != nil {
                phase = .ready
                // 自动下载：只针对单个视频，播放列表还是让用户先勾选
                if let autoKind, info != nil {
                    download(DownloadOption(label: Self.defaultQuality.rawValue, detail: "", kind: autoKind))
                }
            } else {
                AppLog.add("解析失败：\(lastError.map(AppLog.describe) ?? "未知错误")")
                phase = .failed("解析失败：\(lastError.map { ErrorText.describe($0).text } ?? "未知错误")")
            }
        }
    }

    /// 抖音、TikTok、B站、小红书、推特、其他网页
    private func fetchSite(_ site: Site, _ url: URL, autoDownload: Bool) {
        task = Task {
            do {
                let loaded = try await site.fetch(url)
                if Task.isCancelled { return }
                guard !loaded.options.isEmpty else { throw SiteError.noVideo }
                AppLog.add("解析成功：\(loaded.title)；选项：\(loaded.options.map(\.label).joined(separator: " / "))"
                           + (loaded.parts.map { "；共 \($0.items.count) P" } ?? ""))
                if let parts = loaded.parts {
                    playlist = parts
                    selectedIDs = Set(parts.items.map(\.videoID))  // 默认全选
                }
                info = loaded
                phase = .ready
                if autoDownload, let first = loaded.options.first {
                    download(first)
                }
            } catch {
                if Task.isCancelled { return }
                AppLog.add("解析失败（\(site.rawValue)）：\(AppLog.describe(error))")
                phase = .failed("解析失败（\(site.rawValue)）：\(ErrorText.describe(error).text)")
            }
        }
    }

    // MARK: 下载单个视频

    func download(_ option: DownloadOption) {
        guard let info else { return }
        startWork()

        task = Task {
            BackgroundKeeper.shared.begin()
            defer { BackgroundKeeper.shared.end() }
            do {
                AppLog.add("开始下载：\(option.label)")
                let output = try await performDownload(option.kind, title: info.title, label: nil, start: 0, span: 1)
                AppLog.add("下载完成：\(output.lastPathComponent)（\(Self.sizeDescription(output))）")
                if let note = info.note {
                    // 作品说明存成同名 .txt，放在视频旁边
                    let noteURL = output.deletingPathExtension().appendingPathExtension("txt")
                    try? note.write(to: noteURL, atomically: true, encoding: .utf8)
                }
                progress = 1
                if UserDefaults.standard.bool(forKey: Clipboard.autoCopyKey) {
                    copiedToClipboard = Clipboard.copyFile(output)
                }
                if Self.autoSavePhotos, Self.isVideoFile(output) {
                    statusText = "正在存到相册…"
                    photoSaveMessage = await PhotoSaver.save(output)
                }
                phase = .finished(output)
            } catch {
                if Self.isCancellation(error) {
                    AppLog.add("已取消")
                    phase = .ready
                } else {
                    AppLog.add("下载失败：\(AppLog.describe(error))")
                    phase = .failed("下载失败：\(ErrorText.describe(error).text)")
                }
            }
        }
    }

    // MARK: 播放列表：选择

    var selectedItems: [PlaylistItem] {
        playlist?.items.filter { selectedIDs.contains($0.videoID) } ?? []
    }

    func toggleSelection(_ item: PlaylistItem) {
        if selectedIDs.contains(item.videoID) {
            selectedIDs.remove(item.videoID)
        } else {
            selectedIDs.insert(item.videoID)
        }
    }

    func selectAll(_ on: Bool) {
        selectedIDs = on ? Set(playlist?.items.map(\.videoID) ?? []) : []
    }

    // MARK: 播放列表：下载

    /// 下载选中的视频
    func downloadPlaylist(_ quality: Quality) {
        runBatch(selectedItems, quality: quality)
    }

    /// 只重新下载上次失败的视频
    func retryFailed(_ quality: Quality) {
        runBatch(failedDownloads.filter(\.retryable).map(\.item), quality: quality)
    }

    private func runBatch(_ items: [PlaylistItem], quality: Quality) {
        guard !items.isEmpty else { return }
        startWork()
        failedDownloads = []
        photoSaveMessage = nil

        task = Task {
            BackgroundKeeper.shared.begin()
            defer { BackgroundKeeper.shared.end() }
            let count = Double(items.count)
            var succeeded = 0
            var savedToPhotos = 0
            var failed: [FailedDownload] = []
            var cancelled = false

            for (index, item) in items.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                let label = "第 \(index + 1)/\(items.count) 个"
                let start = Double(index) / count
                progress = start
                sizeText = ""
                statusText = "\(label)：正在解析…"
                do {
                    let output: URL
                    if let pageURL = item.pageURL {
                        // B站分P 等：先解析这一项自己的页面
                        guard let site = Site.detect(pageURL) else { throw AppError("不支持的链接") }
                        let loaded = try await site.fetch(pageURL)
                        guard let kind = Self.pickSiteOption(quality, from: loaded.options) else {
                            throw AppError("没有合适的格式")
                        }
                        AppLog.add("\(label)：\(loaded.title)")
                        output = try await performDownload(kind, title: loaded.title, label: label,
                                                           start: start, span: 1 / count)
                        if let note = loaded.note {
                            try? note.write(to: output.deletingPathExtension().appendingPathExtension("txt"),
                                            atomically: true, encoding: .utf8)
                        }
                    } else {
                        let streams = try await YouTube(videoID: item.videoID, methods: [.local, .remote]).streams
                        guard let kind = Self.pick(quality, from: streams) else {
                            throw AppError("没有合适的格式")
                        }
                        output = try await performDownload(kind, title: item.title, label: label,
                                                           start: start, span: 1 / count)
                    }
                    succeeded += 1
                    if Self.autoSavePhotos, Self.isVideoFile(output) {
                        statusText = "\(label)：正在存到相册…"
                        if await PhotoSaver.save(output).hasPrefix("已存到相册") { savedToPhotos += 1 }
                    }
                } catch {
                    if Self.isCancellation(error) { cancelled = true; break }
                    // 失败的先记下来，继续下一个
                    let described = ErrorText.describe(error)
                    AppLog.add("\(label) 失败：\(AppLog.describe(error))")
                    failed.append(FailedDownload(item: item, reason: described.text, retryable: described.retryable))
                }
            }

            failedDownloads = failed
            progress = 1
            var message = cancelled ? "已取消，完成 \(succeeded) 个" : "下载完成：成功 \(succeeded) 个"
            if !failed.isEmpty { message += "，失败 \(failed.count) 个" }
            if Self.autoSavePhotos && succeeded > 0 { message += "\n已存到相册 \(savedToPhotos) 个" }
            phase = .batchDone(message)
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: 下载核心

    private func startWork() {
        task?.cancel()
        phase = .downloading
        progress = 0
        sizeText = ""
        speedText = ""
        speed.reset()
        measuring = false
        copiedToClipboard = false
        startSpeedTicker()
    }

    /// 每半秒刷新一次速度；卡住不动时会慢慢降到 0
    private func startSpeedTicker() {
        speedTicker?.cancel()
        speedTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isDownloading else { break }
                self.speedText = self.measuring ? (self.speed.rate().map(DownloadManager.speedString) ?? "") : ""
            }
            self?.speedText = ""
        }
    }

    /// 开始传输一个新文件，返回它的编号
    private func beginTransfer() -> Int {
        fileToken += 1
        speed.startFile()
        measuring = true
        return fileToken
    }

    /// 下载一个视频（必要时合并），返回保存的文件
    private func performDownload(
        _ kind: DownloadOption.Kind, title: String, label: String?, start: Double, span: Double
    ) async throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = Self.safeFileName(title)
        let prefix = label.map { "\($0)：" } ?? ""
        var cleanup: [URL] = []
        defer { measuring = false }

        do {
            let output: URL
            switch kind {
            case let .single(stream, ext):
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).\(ext)"))
                cleanup = [output]
                statusText = "\(prefix)正在下载…"
                let token = beginTransfer()
                try await ChunkedDownloader.download(from: stream.url, to: output) { done, total in
                    Task { @MainActor in self.report(done, total, token: token, start: start, span: span) }
                }

            case let .direct(url, ext, headers):
                AppLog.add("直接下载：\(AppLog.short(url))")
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).\(ext)"))
                cleanup = [output]
                statusText = "\(prefix)正在下载…"
                let token = beginTransfer()
                try await ChunkedDownloader.download(from: url, to: output, headers: headers) { done, total in
                    Task { @MainActor in self.report(done, total, token: token, start: start, span: span) }
                }
                // 确认下到的是视频，而不是一个错误网页
                guard !["mp4", "m4a", "m4v", "mov"].contains(ext.lowercased()) || Self.looksLikeMP4(output) else {
                    throw AppError("下载到的不是视频文件，换另一个选项试试")
                }

            case let .merge(video, audio):
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).mp4"))
                try await downloadAndMerge(video: video.url, audio: audio.url, headers: [:], output: output,
                                           prefix: prefix, start: start, span: span, cleanup: &cleanup)

            case let .mergeDirect(video, audio, headers):
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).mp4"))
                try await downloadAndMerge(video: video, audio: audio, headers: headers, output: output,
                                           prefix: prefix, start: start, span: span, cleanup: &cleanup)
            }
            return output
        } catch {
            cleanup.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    /// 分别下载画面和声音，再合并成一个 mp4
    private func downloadAndMerge(
        video: URL, audio: URL, headers: [String: String], output: URL,
        prefix: String, start: Double, span: Double, cleanup: inout [URL]
    ) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let videoFile = tmp.appendingPathComponent(UUID().uuidString + ".mp4")
        let audioFile = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
        cleanup = [videoFile, audioFile, output]
        AppLog.add("分开下载：画面 \(AppLog.short(video))，声音 \(AppLog.short(audio))")

        statusText = "\(prefix)正在下载画面…"
        let videoToken = beginTransfer()
        do {
            try await ChunkedDownloader.download(from: video, to: videoFile, headers: headers) { done, total in
                Task { @MainActor in self.report(done, total, token: videoToken, start: start, span: span * 0.85) }
            }
        } catch {
            throw Self.isCancellation(error) ? error : AppError("画面下载失败：\(ErrorText.describe(error).text)") as Error
        }
        guard Self.looksLikeMP4(videoFile) else {
            throw AppError("下载到的画面不是视频文件（\(Self.sizeDescription(videoFile))），换「快速」选项试试")
        }
        statusText = "\(prefix)正在下载声音…"
        let audioToken = beginTransfer()
        do {
            try await ChunkedDownloader.download(from: audio, to: audioFile, headers: headers) { done, total in
                Task { @MainActor in
                    self.report(done, total, token: audioToken, start: start + span * 0.85, span: span * 0.12)
                }
            }
        } catch {
            throw Self.isCancellation(error) ? error : AppError("声音下载失败：\(ErrorText.describe(error).text)") as Error
        }
        guard Self.looksLikeMP4(audioFile) else {
            throw AppError("下载到的声音不是音频文件（\(Self.sizeDescription(audioFile))），换「快速」选项试试")
        }
        statusText = "\(prefix)正在合并…"
        measuring = false
        speedText = ""
        sizeText = ""
        do {
            try await Merger.merge(video: videoFile, audio: audioFile, output: output)
        } catch {
            AppLog.add("合并失败：\(AppLog.describe(error))")
            throw Self.isCancellation(error) ? error : AppError(
                "合并失败：\(error.localizedDescription)（画面 \(Self.sizeDescription(videoFile))，声音 \(Self.sizeDescription(audioFile))），换「快速」选项试试") as Error
        }
        try? fm.removeItem(at: videoFile)
        try? fm.removeItem(at: audioFile)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func report(_ done: Int64, _ total: Int64?, token: Int, start: Double, span: Double) {
        guard isDownloading, token == fileToken else { return }
        speed.record(done)
        if let total, total > 0 {
            progress = start + span * min(1, Double(done) / Double(total))
            sizeText = "\(Self.mb(done)) / \(Self.mb(total))"
        } else {
            sizeText = Self.mb(done)
        }
    }

    // MARK: 选择格式

    private static func isAVC(_ stream: YouTubeKit.Stream) -> Bool {
        if case .avc1(_)? = stream.videoCodec { return true }
        return false
    }

    static func buildOptions(from streams: [YouTubeKit.Stream]) -> [DownloadOption] {
        var options: [DownloadOption] = []

        let audio = streams.filterAudioOnly()
            .filter { $0.fileExtension == .m4a }
            .highestAudioBitrateStream()

        let progressive = streams.filterVideoAndAudio()
            .filter { $0.isNativelyPlayable && $0.fileExtension == .mp4 }
            .highestResolutionStream()
        let progressiveRes = progressive?.videoResolution ?? 0

        // 高画质：H.264 视频轨 + m4a 音频轨，下载后在手机上合并（iPhone 相册兼容性最好）
        if let audio {
            let videoOnly = streams.filterVideoOnly().filter { isAVC($0) && $0.fileExtension == .mp4 }
            let bestPerResolution = Dictionary(grouping: videoOnly) { $0.videoResolution ?? 0 }
                .compactMapValues { group in group.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) } }
            let resolutions = bestPerResolution.keys.filter { $0 > progressiveRes }.sorted(by: >).prefix(3)
            for res in resolutions {
                guard let video = bestPerResolution[res] else { continue }
                options.append(DownloadOption(
                    label: "\(res)p 高画质",
                    detail: "画面和声音分开下载，再自动合并",
                    kind: .merge(video: video, audio: audio)
                ))
            }
        }

        if let progressive {
            options.append(DownloadOption(
                label: "\(progressiveRes)p 快速",
                detail: "直接下载一个文件，最稳定",
                kind: .single(progressive, ext: "mp4")
            ))
        }

        if let audio {
            options.append(DownloadOption(
                label: "仅音频（m4a）",
                detail: "适合听歌、听播客",
                kind: .single(audio, ext: "m4a")
            ))
        }

        return options
    }

    /// 批量下载时，按画质偏好挑一个格式
    static func pick(_ quality: Quality, from streams: [YouTubeKit.Stream]) -> DownloadOption.Kind? {
        let audio = streams.filterAudioOnly()
            .filter { $0.fileExtension == .m4a }
            .highestAudioBitrateStream()
        let progressive = streams.filterVideoAndAudio()
            .filter { $0.isNativelyPlayable && $0.fileExtension == .mp4 }
            .highestResolutionStream()
        let videos = streams.filterVideoOnly()
            .filter { isAVC($0) && $0.fileExtension == .mp4 }

        func bestVideo(maxHeight: Int) -> YouTubeKit.Stream? {
            videos.filter { ($0.videoResolution ?? 0) <= maxHeight }
                .max { a, b in
                    let ra = a.videoResolution ?? 0, rb = b.videoResolution ?? 0
                    return ra != rb ? ra < rb : (a.bitrate ?? 0) < (b.bitrate ?? 0)
                }
        }

        switch quality {
        case .audio:
            return audio.map { .single($0, ext: "m4a") }
        case .fast:
            if let progressive { return .single(progressive, ext: "mp4") }
            if let audio, let v = bestVideo(maxHeight: 480) { return .merge(video: v, audio: audio) }
            return nil
        case .best, .hd720:
            let limit = quality == .best ? Int.max : 720
            if let audio, let v = bestVideo(maxHeight: limit),
               (v.videoResolution ?? 0) > (progressive?.videoResolution ?? 0) {
                return .merge(video: v, audio: audio)
            }
            return progressive.map { .single($0, ext: "mp4") }
        }
    }

    /// 批量下载其他网站（B站分P 等）时，按画质偏好从解析出的选项里挑一个
    static func pickSiteOption(_ quality: Quality, from options: [DownloadOption]) -> DownloadOption.Kind? {
        func isAudio(_ option: DownloadOption) -> Bool {
            if case let .direct(_, ext, _) = option.kind { return ext == "m4a" }
            return false
        }
        func isDirect(_ option: DownloadOption) -> Bool {
            if case .direct = option.kind { return true }
            return false
        }
        func height(_ option: DownloadOption) -> Int {
            Web.firstMatch(option.label, "(\\d+)p").flatMap(Int.init) ?? 0
        }
        let videos = options.filter { !isAudio($0) }
        switch quality {
        case .audio:
            return options.first(where: isAudio)?.kind
        case .fast:
            return (videos.first(where: isDirect) ?? videos.last)?.kind
        case .hd720:
            let fitting = videos.filter { (1...720).contains(height($0)) }
            return (fitting.max { height($0) < height($1) } ?? videos.last)?.kind
        case .best:
            return videos.first?.kind  // 选项本来就是从高到低排的
        }
    }

    // MARK: 小工具

    /// 剪贴板里的链接要不要自动解析（YouTube 和专门支持的网站；其他网页不自动）
    static func isSupportedLink(_ url: URL) -> Bool {
        Site.detect(url) != .generic
    }

    static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// mp4 文件的第 4～8 个字节是 "ftyp"
    static func looksLikeMP4(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 8 else { return false }
        return head.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    /// 从链接里取出视频 ID 和列表 ID
    static func parseIDs(_ url: URL) -> (videoID: String?, listID: String?) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = comps?.queryItems ?? []
        let listID = query.first { $0.name == "list" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        var videoID = query.first { $0.name == "v" }?.value
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        if videoID == nil {
            if host.contains("youtu.be"), let first = parts.first {
                videoID = first
            } else if let i = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), i + 1 < parts.count {
                videoID = parts[i + 1]
            }
        }
        if let id = videoID, id.isEmpty { videoID = nil }
        return (videoID, listID)
    }


    static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+", options: .regularExpression) {
            return URL(string: String(trimmed[range]))
        }
        // 只粘贴了视频 ID 的情况
        if trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return URL(string: "https://www.youtube.com/watch?v=\(trimmed)")
        }
        return nil
    }

    static func safeFileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = title.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        let short = String(cleaned.prefix(80))
        return short.isEmpty ? "video" : short
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(name) (\(i)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    /// 文件大小，给错误提示用
    static func sizeDescription(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size < 1024 ? "\(size) 字节" : mb(size)
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// 不到 1 MB/s 显示 KB/s，否则显示 MB/s
    static func speedString(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return "\(Int(bytesPerSecond / 1024)) KB/s"
    }
}

/// 根据最近 3 秒收到的数据量算下载速度
struct SpeedMeter {
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    /// 之前几个文件（比如画面）已经下完的量
    private var finishedBytes: Int64 = 0
    private var currentDone: Int64 = 0
    private var hasData = false
    private static let window: TimeInterval = 3

    mutating func reset() {
        self = SpeedMeter()
    }

    mutating func startFile() {
        finishedBytes += currentDone
        currentDone = 0
    }

    mutating func record(_ done: Int64) {
        currentDone = max(currentDone, done)
        hasData = true
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, finishedBytes + currentDone))
        samples.removeAll { now - $0.time > SpeedMeter.window }
    }

    /// 字节/秒；刚开始数据还不够时返回 nil
    mutating func rate() -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        samples.removeAll { now - $0.time > SpeedMeter.window }
        guard let first = samples.first, let last = samples.last else { return hasData ? 0 : nil }
        let elapsed = now - first.time
        guard elapsed >= 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / elapsed
    }
}

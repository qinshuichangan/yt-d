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
}

struct DownloadOption: Identifiable {
    enum Kind {
        case single(YouTubeKit.Stream, ext: String)
        case merge(video: YouTubeKit.Stream, audio: YouTubeKit.Stream)
        /// 直接下载一个地址（抖音等）
        case direct(URL, ext: String, headers: [String: String])
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

    @Published var phase: Phase = .idle
    @Published var info: VideoInfo?
    @Published var playlist: PlaylistInfo?
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var sizeText = ""
    @Published var copiedToClipboard = false
    @Published var selectedIDs: Set<String> = []
    @Published var failedDownloads: [FailedDownload] = []
    @Published var photoSaveMessage: String?

    static let autoDownloadKey = "autoDownload"
    static let autoSavePhotosKey = "autoSaveToPhotos"
    static let qualityKey = "playlistQuality"

    /// 设置里选的默认画质
    static var defaultQuality: Quality {
        Quality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .best
    }
    private static var autoSavePhotos: Bool { UserDefaults.standard.bool(forKey: autoSavePhotosKey) }

    private var task: Task<Void, Never>?

    // MARK: 给界面用的状态

    var isFetching: Bool { if case .fetching = phase { return true }; return false }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }
    var isBusy: Bool { isFetching || isDownloading }
    var finishedURL: URL? { if case .finished(let url) = phase { return url }; return nil }
    var batchMessage: String? { if case .batchDone(let msg) = phase { return msg }; return nil }
    var errorMessage: String? { if case .failed(let msg) = phase { return msg }; return nil }

    // MARK: 解析链接

    func fetch(_ text: String, autoDownload: Bool = false) {
        guard let url = Self.extractURL(from: text) else {
            phase = .failed("没认出链接，请粘贴完整的 YouTube 链接")
            return
        }
        let ids = Self.parseIDs(url)
        task?.cancel()
        info = nil
        playlist = nil
        selectedIDs = []
        failedDownloads = []
        photoSaveMessage = nil
        phase = .fetching

        if DouyinFetcher.isDouyin(url) {
            fetchDouyin(url, autoDownload: autoDownload)
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
                phase = .failed("解析失败：\(lastError.map { ErrorText.describe($0).text } ?? "未知错误")")
            }
        }
    }

    private func fetchDouyin(_ url: URL, autoDownload: Bool) {
        task = Task {
            do {
                let result = try await DouyinFetcher.fetch(url)
                var options: [DownloadOption] = []
                if let clean = result.noWatermark {
                    options.append(DownloadOption(
                        label: "无水印原画",
                        detail: "直接下载 mp4，同时保存作品说明",
                        kind: .direct(clean, ext: "mp4", headers: DouyinFetcher.headers)
                    ))
                }
                if let marked = result.watermarked, marked != result.noWatermark {
                    options.append(DownloadOption(
                        label: "带水印版本（备用）",
                        detail: "无水印下载失败时用这个",
                        kind: .direct(marked, ext: "mp4", headers: DouyinFetcher.headers)
                    ))
                }
                guard !options.isEmpty else { throw DouyinFetcher.Failure.noData }
                info = VideoInfo(title: result.title, thumbnail: result.cover, options: options, note: result.note)
                phase = .ready
                if autoDownload, let first = options.first {
                    download(first)
                }
            } catch {
                if Task.isCancelled { return }
                phase = .failed("解析失败：\(ErrorText.describe(error).text)")
            }
        }
    }

    // MARK: 下载单个视频

    func download(_ option: DownloadOption) {
        guard let info else { return }
        startWork()

        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let output = try await performDownload(option.kind, title: info.title, label: nil, start: 0, span: 1)
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
                    phase = .ready
                } else {
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
            defer { UIApplication.shared.isIdleTimerDisabled = false }
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
                    let streams = try await YouTube(videoID: item.videoID, methods: [.local, .remote]).streams
                    guard let kind = Self.pick(quality, from: streams) else {
                        throw AppError("没有合适的格式")
                    }
                    let output = try await performDownload(kind, title: item.title, label: label, start: start, span: 1 / count)
                    succeeded += 1
                    if Self.autoSavePhotos, Self.isVideoFile(output) {
                        statusText = "\(label)：正在存到相册…"
                        if await PhotoSaver.save(output).hasPrefix("已存到相册") { savedToPhotos += 1 }
                    }
                } catch {
                    if Self.isCancellation(error) { cancelled = true; break }
                    // 失败的先记下来，继续下一个
                    let described = ErrorText.describe(error)
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
        copiedToClipboard = false
        UIApplication.shared.isIdleTimerDisabled = true  // 下载时不自动锁屏
    }

    /// 下载一个视频（必要时合并），返回保存的文件
    private func performDownload(
        _ kind: DownloadOption.Kind, title: String, label: String?, start: Double, span: Double
    ) async throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory
        let base = Self.safeFileName(title)
        let prefix = label.map { "\($0)：" } ?? ""
        var cleanup: [URL] = []

        do {
            let output: URL
            switch kind {
            case let .single(stream, ext):
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).\(ext)"))
                cleanup = [output]
                statusText = "\(prefix)正在下载…"
                try await ChunkedDownloader.download(from: stream.url, to: output) { done, total in
                    Task { @MainActor in self.report(done, total, start: start, span: span) }
                }

            case let .direct(url, ext, headers):
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).\(ext)"))
                cleanup = [output]
                statusText = "\(prefix)正在下载…"
                try await ChunkedDownloader.download(from: url, to: output, headers: headers) { done, total in
                    Task { @MainActor in self.report(done, total, start: start, span: span) }
                }
                // 确认下到的是视频，而不是一个错误网页
                guard Self.looksLikeMP4(output) else {
                    throw AppError("下载到的不是视频文件，换另一个选项试试")
                }

            case let .merge(video, audio):
                let videoFile = tmp.appendingPathComponent(UUID().uuidString + ".mp4")
                let audioFile = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
                output = Self.uniqueURL(docs.appendingPathComponent("\(base).mp4"))
                cleanup = [videoFile, audioFile, output]

                statusText = "\(prefix)正在下载画面…"
                try await ChunkedDownloader.download(from: video.url, to: videoFile) { done, total in
                    Task { @MainActor in self.report(done, total, start: start, span: span * 0.85) }
                }
                statusText = "\(prefix)正在下载声音…"
                try await ChunkedDownloader.download(from: audio.url, to: audioFile) { done, total in
                    Task { @MainActor in self.report(done, total, start: start + span * 0.85, span: span * 0.12) }
                }
                statusText = "\(prefix)正在合并…"
                sizeText = ""
                try await Merger.merge(video: videoFile, audio: audioFile, output: output)
                try? fm.removeItem(at: videoFile)
                try? fm.removeItem(at: audioFile)
            }
            return output
        } catch {
            cleanup.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func report(_ done: Int64, _ total: Int64?, start: Double, span: Double) {
        guard isDownloading else { return }
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

    // MARK: 小工具

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

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

import AVFoundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 从相册选视频时，把文件复制到 App 自己的临时文件夹
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let target = try EditorModel.makeImportURL(name: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    static let formatKey = "outputFormat"
    static let bitrateKey = "audioBitrate"
    static let preciseKey = "preciseTrim"
    static let compressSideKey = "compressShortSide"
    static let compressFPSKey = "compressFPS"
    static let compressBitrateKey = "compressBitrate"
    static let compressHEVCKey = "compressHEVC"
    static let compressModeKey = "compressMode"
    static let compressTargetKey = "compressTargetMB"

    // 已载入的文件
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceName = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasVideo = false
    @Published private(set) var hasAudio = false
    /// 原视频信息，例：「1920×1080 · 30 fps · 码率 15.2 Mbps · 85.3 MB」
    @Published private(set) var videoInfo = ""
    /// 原视频的宽高、帧率、码率（自动计算压缩设置用）
    @Published private(set) var sourceVideo: SourceVideo?
    @Published private(set) var isLoading = false

    // 截取范围（文字输入）
    @Published var startText = ""
    @Published var endText = ""
    @Published private(set) var currentTime: Double = 0

    // 导出
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    /// 导出的结果（分割时有好几个）
    @Published private(set) var results: [URL] = []
    @Published var errorMessage: String?

    let player = AVPlayer()
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var exportTask: Task<[URL], Error>?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor in self.currentTime = seconds }
        }
    }

    // MARK: - 范围

    var startSeconds: Double? { TimeText.parse(startText) }
    var endSeconds: Double? { TimeText.parse(endText) }

    /// 范围有问题时返回提示文字，没问题返回 nil
    var rangeProblem: String? {
        guard sourceURL != nil else { return nil }
        guard let start = startSeconds else { return "开始时间格式不对（例：1:23 或 83.5）" }
        guard let end = endSeconds else { return "结束时间格式不对（例：2:05 或 125）" }
        if start >= duration { return "开始时间超过了总长度 \(TimeText.format(duration))" }
        if end > duration + 0.05 { return "结束时间超过了总长度 \(TimeText.format(duration))" }
        if end <= start { return "结束时间要比开始时间晚" }
        return nil
    }

    var selectedLength: Double? {
        guard rangeProblem == nil, let s = startSeconds, let e = endSeconds else { return nil }
        return min(e, duration) - s
    }

    private var isFullRange: Bool {
        guard let s = startSeconds, let e = endSeconds else { return false }
        return s < 0.005 && e >= duration - 0.005
    }

    func setStartToCurrent() { startText = TimeText.format(currentTime) }
    func setEndToCurrent() { endText = TimeText.format(min(currentTime, duration)) }

    func resetRange() {
        startText = TimeText.format(0)
        endText = TimeText.format(duration)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 只播放选中的部分，到结束时间自动停
    func previewSelection() {
        guard rangeProblem == nil, let start = startSeconds, let end = endSeconds else { return }
        removeBoundaryObserver()
        let endTime = CMTime(seconds: min(end, duration), preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)], queue: .main
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.player.pause()
                self.removeBoundaryObserver()
            }
        }
        let player = self.player
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in player.play() }
        }
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    // MARK: - 载入

    static func importFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Imported", isDirectory: true)
    }

    /// 在临时文件夹里准备一个不重名的位置（nonisolated：相册导入时在后台调用）
    nonisolated static func makeImportURL(name: String, folder base: String = "Imported") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(base, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name.isEmpty ? "video.mov" : name)
    }

    /// 从「文件」App 或别的 App 传来的文件：先复制一份再用
    func loadExternal(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let target = try Self.makeImportURL(name: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            load(target)
        } catch {
            errorMessage = "读取文件失败：\(error.localizedDescription)"
        }
    }

    func loadPhotoItem(_ movie: PickedMovie) {
        load(movie.url)
    }

    /// 剪贴板里的音频 / 视频（来自「粘贴」按钮）
    func loadPasted(_ providers: [NSItemProvider]) {
        guard let provider = providers.first,
              let typeID = provider.registeredTypeIdentifiers.first(where: {
                  UTType($0)?.conforms(to: .audiovisualContent) == true
              }) else {
            errorMessage = "剪贴板里没有音频或视频"
            return
        }
        let ext = UTType(typeID)?.preferredFilenameExtension ?? "m4a"
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd_HHmmss"
        let name = "剪贴板_\(formatter.string(from: Date())).\(ext)"

        errorMessage = nil
        isLoading = true
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, error in
            Task { @MainActor in
                guard let data, !data.isEmpty else {
                    self.isLoading = false
                    self.errorMessage = "读取剪贴板失败：\(error?.localizedDescription ?? "没有数据")"
                    return
                }
                do {
                    let target = try Self.makeImportURL(name: name)
                    try data.write(to: target)
                    self.load(target)
                } catch {
                    self.isLoading = false
                    self.errorMessage = "读取剪贴板失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 载入一个已经在 App 里的文件
    func load(_ url: URL) {
        cancelExport()
        removeBoundaryObserver()
        player.pause()
        cleanImports(keeping: url)

        isLoading = true
        errorMessage = nil
        results = []
        Task {
            defer { isLoading = false }
            let asset = AVURLAsset(url: url)
            do {
                let length = try await asset.load(.duration).seconds
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard length.isFinite, length > 0 else {
                    errorMessage = "读不出这个文件的长度，可能不是视频或音频"
                    return
                }
                guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                    errorMessage = "这个文件里没有画面也没有声音"
                    return
                }
                sourceURL = url
                sourceName = url.deletingPathExtension().lastPathComponent
                duration = length
                hasVideo = !videoTracks.isEmpty
                hasAudio = !audioTracks.isEmpty
                let meta = await Self.describeVideo(videoTracks.first, file: url)
                videoInfo = meta.text
                sourceVideo = meta.video
                currentTime = 0
                resetRange()
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            } catch {
                errorMessage = "打开失败：\(error.localizedDescription)"
            }
        }
    }

    /// 原视频的分辨率、帧率、码率、文件大小
    static func describeVideo(_ track: AVAssetTrack?,
                                      file: URL) async -> (text: String, video: SourceVideo?) {
        guard let track,
              let info = try? await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        else { return ("", nil) }
        let (size, transform, fps, rate) = info
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = Int(abs(rect.width).rounded())
        let height = Int(abs(rect.height).rounded())
        let mbps = Double(rate) / 1_000_000
        var parts = ["\(width)×\(height)"]
        if fps > 0 { parts.append("\(Int(fps.rounded())) fps") }
        if rate > 0 { parts.append(String(format: "码率 %.1f Mbps", mbps)) }
        parts.append(ExportLibraryView.sizeText(file))
        let video = width > 0 && height > 0
            ? SourceVideo(width: width, height: height, fps: Double(fps), bitrateMbps: mbps)
            : nil
        return (parts.joined(separator: " · "), video)
    }

    /// 删掉以前导入的临时文件（正在用的那个除外）
    private func cleanImports(keeping url: URL) {
        let folder = Self.importFolder()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let keepPath = url.standardizedFileURL.path
        for item in items where !keepPath.hasPrefix(item.standardizedFileURL.path + "/") {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: - 导出

    func export(format: OutputFormat, bitrate: Int, precise: Bool, compress: CompressSettings,
                split: SplitSettings) {
        guard let source = sourceURL, !isExporting else { return }
        if let problem = rangeProblem {
            errorMessage = problem
            return
        }
        guard let start = startSeconds, let end = endSeconds else { return }
        if format.isVideo && !hasVideo {
            errorMessage = "这个文件没有画面，只能转成音频"
            return
        }
        if format.isAudio && !hasAudio {
            errorMessage = "这个文件里没有声音"
            return
        }

        player.pause()
        let name = format == .compressed ? sourceName + "_压缩" : sourceName
        let segments = Exporter.segments(base: name, start: start, end: min(end, duration),
                                         fullFile: isFullRange, split: split, ext: format.fileExtension)
        let job = Exporter.Job(format: format, precise: precise, audioBitrate: bitrate, compress: compress)

        isExporting = true
        progress = 0
        errorMessage = nil
        results = []

        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in
                self.progress = value
                WorkSession.shared.update(progress: value)
            }
        }
        let task = Task.detached(priority: .userInitiated) { () async throws -> [URL] in
            try await Exporter.run(job, source: source, segments: segments, progress: report)
        }
        exportTask = task

        let backgroundMark = WorkSession.shared.backgroundCount
        WorkSession.shared.begin(title: "剪辑转换：\(sourceName)") { [weak self] in
            self?.cancelExport()
        }

        Task {
            var success = false
            do {
                results = try await task.value
                success = true
            } catch is CancellationError {
                errorMessage = WorkSession.shared.backgroundCount != backgroundMark
                    ? "在后台被系统停止了，请重新开始"
                    : "已取消"
            } catch {
                errorMessage = WorkSession.shared.backgroundCount != backgroundMark
                    ? "切到后台时被系统中断了，请留在 App 里重新开始（\(error.localizedDescription)）"
                    : error.localizedDescription
            }
            WorkSession.shared.end(success: success)
            isExporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    // MARK: - 文件名

    /// 剪辑结果放在「剪辑输出」文件夹，不和下载的视频混在一起
    static func outputFolder() -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("剪辑输出", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 例：「我的视频_1m05s-2m30s.mp3」，整段的话就是「我的视频.mp3」；重名时加 (2)、(3)…
    static func outputURL(name: String, start: Double, end: Double, full: Bool, ext: String) -> URL {
        var base = name.isEmpty ? "输出" : name
        if !full {
            base += "_\(TimeText.fileStamp(start))-\(TimeText.fileStamp(end))"
        }
        let folder = outputFolder()
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        let fm = FileManager.default
        // 视频可能被改存成 .mov，两种都要避开
        while fm.fileExists(atPath: url.path)
                || (ext == "mp4" && fm.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("mov").path)) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

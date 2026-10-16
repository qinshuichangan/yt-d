import Foundation
import UIKit
import YouTubeKit

struct VideoInfo {
    let title: String
    let thumbnail: URL?
    let options: [DownloadOption]
}

struct DownloadOption: Identifiable {
    enum Kind {
        case single(YouTubeKit.Stream, ext: String)
        case merge(video: YouTubeKit.Stream, audio: YouTubeKit.Stream)
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
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var info: VideoInfo?
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var sizeText = ""

    private var task: Task<Void, Never>?

    // MARK: 给界面用的状态

    var isFetching: Bool { if case .fetching = phase { return true }; return false }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }
    var isBusy: Bool { isFetching || isDownloading }
    var finishedURL: URL? { if case .finished(let url) = phase { return url }; return nil }
    var errorMessage: String? { if case .failed(let msg) = phase { return msg }; return nil }

    // MARK: 解析链接

    func fetch(_ text: String) {
        guard let url = Self.extractURL(from: text) else {
            phase = .failed("没认出链接，请粘贴完整的 YouTube 链接")
            return
        }
        task?.cancel()
        info = nil
        phase = .fetching

        task = Task {
            do {
                // 先在本机解析，失败时再用 YouTubeKit 作者提供的远程服务器
                let video = YouTube(url: url, methods: [.local, .remote])
                let streams = try await video.streams
                let metadata = try? await video.metadata
                let options = Self.buildOptions(from: streams)
                guard !options.isEmpty else {
                    phase = .failed("没有找到可以下载的格式")
                    return
                }
                info = VideoInfo(
                    title: metadata?.title ?? video.videoID,
                    thumbnail: metadata?.thumbnail?.url,
                    options: options
                )
                phase = .ready
            } catch {
                if Task.isCancelled { return }
                phase = .failed("解析失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 下载

    func download(_ option: DownloadOption) {
        guard let info else { return }
        task?.cancel()
        phase = .downloading
        progress = 0
        sizeText = ""
        UIApplication.shared.isIdleTimerDisabled = true  // 下载时不自动锁屏

        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let tmp = fm.temporaryDirectory
            let base = Self.safeFileName(info.title)
            var cleanup: [URL] = []

            do {
                let output: URL
                switch option.kind {
                case let .single(stream, ext):
                    output = Self.uniqueURL(docs.appendingPathComponent("\(base).\(ext)"))
                    cleanup = [output]
                    statusText = "正在下载…"
                    try await ChunkedDownloader.download(from: stream.url, to: output) { done, total in
                        Task { @MainActor in self.report(done, total, start: 0, span: 1) }
                    }

                case let .merge(video, audio):
                    let videoFile = tmp.appendingPathComponent(UUID().uuidString + ".mp4")
                    let audioFile = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
                    output = Self.uniqueURL(docs.appendingPathComponent("\(base).mp4"))
                    cleanup = [videoFile, audioFile, output]

                    statusText = "正在下载画面…"
                    try await ChunkedDownloader.download(from: video.url, to: videoFile) { done, total in
                        Task { @MainActor in self.report(done, total, start: 0, span: 0.85) }
                    }
                    statusText = "正在下载声音…"
                    try await ChunkedDownloader.download(from: audio.url, to: audioFile) { done, total in
                        Task { @MainActor in self.report(done, total, start: 0.85, span: 0.12) }
                    }
                    statusText = "正在合并…"
                    sizeText = ""
                    try await Merger.merge(video: videoFile, audio: audioFile, output: output)
                    try? fm.removeItem(at: videoFile)
                    try? fm.removeItem(at: audioFile)
                }
                progress = 1
                phase = .finished(output)
            } catch {
                cleanup.forEach { try? fm.removeItem(at: $0) }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    phase = .ready
                } else {
                    phase = .failed("下载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
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

    // MARK: 小工具

    static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "https?://\\S+", options: .regularExpression) {
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

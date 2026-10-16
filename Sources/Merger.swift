import AVFoundation

/// 把分开下载的视频轨和音频轨合并成一个 mp4（不重新编码，速度很快）。
enum Merger {
    enum Failure: LocalizedError {
        case missingTrack, exportFailed
        var errorDescription: String? {
            switch self {
            case .missingTrack: return "合并失败：找不到视频或音频轨道"
            case .exportFailed: return "合并失败"
            }
        }
    }

    static func merge(video: URL, audio: URL, output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw Failure.missingTrack
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let transform = try await videoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compVideo.preferredTransform = transform
        try compAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
            of: audioTrack, at: .zero
        )

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        await export.export()
        guard export.status == .completed else {
            throw export.error ?? Failure.exportFailed
        }
    }
}

import AVFoundation

/// 把分开下载的视频轨和音频轨合并成一个 mp4（不重新编码，画质不变）。
///
/// YouTube 的画面文件里，最后一帧有时被标成持续好几分钟，
/// 用 AVAssetExportSession 合并会原样保留，导致视频变长、结尾定格。
/// 所以这里用 AVAssetReader/AVAssetWriter 逐帧写入，并修正异常的帧时长。
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

    /// 在两个队列间共享的写入状态
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var videoEnd: CMTime = .zero
        var audioEnd: CMTime = .zero
        var videoDone = false
        var audioDone = false
    }

    static func merge(video: URL, audio: URL, output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw Failure.missingTrack
        }
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let audioFormat = try await audioTrack.load(.formatDescriptions).first
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let frameDuration = CMTime(seconds: 1.0 / Double(fps > 1 ? fps : 30), preferredTimescale: 600_000)

        // 读取（不解码）
        let videoReader = try AVAssetReader(asset: videoAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)

        let audioReader = try AVAssetReader(asset: audioAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioOutput.alwaysCopiesSampleData = false
        audioReader.add(audioOutput)

        // 写入（不编码）
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw Failure.exportFailed }
        writer.add(videoInput)
        writer.add(audioInput)

        guard videoReader.startReading(), audioReader.startReading() else {
            throw videoReader.error ?? audioReader.error ?? Failure.exportFailed
        }
        guard writer.startWriting() else { throw writer.error ?? Failure.exportFailed }
        writer.startSession(atSourceTime: .zero)

        let state = State()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()

            func finish(video: Bool) {
                state.lock.lock()
                let alreadyDone = video ? state.videoDone : state.audioDone
                if video { state.videoDone = true } else { state.audioDone = true }
                state.lock.unlock()
                guard !alreadyDone else { return }
                if video { videoInput.markAsFinished() } else { audioInput.markAsFinished() }
                group.leave()
            }

            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "merge.video")) {
                while videoInput.isReadyForMoreMediaData {
                    guard let buffer = videoOutput.copyNextSampleBuffer(),
                          let fixed = fixTiming(buffer, normal: frameDuration),
                          videoInput.append(fixed) else {
                        finish(video: true)
                        return
                    }
                    if let end = endTime(of: fixed) {
                        state.lock.lock()
                        if end > state.videoEnd { state.videoEnd = end }
                        state.lock.unlock()
                    }
                }
            }

            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "merge.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard let buffer = audioOutput.copyNextSampleBuffer(),
                          audioInput.append(buffer) else {
                        finish(video: false)
                        return
                    }
                    if let end = endTime(of: buffer) {
                        state.lock.lock()
                        if end > state.audioEnd { state.audioEnd = end }
                        state.lock.unlock()
                    }
                }
            }

            group.notify(queue: .global()) { continuation.resume() }
        }

        if videoReader.status == .failed || audioReader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw videoReader.error ?? audioReader.error ?? writer.error ?? Failure.exportFailed
        }

        // 按画面和声音中较短的那个结束
        var end = state.videoEnd
        if state.audioEnd.isNumeric, state.audioEnd > .zero,
           !end.isNumeric || end == .zero || state.audioEnd < end {
            end = state.audioEnd
        }
        if end.isNumeric && end > .zero {
            writer.endSession(atSourceTime: end)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? Failure.exportFailed
        }
    }

    /// 一个采样的结束时间；没有有效时间信息（比如标记帧）时返回 nil
    private static func endTime(of buffer: CMSampleBuffer) -> CMTime? {
        guard CMSampleBufferGetNumSamples(buffer) > 0 else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = CMSampleBufferGetDuration(buffer)
        guard pts.isNumeric, duration.isNumeric, duration.seconds <= 1 else { return nil }
        let end = pts + duration
        return end.isNumeric ? end : nil
    }

    /// 帧时长异常（超过 1 秒）时，改成正常的一帧时长
    private static func fixTiming(_ buffer: CMSampleBuffer, normal: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(buffer) == 1 else { return buffer }
        guard CMSampleBufferGetPresentationTimeStamp(buffer).isNumeric else { return buffer }
        let duration = CMSampleBufferGetDuration(buffer)
        guard !duration.isNumeric || duration.seconds > 1 else { return buffer }

        var timing = CMSampleTimingInfo(
            duration: normal,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(buffer)
        )
        var fixed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &fixed
        )
        return status == noErr ? fixed : buffer
    }
}

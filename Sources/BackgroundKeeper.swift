import AVFoundation
import UIKit

/// 下载时让 App 在后台继续运行。
///
/// iOS 一般在 App 切到后台几秒后就把它暂停，下载也就停了。
/// 这里在下载期间循环播放一段无声音频（和别的 App 的声音混在一起，不会打断音乐或视频），
/// 系统就会让 App 一直跑下去，合并、存相册也能在后台完成。下载结束就停掉。
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var users = 0
    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 开始一项需要在后台继续的工作（和 end() 成对调用）
    func begin() {
        users += 1
        guard users == 1 else { return }
        UIApplication.shared.isIdleTimerDisabled = true  // 留在前台时不自动锁屏
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "download") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        startAudio()
        observeInterruptions()
    }

    func end() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let newPlayer = try AVAudioPlayer(data: Self.silentWAV)
                newPlayer.numberOfLoops = -1
                player = newPlayer
            }
            player?.play()
        } catch {
            // 声音开不起来也没关系，只是切到后台后可能会停
        }
    }

    /// 来电等打断结束后，重新开始播放
    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            Task { @MainActor in
                guard let self, self.users > 0 else { return }
                self.startAudio()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.users > 0 else { return }
                self.player = nil
                self.startAudio()
            }
        })
    }

    /// 1 秒的无声 WAV（8kHz、16 位、单声道）
    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))            // PCM、单声道
        append(sampleRate); append(sampleRate * 2)      // 采样率、每秒字节数
        append(UInt16(2)); append(UInt16(16))           // 每帧字节数、位深
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()
}

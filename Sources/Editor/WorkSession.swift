import BackgroundTasks
import UIKit

/// 处理期间的「保护」：
/// - 不自动锁屏，可选把屏幕调到最暗（离开 App 时先恢复亮度，回来再调暗）
/// - iOS 26 起向系统申请「继续处理」任务，切到后台也能接着做，锁屏 / 灵动岛上显示进度
/// - 申请不到时退回到普通的后台时间（只有几十秒）
@MainActor
final class WorkSession {
    static let shared = WorkSession()
    static let dimKey = "dimWhileWorking"

    /// 每次 App 进入后台就 +1。任务失败时拿来判断「是不是因为切到后台被系统打断的」
    private(set) var backgroundCount = 0

    private var active = false
    private var title = ""
    private var lastProgress = 0.0
    private var savedBrightness: CGFloat?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject?   // iOS 26 的 BGContinuedProcessingTask
    private var onExpire: (() -> Void)?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WorkSession.shared.restoreBrightness() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WorkSession.shared.applyDim() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WorkSession.shared.backgroundCount += 1 }
        }
    }

    var isActive: Bool { active }

    private var dimEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dimKey) as? Bool ?? true
    }

    /// 开始处理。onExpire：系统收回后台时间（或用户在系统进度里点了停止）时调用，应当取消任务
    func begin(title: String, onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
        self.title = title
        guard !active else { return }
        active = true
        lastProgress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        applyDim()
        startBackgroundProtection()
    }

    /// 更新进度（0...1），会显示在系统的后台任务进度上
    func update(progress: Double) {
        lastProgress = min(max(progress, 0), 1)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(lastProgress * 1000)
        }
    }

    func end(success: Bool) {
        guard active else { return }
        active = false
        onExpire = nil
        // 下载那边还在进行的话，继续保持不锁屏
        if !BackgroundKeeper.shared.isActive { UIApplication.shared.isIdleTimerDisabled = false }
        restoreBrightness()
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        endLegacyTask()
    }

    /// 开关改了之后马上生效
    func refreshDim() {
        if dimEnabled { applyDim() } else { restoreBrightness() }
    }

    // MARK: - 亮度

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private func applyDim() {
        guard active, dimEnabled, UIApplication.shared.applicationState == .active,
              let screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = 0
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        savedBrightness = nil
        screen?.brightness = saved
    }

    // MARK: - 后台

    private func startBackgroundProtection() {
        if #available(iOS 26.0, *), startContinuedTask() { return }
        startLegacyTask()
    }

    private func startLegacyTask() {
        guard legacyTask == .invalid else { return }
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "export") {
            Task { @MainActor in WorkSession.shared.expired() }
        }
    }

    private func endLegacyTask() {
        guard legacyTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyTask)
        legacyTask = .invalid
    }

    private func expired() {
        let handler = onExpire
        onExpire = nil
        handler?()
        endLegacyTask()
    }

    @available(iOS 26.0, *)
    private func startContinuedTask() -> Bool {
        // Info.plist 里登记的是「前缀.*」，每次用前缀 + 随机后缀申请
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let pattern = ids.first(where: { $0.hasSuffix(".*") }) else { return false }
        let identifier = String(pattern.dropLast()) + UUID().uuidString

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in WorkSession.shared.attach(task) }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "处理中…")
        request.strategy = .fail   // 不能马上开始就算了，不要排队
        do {
            try BGTaskScheduler.shared.submit(request)
            // 系统真正开始之前的这一小段，先用普通后台时间垫着
            startLegacyTask()
            return true
        } catch {
            return false
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard active else {
            task.setTaskCompleted(success: true)
            return
        }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(lastProgress * 1000)
        task.expirationHandler = {
            Task { @MainActor in WorkSession.shared.continuedExpired() }
        }
        continuedTask = task
        endLegacyTask()
    }

    @available(iOS 26.0, *)
    private func continuedExpired() {
        if let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: false)
        }
        continuedTask = nil
        expired()
    }
}

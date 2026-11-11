import UIKit

/// 运行日志：记录解析、下载、出错的过程，方便一键复制出来排查问题。
/// 只记网址的域名和路径（不记 ? 后面的签名参数），不记 Cookie 和账号信息。
enum AppLog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let maxLines = 400

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func add(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("\(timeFormatter.string(from: Date())) \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    static func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    /// 网址只留域名和路径
    static func short(_ url: URL?) -> String {
        guard let url else { return "（无）" }
        var path = url.path
        if path.count > 80 { path = String(path.prefix(80)) + "…" }
        return "\(url.host ?? "?")\(path)"
    }

    /// 错误的详细信息（类型 + 内容）
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(type(of: error)) \(ns.domain)#\(ns.code)：\(error.localizedDescription)"
    }

    /// 带上版本和设置的完整日志
    static func text() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let defaults = UserDefaults.standard
        let header = """
        === 视频下载 运行日志 ===
        版本：\(version)（\(build)）
        系统：iOS \(UIDevice.current.systemVersion)，\(model)
        线程数：\(ChunkedDownloader.threadCount)，队列模式：\(defaults.bool(forKey: DownloadManager.queueModeKey) ? "开" : "关")
        登录：\(LoginSite.allCases.map { "\($0.rawValue)\(WebLogin.isLoggedIn($0) ? "已登录" : "未登录")" }.joined(separator: "，"))
        ========================
        """
        lock.lock()
        let body = lines.joined(separator: "\n")
        lock.unlock()
        return header + "\n" + (body.isEmpty ? "（还没有记录）" : body)
    }
}

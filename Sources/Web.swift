import Foundation

/// 各网站解析时共用的网络 / JSON / 文本小工具
enum Web {
    /// 请求一个地址（自动跟随跳转），返回内容和最终的响应
    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func text(_ url: URL, headers: [String: String] = [:]) async throws -> (String, URL) {
        let (data, http) = try await get(url, headers: headers)
        guard (200..<400).contains(http.statusCode) else { throw SiteError.http(http.statusCode) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (text, http.url ?? url)
    }

    static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        let (data, http) = try await get(url, headers: headers)
        guard (200..<300).contains(http.statusCode) else { throw SiteError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// 短链接打开一次，看最终跳到哪里
    static func resolve(_ url: URL, headers: [String: String] = [:]) async throws -> URL {
        let (_, http) = try await get(url, headers: headers)
        return http.url ?? url
    }

    /// 第一个括号里匹配到的内容
    static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// 网页里的 &amp; 之类还原
    static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\u002F", with: "/")
    }

    static func url(_ string: String?) -> URL? {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        return URL(string: s)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// 在 JSON（[String: Any] / [Any]）里按路径取值，路径里可以混用字符串和下标
enum J {
    static func get(_ root: Any?, _ path: Any...) -> Any? {
        var current = root
        for key in path {
            if let name = key as? String {
                current = (current as? [String: Any])?[name]
            } else if let index = key as? Int {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
            if current == nil || current is NSNull { return nil }
        }
        return current
    }

    static func str(_ root: Any?, _ path: Any...) -> String? {
        let value = path.reduce(root) { partial, key in get(partial, key) }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ root: Any?, _ path: Any...) -> Int64? {
        let value = path.reduce(root) { partial, key in get(partial, key) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    static func array(_ root: Any?, _ path: Any...) -> [Any] {
        let value = path.reduce(root) { partial, key in get(partial, key) }
        return value as? [Any] ?? []
    }
}

/// 各网站解析时的错误
enum SiteError: LocalizedError {
    case http(Int)
    case noID(String)
    case noData(String)
    case noVideo
    case imagePost
    case needLogin(String)
    case unavailable(String?)
    case unsupportedStream

    var errorDescription: String? {
        switch self {
        case .http(let code): return "网站返回错误（HTTP \(code)）"
        case .noID(let site): return "没认出\(site)作品的编号，请粘贴完整的分享链接"
        case .noData(let site): return "没能从\(site)页面里读到视频信息（网站可能改了页面）"
        case .noVideo: return "这个页面里没有找到可以下载的视频"
        case .imagePost: return "这是图文作品，暂时只支持视频"
        case .needLogin(let site): return "\(site)要求登录才能看。请到「设置」→「登录网站」登录后再试"
        case .unavailable(let reason): return "作品不可用" + (reason.map { "：\($0)" } ?? "（可能已被删除或设为私密）")
        case .unsupportedStream: return "这个视频是直播流（m3u8）格式，暂不支持下载"
        }
    }

    /// 重试有没有意义
    var retryable: Bool {
        switch self {
        case .http, .noData: return true
        default: return false
        }
    }
}

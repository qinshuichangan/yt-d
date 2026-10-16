import Foundation

/// 解析抖音分享链接，拿到视频地址。
///
/// 做法：短链接（v.douyin.com/…）会跳转到带作品 ID 的地址，
/// 再打开 iesdouyin.com 的分享页，从页面里的 _ROUTER_DATA 里取出视频信息。
/// 抖音经常改页面，这里同样用递归查找，尽量不写死路径。
enum DouyinFetcher {
    struct Result {
        let id: String
        let title: String
        let cover: URL?
        let noWatermark: URL?
        let watermarked: URL?
        /// 一起保存的文字说明（作者、描述、原链接等）
        let note: String
    }

    enum Failure: LocalizedError {
        case noID
        case noData
        case imagePost
        case unavailable(String?)

        var errorDescription: String? {
            switch self {
            case .noID: return "没认出抖音作品 ID，请粘贴完整的分享链接"
            case .noData: return "没能从抖音页面里读到视频信息（抖音可能改了页面）"
            case .imagePost: return "这是图文作品，暂时只支持视频"
            case .unavailable(let reason):
                return "作品不可用" + (reason.map { "：\($0)" } ?? "（可能已被删除或屏蔽）")
            }
        }
    }

    static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
        "Referer": "https://www.douyin.com/",
    ]

    static func isDouyin(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix("douyin.com") || host.hasSuffix("iesdouyin.com")
    }

    static func fetch(_ url: URL) async throws -> Result {
        let id = try await resolveID(url)

        var request = URLRequest(url: URL(string: "https://www.iesdouyin.com/share/video/\(id)/")!)
        request.timeoutInterval = 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let json = routerData(in: html) else {
            throw Failure.noData
        }

        guard let item = findItem(json) else {
            throw Failure.unavailable(findFilterReason(json))
        }

        let desc = (item["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (item["author"] as? [String: Any])?["nickname"] as? String
        let video = item["video"] as? [String: Any]
        let playAddr = video?["play_addr"] as? [String: Any]
        let urls = (playAddr?["url_list"] as? [String]) ?? []

        if urls.isEmpty {
            if let images = item["images"] as? [Any], !images.isEmpty { throw Failure.imagePost }
            throw Failure.noData
        }

        let watermarkedString = urls.first!
        var noWatermarkString = watermarkedString.replacingOccurrences(of: "playwm", with: "play")
        if noWatermarkString == watermarkedString, let uri = playAddr?["uri"] as? String, !uri.isEmpty {
            noWatermarkString = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=1080p&line=0"
        }

        let coverString = ((video?["cover"] as? [String: Any])?["url_list"] as? [String])?.first
            ?? ((video?["origin_cover"] as? [String: Any])?["url_list"] as? [String])?.first

        var title = desc.isEmpty ? "抖音作品 \(id)" : desc
        if let author, !author.isEmpty { title = "\(author) - \(title)" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let note = """
        作者：\(author ?? "（未知）")
        描述：\(desc.isEmpty ? "（无）" : desc)
        原链接：https://www.douyin.com/video/\(id)
        作品 ID：\(id)
        保存时间：\(formatter.string(from: Date()))
        """

        return Result(
            id: id,
            title: title,
            cover: coverString.flatMap(URL.init(string:)),
            noWatermark: URL(string: noWatermarkString),
            watermarked: URL(string: watermarkedString),
            note: note
        )
    }

    // MARK: 作品 ID

    private static func resolveID(_ url: URL) async throws -> String {
        if let id = idFromURL(url) { return id }
        if url.path.contains("/note/") || url.path.contains("/slides/") { throw Failure.imagePost }

        // 短链接：打开一次，看跳转到哪里
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let final = response.url {
            if final.path.contains("/note/") || final.path.contains("/slides/") { throw Failure.imagePost }
            if let id = idFromURL(final) { return id }
        }
        // 再从页面内容里找一次
        if let html = String(data: data, encoding: .utf8),
           let id = firstMatch(in: html, pattern: "/video/(\\d{8,})") {
            return id
        }
        throw Failure.noID
    }

    private static func idFromURL(_ url: URL) -> String? {
        if let id = firstMatch(in: url.path, pattern: "/(?:video|share/video)/(\\d{8,})") { return id }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in ["modal_id", "aweme_id", "item_id"] {
            if let value = query.first(where: { $0.name == name })?.value,
               value.range(of: "^\\d{8,}$", options: .regularExpression) != nil {
                return value
            }
        }
        return nil
    }

    // MARK: 页面数据

    private static func routerData(in html: String) -> Any? {
        for marker in ["window._ROUTER_DATA = ", "window._ROUTER_DATA="] {
            guard let start = html.range(of: marker) else { continue }
            let rest = html[start.upperBound...]
            guard let end = rest.range(of: "</script>") else { continue }
            var jsonText = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonText.hasSuffix(";") { jsonText.removeLast() }
            if let data = jsonText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
        }
        return nil
    }

    private static func findItem(_ node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let list = dict["item_list"] as? [[String: Any]], let first = list.first { return first }
            if let detail = dict["aweme_detail"] as? [String: Any] { return detail }
            for value in dict.values {
                if let found = findItem(value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findItem(value) { return found }
            }
        }
        return nil
    }

    private static func findFilterReason(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let list = dict["filter_list"] as? [[String: Any]], let first = list.first {
                return (first["detail_msg"] as? String) ?? (first["filter_reason"] as? String)
            }
            for value in dict.values {
                if let found = findFilterReason(value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findFilterReason(value) { return found }
            }
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

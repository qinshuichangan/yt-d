import Foundation

struct PlaylistItem: Identifiable, Hashable {
    let videoID: String
    let title: String
    var id: String { videoID }
}

struct PlaylistInfo {
    let id: String
    let title: String
    let items: [PlaylistItem]
    /// YouTube 自动生成的合辑（列表 ID 以 RD 开头）
    let isMix: Bool
}

/// 读取播放列表里的视频 ID 和标题（通过 YouTube 网页版用的内部接口）。
///
/// 返回的 JSON 结构经常变，所以这里不写死路径，
/// 而是在整个 JSON 里递归查找视频条目。
enum PlaylistFetcher {
    enum Failure: LocalizedError {
        case empty
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .empty: return "没有读到列表里的视频（可能是私人列表）"
            case .http(let code): return "读取列表失败（HTTP \(code)）"
            }
        }
    }

    private static let clientVersion = "2.20250312.04.00"
    private static let maxPages = 40  // 普通列表每页约 100 个，最多读约 4000 个

    private static var context: [String: Any] {
        ["client": [
            "clientName": "WEB",
            "clientVersion": clientVersion,
            "hl": "zh-CN",
            "gl": "JP",
        ]]
    }

    static func fetch(listID: String, seedVideoID: String?) async throws -> PlaylistInfo {
        if listID.hasPrefix("RD") {
            return try await fetchMix(listID: listID, seedVideoID: seedVideoID)
        } else {
            return try await fetchPlaylist(listID: listID)
        }
    }

    // MARK: 普通列表

    private static func fetchPlaylist(listID: String) async throws -> PlaylistInfo {
        var title: String?
        var items: [PlaylistItem] = []

        // 方法一：列表页接口（新旧两种格式都认）
        do {
            var json = try await post("browse", ["context": context, "browseId": "VL" + listID])
            title = playlistTitle(fromBrowse: json)
            collectBrowseItems(json, into: &items)

            var seenTokens = Set<String>()
            var pages = 0
            while pages < maxPages, let token = findContinuationToken(json, excluding: seenTokens) {
                try Task.checkCancellation()
                seenTokens.insert(token)
                pages += 1
                json = try await post("browse", ["context": context, "continuation": token])
                let before = items.count
                collectBrowseItems(json, into: &items)
                if items.count == before { break }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 忽略，下面换方法二
        }

        // 方法二：播放页右侧的列表面板（和合辑用的是同一个接口），一段一段往后翻
        if items.isEmpty {
            let viaNext = try await fetchViaNext(listID: listID, seedVideoID: nil, paginate: true)
            items = viaNext.items
            if title == nil { title = viaNext.title }
        }

        let unique = dedupe(items)
        guard !unique.isEmpty else { throw Failure.empty }
        return PlaylistInfo(id: listID, title: title ?? "播放列表", items: unique, isMix: false)
    }

    private static func collectBrowseItems(_ json: Any, into items: inout [PlaylistItem]) {
        collect(json, key: "playlistVideoRenderer", into: &items)
        collectLockups(json, into: &items)
    }

    private static func playlistTitle(fromBrowse json: Any) -> String? {
        if let meta = findDict(json, key: "playlistMetadataRenderer"), let t = meta["title"] as? String {
            return t
        }
        if let header = findDict(json, key: "pageHeaderViewModel"),
           let t = findDict(header, key: "title")?["content"] as? String {
            return t
        }
        return nil
    }

    // MARK: 自动合辑（Mix）

    private static func fetchMix(listID: String, seedVideoID: String?) async throws -> PlaylistInfo {
        var seed = seedVideoID
        if seed == nil, listID.count == 13 {
            // RD + 11 位视频 ID：合辑是以这个视频为起点生成的
            seed = String(listID.dropFirst(2))
        }
        // 合辑是无限延伸的，只读第一段
        let result = try await fetchViaNext(listID: listID, seedVideoID: seed, paginate: false)
        guard !result.items.isEmpty else { throw Failure.empty }
        return PlaylistInfo(id: listID, title: result.title ?? "合辑", items: result.items, isMix: true)
    }

    // MARK: 播放页右侧的列表面板

    private static func fetchViaNext(
        listID: String, seedVideoID: String?, paginate: Bool
    ) async throws -> (title: String?, items: [PlaylistItem]) {
        var items: [PlaylistItem] = []
        var seen = Set<String>()
        var title: String?
        var seed = seedVideoID
        var index: Int?

        for _ in 0..<maxPages {
            try Task.checkCancellation()
            var body: [String: Any] = ["context": context, "playlistId": listID]
            if let seed { body["videoId"] = seed }
            if let index { body["playlistIndex"] = index }

            let json = try await post("next", body)
            // 只在播放列表面板里找，避免把旁边的推荐视频也算进去
            let panel: Any = findDict(json, key: "twoColumnWatchNextResults")
                .flatMap { findDict($0, key: "playlist") } ?? json

            if title == nil, let dict = panel as? [String: Any] {
                title = dict["title"] as? String
                    ?? (dict["playlist"] as? [String: Any])?["title"] as? String
            }

            var page: [PlaylistItem] = []
            collect(panel, key: "playlistPanelVideoRenderer", into: &page)
            let fresh = page.filter { seen.insert($0.videoID).inserted }
            items.append(contentsOf: fresh)

            guard paginate, !fresh.isEmpty, let last = items.last else { break }
            // 从目前读到的最后一个视频继续往后翻
            seed = last.videoID
            index = items.count - 1
        }
        return (title, items)
    }

    // MARK: 网络

    private static func post(_ endpoint: String, _ body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: JSON 工具

    /// 在 JSON 里递归找所有 key 对应的视频条目（数组顺序会保留）
    private static func collect(_ node: Any, key: String, into items: inout [PlaylistItem]) {
        if let dict = node as? [String: Any] {
            if let renderer = dict[key] as? [String: Any], let id = renderer["videoId"] as? String {
                items.append(PlaylistItem(videoID: id, title: text(renderer["title"]) ?? id))
                return
            }
            for value in dict.values { collect(value, key: key, into: &items) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, key: key, into: &items) }
        }
    }

    /// YouTube 新版列表页的视频条目（lockupViewModel）
    private static func collectLockups(_ node: Any, into items: inout [PlaylistItem]) {
        if let dict = node as? [String: Any] {
            if let lockup = dict["lockupViewModel"] as? [String: Any] {
                let type = lockup["contentType"] as? String ?? ""
                if type.contains("VIDEO"), let id = lockup["contentId"] as? String {
                    let title = findDict(lockup, key: "lockupMetadataViewModel")
                        .flatMap { ($0["title"] as? [String: Any])?["content"] as? String }
                    items.append(PlaylistItem(videoID: id, title: title ?? id))
                }
                return
            }
            for value in dict.values { collectLockups(value, into: &items) }
        } else if let array = node as? [Any] {
            for value in array { collectLockups(value, into: &items) }
        }
    }

    private static func findDict(_ node: Any, key: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let found = dict[key] as? [String: Any] { return found }
            for value in dict.values {
                if let found = findDict(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findDict(value, key: key) { return found }
            }
        }
        return nil
    }

    private static func findContinuationToken(_ node: Any, excluding seen: Set<String>) -> String? {
        if let dict = node as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String, !seen.contains(token) {
                return token
            }
            for value in dict.values {
                if let token = findContinuationToken(value, excluding: seen) { return token }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let token = findContinuationToken(value, excluding: seen) { return token }
            }
        }
        return nil
    }

    /// YouTube 的文字有 simpleText 和 runs 两种写法
    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return node as? String }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func dedupe(_ items: [PlaylistItem]) -> [PlaylistItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.videoID).inserted }
    }
}

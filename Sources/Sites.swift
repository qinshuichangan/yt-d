import Foundation

/// 除 YouTube 以外支持的网站
enum Site: String {
    case douyin = "抖音"
    case tiktok = "TikTok"
    case bilibili = "B站"
    case xiaohongshu = "小红书"
    case twitter = "X（推特）"
    case generic = "网页"

    /// 根据链接判断是哪个网站；YouTube 返回 nil（走原来的流程）
    static func detect(_ url: URL) -> Site? {
        let host = url.host?.lowercased() ?? ""
        func on(_ domains: String...) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if on("youtube.com", "youtu.be") { return nil }
        if DouyinFetcher.isDouyin(url) { return .douyin }
        if on("tiktok.com") { return .tiktok }
        if on("bilibili.com", "b23.tv", "bili2233.cn") { return .bilibili }
        if on("xiaohongshu.com", "xhslink.com", "rednote.com") { return .xiaohongshu }
        if on("twitter.com", "x.com", "t.co", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com") { return .twitter }
        return .generic
    }

    func fetch(_ url: URL) async throws -> VideoInfo {
        switch self {
        case .douyin: return try await DouyinFetcher.videoInfo(url)
        case .tiktok: return try await TikTokFetcher.fetch(url)
        case .bilibili: return try await BilibiliFetcher.fetch(url)
        case .xiaohongshu: return try await XiaohongshuFetcher.fetch(url)
        case .twitter: return try await TwitterFetcher.fetch(url)
        case .generic: return try await GenericFetcher.fetch(url)
        }
    }
}

// MARK: - 抖音（沿用原来的解析）

extension DouyinFetcher {
    static func videoInfo(_ url: URL) async throws -> VideoInfo {
        let result = try await fetch(url)
        var options: [DownloadOption] = []
        if let clean = result.noWatermark {
            options.append(DownloadOption(label: "无水印原画", detail: "直接下载 mp4，同时保存作品说明",
                                          kind: .direct(clean, ext: "mp4", headers: headers)))
        }
        if let marked = result.watermarked, marked != result.noWatermark {
            options.append(DownloadOption(label: "带水印版本（备用）", detail: "无水印下载失败时用这个",
                                          kind: .direct(marked, ext: "mp4", headers: headers)))
        }
        guard !options.isEmpty else { throw Failure.noData }
        return VideoInfo(title: result.title, thumbnail: result.cover, options: options, note: result.note)
    }
}

// MARK: - TikTok

/// 打开作品网页，从 __UNIVERSAL_DATA_FOR_REHYDRATION__ 里取视频地址。
/// 网页会顺便设置 Cookie，下载视频时要带上（系统会自动带）。
enum TikTokFetcher {
    static let mediaHeaders = ["Referer": "https://www.tiktok.com/"]

    static func fetch(_ url: URL) async throws -> VideoInfo {
        var page = url
        if Web.firstMatch(url.path, "/video/(\\d+)") == nil {
            page = try await Web.resolve(url)  // vm.tiktok.com 之类的短链接
        }
        if page.path.contains("/photo/") { throw SiteError.imagePost }
        guard let id = Web.firstMatch(page.path, "/video/(\\d+)") else { throw SiteError.noID("TikTok") }

        let (html, _) = try await Web.text(page)
        guard let raw = Web.firstMatch(html, "<script[^>]+id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"[^>]*>(.*?)</script>"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            throw SiteError.noData("TikTok")
        }
        let detail = J.get(json, "__DEFAULT_SCOPE__", "webapp.video-detail")
        if let status = J.int(detail, "statusCode"), status != 0 {
            throw SiteError.unavailable(J.str(detail, "statusMsg").flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let item = J.get(detail, "itemInfo", "itemStruct") else { throw SiteError.noData("TikTok") }
        if J.get(item, "imagePost") != nil { throw SiteError.imagePost }

        let video = J.get(item, "video")
        var options: [DownloadOption] = []

        // 各档画质里挑码率最高的 H.264（兼容性最好）
        let h264 = J.array(video, "bitrateInfo")
            .filter { (J.str($0, "CodecType") ?? "").lowercased().contains("h264") }
            .sorted { (J.int($0, "Bitrate") ?? 0) > (J.int($1, "Bitrate") ?? 0) }
        if let best = h264.first, let link = Web.url(J.str(best, "PlayAddr", "UrlList", 0)) {
            let height = J.int(best, "PlayAddr", "Height") ?? J.int(video, "height")
            options.append(DownloadOption(
                label: "原画" + (height.map { " \($0)p" } ?? "") + "（无水印）",
                detail: "直接下载 mp4，同时保存作品说明",
                kind: .direct(link, ext: "mp4", headers: mediaHeaders)))
        }
        if let play = Web.url(J.str(video, "playAddr")) {
            options.append(DownloadOption(label: "备用地址", detail: "上面的下载失败时用这个",
                                          kind: .direct(play, ext: "mp4", headers: mediaHeaders)))
        }
        if let marked = Web.url(J.str(video, "downloadAddr")) {
            options.append(DownloadOption(label: "带水印版本（备用）", detail: "都失败时再试这个",
                                          kind: .direct(marked, ext: "mp4", headers: mediaHeaders)))
        }
        guard !options.isEmpty else { throw SiteError.noVideo }

        let author = J.str(item, "author", "nickname") ?? J.str(item, "author", "uniqueId")
        let desc = (J.str(item, "desc") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = desc.isEmpty ? "TikTok \(id)" : desc
        if let author, !author.isEmpty { title = "\(author) - \(title)" }
        let note = """
        作者：\(author ?? "（未知）")
        描述：\(desc.isEmpty ? "（无）" : desc)
        原链接：\(page.absoluteString)
        保存时间：\(Web.timestamp())
        """
        return VideoInfo(title: title, thumbnail: Web.url(J.str(video, "cover")), options: options, note: note)
    }
}

// MARK: - B站

/// 用 B站公开的接口：先查视频信息拿到 cid，再查播放地址。
/// 不登录时一般最高 720p（mp4 直接下载）；登录后可以下 1080p（画面和声音分开，下载后合并）。
enum BilibiliFetcher {
    /// B站的视频服务器要求请求像浏览器发出的一样（来源页 + 浏览器标识），否则返回 403
    static let mediaHeaders = [
        "Referer": "https://www.bilibili.com/",
        "Origin": "https://www.bilibili.com",
        "User-Agent": DouyinFetcher.headers["User-Agent"] ?? "",
    ]
    /// 查接口用（接口不需要浏览器标识）
    static let apiHeaders = ["Referer": "https://www.bilibili.com/"]

    static func fetch(_ url: URL) async throws -> VideoInfo {
        await WebLogin.syncCookies()
        var page = url
        let host = url.host?.lowercased() ?? ""
        if host.contains("b23.tv") || host.contains("bili2233") {
            page = try await Web.resolve(url)
        }

        let text = page.absoluteString
        let query: String
        if let bvid = Web.firstMatch(text, "(BV[0-9A-Za-z]{10})") {
            query = "bvid=\(bvid)"
        } else if let aid = Web.firstMatch(text, "/av(\\d+)") {
            query = "aid=\(aid)"
        } else {
            throw SiteError.noID("B站")
        }
        let partNumber = URLComponents(url: page, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1

        let view = try await Web.json(URL(string: "https://api.bilibili.com/x/web-interface/view?\(query)")!,
                                      headers: apiHeaders)
        guard J.int(view, "code") == 0, let data = J.get(view, "data") else {
            throw SiteError.unavailable(J.str(view, "message"))
        }
        let bvid = J.str(data, "bvid") ?? ""
        let pages = J.array(data, "pages")
        let pageInfo = pages.indices.contains(partNumber - 1) ? pages[partNumber - 1] : pages.first
        guard let cid = J.int(pageInfo, "cid") ?? J.int(data, "cid") else { throw SiteError.noData("B站") }

        // 1. 画面和声音分开的格式（DASH）
        var options: [DownloadOption] = []
        let dashJSON = try? await Web.json(
            URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&fourk=1")!,
            headers: apiHeaders)
        let dash = J.get(dashJSON, "data", "dash")
        let audio = J.array(dash, "audio")
            .max { (J.int($0, "bandwidth") ?? 0) < (J.int($1, "bandwidth") ?? 0) }
            .flatMap { Web.url(J.str($0, "baseUrl") ?? J.str($0, "base_url")) }
        // 每个高度挑 H.264（codecid 7）里码率最高的
        var bestByHeight: [Int64: (bandwidth: Int64, url: URL)] = [:]
        for stream in J.array(dash, "video") where J.int(stream, "codecid") == 7 {
            guard let height = J.int(stream, "height"),
                  let link = Web.url(J.str(stream, "baseUrl") ?? J.str(stream, "base_url")) else { continue }
            let bandwidth = J.int(stream, "bandwidth") ?? 0
            if bandwidth >= (bestByHeight[height]?.bandwidth ?? -1) {
                bestByHeight[height] = (bandwidth, link)
            }
        }

        // 2. 直接下载的 mp4（不登录一般能到 720p）
        let mp4JSON = try? await Web.json(
            URL(string: "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1")!,
            headers: apiHeaders)
        let durl = J.array(mp4JSON, "data", "durl")
        var mp4Height: Int64 = 0
        var mp4Option: DownloadOption?
        if durl.count == 1, let link = Web.url(J.str(durl[0], "url")), !link.path.lowercased().hasSuffix(".flv") {
            mp4Height = Self.height(forQuality: J.int(mp4JSON, "data", "quality") ?? 0)
            mp4Option = DownloadOption(
                label: (mp4Height > 0 ? "\(mp4Height)p " : "") + "快速",
                detail: "直接下载一个 mp4，最稳定",
                kind: .direct(link, ext: "mp4", headers: mediaHeaders))
        }

        if let audio {
            for height in bestByHeight.keys.filter({ $0 > mp4Height }).sorted(by: >).prefix(3) {
                guard let video = bestByHeight[height] else { continue }
                options.append(DownloadOption(
                    label: "\(height)p 高画质",
                    detail: "画面和声音分开下载，再自动合并",
                    kind: .mergeDirect(video: video.url, audio: audio, headers: mediaHeaders)))
            }
        }
        if var mp4Option {
            if !WebLogin.isLoggedIn(.bilibili) && options.isEmpty {
                mp4Option = DownloadOption(label: mp4Option.label,
                                           detail: mp4Option.detail + "（登录 B站 后可下载 1080p）",
                                           kind: mp4Option.kind)
            }
            options.append(mp4Option)
        }
        if let audio {
            options.append(DownloadOption(label: "仅音频（m4a）", detail: "适合听歌、听播客",
                                          kind: .direct(audio, ext: "m4a", headers: mediaHeaders)))
        }
        // mp4 没有时，用 DASH 里最好的
        if options.allSatisfy({ if case .direct(_, "m4a", _) = $0.kind { return true }; return false }),
           let audio, let best = bestByHeight.max(by: { $0.key < $1.key }) {
            options.insert(DownloadOption(label: "\(best.key)p", detail: "画面和声音分开下载，再自动合并",
                                          kind: .mergeDirect(video: best.value.url, audio: audio, headers: mediaHeaders)),
                           at: 0)
        }
        guard !options.isEmpty else {
            throw SiteError.unavailable(J.str(dashJSON, "message") ?? J.str(mp4JSON, "message"))
        }

        let up = J.str(data, "owner", "name")
        var title = J.str(data, "title") ?? bvid
        if pages.count > 1, let part = J.str(pageInfo, "part"), !part.isEmpty {
            title += " P\(partNumber) \(part)"
        }
        if let up, !up.isEmpty { title = "\(up) - \(title)" }
        let desc = (J.str(data, "desc") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = """
        UP主：\(up ?? "（未知）")
        标题：\(J.str(data, "title") ?? "")
        简介：\(desc.isEmpty ? "（无）" : desc)
        原链接：https://www.bilibili.com/video/\(bvid)\(pages.count > 1 ? "?p=\(partNumber)" : "")
        保存时间：\(Web.timestamp())
        """
        return VideoInfo(title: title, thumbnail: Web.url(J.str(data, "pic")), options: options, note: note)
    }

    private static func height(forQuality quality: Int64) -> Int64 {
        switch quality {
        case 6: return 240
        case 16: return 360
        case 32: return 480
        case 64, 74: return 720
        case 80, 112, 116: return 1080
        case 120: return 2160
        default: return 0
        }
    }
}

// MARK: - 小红书

/// 打开笔记网页，从 window.__INITIAL_STATE__ 里取视频地址。
/// 分享链接里要带 xsec_token；海外网络打开时常常要求登录（会跳到 rednote.com 的登录页）。
enum XiaohongshuFetcher {
    static let mediaHeaders = ["Referer": "https://www.xiaohongshu.com/"]

    static func fetch(_ url: URL) async throws -> VideoInfo {
        await WebLogin.syncCookies()
        let (html, finalURL) = try await Web.text(url)
        if finalURL.path.contains("/login") || finalURL.path.contains("/website-login") {
            throw SiteError.needLogin("小红书")
        }
        guard let raw = Web.firstMatch(html, "window\\.__INITIAL_STATE__\\s*=\\s*(\\{.*?\\})\\s*</script>") else {
            throw SiteError.noData("小红书")
        }
        // 页面里的数据是 JS，不是严格的 JSON：undefined 换成 null
        let cleaned = raw.replacingOccurrences(of: "\\bundefined\\b", with: "null", options: .regularExpression)
        guard let data = cleaned.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) else {
            throw SiteError.noData("小红书")
        }
        let map = J.get(state, "note", "noteDetailMap") as? [String: Any] ?? [:]
        let id = Web.firstMatch(finalURL.path, "/(?:explore|discovery/item|item)/([0-9a-f]+)")
        guard let note = J.get(id.flatMap { map[$0] } ?? map.values.first, "note") else {
            throw map.isEmpty ? SiteError.needLogin("小红书") : SiteError.noData("小红书")
        }
        guard J.str(note, "type") == "video", let video = J.get(note, "video") else {
            throw SiteError.imagePost
        }

        var options: [DownloadOption] = []
        if let key = J.str(video, "consumer", "originVideoKey"), !key.isEmpty,
           let link = URL(string: "https://sns-video-bd.xhscdn.com/\(key)") {
            options.append(DownloadOption(label: "原画（无水印）", detail: "直接下载 mp4，同时保存笔记说明",
                                          kind: .direct(link, ext: "mp4", headers: mediaHeaders)))
        }
        let streams = J.array(video, "media", "stream", "h264")
            .sorted { (J.int($0, "height") ?? 0) > (J.int($1, "height") ?? 0) }
        if let best = streams.first, let link = Web.url(J.str(best, "masterUrl")) {
            let height = J.int(best, "height")
            options.append(DownloadOption(label: (height.map { "\($0)p" } ?? "普通画质") + (options.isEmpty ? "" : "（备用）"),
                                          detail: "原画下载失败时用这个",
                                          kind: .direct(link, ext: "mp4", headers: mediaHeaders)))
        }
        guard !options.isEmpty else { throw SiteError.noVideo }

        let author = J.str(note, "user", "nickname") ?? J.str(note, "user", "nickName")
        let noteTitle = (J.str(note, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (J.str(note, "desc") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = noteTitle.isEmpty ? (desc.isEmpty ? "小红书笔记" : String(desc.prefix(60))) : noteTitle
        if let author, !author.isEmpty { title = "\(author) - \(title)" }
        let text = """
        作者：\(author ?? "（未知）")
        标题：\(noteTitle.isEmpty ? "（无）" : noteTitle)
        正文：\(desc.isEmpty ? "（无）" : desc)
        原链接：\(finalURL.absoluteString)
        保存时间：\(Web.timestamp())
        """
        let cover = Web.url(J.str(J.array(note, "imageList").first, "urlDefault"))
        return VideoInfo(title: title, thumbnail: cover, options: options, note: text)
    }
}

// MARK: - X（推特）

/// 先用推特官方的嵌入接口（cdn.syndication.twimg.com，不需要登录），
/// 读不到视频时再用开源项目 FxTwitter 的公开接口（api.fxtwitter.com）。
enum TwitterFetcher {
    static func fetch(_ url: URL) async throws -> VideoInfo {
        var page = url
        if url.host?.lowercased() == "t.co" { page = try await Web.resolve(url) }
        guard let id = Web.firstMatch(page.path, "/status(?:es)?/(\\d+)") else { throw SiteError.noID("推特") }

        var videos: [(variants: [(bitrate: Int64, url: URL)], cover: URL?)] = []
        var author: String?
        var text = ""

        // 1. 官方嵌入接口
        if let status = try? await Web.json(
            URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&token=\(token(id))&lang=zh")!) {
            author = J.str(status, "user", "name")
            text = J.str(status, "text") ?? ""
            let details = J.array(status, "mediaDetails") + J.array(status, "quoted_tweet", "mediaDetails")
            for media in details {
                let variants = J.array(media, "video_info", "variants").compactMap { v -> (Int64, URL)? in
                    guard J.str(v, "content_type") == "video/mp4", let link = Web.url(J.str(v, "url")) else { return nil }
                    return (J.int(v, "bitrate") ?? 0, link)
                }
                if !variants.isEmpty {
                    videos.append((variants.map { (bitrate: $0.0, url: $0.1) }, Web.url(J.str(media, "media_url_https"))))
                }
            }
        }

        // 2. FxTwitter
        if videos.isEmpty,
           let fx = try? await Web.json(URL(string: "https://api.fxtwitter.com/status/\(id)")!),
           let tweet = J.get(fx, "tweet") {
            author = author ?? J.str(tweet, "author", "name")
            if text.isEmpty { text = J.str(tweet, "text") ?? "" }
            let all = J.array(tweet, "media", "videos")
                + (J.array(tweet, "media", "videos").isEmpty ? J.array(tweet, "quote", "media", "videos") : [])
            for media in all {
                var variants = J.array(media, "formats").compactMap { f -> (bitrate: Int64, url: URL)? in
                    guard J.str(f, "container") == "mp4", let link = Web.url(J.str(f, "url")) else { return nil }
                    return (J.int(f, "bitrate") ?? 0, link)
                }
                if variants.isEmpty, let link = Web.url(J.str(media, "url")), link.path.hasSuffix(".mp4") {
                    variants = [(0, link)]
                }
                if !variants.isEmpty { videos.append((variants, Web.url(J.str(media, "thumbnail_url")))) }
            }
        }

        guard !videos.isEmpty else { throw SiteError.noVideo }

        var options: [DownloadOption] = []
        for (index, video) in videos.enumerated() {
            let sorted = video.variants.sorted { $0.bitrate > $1.bitrate }
            let prefix = videos.count > 1 ? "第 \(index + 1) 个视频 · " : ""
            for (rank, variant) in sorted.prefix(2).enumerated() {
                options.append(DownloadOption(
                    label: prefix + (resolution(variant.url) ?? (rank == 0 ? "最高画质" : "较低画质")),
                    detail: rank == 0 ? "直接下载 mp4，同时保存推文内容" : "文件更小",
                    kind: .direct(variant.url, ext: "mp4", headers: [:])))
            }
        }

        let cleanText = text.replacingOccurrences(of: "https://t\\.co/\\S+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var title = cleanText.isEmpty ? "推文 \(id)" : String(cleanText.prefix(60))
        if let author, !author.isEmpty { title = "\(author) - \(title)" }
        let note = """
        作者：\(author ?? "（未知）")
        内容：\(cleanText.isEmpty ? "（无）" : cleanText)
        原链接：https://x.com/i/status/\(id)
        保存时间：\(Web.timestamp())
        """
        return VideoInfo(title: title, thumbnail: videos.first?.cover, options: options, note: note)
    }

    /// 地址里的 1280x720 → 720p
    private static func resolution(_ url: URL) -> String? {
        guard let size = Web.firstMatch(url.path, "/(\\d+x\\d+)/") else { return nil }
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return size }
        return "\(min(parts[0], parts[1]))p"
    }

    /// 嵌入接口要求的 token：((id / 1e15) * π) 转成 36 进制，去掉 0 和小数点
    private static func token(_ id: String) -> String {
        let value = (Double(id) ?? 0) / 1e15 * Double.pi
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var whole = Int64(value)
        var fraction = value - Double(whole)
        var integerPart = ""
        repeat {
            integerPart = String(digits[Int(whole % 36)]) + integerPart
            whole /= 36
        } while whole > 0
        var fractionPart = ""
        for _ in 0..<12 {
            fraction *= 36
            let digit = Int(fraction)
            fractionPart.append(digits[digit])
            fraction -= Double(digit)
        }
        return (integerPart + fractionPart).replacingOccurrences(of: "0", with: "")
    }
}

// MARK: - 其他网页（通用）

/// 其他网站：链接本身就是视频文件的话直接下载；
/// 否则打开网页，找 og:video 之类的标记或 <video> 里的 mp4 地址。
enum GenericFetcher {
    static func fetch(_ url: URL) async throws -> VideoInfo {
        // 先只要 1 个字节，看看是不是视频文件本身
        let (_, head) = try await Web.get(url, headers: ["Range": "bytes=0-0"])
        let type = (head.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let finalURL = head.url ?? url
        if type.hasPrefix("video/") || type.hasPrefix("audio/") {
            let ext = finalURL.pathExtension.isEmpty ? (type.hasPrefix("audio/") ? "m4a" : "mp4") : finalURL.pathExtension
            let name = finalURL.deletingPathExtension().lastPathComponent
            return VideoInfo(title: name.isEmpty ? "视频" : name, thumbnail: nil, options: [
                DownloadOption(label: "直接下载", detail: "链接本身就是视频文件", kind: .direct(finalURL, ext: ext, headers: [:])),
            ])
        }
        if type.contains("mpegurl") { throw SiteError.unsupportedStream }

        let (html, pageURL) = try await Web.text(finalURL)
        func meta(_ name: String) -> String? {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return Web.firstMatch(html, "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']")
                ?? Web.firstMatch(html, "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']")
        }

        var candidates: [String] = []
        for name in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            if let value = meta(name) { candidates.append(value) }
        }
        if let src = Web.firstMatch(html, "<(?:video|source)[^>]+src=[\"']([^\"']+\\.(?:mp4|m4v|mov)[^\"']*)[\"']") {
            candidates.append(src)
        }
        if let raw = Web.firstMatch(html, "[\"'](https?:[^\"'\\s]+?\\.mp4(?:\\?[^\"'\\s]*)?)[\"']") {
            candidates.append(raw)
        }

        let links = candidates.compactMap { URL(string: Web.unescapeHTML($0), relativeTo: pageURL)?.absoluteURL }
        if links.isEmpty {
            if candidates.contains(where: { $0.contains(".m3u8") }) || html.contains(".m3u8") {
                throw SiteError.unsupportedStream
            }
            throw SiteError.noVideo
        }
        guard let link = links.first(where: { !$0.path.lowercased().hasSuffix(".m3u8") }) else {
            throw SiteError.unsupportedStream
        }

        let title = meta("og:title") ?? Web.firstMatch(html, "<title[^>]*>([^<]+)</title>")
        let ext = ["mp4", "m4v", "mov"].contains(link.pathExtension.lowercased()) ? link.pathExtension.lowercased() : "mp4"
        let note = """
        标题：\(title.map(Web.unescapeHTML) ?? "（无）")
        原链接：\(pageURL.absoluteString)
        保存时间：\(Web.timestamp())
        """
        return VideoInfo(
            title: title.map(Web.unescapeHTML)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (pageURL.host ?? "视频"),
            thumbnail: meta("og:image").flatMap { URL(string: Web.unescapeHTML($0), relativeTo: pageURL)?.absoluteURL },
            options: [DownloadOption(label: "网页里的视频", detail: "从网页中找到的视频文件",
                                     kind: .direct(link, ext: ext, headers: ["Referer": pageURL.absoluteString]))],
            note: note)
    }
}

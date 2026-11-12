import Foundation

// MARK: - Instagram

/// 解析思路参考 yt-dlp 的 Instagram 解析器：
/// 1. 登录了：用网页版的 media/info 接口（最稳定）
/// 2. 没登录：先打开首页拿 csrftoken 和 LSD，再查未登录用的 GraphQL 接口
/// 3. 还不行：打开帖子网页，从页面里的数据找；最后再试嵌入页面（embed）
/// 前三种拿到的数据格式一样（video_versions / carousel_media / caption …），统一在 build 里处理。
enum InstagramFetcher {
    static let mediaHeaders = ["Referer": "https://www.instagram.com/"]

    private static let base = URL(string: "https://www.instagram.com/")!
    private static let appID = "936619743392459"
    /// Instagram 对桌面浏览器最宽松；未登录用的接口也是桌面版的
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// 帖子编号用的 64 进制字母表
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func fetch(_ url: URL) async throws -> VideoInfo {
        await WebLogin.syncCookies()
        var page = url
        if page.path.hasPrefix("/share/") || shortcode(page) == nil {
            page = try await Web.resolve(page, headers: ["User-Agent": userAgent])  // /share/… 和 instagr.am 短链接
        }
        if page.path.contains("/stories/") { throw SiteError.unsupported("Instagram 快拍（Stories）") }
        guard let code = shortcode(page), let pk = mediaPK(code) else { throw SiteError.noID("Instagram") }

        let loggedIn = WebLogin.isLoggedIn(.instagram)
        AppLog.add("Instagram：帖子 \(code)，\(loggedIn ? "已登录" : "未登录")")

        var product: Any?
        var loginWall = false

        // 1. 登录接口
        if loggedIn {
            do {
                product = try await loggedInInfo(pk)
            } catch SiteError.needLogin(_) {
                loginWall = true
                AppLog.add("Instagram：登录已失效，改用未登录方式")
            } catch {
                AppLog.add("Instagram：登录接口失败 \(AppLog.describe(error))")
            }
        }

        // 2. 未登录的 GraphQL
        var ruling: Any?
        if product == nil {
            do {
                let lsd = try await prepareSession()
                ruling = try? await Web.json(
                    URL(string: "https://www.instagram.com/api/v1/web/get_ruling_for_content/?content_type=MEDIA&target_id=\(pk)")!,
                    headers: apiHeaders(csrf: true))
                product = try await graphQL(pk: pk, lsd: lsd, referer: page, csrf: J.str(ruling, "status") == "ok")
                if product == nil { AppLog.add("Instagram：GraphQL 没有返回帖子内容") }
            } catch {
                AppLog.add("Instagram：GraphQL 失败 \(AppLog.describe(error))")
            }
        }

        // 3. 帖子网页 / 嵌入页面
        if product == nil {
            let result = await fromPostPage(code)
            product = result.product
            loginWall = loginWall || result.loginWall
        }
        if product == nil {
            product = await fromEmbed(code)
        }

        guard let product else {
            let reason = [J.str(ruling, "title"), J.str(ruling, "description")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "：")
            if reason.contains("Restricted") { throw SiteError.needLogin("Instagram") }
            if !reason.isEmpty { throw SiteError.unavailable(reason) }
            if loginWall || !loggedIn || code.count > 28 { throw SiteError.needLogin("Instagram") }
            throw SiteError.noData("Instagram")
        }
        return try build(product, code: code)
    }

    // MARK: 编号

    /// /p/编号、/reel/编号、/reels/编号、/tv/编号（前面可以带用户名）
    static func shortcode(_ url: URL) -> String? {
        Web.firstMatch(url.path, "^/(?:[^/]+/)?(?:p|reels?|tv)/([A-Za-z0-9_-]+)")
    }

    /// 编号 → 数字 ID（64 进制转 10 进制）。私密帖子的编号后面多 28 个字符，要去掉。
    static func mediaPK(_ code: String) -> String? {
        let core = code.count > 28 ? String(code.dropLast(28)) : code
        var value: UInt64 = 0
        for char in core {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 64)
            let (sum, overflow2) = shifted.addingReportingOverflow(UInt64(digit))
            if overflow1 || overflow2 { return nil }
            value = sum
        }
        return value == 0 ? nil : String(value)
    }

    // MARK: 请求

    private static func csrfToken() -> String? {
        HTTPCookieStorage.shared.cookies(for: base)?.first { $0.name == "csrftoken" }?.value
    }

    private static func apiHeaders(csrf: Bool) -> [String: String] {
        var headers = [
            "User-Agent": userAgent,
            "X-IG-App-ID": appID,
            "X-ASBD-ID": "359341",
            "X-IG-WWW-Claim": "0",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": "https://www.instagram.com",
            "Referer": "https://www.instagram.com/",
            "Accept": "*/*",
        ]
        if csrf, let token = csrfToken() { headers["X-CSRFToken"] = token }
        return headers
    }

    private static func isLoginRedirect(_ url: URL?) -> Bool {
        guard let path = url?.path else { return false }
        return path.hasPrefix("/accounts/login") || path == "/" || path.isEmpty
    }

    /// 登录后的接口：返回 items[0]
    private static func loggedInInfo(_ pk: String) async throws -> Any? {
        let link = URL(string: "https://www.instagram.com/api/v1/media/\(pk)/info/")!
        let (data, http) = try await Web.get(link, headers: apiHeaders(csrf: true))
        if isLoginRedirect(http.url) || http.statusCode == 401 { throw SiteError.needLogin("Instagram") }
        guard (200..<300).contains(http.statusCode) else { throw SiteError.http(http.statusCode) }
        let json = try JSONSerialization.jsonObject(with: data)
        return J.get(json, "items", 0)
    }

    /// 打开首页：顺便拿到 csrftoken（Cookie）和 LSD
    private static func prepareSession() async throws -> String {
        let (html, _) = try await Web.text(base, headers: ["User-Agent": userAgent])
        if let raw = Web.firstMatch(html, "<script\\b[^>]*\\bid=\"__eqmc\"[^>]*>(\\{.*?\\})</script>"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let token = J.str(json, "l"), !token.isEmpty {
            return token
        }
        if let token = Web.firstMatch(html, "\\[\"LSD\",\\[\\],\\{\"token\":\"([^\"]+)\"") { return token }
        throw SiteError.noData("Instagram")
    }

    /// 未登录用的 GraphQL：data.xig_polaris_media.if_not_gated_logged_out
    private static func graphQL(pk: String, lsd: String, referer: URL, csrf: Bool) async throws -> Any? {
        let name = "PolarisLoggedOutDesktopWWWPostRootContentQuery"
        var request = URLRequest(url: URL(string: "https://www.instagram.com/api/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        var headers = apiHeaders(csrf: csrf)
        headers["X-FB-Friendly-Name"] = name
        headers["X-FB-LSD"] = lsd
        headers["Referer"] = referer.absoluteString
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let fields = [
            ("lsd", lsd),
            ("fb_api_caller_class", "RelayModern"),
            ("fb_api_req_friendly_name", name),
            ("server_timestamps", "true"),
            ("variables", "{\"media_id\":\"\(pk)\"}"),
            ("doc_id", "27130156389949648"),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SiteError.http(http.statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return J.get(json, "data", "xig_polaris_media", "if_not_gated_logged_out")
    }

    /// 帖子网页里 <script data-sjs> 的数据
    private static func fromPostPage(_ code: String) async -> (product: Any?, loginWall: Bool) {
        guard let page = try? await Web.text(URL(string: "https://www.instagram.com/p/\(code)/")!,
                                             headers: ["User-Agent": userAgent]) else {
            return (nil, false)
        }
        let (html, finalURL) = page
        if isLoginRedirect(finalURL) {
            AppLog.add("Instagram：帖子网页跳到了登录页")
            return (nil, true)
        }
        for raw in Web.allMatches(html, "<script\\b[^>]+\\bdata-sjs>(\\{.+?\\})</script>") {
            guard raw.contains("xig_polaris_media") || raw.contains("video_versions"),
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let media = find(json, key: "xig_polaris_media"),
               let product = J.get(media, "if_not_gated_logged_out") {
                return (product, false)
            }
            if let info = find(json, key: "xdt_api__v1__media__shortcode__web_info"),
               let product = J.get(info, "items", 0) {
                return (product, false)
            }
        }
        AppLog.add("Instagram：帖子网页里没有帖子数据")
        return (nil, false)
    }

    /// 嵌入页面（老办法）：只找视频地址，转成和接口一样的格式
    private static func fromEmbed(_ code: String) async -> Any? {
        guard let embed = try? await Web.text(URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")!,
                                                  headers: ["User-Agent": userAgent]),
              let raw = Web.firstMatch(embed.0, "video_url\\\\*\"\\s*:\\s*\\\\*\"(https?:.+?)\\\\*\"") else {
            return nil
        }
        let cleaned = raw.replacingOccurrences(of: "\\\\*u0026", with: "&", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: "")
        guard Web.url(cleaned) != nil else { return nil }
        let html = embed.0
        AppLog.add("Instagram：从嵌入页面找到了视频")
        var product: [String: Any] = ["video_versions": [["url": cleaned]]]
        if let user = Web.firstMatch(html, "class=\"UsernameText\"[^>]*>([^<]+)<") {
            product["user"] = ["username": Web.unescapeHTML(user)]
        }
        return product
    }

    /// 在 JSON 里递归找某个键
    private static func find(_ node: Any, key: String) -> Any? {
        if let dict = node as? [String: Any] {
            if let value = dict[key], !(value is NSNull) { return value }
            for value in dict.values { if let hit = find(value, key: key) { return hit } }
        } else if let array = node as? [Any] {
            for value in array { if let hit = find(value, key: key) { return hit } }
        }
        return nil
    }

    // MARK: 整理成下载选项

    private static func build(_ product: Any, code: String) throws -> VideoInfo {
        let carousel = J.array(product, "carousel_media")
        let items = carousel.isEmpty ? [product] : carousel

        typealias Version = (url: URL, width: Int64, height: Int64)
        let videos: [(position: Int, versions: [Version])] = items.enumerated().compactMap { offset, item -> (position: Int, versions: [Version])? in
            let versions = J.array(item, "video_versions").compactMap { v -> Version? in
                guard let link = Web.url(J.str(v, "url")) else { return nil }
                return (link, J.int(v, "width") ?? 0, J.int(v, "height") ?? 0)
            }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            return versions.isEmpty ? nil : (offset + 1, versions)
        }
        guard !videos.isEmpty else { throw SiteError.imagePost }

        var options: [DownloadOption] = []
        for (index, video) in videos.enumerated() {
            let prefix = videos.count > 1 || items.count > 1
                ? "第 \(index + 1) 个视频" + (items.count > videos.count ? "（第 \(video.position) 张）" : "") + " · "
                : ""
            var seen: Set<Int64> = []
            var picked: [Version] = []
            for version in video.versions where seen.insert(min(version.width, version.height)).inserted {
                picked.append(version)
                if picked.count == 2 { break }
            }
            for (rank, version) in picked.enumerated() {
                let side = min(version.width, version.height)
                options.append(DownloadOption(
                    label: prefix + (side > 0 ? "\(side)p" : (rank == 0 ? "最高画质" : "较低画质")),
                    detail: rank == 0 ? "直接下载 mp4，同时保存帖子文字" : "文件更小",
                    kind: .direct(version.url, ext: "mp4", headers: mediaHeaders)))
            }
        }

        let username = J.str(product, "user", "username")
        let fullName = J.str(product, "user", "full_name")
        let author = [fullName, username].compactMap { $0 }.first { !$0.isEmpty }
        let caption = (J.str(product, "caption", "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = caption.split(separator: "\n").first.map(String.init) ?? ""
        var title = firstLine.isEmpty ? "Instagram \(code)" : String(firstLine.prefix(60))
        if let author { title = "\(author) - \(title)" }

        let cover = Web.url(J.str(items.first, "image_versions2", "candidates", 0, "url"))
            ?? Web.url(J.str(product, "image_versions2", "candidates", 0, "url"))
        let note = """
        作者：\(author ?? "（未知）")\(username.map { " (@\($0))" } ?? "")
        内容：\(caption.isEmpty ? "（无）" : caption)
        原链接：https://www.instagram.com/p/\(code)/
        保存时间：\(Web.timestamp())
        """
        return VideoInfo(title: title, thumbnail: cover, options: options, note: note)
    }
}

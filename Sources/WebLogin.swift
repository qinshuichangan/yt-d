import SwiftUI
import WebKit

/// 可以在 App 里登录的网站。
/// 登录用的是 App 内置的网页（你自己的账号），Cookie 只保存在这台手机上。
enum LoginSite: String, CaseIterable, Identifiable {
    case xiaohongshu = "小红书"
    case bilibili = "B站"
    case instagram = "Instagram"

    var id: String { rawValue }

    var loginURL: URL {
        switch self {
        case .xiaohongshu: return URL(string: "https://www.xiaohongshu.com/explore")!
        case .bilibili: return URL(string: "https://passport.bilibili.com/h5-app/passport/login")!
        case .instagram: return URL(string: "https://www.instagram.com/accounts/login/")!
        }
    }

    var domains: [String] {
        switch self {
        case .xiaohongshu: return ["xiaohongshu.com", "rednote.com", "xhscdn.com"]
        case .bilibili: return ["bilibili.com"]
        case .instagram: return ["instagram.com"]
        }
    }

    /// 登录后才会有的 Cookie
    var sessionCookie: String {
        switch self {
        case .xiaohongshu: return "web_session"
        case .bilibili: return "SESSDATA"
        case .instagram: return "sessionid"
        }
    }

    var hint: String {
        switch self {
        case .xiaohongshu: return "海外网络打开小红书经常要求登录，登录后才能解析"
        case .bilibili: return "不登录最高 720p，登录后可以下载 1080p"
        case .instagram: return "不登录时经常读不到视频（看多了会被限制），登录后最稳定。建议用小号登录"
        }
    }

    func owns(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }
}

enum WebLogin {
    /// 把内置网页里登录得到的 Cookie 复制给下载用的网络请求
    @MainActor
    static func syncCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where LoginSite.allCases.contains(where: { $0.owns(cookie) }) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    static func isLoggedIn(_ site: LoginSite) -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        return cookies.contains { $0.name == site.sessionCookie && site.owns($0) && !$0.value.isEmpty }
    }

    @MainActor
    static func logout(_ site: LoginSite) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where site.owns(cookie) {
            await store.deleteCookie(cookie)
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where site.owns(cookie) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}

// MARK: - 界面

struct LoginListView: View {
    @State private var loggedIn: Set<LoginSite> = []
    @State private var openSite: LoginSite?

    var body: some View {
        List {
            Section {
                ForEach(LoginSite.allCases) { site in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(site.rawValue).font(.headline)
                            Spacer()
                            Text(loggedIn.contains(site) ? "已登录" : "未登录")
                                .font(.caption)
                                .foregroundStyle(loggedIn.contains(site) ? .green : .secondary)
                        }
                        Text(site.hint).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(loggedIn.contains(site) ? "重新登录" : "登录") { openSite = site }
                                .buttonStyle(.bordered)
                            if loggedIn.contains(site) {
                                Button("退出登录", role: .destructive) {
                                    Task {
                                        await WebLogin.logout(site)
                                        await refresh()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("登录页面是网站自己的网页，账号密码直接交给网站，这个 App 不会保存或上传。登录信息（Cookie）只保存在这台手机上，退出登录就会删掉。")
            }
        }
        .navigationTitle("登录网站")
        .task { await refresh() }
        .sheet(item: $openSite, onDismiss: { Task { await refresh() } }) { site in
            WebLoginSheet(site: site)
        }
    }

    private func refresh() async {
        await WebLogin.syncCookies()
        loggedIn = Set(LoginSite.allCases.filter(WebLogin.isLoggedIn))
    }
}

private struct WebLoginSheet: View {
    let site: LoginSite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(url: site.loginURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("登录\(site.rawValue)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            Task {
                                await WebLogin.syncCookies()
                                dismiss()
                            }
                        }
                    }
                }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

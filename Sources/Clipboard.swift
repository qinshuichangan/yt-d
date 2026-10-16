import UIKit
import UniformTypeIdentifiers

enum Clipboard {
    static let autoCopyKey = "autoCopyToClipboard"

    /// 把视频 / 音频文件本身复制到剪贴板（可以直接粘贴到微信等 App）
    @discardableResult
    static func copyFile(_ url: URL) -> Bool {
        let type: UTType = url.pathExtension.lowercased() == "m4a" ? .mpeg4Audio : .mpeg4Movie
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        return true
    }
}

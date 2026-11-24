import UIKit
import UniformTypeIdentifiers

enum Clipboard {
    static let autoCopyKey = "autoCopyToClipboard"

    /// 把音频 / 视频文件本身复制到剪贴板（可以直接粘贴到微信、LINE 等 App）
    @discardableResult
    static func copyFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        UIPasteboard.general.setData(data, forPasteboardType: pasteboardType(for: url).identifier)
        return true
    }

    static func pasteboardType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "m4a": return .mpeg4Audio
        case "mp3": return .mp3
        case "mp4", "m4v": return .mpeg4Movie
        case "mov": return .quickTimeMovie
        default:
            return UTType(filenameExtension: url.pathExtension) ?? .data
        }
    }
}

import Photos

enum PhotoSaver {
    /// 把视频存进相册，返回给用户看的提示文字
    static func save(_ url: URL) async -> String {
        await saveAll([url])
    }

    /// 把几个视频按顺序存进相册
    static func saveAll(_ urls: [URL]) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "没有相册权限，请到「设置」里允许这个 App 添加照片"
        }
        var saved = 0
        for url in urls {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saved += 1
            } catch {
                let done = urls.count > 1 ? "已存 \(saved) 个，" : ""
                return "\(done)保存失败：\(error.localizedDescription)"
            }
        }
        return urls.count > 1 ? "已把 \(saved) 个都存到相册 ✓" : "已存到相册 ✓"
    }
}

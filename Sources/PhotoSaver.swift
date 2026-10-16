import Photos

enum PhotoSaver {
    /// 把视频存进相册，返回给用户看的提示文字
    static func save(_ url: URL) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "没有相册权限，请到「设置」里允许这个 App 添加照片"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return "已存到相册 ✓"
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }
}

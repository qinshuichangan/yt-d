import Foundation
import YouTubeKit

/// 把各种错误翻成看得懂的中文，并判断重试有没有意义
enum ErrorText {
    static func describe(_ error: Error) -> (text: String, retryable: Bool) {
        if let e = error as? YouTubeKitError {
            switch e {
            case .membersOnly:
                return ("会员专享视频，需要加入频道会员才能看，无法下载", false)
            case .videoPrivate:
                return ("私人视频，无法下载", false)
            case .videoUnavailable:
                return ("视频不可用（可能已被删除）", false)
            case .videoAgeRestricted:
                return ("有年龄限制的视频，需要登录才能看，暂时无法下载", false)
            case .videoRegionBlocked:
                return ("这个视频在当前地区不可用", false)
            case .liveStreamError, .recordingUnavailable:
                return ("直播或直播回放，暂不支持下载", false)
            default:
                return ("解析失败（\(e.rawValue)），可以稍后重试", true)
            }
        }
        if let e = error as? DouyinFetcher.Failure {
            switch e {
            case .imagePost, .unavailable: return (e.localizedDescription, false)
            default: return (e.localizedDescription, true)
            }
        }
        if error is URLError {
            return ("网络错误：\(error.localizedDescription)", true)
        }
        return (error.localizedDescription, true)
    }
}

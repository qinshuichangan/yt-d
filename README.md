# 视频下载（iOS 侧载用）

在 iPhone 上独立运行的 YouTube 下载 App，不需要电脑开着。
基于开源库 [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)（MIT 许可）。

## 功能
- 粘贴链接 → 自动列出可选格式
- **高画质**（1080p 等）：画面和声音分开下载，手机上自动合并成 mp4
- **快速**：直接下载音视频合一的文件（通常 360p）
- **仅音频**：m4a
- 存到相册、分享、「已下载」列表里直接播放 / 左滑删除
- 文件同时出现在「文件」App →「我的 iPhone」→「视频下载」

## 编译 IPA（不需要 Mac）
1. 在 GitHub 新建一个仓库，把这个文件夹里的**全部内容**（包括 `.github` 文件夹）上传上去。
2. 打开仓库的 **Actions** 页面，选 **Build IPA** → **Run workflow**（推送到 main 也会自动编译）。
3. 大约 5～10 分钟后，点进完成的那次运行，在页面底部 **Artifacts** 下载 `YTDownloader-ipa`，解压得到 `YTDownloader.ipa`。
4. 用你平时的侧载工具（Sideloadly / AltStore / SideStore / TrollStore 等）安装。
   生成的 IPA 没有签名，侧载工具会用你的 Apple ID 重新签名。

## 有 Mac 的话
```bash
brew install xcodegen
xcodegen generate
open YTDownloader.xcodeproj
```
在 Xcode 里选自己的 Team，直接装到手机上即可。

## 常见问题
- **解析失败**：多半是 YouTube 改了规则。到 YouTubeKit 的 Releases 看有没有新版本，
  有的话重新跑一次 Actions 就会自动用上新版（`project.yml` 里写的是 `from: 0.4.9`，会取最新的 0.x 版本）。
- **下载中断**：下载时请留在 App 里，切到后台系统可能会暂停网络。
- **合并失败**：改选「快速」格式。
- 本机解析失败时，App 会改用 YouTubeKit 作者提供的远程解析服务器（只发送视频 ID）。

## 注意
YouTube 的使用条款原则上不允许下载视频。请只用于自己的视频、允许下载的内容或个人离线观看，
不要再上传或分发他人的作品。

import SwiftUI

/// 输出设置（单个文件和批量处理共用，都存在 UserDefaults 里）
struct OutputChoice: Sendable {
    var format: OutputFormat
    var audioBitrate: Int
    var precise: Bool
    var compressMode: CompressMode
    var manual: CompressSettings
    var targetMB: Double
    var split: SplitSettings

    /// 读取当前保存的设置（默认值要和 OutputSettingsSection 里的 @AppStorage 一致）
    static func current() -> OutputChoice {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        let defaults = SplitSettings()
        return OutputChoice(
            format: OutputFormat(rawValue: value(EditorModel.formatKey, "")) ?? .video,
            audioBitrate: value(EditorModel.bitrateKey, 192),
            precise: value(EditorModel.preciseKey, false),
            compressMode: CompressMode(rawValue: value(EditorModel.compressModeKey, "")) ?? .lecture,
            manual: CompressSettings(shortSide: value(EditorModel.compressSideKey, 720),
                                     fps: value(EditorModel.compressFPSKey, 30),
                                     bitrateMbps: value(EditorModel.compressBitrateKey, 3.0),
                                     hevc: value(EditorModel.compressHEVCKey, true)),
            targetMB: value(EditorModel.compressTargetKey, 30.0),
            split: SplitSettings(
                enabled: value(SplitSettings.enabledKey, defaults.enabled),
                mode: SplitMode(rawValue: value(SplitSettings.modeKey, "")) ?? defaults.mode,
                minutes: value(SplitSettings.minutesKey, defaults.minutes),
                count: value(SplitSettings.countKey, defaults.count)))
    }

    /// 只有声音的文件没法输出视频，自动换成 MP3
    func format(hasVideo: Bool) -> OutputFormat {
        format.isVideo && !hasVideo ? .mp3 : format
    }

    /// 目标大小模式的计算结果（含「目标太小」的提示）
    func targetPlan(source: SourceVideo?, seconds: Double?) -> (settings: CompressSettings, warning: String?)? {
        guard let source, let seconds, seconds > 0 else { return nil }
        return CompressSettings.forTarget(megabytes: max(targetMB, 1), seconds: seconds, source: source)
    }

    /// 按压缩方式算出这个视频实际要用的设置
    func compressSettings(source: SourceVideo?, seconds: Double?) -> CompressSettings {
        switch compressMode {
        case .lecture:
            if let source { return CompressSettings.lecture(source: source) }
        case .target:
            if let plan = targetPlan(source: source, seconds: seconds) { return plan.settings }
        case .manual:
            break
        }
        return manual
    }
}

/// 「输出」设置区块 + 「分割」设置区块
struct OutputSettingsSection: View {
    let header: String
    let splitHeader: String
    /// 有画面的文件才能选视频格式（批量时传 true）
    let allowVideo: Bool
    /// 单个文件时用来显示自动设置和预计大小；批量时为 nil
    let source: SourceVideo?
    let seconds: Double?
    var targetFocus: FocusState<Bool>.Binding

    @AppStorage(EditorModel.formatKey) private var format: OutputFormat = .video
    @AppStorage(EditorModel.bitrateKey) private var bitrate = 192
    @AppStorage(EditorModel.preciseKey) private var precise = false
    @AppStorage(EditorModel.compressSideKey) private var compressSide = 720
    @AppStorage(EditorModel.compressFPSKey) private var compressFPS = 30
    @AppStorage(EditorModel.compressBitrateKey) private var compressBitrate = 3.0
    @AppStorage(EditorModel.compressHEVCKey) private var compressHEVC = true
    @AppStorage(EditorModel.compressModeKey) private var compressMode: CompressMode = .lecture
    @AppStorage(EditorModel.compressTargetKey) private var targetMB = 30.0
    @AppStorage(SplitSettings.enabledKey) private var splitEnabled = false
    @AppStorage(SplitSettings.modeKey) private var splitMode: SplitMode = .minutes
    @AppStorage(SplitSettings.minutesKey) private var splitMinutes = 15.0
    @AppStorage(SplitSettings.countKey) private var splitCount = 3

    private var isBatch: Bool { source == nil && seconds == nil }

    private var availableFormats: [OutputFormat] {
        OutputFormat.allCases.filter { !$0.isVideo || allowVideo }
    }

    /// 只用来显示（拿到的是界面上的最新值）
    private var choice: OutputChoice {
        OutputChoice(format: format, audioBitrate: bitrate, precise: precise, compressMode: compressMode,
                     manual: CompressSettings(shortSide: compressSide, fps: compressFPS,
                                              bitrateMbps: compressBitrate, hevc: compressHEVC),
                     targetMB: targetMB,
                     split: SplitSettings(enabled: splitEnabled, mode: splitMode,
                                          minutes: splitMinutes, count: splitCount))
    }

    var body: some View {
        Group {
            outputSection
            splitSection
        }
    }

    private var outputSection: some View {
        Section {
            Picker("格式", selection: $format) {
                ForEach(availableFormats) { f in
                    Text(f.label).tag(f)
                }
            }
            if format == .video {
                Toggle("精确剪切（重新编码）", isOn: $precise)
            } else if format == .compressed {
                compressControls
            } else {
                Picker("音质（码率）", selection: $bitrate) {
                    ForEach(Exporter.bitrates, id: \.self) { b in
                        Text("\(b) kbps").tag(b)
                    }
                }
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }

    // MARK: 压缩

    private var compressControls: some View {
        Group {
            Picker("压缩方式", selection: $compressMode) {
                ForEach(CompressMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch compressMode {
            case .lecture:
                planSummary
            case .target:
                HStack {
                    Text(isBatch ? "每个视频的目标大小" : "目标大小")
                    Spacer()
                    TextField("30", value: $targetMB, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                        .focused(targetFocus)
                    Text("MB")
                }
                planSummary
                if let warning = choice.targetPlan(source: source, seconds: seconds)?.warning {
                    Text(warning).font(.caption).foregroundStyle(.red)
                }
            case .manual:
                manualControls
            }
        }
    }

    /// 自动算出来的设置 + 预计大小
    @ViewBuilder
    private var planSummary: some View {
        if isBatch {
            Text("每个视频分别按自己的分辨率和长度自动计算。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if source == nil {
            Text("读不出原视频的信息，自动模式用不了，请用「手动」。")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("自动设置：\(settings.summary(for: source))")
                    .font(.caption)
                estimateText
            }
        }
    }

    private var settings: CompressSettings {
        choice.compressSettings(source: source, seconds: seconds)
    }

    @ViewBuilder
    private var estimateText: some View {
        if let seconds, seconds > 0 {
            Text(String(format: "预计大小约 %.1f MB", settings.estimatedMB(seconds: seconds)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var manualControls: some View {
        Group {
            Picker("分辨率", selection: $compressSide) {
                ForEach(CompressSettings.resolutions, id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
            }
            Picker("帧率", selection: $compressFPS) {
                ForEach(CompressSettings.frameRates, id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("码率")
                    Spacer()
                    Text(String(format: "%.1f Mbps", compressBitrate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $compressBitrate, in: CompressSettings.bitrateRange, step: 0.1)
                estimateText
            }
            Toggle("HEVC 编码（体积更小）", isOn: $compressHEVC)
        }
    }

    // MARK: 分割

    private var splitSection: some View {
        Section {
            Toggle(isOn: $splitEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(splitTitle)
                    Text("切成几个小文件，方便一段一段上传或发送")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if splitEnabled {
                Picker("分割方式", selection: $splitMode) {
                    ForEach(SplitMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch splitMode {
                case .minutes:
                    HStack {
                        Text("每段长度")
                        Spacer()
                        TextField("15", value: $splitMinutes, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                            .focused(targetFocus)
                        Text("分钟")
                    }
                case .count:
                    Stepper(value: $splitCount, in: 2...SplitSettings.maxParts) {
                        HStack {
                            Text("分成")
                            Spacer()
                            Text("\(splitCount) 段").monospacedDigit()
                        }
                    }
                }
                splitPlan
            }
        } header: {
            Text(splitHeader)
        } footer: {
            Text(splitFooter)
        }
    }

    /// 压缩时叫「压缩后自动分割」，其它格式按各自的说法
    private var splitTitle: String {
        switch format {
        case .video: return "分割成几段"
        case .compressed: return "压缩后自动分割"
        default: return "转换后自动分割"
        }
    }

    /// 会分成几段、每段多长、每段大概多大
    @ViewBuilder
    private var splitPlan: some View {
        if isBatch {
            Text(splitMode == .minutes
                 ? "每个文件分别按自己的长度来分，不够 \(TimeText.short(max(splitMinutes, 0.1) * 60)) 的文件不分。"
                 : "每个文件都平均分成 \(splitCount) 段。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let seconds, seconds > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.split.summary(seconds: seconds)).font(.caption)
                if let size = segmentSizeText(seconds: seconds) {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func segmentSizeText(seconds: Double) -> String? {
        let parts = choice.split.parts(start: 0, end: seconds)
        guard parts.count > 1, let longest = parts.map(\.length).max() else { return nil }
        let mb: Double
        switch format {
        case .video: return nil   // 不重新编码，大小跟着原视频走
        case .compressed: mb = settings.estimatedMB(seconds: longest)
        default: mb = Double(bitrate) * longest / 8 / 1000
        }
        return String(format: "每段预计最大约 %.1f MB", mb)
    }

    private var splitFooter: String {
        guard splitEnabled else {
            return "打开后，处理完会按设置切成几个文件，文件名后面加「_第1段」「_第2段」…，按名字排序就是顺序。"
        }
        switch format {
        case .video:
            return precise
                ? "每段都重新编码，切点精确到帧，比较慢。"
                : "不重新编码，很快、画质无损。每段开头从最近的关键帧开始，相邻两段可能会有一两秒重叠，不会漏掉内容；介意的话在上面打开「精确剪切」。"
        case .compressed:
            return "按上面的压缩设置处理，再切成几段，每段都能单独播放。压缩设置按整段的长度来算，所以「目标大小」是所有段加起来的大小。"
        default:
            return "每段分别转成音频，可以一段一段发给 Claude 转写。文件名后面会加「_第1段」「_第2段」…"
        }
    }

    // MARK: 说明

    private var footer: String {
        switch format {
        case .video:
            if isBatch {
                return "批量时整段不剪，只是转成 MP4。想变小请选「压缩视频」。"
            }
            return precise
                ? "重新编码：切点精确到帧，但比较慢，画质会有一点点损失。"
                : "不重新编码：很快、画质无损。开头可能会从最近的关键帧开始，有零点几秒的误差，介意的话打开「精确剪切」。"
        case .compressed:
            switch compressMode {
            case .lecture:
                return "专门压给 Claude 看的网课：480p、每秒 1 帧、单声道 32 kbps 人声，一小时大约 60 MB。画面会一卡一卡的，但幻灯片和板书的字、老师讲的话都够 Claude 看清听清。原视频本身就很小、字很小或者黑板拍得很远的话，换「目标大小」给多一点空间。"
            case .target:
                return "输入想要的文件大小，自动算码率，再挑这个码率下最清楚的分辨率和帧率。只压缩选中的那一段时，按那一段的长度算。实际大小可能有一点点误差。"
            case .manual:
                return "分辨率和帧率只会降低、不会比原视频高。码率参考：1080p 约 4–8 Mbps，720p 约 2–4 Mbps，480p 约 1–2 Mbps，太低会有马赛克。HEVC 体积更小；要发给旧手机或 Windows 电脑就关掉，用 H.264。HDR 视频会转成普通画面。"
            }
        case .ogg:
            return "OGG 用的是可变码率，选的数值是大概的平均码率。iPhone 自带的播放器不能播 OGG。"
        case .aac:
            return ".aac 是不带封装的纯 AAC，兼容性比 .m4a 稍差；不确定就选 .m4a。"
        default:
            return "192 kbps 一般就够用了，听音乐想要更好可以选 256 或 320。"
        }
    }
}

/// 「处理时屏幕调到最暗」开关
struct DimToggle: View {
    @AppStorage(WorkSession.dimKey) private var dim = true

    var body: some View {
        Toggle(isOn: $dim) {
            VStack(alignment: .leading, spacing: 2) {
                Text("处理时屏幕调到最暗")
                Text("处理完之前不会自动锁屏，结束后恢复原来的亮度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: dim) { _ in WorkSession.shared.refreshDim() }
    }
}

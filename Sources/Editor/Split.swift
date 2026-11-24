import Foundation

/// 分割方式
enum SplitMode: String, CaseIterable, Identifiable {
    case minutes, count

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minutes: return "每 X 分钟一段"
        case .count: return "平均分成 X 段"
        }
    }
}

/// 处理完自动分割成几段（单个文件和批量共用，存在 UserDefaults 里）
struct SplitSettings: Sendable, Equatable {
    var enabled = false
    var mode: SplitMode = .minutes
    var minutes = 15.0
    var count = 3

    static let enabledKey = "splitEnabled"
    static let modeKey = "splitMode"
    static let minutesKey = "splitMinutes"
    static let countKey = "splitCount"

    /// 最多分成几段
    static let maxParts = 99
    /// 按时长分时，最后剩下不到这么多秒就并到前一段（不会出现只有两三秒的小尾巴）
    static let minTail = 10.0

    struct Part: Sendable, Equatable {
        let start: Double
        let end: Double
        var length: Double { end - start }
    }

    /// 按时长分时，不限段数的话会分成几段
    private func rawMinuteCount(_ total: Double) -> Int {
        let step = max(minutes, 0.1) * 60
        var n = Int((total / step).rounded(.up))
        if n > 1 && total - Double(n - 1) * step < Self.minTail { n -= 1 }
        return max(n, 1)
    }

    /// 把 start…end 分成几段（没打开分割、或者不够分时只有一段）
    func parts(start: Double, end: Double) -> [Part] {
        let total = end - start
        guard enabled, total > 1 else { return [Part(start: start, end: end)] }

        var n: Int
        var step: Double
        switch mode {
        case .minutes:
            n = rawMinuteCount(total)
            step = max(minutes, 0.1) * 60
            if n > Self.maxParts {
                n = Self.maxParts    // 太多了：改成平均分 99 段
                step = total / Double(n)
            }
        case .count:
            let longest = max(Int(total), 1)          // 每段至少 1 秒
            n = min(max(count, 1), Self.maxParts)
            n = min(n, longest)
            step = total / Double(n)
        }
        return Self.cut(start: start, end: end, count: n, step: step)
    }

    /// 从 start 开始每 step 秒切一刀，一共 count 段，最后一段一直到 end
    private static func cut(start: Double, end: Double, count: Int, step: Double) -> [Part] {
        var list: [Part] = []
        for i in 0..<count {
            let from: Double = start + Double(i) * step
            let to: Double = (i == count - 1) ? end : start + Double(i + 1) * step
            list.append(Part(start: from, end: to))
        }
        return list
    }

    /// 例：「会分成 3 段：每段 15:00，最后一段 12:31」
    func summary(seconds total: Double) -> String {
        let list = parts(start: 0, end: total)
        guard list.count > 1, let first = list.first, let last = list.last else {
            return "这段不够分，会照常输出一个文件。"
        }
        var text = abs(first.length - last.length) < 1
            ? "会分成 \(list.count) 段，每段约 \(TimeText.short(first.length))"
            : "会分成 \(list.count) 段：每段 \(TimeText.short(first.length))，最后一段 \(TimeText.short(last.length))"
        if mode == .minutes && rawMinuteCount(total) > Self.maxParts {
            text += "（最多 \(Self.maxParts) 段，所以改成了平均分）"
        }
        return text
    }

    /// 每段的文件名：「我的视频_第1段」；10 段以上补 0（第01段），按名字排序就是按顺序
    static func partName(_ base: String, index: Int, count: Int) -> String {
        let digits = String(count).count
        let number = String(index + 1)
        return base + "_第" + String(repeating: "0", count: max(0, digits - number.count)) + number + "段"
    }
}

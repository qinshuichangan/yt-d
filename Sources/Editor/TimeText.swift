import Foundation

/// 时间文字 ⇄ 秒数
enum TimeText {
    /// 支持的写法：
    /// `90`、`90.5`、`1:30`、`1:30.25`、`1:02:03`、`01:02:03.5`
    /// 全角「：」、中文「1分30秒」「1时2分3秒」、小数点用「,」「。」也可以
    static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements: [(String, String)] = [
            ("：", ":"), ("，", "."), (",", "."), ("。", "."), ("．", "."),
            ("小时", ":"), ("时", ":"), ("分钟", ":"), ("分", ":"), ("秒", ""), (" ", ""),
        ]
        for (from, to) in replacements {
            t = t.replacingOccurrences(of: from, with: to)
        }
        // 全角数字转半角
        t = String(t.map { ch -> Character in
            if let v = ch.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v),
               let scalar = Unicode.Scalar(v - 0xFF10 + 0x30) {
                return Character(scalar)
            }
            return ch
        })
        if t.hasSuffix(":") { t += "0" }   // 「1分」→ 1:0
        guard !t.isEmpty else { return nil }

        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            // 只有最后一段可以带小数
            if index < parts.count - 1 && part.contains(".") { return nil }
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// 秒数 → 「1:23.45」或「1:02:03.45」（精确到 0.01 秒）
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let cs = Int((max(0, seconds) * 100).rounded())
        let h = cs / 360_000
        let m = (cs / 6000) % 60
        let s = (cs / 100) % 60
        let f = cs % 100
        if h > 0 {
            return String(format: "%d:%02d:%02d.%02d", h, m, s, f)
        }
        return String(format: "%d:%02d.%02d", m, s, f)
    }

    /// 秒数 → 「15:00」或「1:02:03」（四舍五入到秒，用在说明文字里）
    static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// 用在文件名里的写法：「1m23s」「1h02m03s」（不足 1 秒的部分省略）
    static func fileStamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
        return String(format: "%dm%02ds", m, s)
    }
}

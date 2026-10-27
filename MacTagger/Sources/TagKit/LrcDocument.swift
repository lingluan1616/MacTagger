//
//  LrcDocument.swift
//  MacTagger — LRC 歌词的解析、变换与渲染
//
//  纯数据模型：不碰网络、不碰文件系统，便于单元测试。
//  对应原版「删除时间轴 / 格式化时间轴 / 删除空白文字的行 / 删除头部标签 / 调整时间轴」
//  五项菜单操作（B 报告 5.2 节 D 条）。
//

import Foundation

// MARK: - 一行歌词

public struct LrcLine: Sendable, Equatable {
    /// 一行可以挂多个时间戳：`[00:12.00][01:30.00]副歌`。空数组表示纯文本行。
    public var timestamps: [TimeInterval]
    public var text: String

    public init(timestamps: [TimeInterval] = [], text: String = "") {
        self.timestamps = timestamps
        self.text = text
    }

    public var hasTimestamp: Bool { !timestamps.isEmpty }
    /// 文字部分是否为空白（只有时间戳没内容）。
    public var isBlankText: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    /// 排序用的首个时间戳。
    public var firstTimestamp: TimeInterval? { timestamps.min() }
}

// MARK: - 文档

public struct LrcDocument: Sendable, Equatable {

    /// `[ti:标题]` `[ar:艺术家]` `[al:专辑]` `[by:]` `[offset:]` 这类元信息标签。
    public var headerTags: [HeaderTag]
    public var lines: [LrcLine]

    public struct HeaderTag: Sendable, Equatable {
        public var key: String
        public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public init(headerTags: [HeaderTag] = [], lines: [LrcLine] = []) {
        self.headerTags = headerTags
        self.lines = lines
    }

    public var isEmpty: Bool { headerTags.isEmpty && lines.isEmpty }

    /// 被识别为元信息标签的键。其余 `[xxx:yyy]` 一律按时间戳或正文处理。
    static let knownHeaderKeys: Set<String> = [
        "ti", "ar", "al", "by", "offset", "re", "ve", "au", "length", "kana", "total"
    ]

    // MARK: - 解析

    /// 容错解析。支持 `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]` / `[mm:ss:xx]`（冒号分隔毫秒也常见）、
    /// 一行多时间戳、BOM、`\r\n` 与 `\r` 行尾、无时间戳的纯文本行。
    /// **任何畸形输入都不应崩溃**，最坏情况下整行当作纯文本保留。
    public static func parse(_ raw: String) -> LrcDocument {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }          // 去 BOM
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")

        var headers: [HeaderTag] = []
        var lines: [LrcLine] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            var cursor = line.startIndex
            var stamps: [TimeInterval] = []
            var headerHere: HeaderTag?

            // 连续吃掉行首的 [...] 块
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let inner = String(line[line.index(after: cursor)..<close])

                if let t = parseTimestamp(inner) {
                    stamps.append(t)
                } else if let colon = inner.firstIndex(of: ":") {
                    let key = String(inner[..<colon]).lowercased()
                    if knownHeaderKeys.contains(key) {
                        headerHere = HeaderTag(key: key,
                                               value: String(inner[inner.index(after: colon)...]))
                    } else {
                        break       // 不认识的 [x:y]，当正文
                    }
                } else {
                    break           // 没冒号也不是时间戳，当正文
                }
                cursor = line.index(after: close)
            }

            let body = String(line[cursor...]).trimmingCharacters(in: .whitespaces)

            if let h = headerHere, stamps.isEmpty, body.isEmpty {
                headers.append(h)
                continue
            }
            // 既有时间戳又有内容，或纯文本行
            if !stamps.isEmpty || !body.isEmpty {
                lines.append(LrcLine(timestamps: stamps, text: body))
            }
        }
        return LrcDocument(headerTags: headers, lines: lines)
    }

    /// 解析 `mm:ss` / `mm:ss.xx` / `mm:ss.xxx` / `mm:ss:xx`。失败返回 nil。
    ///
    /// **整数运算**（BP-G 轮，BO 报告 #17）：分、秒、小数位分别按整数读，合成**整毫秒**后
    /// 才转成 `TimeInterval`。返回值恒为「整毫秒 / 1000」，渲染时 `millis(_:)` 能原样取回 ——
    /// 原先 `Double("12.29")` 一路浮点，渲染端 `floor(x * 100)` 碰上 0.29×100 = 28.999… 就早 10 ms。
    /// 小数超过三位的按四舍五入归到毫秒。非常规写法（如 `1.5:00`）退回旧的浮点解析，再归整到毫秒。
    static func parseTimestamp(_ s: String) -> TimeInterval? {
        // 必须以数字开头，排除 [ti:...] 这类
        guard let first = s.first, first.isNumber else { return nil }

        // 统一把毫秒前的冒号分隔符换成点
        var normalized = s
        let parts = s.components(separatedBy: ":")
        if parts.count == 3 {
            normalized = parts[0] + ":" + parts[1] + "." + parts[2]
        }

        let mm_ss = normalized.components(separatedBy: ":")
        guard mm_ss.count == 2 else { return nil }

        if let ms = strictMillis(minutes: mm_ss[0], seconds: mm_ss[1]) {
            return TimeInterval(ms) / 1000
        }
        // 兜底：旧的宽松浮点解析（保持对怪写法的容忍度），结果同样归整到整毫秒。
        guard let minutes = Double(mm_ss[0]), let seconds = Double(mm_ss[1]) else { return nil }
        guard minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(millis(minutes * 60 + seconds)) / 1000
    }

    /// `mm` + `ss[.fff…]` 全是 ASCII 数字时按整数合成毫秒；形状不对返回 nil（交给兜底）。
    private static func strictMillis(minutes: String, seconds: String) -> Int? {
        func digits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        let mm = Substring(minutes)
        guard digits(mm), mm.count <= 9, let m = Int(mm) else { return nil }
        let secParts = seconds.split(separator: ".", omittingEmptySubsequences: false)
        guard secParts.count <= 2, digits(secParts[0]), secParts[0].count <= 2,
              let sec = Int(secParts[0]), sec < 60 else { return nil }
        var frac = 0
        if secParts.count == 2 {
            let f = secParts[1]
            guard digits(f) else { return nil }
            // 前三位是毫秒；第四位起只用来四舍五入（`.2995` → 300 ms）。
            let head = String(f.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            frac = Int(head) ?? 0
            if f.count > 3, let d = f.dropFirst(3).first?.wholeNumberValue, d >= 5 { frac += 1 }
        }
        return (m * 60 + sec) * 1000 + frac
    }

    /// 秒 → **整毫秒**（四舍五入，带符号）。所有时间戳运算都先过这一道，把浮点误差挡在门外。
    /// 非有限值当 0；量级钳在 ±10 亿秒以内，保证转 `Int` 不溢出。
    static func millis(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        let clamped = min(max(seconds, -1e9), 1e9)
        return Int((clamped * 1000).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: - 渲染

    /// - Parameter millisecondDigits: 2 或 3。原版「格式化时间轴」即三位转二位。
    public func render(millisecondDigits: Int = 2) -> String {
        var out: [String] = []
        for h in headerTags { out.append("[\(h.key):\(h.value)]") }
        for line in lines {
            if line.timestamps.isEmpty {
                out.append(line.text)
            } else {
                let stamps = line.timestamps
                    .map { "[" + Self.formatTimestamp($0, digits: millisecondDigits) + "]" }
                    .joined()
                out.append(stamps + line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 全程整数（BP-G 轮）：先 `millis(_:)` 四舍五入到整毫秒，再用整除拆分钟 / 秒 / 小数位。
    static func formatTimestamp(_ t: TimeInterval, digits: Int) -> String {
        let ms = max(0, millis(t))
        let totalMinutes = ms / 60_000
        let secMs = ms % 60_000

        if digits >= 3 {
            return String(format: "%02d:%02d.%03d", totalMinutes, secMs / 1000, secMs % 1000)
        }
        // 两位毫秒：**截断而非四舍五入**（毫秒 → 厘秒用整除，没有浮点误差）。
        // 理由：歌词时间戳是「该句开始唱的时刻」，四舍五入可能把它推后到人声之后，
        // 导致这一句晚半拍才高亮；截断只会早最多 10ms，听感上无害。
        // 「截断」只作用在**第三位毫秒**上（`12.345 → 12.34`）；两位的输入原样往返。
        let cs = secMs / 10
        return String(format: "%02d:%02d.%02d", totalMinutes, cs / 100, cs % 100)
    }

    // MARK: - 五种变换（对应原版菜单项）

    /// 删除时间轴 —— 只留纯文本。
    public func removingTimestamps() -> LrcDocument {
        LrcDocument(headerTags: headerTags,
                    lines: lines.map { LrcLine(timestamps: [], text: $0.text) })
    }

    /// 格式化时间轴 —— 三位毫秒转二位。
    /// 时间值本身不变，变的是渲染精度；这里把值按两位精度归一，使后续渲染稳定。
    public func formattingTimestamps() -> LrcDocument {
        LrcDocument(headerTags: headerTags,
                    lines: lines.map { line in
                        // 整数：毫秒整除到厘秒再乘回（= 渲染时两位截断的口径），无浮点误差。
                        LrcLine(timestamps: line.timestamps.map {
                                    TimeInterval(max(0, Self.millis($0)) / 10 * 10) / 1000
                                },
                                text: line.text)
                    })
    }

    /// 删除空白文字的行 —— 只有时间戳没内容的行。纯文本空行在解析阶段已被丢弃。
    public func removingBlankLines() -> LrcDocument {
        LrcDocument(headerTags: headerTags, lines: lines.filter { !$0.isBlankText })
    }

    /// 删除头部标签 —— `[ti:]` `[ar:]` `[al:]` 之类。
    public func removingHeaderTags() -> LrcDocument {
        LrcDocument(headerTags: [], lines: lines)
    }

    /// 调整时间轴 —— 整体偏移，正负均可。**结果钳到 0，不允许负时间戳。**
    public func shiftingTime(by seconds: TimeInterval) -> LrcDocument {
        LrcDocument(headerTags: headerTags,
                    lines: lines.map { line in
                        // 整毫秒相加（BP-G 轮）：「延后 0.05」再「提前 0.05」必须回到原值。
                        LrcLine(timestamps: line.timestamps.map {
                                    TimeInterval(max(0, Self.millis($0) + Self.millis(seconds))) / 1000
                                },
                                text: line.text)
                    })
    }

    // MARK: - 便利

    /// 按时间排序（多时间戳行按其最早时间戳）。无时间戳的行保持相对位置排在最前。
    public func sortedByTime() -> LrcDocument {
        let timed = lines.filter { $0.hasTimestamp }
            .sorted { ($0.firstTimestamp ?? 0) < ($1.firstTimestamp ?? 0) }
        let untimed = lines.filter { !$0.hasTimestamp }
        return LrcDocument(headerTags: headerTags, lines: untimed + timed)
    }

    /// 纯文本（供「删除时间轴」后直接写入标签，或做查找替换）。
    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

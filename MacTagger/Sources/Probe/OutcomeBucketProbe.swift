//
//  OutcomeBucketProbe.swift
//  mactagger-probe — 逐源结果分桶表（BD 轮第三部分）
//
//  用户原话是「QQ 音乐和 iTunes 一直失败」。要处置这句话，先得把「失败」拆开：
//  超时、HTTP 码、空结果、熔断暂停、软截止跳过 —— 这五件事的根因与处置完全不同，
//  混在一起看永远只能得出「时好时坏」。
//
//  这份表把一轮批量里每个源的每一次结果按桶计数，并把**原文 detail** 原样附上
//  （不改写、不归纳），好在报告里对着实测原文写处置。
//

import Foundation

/// 一个桶。顺序即打印顺序。
enum OutcomeBucket: String, CaseIterable {
    case hits      = "命中"
    case empty     = "0 条"
    case timeout   = "超时"
    case http      = "HTTP 码"
    case rateLimit = "限流"
    case paused    = "熔断暂停"
    case skipped   = "软截止跳过"
    case cancelled = "已取消"
    case other     = "其它失败"

    /// **只有这三个桶算「失败」**。
    /// `0 条` 是「这个源没有这首歌」，`软截止跳过` 是我们自己不等了，
    /// `熔断暂停` 是上一批已经问出它在挂 —— 三者都不是「这一发失败了」。
    var countsAsFailure: Bool {
        switch self {
        case .timeout, .http, .other: return true
        default: return false
        }
    }
}

func outcomeBucket(_ o: SourceOutcome) -> OutcomeBucket {
    switch o.status {
    case .hits:    return .hits
    case .empty:   return .empty
    case .paused:  return .paused
    case .skipped: return .skipped
    case .failed(let why):
        if why.contains("超时") { return .timeout }
        if why.contains("限流") { return .rateLimit }
        if why.hasPrefix("HTTP") { return .http }
        if why.contains("已取消") { return .cancelled }
        if why.contains("暂停中") { return .paused }
        return .other
    }
}

/// 打印分桶表 + 每桶的原文样本。
///
/// `tag` 会出现在每一行机读输出的前缀里（`BUCKET\t<tag>\t<源>\t<桶>\t<次数>`），
/// 好让三轮的结果用同一把尺子拼起来。
func printOutcomeBuckets(_ perFile: [[SourceOutcome]], tag: String) {
    let flat = perFile.flatMap { $0 }
    guard !flat.isEmpty else { return }
    let sources = Array(Set(flat.map(\.sourceID))).sorted()

    print("")
    print("═══ 逐源结果分桶（\(tag)）═══")
    var header = "  " + cnPad("数据源", 14)
    for b in OutcomeBucket.allCases { header += cnPad(b.rawValue, 12) }
    header += cnPad("失败率", 10) + "有效率"
    print(header)
    print("  " + String(repeating: "─", count: 128))

    for sid in sources {
        let rows = flat.filter { $0.sourceID == sid }
        var line = "  " + cnPad(SourceOutcome.displayName(sid), 14)
        var failed = 0
        for b in OutcomeBucket.allCases {
            let n = rows.filter { outcomeBucket($0) == b }.count
            if b.countsAsFailure { failed += n }
            line += cnPad(n == 0 ? "·" : "\(n)", 12)
            print("BUCKET\t\(tag)\t\(sid)\t\(b.rawValue)\t\(n)", to: &probeBucketSink)
        }
        let total = rows.count
        let hits = rows.filter { outcomeBucket($0) == .hits }.count
        line += cnPad(String(format: "%d/%d", failed, total), 10)
        line += String(format: "%d/%d = %.0f%%", hits, total,
                       total > 0 ? Double(hits) / Double(total) * 100 : 0)
        print(line)
    }
    print("")
    print("  口径：失败率的分子**只含**超时 / HTTP 码 / 其它失败三桶。")
    print("        「0 条」是这个源真没这首歌，「软截止跳过」是我们自己不等了，")
    print("        「熔断暂停」是上一批已经问出它在挂 —— 三者都不进失败率。")

    // 每桶的原文样本：报告里写处置要对着实测原文，不能凭印象。
    print("")
    print("  各桶原文样本（detail 原样，未改写）：")
    for sid in sources {
        let rows = flat.filter { $0.sourceID == sid }
        for b in OutcomeBucket.allCases where b != .hits {
            let hit = rows.filter { outcomeBucket($0) == b }
            guard !hit.isEmpty else { continue }
            let samples = Set(hit.compactMap { $0.detail }).sorted().prefix(3)
            let avg = hit.map(\.latency).reduce(0, +) / Double(hit.count)
            print(String(format: "    %@ · %@ ×%d（平均 %.2f s）：%@",
                         SourceOutcome.displayName(sid), b.rawValue, hit.count, avg,
                         samples.isEmpty ? "（无 detail）" : samples.joined(separator: " ｜ ")))
        }
    }
}

/// 机读行写到 stderr，免得和人读的表混在一起被 grep 误伤。
struct ProbeBucketSink: TextOutputStream {
    func write(_ string: String) {
        FileHandle.standardError.write(string.data(using: .utf8)!)
    }
}
nonisolated(unsafe) var probeBucketSink = ProbeBucketSink()

// MARK: - qqclean —— 检索词清洗用例表（BD 轮）

//
//  `mactagger-probe qqclean`
//
//  两件事一次验完：
//  ① 洗出来的检索词对不对（全角写法是 BD 轮新补的，来自 LDDC 的 `unified_symbol`）；
//  ② **AZ 轮那条艺术家判据没被洗坏** —— `artistTier(.haystack)` 是拿洗过的文件名
//     当「包含」判据用的，洗法一改就可能把艺术家名洗没了，那会让翻唱重新压过原版。
//     所以每条用例都把「这个文件名还认不认得出周杰伦/米津玄師」一起打出来。
//

func cmdQQClean() {
    cnHR("QQ 检索词清洗用例表（qqclean）")
    out("  洗法：全角符号归一 → 剥前导音轨号 → 分隔符换空格 → 压空白")
    out("")
    out("  " + cnPad("原文件名", 34) + cnPad("洗出的检索词", 26) + "艺术家判据")
    out("  " + String(repeating: "─", count: 92))

    // (文件名, 期望能认出来的艺术家)
    let cases: [(String, String)] = [
        ("01 - 稻香 - 周杰伦", "周杰伦"),
        ("01. 稻香 - 周杰伦", "周杰伦"),
        ("01．稻香－周杰伦", "周杰伦"),          // ← 全角句点 + 全角连字符（BD 轮新增）
        ("［01］稻香－周杰伦", "周杰伦"),          // ← 全角方括号音轨号（BD 轮新增）
        ("(01) 稻香 - 周杰伦", "周杰伦"),
        ("01、稻香、周杰伦", "周杰伦"),
        ("Track 01 稻香 - 周杰伦", "周杰伦"),
        ("稻香｜周杰伦", "周杰伦"),               // ← 全角竖线（BD 轮新增）
        ("周杰伦／稻香", "周杰伦"),               // ← 全角斜杠（BD 轮新增）
        ("11 - Lemon - 米津玄師", "米津玄師"),
        ("ラーメン - 米津玄師", "米津玄師"),        // ← 长音符「ー」必须原样保留
        ("15 - Blank Space - Taylor Swift", "Taylor Swift"),
    ]

    var pass = 0
    for (raw, artist) in cases {
        let cleaned = QQSource.cleanedFilename(raw)
        var q = TrackQuery(); q.filename = raw
        let tier: Int
        if let hint = QQSource.artistHint(q) {
            tier = QQSource.artistTier(artist, hint: hint)
        } else {
            tier = -1
        }
        let ok = tier == 2 && !cleaned.hasPrefix("0") && !cleaned.hasPrefix("[")
        if ok { pass += 1 }
        out("  " + cnPad(raw, 34) + cnPad(cleaned, 26)
            + (tier == 2 ? "✔ 认出「\(artist)」" : "✘ tier=\(tier)"))
    }
    out("")
    out("  长音符体检：ラーメン → 洗后「\(QQSource.cleanedFilename("ラーメン"))」"
        + (QQSource.cleanedFilename("ラーメン") == "ラーメン" ? " ✔ 未被改写" : " ✘ 被改写了！"))
    out("  判定：\(pass)/\(cases.count) 条用例通过"
        + (pass == cases.count ? " ✔" : " ✘"))
    if pass != cases.count { exit(1) }
}

//
//  CNSourceProbe.swift
//  mactagger-probe — 中文在线数据源的联网验证子命令
//
//  子命令（在 main.swift 的 switch 里注册，不影响既有子命令）：
//    cnsource <sourceID> <搜索词>     搜索并打印候选表格（含补详情后的字段）
//    cnlyric  <sourceID> <搜索词>     取首个候选的歌词，打印原词/翻译/逐字可用性与前若干行
//    cnart    <sourceID> <搜索词>     取首个候选的封面，打印字节数与图片魔数
//    cnfallback <搜索词>              走 SourceRegistry 降级链，打印每个源的成败
//
//  合规：全部为只读查询，不登录、不带他人 Cookie、不下载音频本体。
//

import Foundation

// MARK: - 同步跑 async

/// CLI 的 main.swift 是同步顶层代码，这里用信号量把 async 调用拉回同步。
/// 泛型函数内不能嵌套类型，盒子提到顶层。
final class CNResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

func cnRunBlocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let sem = DispatchSemaphore(value: 0)
    let box = CNResultBox<T>()
    Task {
        do { box.value = .success(try await body()) }
        catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return box.value ?? .failure(SourceError.network("任务未返回结果"))
}

// MARK: - 源工厂（不经注册表也能单点验证）

func cnMakeSource(_ id: String) -> (any MetadataSource)? {
    switch id.lowercased() {
    case "netease", "163", "wyy": return NeteaseSource()
    case "kugou":                 return KugouSource()
    case "qq", "qqmusic":         return QQSource()
    case "kuwo", "kw":            return KuwoSource()
    default:                      return SourceRegistry.shared.source(id: id)
    }
}

// MARK: - 排版

/// CJK 字符按 2 列宽计算，否则中文表格会错位。
func cnDisplayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { acc, u in
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return acc + 2
        default:
            return acc + 1
        }
    }
}

func cnPad(_ s: String, _ width: Int) -> String {
    var t = s
    // 先按显示宽度截断
    while cnDisplayWidth(t) > width, !t.isEmpty { t.removeLast() }
    return t + String(repeating: " ", count: max(0, width - cnDisplayWidth(t)))
}

func cnHR(_ title: String) {
    print("")
    print("=== \(title) " + String(repeating: "=", count: max(0, 66 - cnDisplayWidth(title))))
}

func cnFmtDuration(_ s: TimeInterval) -> String {
    guard s > 0 else { return "--:--" }
    let total = Int(s.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - cnsource

func cmdCNSource(_ sourceID: String, _ term: String, limit: Int = 8) {
    guard let source = cnMakeSource(sourceID) else {
        print("错误：未知源 \(sourceID)；可用：\(SourceRegistry.shared.allIDs.joined(separator: " / "))")
        exit(1)
    }
    cnHR("\(source.displayName)（\(source.id)）搜索 “\(term)”")
    print("能力：\(cnCapabilityText(source.capabilities))")

    let query = TrackQuery(title: term, duration: 0)
    let started = Date()
    let result = cnRunBlocking { try await source.searchTracks(query, limit: limit) }
    let elapsed = Date().timeIntervalSince(started)

    switch result {
    case .failure(let e):
        print("搜索失败（\(String(format: "%.2f", elapsed))s）：\(e.localizedDescription)")
        exit(2)
    case .success(let candidates):
        print("命中 \(candidates.count) 条，耗时 \(String(format: "%.2f", elapsed))s")
        guard !candidates.isEmpty else { print("（空结果）"); return }

        print("")
        print(cnPad("#", 3) + cnPad("标题", 26) + cnPad("艺术家", 20) + cnPad("专辑", 24)
              + cnPad("年", 6) + cnPad("轨", 4) + cnPad("碟", 4) + cnPad("时长", 7) + "封面")
        print(String(repeating: "-", count: 100))
        for (i, c) in candidates.enumerated() {
            print(cnPad("\(i)", 3)
                  + cnPad(c.title ?? "-", 26)
                  + cnPad(c.artist ?? "-", 20)
                  + cnPad(c.album ?? "-", 24)
                  + cnPad(c.year ?? "-", 6)
                  + cnPad(c.trackNumber ?? "-", 4)
                  + cnPad(c.discNumber ?? "-", 4)
                  + cnPad(cnFmtDuration(c.durationSeconds), 7)
                  + (c.artworkURL == nil ? "无" : "有"))
        }

        // 二段式详情：验证补全逻辑
        print("")
        print("— 对第 0 条调用 fetchDetail 补全 —")
        switch cnRunBlocking({ try await source.fetchDetail(candidates[0]) }) {
        case .failure(let e): print("  详情失败：\(e.localizedDescription)")
        case .success(let d):
            print("  nativeID=\(d.nativeID) albumID=\(d.albumID ?? "-")")
            print("  标题=\(d.title ?? "-") 艺术家=\(d.artist ?? "-") 专辑=\(d.album ?? "-")")
            print("  年=\(d.year ?? "-") 轨=\(d.trackNumber ?? "-") 碟=\(d.discNumber ?? "-") 时长=\(cnFmtDuration(d.durationSeconds))")
            print("  封面URL=\(d.artworkURL?.absoluteString ?? "-")")
        }
    }
}

func cnCapabilityText(_ c: SourceCapabilities) -> String {
    var parts: [String] = []
    if c.contains(.searchTracks)      { parts.append("搜曲") }
    if c.contains(.searchAlbums)      { parts.append("搜专辑") }
    if c.contains(.artwork)           { parts.append("封面") }
    if c.contains(.lyrics)            { parts.append("歌词") }
    if c.contains(.translatedLyrics)  { parts.append("翻译歌词") }
    if c.contains(.wordByWordLyrics)  { parts.append("逐字歌词") }
    if c.contains(.authoritative)     { parts.append("权威元数据") }
    if c.contains(.requiresAPIKey)    { parts.append("需APIKey") }
    return parts.isEmpty ? "（无）" : parts.joined(separator: "、")
}

// MARK: - cnlyric

func cmdCNLyric(_ sourceID: String, _ term: String, lines: Int = 8) {
    guard let source = cnMakeSource(sourceID) else {
        print("错误：未知源 \(sourceID)"); exit(1)
    }
    cnHR("\(source.displayName)（\(source.id)）歌词 “\(term)”")

    let query = TrackQuery(title: term, duration: 0)
    let searched = cnRunBlocking { try await source.searchTracks(query, limit: 5) }
    guard case .success(let candidates) = searched, let first = candidates.first else {
        if case .failure(let e) = searched { print("搜索失败：\(e.localizedDescription)") }
        else { print("搜索为空，无法取歌词") }
        exit(2)
    }
    print("选中候选：[\(first.nativeID)] \(first.title ?? "-") — \(first.artist ?? "-")（\(first.album ?? "-")）")

    let started = Date()
    let got = cnRunBlocking { try await source.fetchLyrics(first) }
    let elapsed = Date().timeIntervalSince(started)

    switch got {
    case .failure(let e):
        print("取歌词失败（\(String(format: "%.2f", elapsed))s）：\(e.localizedDescription)")
        exit(2)
    case .success(let bundle):
        guard let b = bundle else { print("该曲目无歌词（返回 nil）"); return }
        print("耗时 \(String(format: "%.2f", elapsed))s")
        cnDumpLyric("原词 plain",      b.plain,      lines)
        cnDumpLyric("翻译 translated", b.translated, lines)
        cnDumpLyric("逐字 wordByWord", b.wordByWord, lines)
        cnDumpLyric("罗马音 romanized", b.romanized, lines)
    }
}

func cnDumpLyric(_ label: String, _ text: String?, _ lines: Int) {
    print("")
    guard let t = text, !t.isEmpty else { print("[\(label)] ✘ 无") ; return }
    let all = t.components(separatedBy: "\n")
    print("[\(label)] ✔ 有，\(t.count) 字符 / \(all.count) 行，前 \(min(lines, all.count)) 行：")
    for l in all.prefix(lines) { print("    \(l)") }
}

// MARK: - cnart

func cmdCNArtwork(_ sourceID: String, _ term: String, size: Int = 800) {
    guard let source = cnMakeSource(sourceID) else { print("错误：未知源 \(sourceID)"); exit(1) }
    cnHR("\(source.displayName)（\(source.id)）封面 “\(term)” @\(size)")

    let query = TrackQuery(title: term, duration: 0)
    guard case .success(let candidates) = cnRunBlocking({ try await source.searchTracks(query, limit: 5) }),
          let first = candidates.first else { print("搜索为空"); exit(2) }
    let detailed = (try? cnRunBlocking({ try await source.fetchDetail(first) }).get()) ?? first
    print("选中候选：[\(detailed.nativeID)] \(detailed.title ?? "-") — \(detailed.album ?? "-")")
    print("封面URL：\(detailed.artworkURL?.absoluteString ?? "-")")

    switch cnRunBlocking({ try await source.fetchArtwork(detailed, preferredSize: size) }) {
    case .failure(let e): print("取封面失败：\(e.localizedDescription)"); exit(2)
    case .success(let data):
        guard let d = data else { print("该源不提供封面（nil）"); return }
        let head = [UInt8](d.prefix(4))
        let kind: String
        if head.starts(with: [0xFF, 0xD8]) { kind = "JPEG" }
        else if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = "PNG" }
        else { kind = "未知(\(head.map { String(format: "%02X", $0) }.joined(separator: " ")))" }
        print("✔ 取到 \(d.count) 字节，格式 \(kind)")
    }
}

// MARK: - cnfallback

func cmdCNFallback(_ term: String, limit: Int = 5) {
    cnHR("降级链搜索 “\(term)”")
    let ids = SourceRegistry.shared.recommendedOrder
    print("注册表内可用源：\(SourceRegistry.shared.allIDs.joined(separator: " / "))")
    print("本次尝试顺序：\(ids.joined(separator: " → "))")

    let query = TrackQuery(title: term, duration: 0)
    let started = Date()
    let outcome = cnRunBlocking {
        await SourceRegistry.shared.searchWithFallback(query: query, sources: ids, limit: limit)
    }
    let elapsed = Date().timeIntervalSince(started)
    guard case .success(let r) = outcome else { print("内部错误"); exit(2) }

    print("")
    print("总耗时 \(String(format: "%.2f", elapsed))s，命中源 = \(r.winningSourceID ?? "无")，候选 \(r.candidates.count) 条")
    print("")
    print(cnPad("源", 16) + cnPad("结果", 10) + "说明")
    print(String(repeating: "-", count: 76))
    for a in r.attempts {
        let status: String
        switch a.outcome {
        case .succeeded(let n): status = "✔ \(n) 条"
        case .empty:            status = "空"
        case .failed:           status = "✘ 失败"
        case .skipped:          status = "跳过"
        }
        print(cnPad(a.sourceID, 16) + cnPad(status, 10) + (a.message ?? ""))
    }
    if !r.candidates.isEmpty {
        print("")
        for (i, c) in r.candidates.prefix(limit).enumerated() {
            print("  \(i). [\(c.sourceID)] \(c.title ?? "-") — \(c.artist ?? "-")（\(c.album ?? "-")）\(cnFmtDuration(c.durationSeconds))")
        }
    }
}

// MARK: - lyricdecrypt：QRC / KRC 解密自检 + 实网抽查

/// `lyricdecrypt [自检]`　`lyricdecrypt qq <搜索词>`　`lyricdecrypt kugou <搜索词>`
///
/// 两件事：
/// ① 不联网的算法自检（FIPS DES 向量 + QRC 3DES 往返 + KRC 异或/zlib 往返）；
/// ② 用真实返回的密文解出可读歌词的前 N 行 —— 「能解密」这件事只有这样才算数。
func cmdLyricDecrypt(_ sourceID: String?, _ term: String?, lines: Int = 5) {
    cnHR("歌词解密自检（lyricdecrypt）")
    let r = LyricsDecrypt.selfTest()
    for n in r.notes { print("  " + n) }
    print("  结论：" + (r.passed ? "✔ 三项全过" : "✘ 有项未过"))

    guard let sourceID, let term, !term.isEmpty else {
        if !r.passed { exit(2) }
        return
    }

    print("")
    guard let source = cnMakeSource(sourceID) else { print("错误：未知源 \(sourceID)"); exit(1) }
    cnHR("\(source.displayName) 实网抽查 “\(term)”")

    let query = TrackQuery(title: term, duration: 0)
    guard case .success(let candidates) = cnRunBlocking({ try await source.searchTracks(query, limit: 5) }),
          let first = candidates.first else { print("搜索为空"); exit(2) }
    print("选中候选：[\(first.nativeID)] \(first.title ?? "-") — \(first.artist ?? "-")"
          + "（数字ID \(first.numericID ?? "-")，专辑 \(first.album ?? "-")，\(Int(first.durationSeconds))s）")

    switch cnRunBlocking({ try await source.fetchLyrics(first) }) {
    case .failure(let e): print("取歌词失败：\(e.localizedDescription)"); exit(2)
    case .success(let bundle):
        guard let b = bundle else { print("无歌词"); exit(2) }
        cnDumpLyric("原词（密文解出）", b.plain, lines)
        cnDumpLyric("翻译（密文解出）", b.translated, lines)
        cnDumpLyric("逐字（密文解出）", b.wordByWord, lines)
        cnDumpLyric("罗马音（密文解出）", b.romanized, lines)
    }
}

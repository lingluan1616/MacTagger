//
//  SourceProbe.swift
//  mactagger-probe — 国际数据源适配器的联网验证子命令
//
//  子命令（在 main.swift 的 switch 里挂了两行 case）：
//    mactagger-probe source  <sourceID> <搜索词...>   打印候选表格
//    mactagger-probe artwork <sourceID> <搜索词...>   下载封面并报告字节数与像素尺寸
//
//  本文件所有符号都以 intl 前缀命名，避免与同目录另一份中文源 probe 冲突。
//

import Foundation
import ImageIO

// MARK: - 同步桥（main.swift 是顶层代码，不能直接 await）

private final class IntlBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func intlRunBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = IntlBox<T>()
    Task {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    switch box.result! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}

// MARK: - 源注册（本文件只登记国际源，中文源由另一份 probe 负责）

func intlMakeSource(_ rawID: String) -> MetadataSource? {
    let parts = rawID.split(separator: ":", maxSplits: 1).map(String.init)
    let key = parts[0].lowercased()
    let arg = parts.count > 1 ? parts[1] : nil

    switch key {
    case "itunes":
        // 与 App 走**同一条**构造路径：回退链由「所选地区 → HK → US 去重」生成，
        // 所以 `itunes:HK` 不会白付一发重复的 HK 请求（iTunes 是 1 秒 1 次的限速）。
        // 不给地区就用 HK（与 App 的出厂值 `SourceBootstrap.itunesCountryDefault` 一致）。
        // probe 刻意**不读** App 的 UserDefaults：自检结果必须只由命令行参数决定，
        // 不受用户当前设置影响 —— 所以这里只能跟着出厂值手动对齐。
        return ITunesSource.configured(country: arg ?? ITunesSource.Region.hongKong.rawValue)
    case "musicbrainz", "mb":
        return MusicBrainzSource()
    case "coverartarchive", "caa":
        return CoverArtArchiveSource()
    default:
        return nil
    }
}

let intlKnownSourceIDs = ["itunes[:国家码]", "musicbrainz", "coverartarchive"]

// MARK: - 排版工具（CJK 按 2 列宽计算）

func intlWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { w, u in
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return w + 2
        default:
            return w + 1
        }
    }
}

func intlPad(_ s: String?, _ width: Int) -> String {
    var text = s ?? "-"
    if text.isEmpty { text = "-" }
    // 超宽则截断
    if intlWidth(text) > width {
        var acc = ""
        for ch in text {
            if intlWidth(acc + String(ch)) > width - 1 { break }
            acc.append(ch)
        }
        text = acc + "…"
    }
    return text + String(repeating: " ", count: max(0, width - intlWidth(text)))
}

func intlDuration(_ sec: TimeInterval) -> String {
    guard sec > 0 else { return "-" }
    let total = Int(sec.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - 查询解析
//   支持 `title=... artist=... album=... dur=秒数`，其余 token 拼成文件名式自由查询。
//   有了 dur= 才能验证 MatchScorer 的时长强信号。

func intlParseQuery(_ term: String) -> TrackQuery {
    let known = ["title", "t", "artist", "a", "album", "b", "dur", "d"]

    // 先切词，再把「不带 key= 的后续词」并进上一个 key 的值里，
    // 这样 `title=Blank Space artist=Taylor Swift` 才不会被拆散。
    var buckets: [(key: String?, words: [String])] = [(nil, [])]
    for token in term.split(separator: " ").map(String.init) {
        if let eq = token.firstIndex(of: "="), eq != token.startIndex {
            let key = String(token[token.startIndex..<eq]).lowercased()
            if known.contains(key) {
                buckets.append((key, [String(token[token.index(after: eq)...])]))
                continue
            }
        }
        buckets[buckets.count - 1].words.append(token)
    }

    var q = TrackQuery()
    var free: [String] = []
    for b in buckets {
        let value = b.words.filter { !$0.isEmpty }.joined(separator: " ")
        switch b.key {
        case "title", "t":   q.title = value
        case "artist", "a":  q.artist = value
        case "album", "b":   q.album = value
        case "dur", "d":     q.duration = TimeInterval(value) ?? 0
        default:             if !value.isEmpty { free.append(value) }
        }
    }
    if !free.isEmpty { q.filename = free.joined(separator: " ") }
    return q
}

func intlDescribeQuery(_ q: TrackQuery) -> String {
    var parts: [String] = []
    if let t = q.title { parts.append("标题=\(t)") }
    if let a = q.artist { parts.append("艺术家=\(a)") }
    if let b = q.album { parts.append("专辑=\(b)") }
    if q.duration > 0 { parts.append("时长=\(intlDuration(q.duration))") }
    if let f = q.filename { parts.append("自由词=\(f)") }
    return parts.isEmpty ? "(空)" : parts.joined(separator: "  ")
}

// MARK: - iTunes 地区回退轨迹

/// 把这一次搜索里发生过的地区回退打出来。
///
/// 值得单独打一段的理由：`country=CN` 的 iTunes 商店 **HTTP 全 200 但一条不给**，
/// 只看「命中 0 条」根本分不清是「没这首歌」还是「整个商店空了」。
func intlPrintITunesFallback(_ src: MetadataSource) {
    guard src is ITunesSource else { return }
    let traces = ITunesSource.regionFallbackHistory.reversed()   // 按发生顺序读着顺
    guard !traces.isEmpty else { return }
    let fellBack = traces.filter { $0.didFallback }
    guard !fellBack.isEmpty else {
        if let t = traces.first(where: { $0.hit != nil }) {
            print("  命中地区: \(t.hit ?? "-")（首选地区直接命中，未回退）")
        }
        return
    }
    print("  回退轨迹:")
    for t in traces {
        let mark = t.didFallback ? "⚑" : "·"
        print("    \(mark) \(t.operation)：\(t.path)"
              + (t.hit.map { "  ⇒ 实际使用 \($0)" } ?? "  ⇒ 全链无结果"))
    }
    if let hit = fellBack.last?.hit {
        print("  命中地区: \(hit)（首选 \(fellBack.last?.requested ?? "-") 为 0 条，已回退）")
    }
    // 与界面/健康台账同一口径的一句话
    if let last = ITunesSource.lastRegionFallback, last.didFallback {
        let annotated = ITunesSource.annotate(
            SourceOutcome(sourceID: "itunes", status: .hits(last.steps.last?.count ?? 0)))
        print("  结果条  : \(annotated.chipLabel)")
        for line in (annotated.detail ?? "").split(separator: "\n") {
            print("            \(line)")
        }
    }
}

// MARK: - source 子命令

func intlCmdSource(_ sourceID: String, _ term: String, limit: Int = 8) {
    print()
    print("=== 数据源搜索 \(sourceID) — 「\(term)」 " + String(repeating: "=", count: 20))

    guard let src = intlMakeSource(sourceID) else {
        print("  未知源 ID：\(sourceID)")
        print("  本 probe 支持：\(intlKnownSourceIDs.joined(separator: ", "))")
        return
    }

    print("  源名称  : \(src.displayName)  (id=\(src.id))")
    print("  能力    : \(intlCapabilityList(src.capabilities).joined(separator: " "))")
    if let it = src as? ITunesSource {
        ITunesSource.resetRegionFallbackLog()      // 每次 probe 从干净台账开始，轨迹才是这一次的
        print("  地区    : 首选 \(it.region.rawValue)（\(it.region.localizedName)）"
              + "  回退链 " + (it.fallbackCountries.isEmpty
                              ? "（已关闭）" : it.fallbackCountries.joined(separator: " → ")))
    }

    let query = intlParseQuery(term)
    print("  查询    : \(intlDescribeQuery(query))")
    let started = Date()
    let candidates: [TrackCandidate]
    do {
        candidates = try intlRunBlocking { try await src.searchTracks(query, limit: limit) }
    } catch {
        print("  ✘ 搜索失败：\(error.localizedDescription)")
        intlPrintITunesFallback(src)
        return
    }
    let elapsed = Date().timeIntervalSince(started)
    print("  耗时    : \(String(format: "%.2f", elapsed)) s，命中 \(candidates.count) 条")
    intlPrintITunesFallback(src)
    print()

    guard !candidates.isEmpty else { print("  （无结果）"); return }

    let ranked = MatchScorer.rank(candidates, for: query)

    print("  " + intlPad("#", 3) + intlPad("标题", 26) + intlPad("艺术家", 18)
          + intlPad("专辑", 26) + intlPad("年份", 6) + intlPad("时长", 7)
          + intlPad("音轨", 7) + intlPad("流派", 12) + intlPad("匹配分", 8))
    print("  " + String(repeating: "-", count: 113))
    for (i, c) in ranked.enumerated() {
        print("  " + intlPad("\(i + 1)", 3) + intlPad(c.title, 26) + intlPad(c.artist, 18)
              + intlPad(c.album, 26) + intlPad(c.year, 6)
              + intlPad(intlDuration(c.durationSeconds), 7)
              + intlPad(c.trackNumber, 7) + intlPad(c.genre, 12)
              + intlPad(String(format: "%.3f", c.matchScore), 8))
    }
    print()
    print("  封面 URL（前 3 条）：")
    for c in ranked.prefix(3) {
        print("    · \(c.artworkURL?.absoluteString ?? "无")")
    }
    print()
    print("  源内主键（前 3 条）：")
    for c in ranked.prefix(3) {
        print("    · nativeID=\(c.nativeID)  albumID=\(c.albumID ?? "-")  专辑艺术家=\(c.albumArtist ?? "-")")
    }

    // 二段式详情
    if let first = ranked.first {
        print()
        print("  fetchDetail 复核第 1 条（搜索阶段 年份=\(first.year ?? "-") 音轨=\(first.trackNumber ?? "-")）：")
        do {
            let d = try intlRunBlocking { try await src.fetchDetail(first) }
            print("    标题=\(d.title ?? "-")  专辑=\(d.album ?? "-")  年份=\(d.year ?? "-")"
                  + "  音轨=\(d.trackNumber ?? "-")  碟号=\(d.discNumber ?? "-")"
                  + "  时长=\(intlDuration(d.durationSeconds))")
            if let y0 = first.year, let y1 = d.year, y0 != y1 {
                print("    ⚑ 年份被纠正：\(y0) → \(y1)（版本发行年 → 作品首发年）")
            }
        } catch {
            print("    ✘ \(error.localizedDescription)")
        }

        // MusicBrainz 独有的权威字段
        if let mb = src as? MusicBrainzSource, let rid = first.albumID {
            print()
            print("  MusicBrainz 权威字段（release \(rid)）：")
            do {
                let info = try intlRunBlocking { try await mb.fetchReleaseInfo(releaseMBID: rid) }
                print("    录音 MBID    : \(first.nativeID)")
                print("    版本 MBID    : \(info.releaseMBID)")
                print("    版本组 MBID  : \(info.releaseGroupMBID ?? "-")")
                print("    该版本发行日 : \(info.date ?? "-")    ← release.date")
                print("    作品首发日   : \(info.firstReleaseDate ?? "-")    ← release-group.first-release-date（写标签用这个）")
                print("    采用年份     : \(info.preferredYear ?? "-")")
                print("    厂牌         : \(info.labels.isEmpty ? "-" : info.labels.joined(separator: " / "))")
                print("    目录号       : \(info.catalogNumbers.isEmpty ? "-" : info.catalogNumbers.joined(separator: " / "))")
                print("    条码         : \(info.barcode ?? "-")")
                print("    国家/状态    : \(info.country ?? "-") / \(info.status ?? "-")")
                print("    介质/曲目数  : \(info.format ?? "-") / \(info.trackCount.map(String.init) ?? "-")")
                print("    CAA 有封面   : \(info.hasFrontCoverArt ? "是" : "否")")
            } catch {
                print("    ✘ \(error.localizedDescription)")
            }
        }
    }
}

func intlCapabilityList(_ c: SourceCapabilities) -> [String] {
    var out: [String] = []
    if c.contains(.searchTracks) { out.append("搜歌") }
    if c.contains(.searchAlbums) { out.append("搜专辑") }
    if c.contains(.artwork) { out.append("封面") }
    if c.contains(.lyrics) { out.append("歌词") }
    if c.contains(.translatedLyrics) { out.append("翻译歌词") }
    if c.contains(.wordByWordLyrics) { out.append("逐字歌词") }
    if c.contains(.authoritative) { out.append("权威元数据") }
    if c.contains(.requiresAPIKey) { out.append("需APIKey") }
    return out.isEmpty ? ["无"] : out
}

// MARK: - artwork 子命令

func intlCmdArtwork(_ sourceID: String, _ term: String, size: Int = 1200) {
    print()
    print("=== 封面下载 \(sourceID) — 「\(term)」 " + String(repeating: "=", count: 20))

    guard let src = intlMakeSource(sourceID) else {
        print("  未知源 ID：\(sourceID)")
        return
    }

    let query = intlParseQuery(term)
    let candidates: [TrackCandidate]
    do {
        candidates = try intlRunBlocking { try await src.searchTracks(query, limit: 5) }
    } catch {
        print("  ✘ 搜索失败：\(error.localizedDescription)")
        return
    }
    guard let best = MatchScorer.rank(candidates, for: query).first else {
        print("  （无结果，无法取封面）"); return
    }

    print("  选中候选 : \(best.title ?? "-") — \(best.artist ?? "-") / \(best.album ?? "-")")
    if let base = best.artworkURL {
        print("  原始 URL : \(base.absoluteString)")
        if src.id == "itunes" {
            let up = ITunesSource.upgradeArtworkURL(base, to: size)
            print("  提权 URL : \(up.absoluteString)")
            print("  提权生效 : \(up != base ? "是" : "否（URL 无尺寸段）")")
        }
    } else {
        print("  原始 URL : 无（该源靠 albumID 二段式取图）")
    }

    let started = Date()
    let data: Data?
    do {
        data = try intlRunBlocking { try await src.fetchArtwork(best, preferredSize: size) }
    } catch {
        print("  ✘ 下载失败：\(error.localizedDescription)")
        return
    }
    let elapsed = Date().timeIntervalSince(started)

    guard let data, !data.isEmpty else { print("  ✘ 未取到封面数据"); return }

    print("  字节数   : \(data.count) B  (\(String(format: "%.1f", Double(data.count) / 1024.0)) KB)")
    print("  耗时     : \(String(format: "%.2f", elapsed)) s")
    print("  魔数     : \(intlMagic(data))")

    if let srcImg = CGImageSourceCreateWithData(data as CFData, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(srcImg, 0, nil) as? [CFString: Any] {
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = CGImageSourceGetType(srcImg) as String? ?? "?"
        print("  像素尺寸 : \(w) × \(h)")
        print("  UTI 类型 : \(type)")
        // iTunes 的 `bb` 是等比适配：非方图时长边=请求值，短边按比例缩，故比长边
        let longSide = max(w, h)
        print(longSide >= size ? "  ✔ 长边已达请求尺寸 \(size)"
                               : "  ⚠ 长边 \(longSide) 小于请求尺寸 \(size)")
    } else {
        print("  ⚠ 无法解码为图片")
    }

    let outPath = NSTemporaryDirectory() + "mactagger-artwork-\(sourceID).jpg"
    try? data.write(to: URL(fileURLWithPath: outPath))
    print("  已落盘   : \(outPath)")
}

func intlMagic(_ d: Data) -> String {
    let b = [UInt8](d.prefix(4))
    guard b.count >= 3 else { return "?" }
    if b[0] == 0xFF && b[1] == 0xD8 { return "JPEG (FF D8)" }
    if b[0] == 0x89 && b[1] == 0x50 { return "PNG (89 50)" }
    if b[0] == 0x52 && b[1] == 0x49 { return "WEBP/RIFF" }
    return b.map { String(format: "%02X", $0) }.joined(separator: " ")
}

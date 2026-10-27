//
//  QuickFilterProbe.swift
//  mactagger-probe — 快捷筛选与「封面/歌词」列排序的模型层自检
//
//  用法：mactagger-probe quickfilter <样本音频> <封面图> [--keep]
//
//  ── 为什么是这里而不是单元测试 ──
//  `mactagger-probe` 是 `type: tool`，只编译 `Sources/Probe + Sources/TagKit`，
//  **看不见 `Sources/App`**（`FileRow` / `AppModel` / `QuickFilter` 都在 App 里）。
//  沿用 `ImportProbe` 立下的规矩：把被验证的那几条判据**原样搬过来一份**，
//  逐条标注它对应工程里的哪一段 —— 漂了就是 bug，两边对照一眼看得出。
//
//  ── 验的是什么 ──
//  1. 10 个真副本（4 有封面 6 无、3 有歌词），`quickFilters=[无封面]` → 6 行；
//  2. `[无封面, 无歌词]` 取**交集**（同时满足）而不是并集；
//  3. 待读的行在「无封面 / 无歌词」下**不命中**（标签未知 ≠ 没有），
//     只被「待读取标签」这一条捞出来；
//  4. 按封面列升序：无封面在前，且**三次打乱重排结果逐行一致**（等值兜底 → 可复现）。
//

import Foundation

// MARK: - 行（= App 的 FileRow 里参与筛选/排序的那几个字段）

/// 与 `Sources/App/Core/FileRow.swift` 的 `TagsState` 一一对应。
enum QFTagsState {
    case pending
    case loaded
    case failed

    var isLoaded: Bool { if case .loaded = self { return true }; return false }
}

/// 与 `FileRow` 同构的最小行。只留筛选与排序真正读到的那几项。
struct QFRow {
    let url: URL
    var draft: Tags
    var artworkCount: Int
    var tagsState: QFTagsState

    var fileName: String { url.lastPathComponent }
}

// MARK: - 判据（逐条对应工程源码，改一边必须改另一边）

/// = `Sources/App/Core/FileRow.swift` 的 `QuickFilter`。
enum QFFilter: String, CaseIterable {
    case noArtwork, noTitle, noAlbum, noLyrics, pendingTags

    var localizedName: String {
        switch self {
        case .noArtwork:   return "无封面"
        case .noTitle:     return "无标题"
        case .noAlbum:     return "无专辑"
        case .noLyrics:    return "无歌词"
        case .pendingTags: return "待读取标签"
        }
    }

    /// = `QuickFilter.matches(_:)`。
    func matches(_ row: QFRow) -> Bool {
        if self == .pendingTags { return !row.tagsState.isLoaded }
        // 标签未知 ≠ 没有：待读 / 读失败的行一律不命中「无 X」。
        guard row.tagsState.isLoaded else { return false }
        func blank(_ s: String?) -> Bool {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch self {
        case .noArtwork:   return row.artworkCount == 0
        case .noTitle:     return blank(row.draft.title)
        case .noAlbum:     return blank(row.draft.album)
        case .noLyrics:    return blank(row.draft.lyrics)
        case .pendingTags: return false
        }
    }
}

/// = `AppModel.matchesQuickFilters(_:)` —— 多条取**交集**。
func qfMatchesAll(_ row: QFRow, _ filters: Set<QFFilter>) -> Bool {
    guard !filters.isEmpty else { return true }
    return filters.allSatisfy { $0.matches(row) }
}

/// = `AppModel.rebuildDisplay()` 的筛选那一段。
func qfDisplayRows(_ rows: [QFRow], _ filters: Set<QFFilter>) -> [QFRow] {
    rows.filter { qfMatchesAll($0, filters) }
}

/// = `FileSortComparator`，只覆盖「封面」「歌词」两列（本轮改的就是它们）。
///
/// 三件事逐条对应工程源码：
/// · 待读行在「要标签才有值」的列上一律沉底，**不随升降序翻转**；
/// · 排序键：封面 = 张数，歌词 = 有/无（0/1）—— 升序即「缺的在前」；
/// · 等值兜底：文件名 → 完整路径，让任意两行都有确定先后。
func qfSorted(_ rows: [QFRow], column: String, reverse: Bool = false) -> [QFRow] {
    func key(_ r: QFRow) -> Double {
        column == "hasPicture"
            ? Double(r.artworkCount)
            : (((r.draft.lyrics ?? "").isEmpty) ? 0 : 1)
    }
    func tieBreak(_ a: QFRow, _ b: QFRow) -> ComparisonResult {
        let byName = a.fileName.localizedStandardCompare(b.fileName)
        guard byName == .orderedSame else { return byName }
        return a.url.path.localizedStandardCompare(b.url.path)
    }
    return rows.sorted { a, b in
        // 待读行沉底（两列都 requiresTags == true）
        let ap = !a.tagsState.isLoaded, bp = !b.tagsState.isLoaded
        if ap != bp { return bp }                       // 已读的在前
        if ap && bp { return tieBreak(a, b) == .orderedAscending }

        let ka = key(a), kb = key(b)
        if ka != kb { return reverse ? ka > kb : ka < kb }
        return tieBreak(a, b) == .orderedAscending
    }
}

// MARK: - 子命令

func cmdQuickFilter(_ samplePath: String, _ imagePath: String, args: [String]) {
    let keep = args.contains("--keep")
    let sample = URL(fileURLWithPath: samplePath)
    let image = URL(fileURLWithPath: imagePath)
    guard FileManager.default.fileExists(atPath: sample.path) else { fail("样本音频不存在：\(samplePath)") }
    guard let cover = try? Data(contentsOf: image) else { fail("封面图读不出来：\(imagePath)") }

    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-quickfilter-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { if !keep { try? FileManager.default.removeItem(at: work) } }

    hr("快捷筛选 / 封面列排序（quickfilter）")
    print("  样本   : \(sample.path)")
    print("  封面   : \(image.path)（\(cover.count) 字节）")
    print("  工作区 : \(work.path)\(keep ? "（--keep：保留）" : "（收工自动删）")")
    print("")

    // ── 造 10 个副本 ──
    // 01…04 有封面；05…10 无封面。歌词给 01 / 05 / 06（跨越有无封面两侧，
    // 这样「无封面 ∩ 无歌词」才不是「无封面」的平凡子集）。
    // 标题空：03 / 07 / 09；专辑空：09 / 10。
    let withArt: Set<Int> = [1, 2, 3, 4]
    let withLyrics: Set<Int> = [1, 5, 6]
    let noTitle: Set<Int> = [3, 7, 9]
    let noAlbum: Set<Int> = [9, 10]

    let ext = sample.pathExtension
    var urls: [URL] = []
    for i in 1...10 {
        let dst = work.appendingPathComponent(String(format: "%02d.%@", i, ext))
        do { try FileManager.default.copyItem(at: sample, to: dst) }
        catch { fail("复制失败：\(error.localizedDescription)") }

        var edit = TagEdit()
        edit.set(.title, noTitle.contains(i) ? nil : "曲目 \(i)")
        edit.set(.album, noAlbum.contains(i) ? nil : "测试专辑")
        edit.set(.artist, "测试艺术家")
        if withLyrics.contains(i) { edit.set(.lyrics, "[00:00.00] 第 \(i) 首的歌词\n[00:05.00] 第二行") }
        if withArt.contains(i) {
            edit.artworkAction = .replace([Artwork(data: cover, mimeType: "image/jpeg",
                                                   caption: "Cover", type: .frontCover)])
        }
        do { _ = try TagService.write(edit, to: dst) }
        catch { fail("写标签失败（\(dst.lastPathComponent)）：\(error.localizedDescription)") }
        urls.append(dst)
    }

    // ── 读回来上表（= 导入的直接路径：整行 .loaded）──
    var rows: [QFRow] = []
    for u in urls {
        guard let f = try? TagService.read(u) else { fail("读回失败：\(u.lastPathComponent)") }
        rows.append(QFRow(url: u, draft: f.tags,
                          artworkCount: f.tags.artworks.count, tagsState: .loaded))
    }

    print("═══ 上表（10 行，标签全部读出）═══")
    print("  行   封面  歌词  标题        专辑")
    for r in rows {
        print(String(format: "  %@   %@    %@    %-10@  %@",
                     r.fileName as NSString,
                     r.artworkCount > 0 ? "✓" : "—",
                     (r.draft.lyrics ?? "").isEmpty ? "—" : "✓",
                     (r.draft.title ?? "（空）") as NSString,
                     (r.draft.album ?? "（空）") as NSString))
    }
    print("")

    var pass = 0, failCount = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  \(ok ? "✔" : "✘") \(name)  \(detail)")
        if ok { pass += 1 } else { failCount += 1 }
    }

    // ── 1. 单条筛选 ──
    print("═══ 筛选计数 ═══")
    let noArt = qfDisplayRows(rows, [.noArtwork])
    check("[无封面] → 6 行", noArt.count == 6,
          "得到 \(noArt.count) 行：" + noArt.map(\.fileName).joined(separator: " "))

    let noLyr = qfDisplayRows(rows, [.noLyrics])
    check("[无歌词] → 7 行", noLyr.count == 7,
          "得到 \(noLyr.count) 行：" + noLyr.map(\.fileName).joined(separator: " "))

    let noTit = qfDisplayRows(rows, [.noTitle])
    check("[无标题] → 3 行", noTit.count == 3,
          "得到 \(noTit.count) 行：" + noTit.map(\.fileName).joined(separator: " "))

    let noAlb = qfDisplayRows(rows, [.noAlbum])
    check("[无专辑] → 2 行", noAlb.count == 2,
          "得到 \(noAlb.count) 行：" + noAlb.map(\.fileName).joined(separator: " "))

    // ── 2. 交集（不是并集）──
    print("")
    print("═══ 多选取交集（同时满足）═══")
    let both = qfDisplayRows(rows, [.noArtwork, .noLyrics])
    let unionCount = Set(noArt.map(\.fileName)).union(noLyr.map(\.fileName)).count
    check("[无封面, 无歌词] → 4 行（交集）", both.count == 4,
          "得到 \(both.count) 行：" + both.map(\.fileName).joined(separator: " "))
    check("确实是交集不是并集", both.count != unionCount,
          "并集会是 \(unionCount) 行（6 ∪ 7），交集是 \(both.count) 行")

    let triple = qfDisplayRows(rows, [.noArtwork, .noLyrics, .noTitle])
    check("[无封面, 无歌词, 无标题] → 2 行", triple.count == 2,
          "得到 \(triple.count) 行：" + triple.map(\.fileName).joined(separator: " "))

    // ── 3. 待读行按「未知」处理 ──
    print("")
    print("═══ 待读行不被误判成「无封面」═══")
    // 阶段一的占位行：artworkCount = 0、draft 全空，但 tagsState = .pending。
    var mixed = rows
    for i in 11...12 {
        let u = work.appendingPathComponent(String(format: "%02d.%@", i, ext))
        mixed.append(QFRow(url: u, draft: Tags(), artworkCount: 0, tagsState: .pending))
    }
    let mixedNoArt = qfDisplayRows(mixed, [.noArtwork])
    check("12 行（10 已读 + 2 待读）里 [无封面] 仍是 6 行",
          mixedNoArt.count == 6,
          "得到 \(mixedNoArt.count) 行；两条待读行"
          + (mixedNoArt.contains { !$0.tagsState.isLoaded } ? "**混进来了**" : "未混入"))
    let mixedNoTitle = qfDisplayRows(mixed, [.noTitle])
    check("[无标题] 也不吃待读行", mixedNoTitle.count == 3,
          "得到 \(mixedNoTitle.count) 行（待读行的 title 也是空的，但它是「未知」）")
    let pendingOnly = qfDisplayRows(mixed, [.pendingTags])
    check("[待读取标签] → 只有那 2 行", pendingOnly.count == 2,
          "得到 \(pendingOnly.count) 行：" + pendingOnly.map(\.fileName).joined(separator: " "))

    // ── 4. 封面列排序 ──
    print("")
    print("═══ 按「封面」列排序（升序 = 无封面在前）═══")
    let asc = qfSorted(rows, column: "hasPicture")
    let ascNames = asc.map(\.fileName)
    print("  升序：" + ascNames.joined(separator: " "))
    let firstSix = asc.prefix(6)
    check("前 6 行全是无封面", firstSix.allSatisfy { $0.artworkCount == 0 },
          "前 6：" + firstSix.map { "\($0.fileName)(\($0.artworkCount))" }.joined(separator: " "))
    check("后 4 行全是有封面", asc.suffix(4).allSatisfy { $0.artworkCount > 0 },
          "后 4：" + asc.suffix(4).map { "\($0.fileName)(\($0.artworkCount))" }.joined(separator: " "))

    // 稳定性：打乱三次重排，结果必须逐行一致。
    var stable = true
    var seen: [[String]] = []
    for _ in 0..<3 {
        let shuffled = rows.shuffled()
        let out = qfSorted(shuffled, column: "hasPicture").map(\.fileName)
        seen.append(out)
        if out != ascNames { stable = false }
    }
    check("三次打乱后重排结果一致（可复现 = 稳定）", stable,
          seen.map { $0.joined(separator: "") }.joined(separator: " | "))

    let desc = qfSorted(rows, column: "hasPicture", reverse: true)
    check("降序 = 有封面在前", desc.prefix(4).allSatisfy { $0.artworkCount > 0 },
          "降序：" + desc.map(\.fileName).joined(separator: " "))

    print("")
    print("═══ 按「歌词」列排序（升序 = 无歌词在前）═══")
    let lyrAsc = qfSorted(rows, column: "hasLyrics")
    print("  升序：" + lyrAsc.map(\.fileName).joined(separator: " "))
    check("前 7 行全是无歌词", lyrAsc.prefix(7).allSatisfy { ($0.draft.lyrics ?? "").isEmpty },
          "前 7：" + lyrAsc.prefix(7).map(\.fileName).joined(separator: " "))

    // 待读行沉底，且**不随升降序翻转**
    let mixedAsc = qfSorted(mixed, column: "hasPicture")
    let mixedDesc = qfSorted(mixed, column: "hasPicture", reverse: true)
    check("待读行在升序与降序里都沉在末尾",
          mixedAsc.suffix(2).allSatisfy { !$0.tagsState.isLoaded }
            && mixedDesc.suffix(2).allSatisfy { !$0.tagsState.isLoaded },
          "升序末两行 " + mixedAsc.suffix(2).map(\.fileName).joined(separator: " ")
          + "；降序末两行 " + mixedDesc.suffix(2).map(\.fileName).joined(separator: " "))

    print("")
    print("═══ 小结 ═══")
    print("  通过 \(pass)，失败 \(failCount)")
    if failCount > 0 { exit(1) }
}

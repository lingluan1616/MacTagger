//
//  PropagationProbe.swift
//  mactagger-probe — 「统一 / 补齐标签」子命令
//
//    mactagger-probe propagate <dir> [--overwrite] [--field album=…] [--keep]
//
//  在临时目录里造「kun」场景，跑完整链路并逐项复核：
//    ① 造夹具：11 个 sample.flac 副本，8 个写入 专辑=kun · 年份=2019 · 艺术家=蔡徐坤 · 封面，
//       3 个留空；再把其中 1 个已写好的年份故意改成 2018（模拟「有一首年份写错」）。
//    ② FieldSurvey：逐字段打印组内各值 × 计数、多数值、空值数、一致性。
//    ③ 计划：哪几个文件补哪些字段；`--overwrite` 时 2018 那个应当被纠正回 2019。
//    ④ 应用 + 回读复核 11 个文件；再跑一次计划应当是「0 个文件需要修改」。
//    ⑤ 字节口径前后对照：6 个小 FLAC 各写一张 1.5 MB 封面，
//       旧口径（只算搬动）vs 新口径（搬动 + 新写入元数据）vs 确认框文案。
//
//  全程在 `NSTemporaryDirectory()` 下的副本上做，**源目录零改动**，跑完自动删除
//  （`--keep` 保留现场）。本文件所有符号以 prop 前缀命名，避免与同目录其它 probe 冲突。
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 小工具

private func propPad(_ s: String, _ n: Int) -> String { pad(s, n) }

private func propMB(_ b: Int64) -> String { String(format: "%.2f MB", Double(b) / 1_048_576.0) }

/// 只关心字节口径的进度记录器：把 `BatchProgress` 真正报上来的 bytesTotal / bytesDone 抓下来。
/// （同目录的 `BatchProgressRecorder` 只记件数，验不了本轮要看的那两个数。）
private final class PropBytesRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bytesTotal: Int64 = 0
    private(set) var bytesDone: Int64 = 0
    private(set) var calls = 0
    func add(_ p: BatchProgress) {
        lock.lock()
        bytesTotal = max(bytesTotal, p.bytesTotal)
        bytesDone = max(bytesDone, p.bytesDone)
        calls += 1
        lock.unlock()
    }
}

/// 造一张指定边长的**噪声** JPEG。噪声不可压缩，才能稳定拿到 ~1.5 MB 的封面
/// （纯色图 JPEG 只有几 KB，测不出「大封面」这条路径）。
private func propMakeNoiseJPEG(edge: Int, quality: CGFloat) -> Data? {
    let bytesPerRow = edge * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * edge)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<pixels.count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
    }
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var image: CGImage?
    pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress,
                                  width: edge, height: edge,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        image = ctx.makeImage()
    }
    guard let cg = image else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

/// 打印一份 FieldSurvey。
private func propPrintSurvey(_ s: FieldSurvey) {
    let name = s.field.localizedName
    var line = "  " + propPad(name, 12) + propPad(s.statusText, 20)
    line += "空 " + propPad("\(s.emptyCount)/\(s.totalCount)", 8)
    print(line)
    if s.buckets.isEmpty {
        print("      （组内无任何取值）")
        return
    }
    for (i, b) in s.buckets.enumerated() {
        let tag = (i == 0) ? "★多数值" : "       "
        print("      \(tag) " + propPad("\(b.display)", 34)
              + "×\(b.count)".padding(toLength: 6, withPad: " ", startingAt: 0)
              + " 例: \(b.exampleFile.lastPathComponent)")
    }
}

// MARK: - propagate

func cmdPropagate(_ dir: String, args: [String]) {
    let overwrite = args.contains("--overwrite")
    let keep = args.contains("--keep")
    // --field album=xxx  可重复，用来覆盖某个字段的选定值（验「自定义…」那条路径）
    var overrides: [String: String] = [:]
    var i = 0
    while i < args.count {
        if args[i] == "--field", i + 1 < args.count {
            let kv = args[i + 1].split(separator: "=", maxSplits: 1)
            if kv.count == 2 { overrides[String(kv[0]).lowercased()] = String(kv[1]) }
            i += 2
        } else { i += 1 }
    }

    hr("统一 / 补齐标签（kun 场景）")

    // ---------- ① 造夹具 ----------
    let fm = FileManager.default
    let src = URL(fileURLWithPath: dir)
    var seedFile: URL?
    if src.pathExtension.lowercased() == "flac" {
        seedFile = src
    } else if let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
        seedFile = items.first { $0.lastPathComponent == "sample.flac" }
            ?? items.first { $0.pathExtension.lowercased() == "flac" }
    }
    guard let seed = seedFile, fm.fileExists(atPath: seed.path) else {
        fail("在 \(dir) 里找不到 sample.flac（或任意 .flac）")
    }

    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-propagate-\(UUID().uuidString)")
    do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
    catch { fail("建工作目录失败：\(error.localizedDescription)") }
    defer { if !keep { try? fm.removeItem(at: work) } }

    out("源文件      : \(seed.path)（只读，一个字节都不动）")
    out("工作副本目录: \(work.path)" + (keep ? "（--keep：保留现场）" : "（跑完自动删除）"))

    var urls: [URL] = []
    for n in 1...11 {
        let dst = work.appendingPathComponent(String(format: "%02d-track.flac", n))
        do { try fm.copyItem(at: seed, to: dst) } catch { fail("复制失败：\(error.localizedDescription)") }
        urls.append(dst)
    }

    // 1150² 的噪声 JPEG 稳定落在 1.5 MB 上下 —— 与任务书里「6 个小 FLAC + 1.5 MB 封面
    // ⇒ 确认框约 9 MB」那组数字对得上，字节口径的前后对照才有可比性。
    guard let coverData = propMakeNoiseJPEG(edge: 1150, quality: 0.93) else {
        fail("生成测试封面失败")
    }
    let cover = Artwork(data: coverData, mimeType: "image/jpeg", caption: "kun",
                        type: .frontCover, declaredWidth: 1150, declaredHeight: 1150)
    out("测试封面    : 1150×1150 噪声 JPEG，\(propMB(Int64(coverData.count)))")

    // 前 8 个写全套；后 3 个只写标题（模拟「从别处拷进来、标签是空的」）。
    for (idx, u) in urls.enumerated() {
        var e = TagEdit()
        e.set(.title, "第 \(idx + 1) 首")
        if idx < 8 {
            e.set(.album, "kun")
            e.set(.year, "2019")
            e.set(.artist, "蔡徐坤")
            e.set(.albumArtist, "蔡徐坤")
            e.set(.genre, "流行")
            e.artworkAction = .replace([cover])
        }
        do { _ = try TagService.write(e, to: u) }
        catch { fail("造夹具写入失败 \(u.lastPathComponent)：\(error.localizedDescription)") }
    }
    // 故意把第 3 首的年份写错成 2018
    do {
        var bad = TagEdit(); bad.set(.year, "2018")
        _ = try TagService.write(bad, to: urls[2])
    } catch { fail("写错误年份失败：\(error.localizedDescription)") }
    // 第 5 首年份写成带日期的 2019-10-15：验「2019 与 2019-10-15 归一化后算同一年」
    do {
        var dated = TagEdit(); dated.set(.year, "2019-10-15")
        _ = try TagService.write(dated, to: urls[4])
    } catch { fail("写日期年份失败：\(error.localizedDescription)") }

    out("夹具        : 11 个副本 —— 8 个有全套标签+封面（其中 03 年份错成 2018、"
        + "05 年份写成 2019-10-15），3 个（09/10/11）只有标题")

    // ---------- ② 分组 + FieldSurvey ----------
    let (files, failures) = TagService.readAll(urls)
    if !failures.isEmpty { out("  ！读取失败 \(failures.count) 个") }

    for grouping in PropagationGrouping.allCases {
        let gs = TagPropagation.groupFiles(files, by: grouping)
        out("分组「\(grouping.localizedName)」: \(gs.count) 组 — "
            + gs.map { "\($0.title)(\($0.count))" }.joined(separator: ", "))
    }

    let groups = TagPropagation.groupFiles(files, by: .folder)
    guard let group = groups.first else { fail("分组为空") }

    out()
    out("② FieldSurvey（按文件夹分组，共 \(group.count) 个文件）")
    out("  " + propPad("字段", 12) + propPad("一致性", 20) + "空值数")
    out("  " + String(repeating: "-", count: 68))
    let surveys = TagPropagation.surveyAll(group, includeArtwork: true)
    for s in surveys where !(s.isAllEmpty && !s.field.isGroupLevel) {
        propPrintSurvey(s)
    }

    // ---------- ③ 计划 ----------
    var (choices, artwork) = TagPropagation.majorityChoices(surveys)
    if !overrides.isEmpty {
        for (k, v) in overrides {
            guard let f = TagEdit.Field.allCases.first(where: { $0.rawValue.lowercased() == k
                                                                || $0.localizedName == k }) else {
                out("  ！--field \(k)=\(v)：认不出这个字段名，已忽略")
                continue
            }
            choices[f] = v
            out("  --field 覆盖：\(f.localizedName) = \(v)")
        }
    }
    let mode: PropagationMode = overwrite ? .overwriteMismatch : .fillEmptyOnly

    out()
    out("③ 计划（模式：\(mode.localizedName)）")
    out("  选定值: " + PropagationField.displayOrder.compactMap { pf -> String? in
        guard case .tag(let f) = pf, let v = choices[f] else { return nil }
        return "\(f.localizedName)=\(v)"
    }.joined(separator: " · ")
        + (artwork != nil ? " · 封面=\(TagPropagation.artworkLabel(artwork!))" : ""))

    let plan = PropagationPlan.plan(group: group, choices: choices, mode: mode, artwork: artwork)
    out("  \(plan.summary)")
    out("  " + propPad("文件", 16) + propPad("字段", 10) + "原 → 新")
    out("  " + String(repeating: "-", count: 68))
    for c in plan.changes {
        let old = c.oldValue.isEmpty ? "（空）" : c.oldValue
        let newV = c.field == .artwork ? "封面 \(c.newValue)" : c.newValue
        out("  " + propPad(c.fileName, 16) + propPad(c.field.localizedName, 10)
            + propPad(old, 24) + "→ " + newV)
    }

    // 关键判据
    let touched = Set(plan.edits.map(\.url.lastPathComponent))
    let emptyOnes = ["09-track.flac", "10-track.flac", "11-track.flac"]
    out()
    out("  判据 1：3 个空文件是否都在计划里 —— "
        + (emptyOnes.allSatisfy { touched.contains($0) } ? "✔ 是" : "✘ 否 (\(touched.sorted()))"))
    let fixed2018 = plan.changes.contains { $0.fileName == "03-track.flac" && $0.oldValue == "2018" }
    out("  判据 2：年份写错的 03 是否被纠正 —— "
        + (overwrite ? (fixed2018 ? "✔ 是（--overwrite）" : "✘ 否，但应该纠正")
                     : (fixed2018 ? "✘ 不该动它（只填空模式）" : "✔ 未动（只填空模式）")))
    let touched05 = plan.changes.contains { $0.fileName == "05-track.flac" && $0.field == .tag(.year) }
    out("  判据 3：05 的 2019-10-15 是否被当成「已经是 2019」放过 —— "
        + (touched05 ? "✘ 被改写了（归一化失效）" : "✔ 未动，日期信息保住了"))

    // ---------- ④ 应用 + 复核 ----------
    out()
    out("④ 应用并回读复核")
    let summary = runAsync { await BatchEngine.applyEdits(plan.edits, concurrency: 4, progress: nil) }
    out("  \(summary.description)")

    let (after, _) = TagService.readAll(urls)
    out("  " + propPad("文件", 16) + propPad("专辑", 8) + propPad("年份", 12)
        + propPad("艺术家", 10) + propPad("专辑艺术家", 12) + propPad("风格", 8) + "封面")
    out("  " + String(repeating: "-", count: 78))
    var albumOK = 0, yearOK = 0, artistOK = 0, aaOK = 0, genreOK = 0, coverOK = 0
    for f in after.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
        let t = f.tags
        let y = t.year ?? "—"
        if t.album == "kun" { albumOK += 1 }
        if TagPropagation.yearOf(y) == "2019" { yearOK += 1 }
        if t.artist == "蔡徐坤" { artistOK += 1 }
        if t.albumArtist == "蔡徐坤" { aaOK += 1 }
        if t.genre == "流行" { genreOK += 1 }
        if !t.artworks.isEmpty { coverOK += 1 }
        out("  " + propPad(f.url.lastPathComponent, 16) + propPad(t.album ?? "—", 8)
            + propPad(y, 12) + propPad(t.artist ?? "—", 10)
            + propPad(t.albumArtist ?? "—", 12) + propPad(t.genre ?? "—", 8)
            + (t.artworks.first.map { TagService.humanBytes(Int64($0.byteCount)) } ?? "—"))
    }
    let n = after.count
    out("  一致数 / 总数：专辑 \(albumOK)/\(n) · 年份(=2019) \(yearOK)/\(n) · 艺术家 \(artistOK)/\(n)"
        + " · 专辑艺术家 \(aaOK)/\(n) · 风格 \(genreOK)/\(n) · 封面 \(coverOK)/\(n)")
    if !overwrite {
        out("  注：只填空模式下 03 的年份仍是 2018（预期如此），所以年份一致数会是 \(n - 1)/\(n)")
    }

    // 幂等：同样的选择再跑一次
    let group2 = PropagationGroup(id: group.id, title: group.title, subtitle: group.subtitle,
                                  files: after)
    let surveys2 = TagPropagation.surveyAll(group2, includeArtwork: true)
    let (choices2, artwork2) = TagPropagation.majorityChoices(surveys2)
    let plan2 = PropagationPlan.plan(group: group2, choices: choices2, mode: mode, artwork: artwork2)
    out("  再跑一次同样的计划：\(plan2.summary) —— "
        + (plan2.isEmpty ? "✔ 幂等，不会重复写盘" : "✘ 还想再写一遍"))

    // ---------- ⑤ 字节口径前后对照 ----------
    out()
    out("⑤ 进度条字节口径：6 个小 FLAC 各写一张 \(propMB(Int64(coverData.count))) 封面")
    let six = Array(urls.prefix(6))
    // 先把封面清掉，保证这一轮是「从无到有写一张大图」——与用户遇到的场景一致。
    for u in six {
        var e = TagEdit(); e.artworkAction = .removeAll
        _ = try? TagService.write(e, to: u)
    }
    var costJobs: [(url: URL, edit: TagEdit)] = []
    for u in six {
        var e = TagEdit()
        e.artworkAction = .replace([cover])
        costJobs.append((u, e))
    }
    let padding: PaddingPolicy? = nil
    var oldCaliber: Int64 = 0, newCaliber: Int64 = 0, moved: Int64 = 0, meta: Int64 = 0
    for j in costJobs {
        let d = TagService.writeCostDetail(url: j.url, edit: j.edit, padding: padding)
        oldCaliber += d.totalMovedBytes
        newCaliber += d.totalWrittenBytes
        moved += d.rewrites ? d.audioBytes : 0
        meta += d.newMetadataBytes
    }
    let costPlan = TagService.estimatedWriteCost(costJobs, padding: padding)
    out("  确认框文案 : " + (costPlan.warningText ?? "（无整文件重写）"))
    out("  旧口径 bytesTotal（只算搬动 totalMovedBytes）: \(propMB(oldCaliber))")
    out("  新口径 bytesTotal（搬动 + 新写入 totalWrittenBytes）: \(propMB(newCaliber))")
    out("    其中 搬动音频 \(propMB(moved)) + 新写入元数据 \(propMB(meta))")

    let rec = PropBytesRecorder()
    let s5 = runAsync {
        await BatchEngine.applyEdits(costJobs, concurrency: 4) { p in rec.add(p) }
    }
    out("  进度回调实报 bytesTotal = \(propMB(rec.bytesTotal))，bytesDone = \(propMB(rec.bytesDone))"
        + "（回调 \(rec.calls) 次）")
    out("  批量结果   : \(s5.description)")
    let matchesNew = rec.bytesTotal == newCaliber
    out("  对账       : 进度条 bytesTotal " + (matchesNew ? "✔ 等于" : "✘ 不等于") + " 新口径；"
        + "旧口径只有 \(propMB(oldCaliber))，与确认框那句「写入新数据约 "
        + TagService.humanBytes(costPlan.totalNewMetadataBytes) + "」差 "
        + String(format: "%.0f", newCaliber > 0 && oldCaliber > 0
                 ? Double(newCaliber) / Double(oldCaliber) : 0) + " 倍")
}

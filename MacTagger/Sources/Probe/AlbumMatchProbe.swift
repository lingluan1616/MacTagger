//
//  AlbumMatchProbe.swift
//  mactagger-probe — 专辑模式（按文件夹匹配）验证
//
//  子命令：
//    folderctx <path>                      推断某个路径的上下文 + 跑 12 条内置用例
//    album <sourceID> "<专辑> <艺术家>"      联网打印专辑候选与曲目表
//    albummatch <dir> [--ignore-tags]      对目录跑整套专辑模式并打印全过程
//

import Foundation

// MARK: - 源注册

func amRegisterSources() {
    let reg = SourceRegistry.shared
    reg.registerChineseBuiltIns()
    reg.register(ITunesSource(countryCode: "CN"))
    reg.register(MusicBrainzSource())
    reg.register(CoverArtArchiveSource())
}

// MARK: - folderctx

func cmdFolderContext(_ path: String?) {
    hr("内置用例（\(FolderContext.probeCases.count) 条）")
    var pass = 0
    for (i, c) in FolderContext.probeCases.enumerated() {
        let (ctx, ok, diffs) = FolderContext.runProbeCase(c)
        if ok { pass += 1 }
        print("[\(i + 1)] \(ok ? "✔" : "✘") \(c.path)")
        print("     说明   : \(c.note)")
        let f = ctx.files.first
        print("     推断   : 专辑=\(fmt(ctx.album)) 艺术家=\(fmt(ctx.artist))"
              + " 年=\(fmt(ctx.year)) 碟=\((ctx.discNumber ?? f?.discNumber).map(String.init) ?? "nil")"
              + " 轨=\(f?.trackNumber.map(String.init) ?? "nil") 曲名=\(fmt(f?.title))")
        print("     艺术家来源: \(ctx.artistOrigin.rawValue)")
        for d in diffs { print("     ✘ \(d)") }
        print("")
    }
    print("═══ 用例结果：\(pass)/\(FolderContext.probeCases.count) 通过 ═══")

    guard let path, !path.isEmpty else { return }

    hr("实际路径推断：\(path)")
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        print("路径不存在（仍按纯字符串推断）")
        let ctx = FolderContext.infer(directory: url.deletingLastPathComponent(), fileURLs: [url])
        printFolderContext(ctx)
        return
    }
    if isDir.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let audio = items.filter { TagService.isSupported(url: $0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        printFolderContext(FolderContext.infer(directory: url, fileURLs: audio))
    } else {
        printFolderContext(FolderContext.infer(directory: url.deletingLastPathComponent(), fileURLs: [url]))
    }
}

func printFolderContext(_ ctx: FolderContext) {
    print("目录        : \(ctx.directory.path)")
    print("专辑目录    : \(ctx.albumDirectory.lastPathComponent)（原名「\(ctx.rawFolderName)」）")
    print("专辑        : \(fmt(ctx.album))")
    print("艺术家      : \(fmt(ctx.artist))  ← \(ctx.artistOrigin.rawValue)")
    print("年份        : \(fmt(ctx.year))")
    print("碟号        : \(ctx.discNumber.map(String.init) ?? "nil")")
    print("可用于专辑模式: \(ctx.isUsable ? "是" : "否")")
    guard !ctx.files.isEmpty else { return }
    print("--- 文件（\(ctx.files.count)）---")
    print("  " + cnPad("文件名", 34) + cnPad("轨", 5) + cnPad("碟", 4) + "曲名")
    for f in ctx.files {
        print("  " + cnPad(f.url.lastPathComponent, 34)
              + cnPad(f.trackNumber.map(String.init) ?? "-", 5)
              + cnPad(f.discNumber.map(String.init) ?? "-", 4)
              + (f.title ?? "-"))
    }
}

// MARK: - album

func cmdAlbumFetch(_ sourceID: String, _ term: String) {
    amRegisterSources()
    guard let src = SourceRegistry.shared.source(id: sourceID) ?? cnMakeSource(sourceID) else {
        print("未知源：\(sourceID)"); exit(1)
    }

    hr("专辑候选：\(src.displayName) ← 「\(term)」")

    // 与 AlbumMatchService.searchAlbumLevel 同路径：album 与 artist 必须分开传，
    // 合在一起当成 release:"魔杰座 周杰伦" 会让 MusicBrainz 精确短语匹配 0 命中。
    // 这里按最后一个空格拆「专辑 / 艺术家」（中文名里空格少，这个约定够用）。
    var albumName = term
    var artistName: String?
    if let idx = term.range(of: " ", options: .backwards) {
        albumName = String(term[..<idx.lowerBound]).trimmingCharacters(in: .whitespaces)
        artistName = String(term[idx.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    print("  拆分：专辑=「\(albumName)」 艺术家=「\(artistName ?? "-")」")
    var q = TrackQuery()
    q.filename = albumName
    q.album = albumName
    q.artist = artistName

    let outcome = cnRunBlocking { () async throws -> [TrackCandidate] in
        if let it = src as? ITunesSource { return try await it.searchAlbums(q, limit: 8) }
        if let mb = src as? MusicBrainzSource { return try await mb.searchReleases(q, limit: 8) }
        return try await src.searchTracks(q, limit: 8)
    }
    guard case .success(let cands) = outcome else {
        if case .failure(let e) = outcome { print("搜索失败：\(e.localizedDescription)") }
        exit(1)
    }

    // 按 albumID 去重成专辑候选
    var seen = Set<String>()
    var picks: [TrackCandidate] = []
    for c in cands {
        guard let aid = c.albumID, !aid.isEmpty, seen.insert(aid).inserted else { continue }
        picks.append(c)
    }
    print("  搜到 \(cands.count) 条候选，去重后 \(picks.count) 张专辑\n")

    for (i, c) in picks.prefix(4).enumerated() {
        print("─── [\(i + 1)] albumID=\(c.albumID ?? "-")  专辑=\(fmt(c.album))  艺术家=\(fmt(c.artist))")
        let r = cnRunBlocking { () async throws -> AlbumDetail? in
            try await src.fetchAlbum(c)
        }
        switch r {
        case .success(let detail?):
            print("    \(detail.summary)")
            print("    声明曲目数=\(detail.trackCount)  实际拿到=\(detail.tracks.count)  碟数=\(detail.discCount)")
            print("    封面 URL=\(detail.artworkURL?.absoluteString ?? "-")")
            for t in detail.tracks.prefix(30) {
                print("      \(cnPad("\(t.disc)-\(t.number)", 7))"
                      + cnPad(t.title, 30)
                      + cnPad(cnFmtDuration(t.durationSeconds), 8)
                      + (t.artist ?? ""))
            }
        case .success(nil):
            print("    该源未返回专辑曲目表（fetchAlbum → nil）")
        case .failure(let e):
            print("    fetchAlbum 失败：\(e.localizedDescription)")
        }
        print("")
    }
}

// MARK: - albummatch

/// 歌词的前 n 行**正文**（跳过开头那一整块「作词 : / 作曲 : / 制作人 :」署名行）。
///
/// 直接印前 4 行的话满屏都是署名，「日文行后面跟着中文译文行」这件**要验的事**
/// 一行都露不出来。正文的界线与升级判定共用 `LyricsService.lrcBodyLines`。
func amLyricPreview(_ text: String, _ n: Int) -> [String] {
    let body = LyricsService.lrcBodyLines(LrcDocument.parse(text))
    guard !body.isEmpty else {
        return text.components(separatedBy: "\n").prefix(n).map { $0 }
    }
    return body.prefix(n).map { line in
        let head = line.timestamps.first.map {
            "[" + LrcDocument.formatTimestamp($0, digits: 2) + "]"
        } ?? ""
        return head + line.text
    }
}

func cmdAlbumMatch(_ path: String, ignoreTags: Bool, sourcesCSV: String?, write: Bool = false,
                   args: [String] = []) {
    let root = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
        print("需要一个目录：\(path)"); exit(1)
    }
    amRegisterSources()

    // 递归收集
    var urls: [URL] = []
    if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in en where TagService.isSupported(url: u) { urls.append(u) }
    }
    urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    guard !urls.isEmpty else { print("目录里没有支持的音频文件"); exit(1) }

    // `--legacy`：AX 轮之前的行为（组内那几枪串行、等所有源）。压测对照组用。
    let legacy = args.contains("--legacy")
    var opts = legacy ? AlbumMatchOptions.legacy : AlbumMatchOptions.recommended
    opts.ignoreExistingTags = ignoreTags
    opts.fetchArtwork = false           // probe 不下封面，省流量、结果更快
    if let csv = sourcesCSV {
        opts.sourceIDs = csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // ★ BJ 轮：专辑模式的歌词。口径与 `automatch` 的同名参数逐字一致 ——
    // `--lyrics` 开取词，`--translation` / `--no-translation` 控合并翻译。
    if args.contains("--lyrics") { opts.fetchLyrics = true }
    if args.contains("--no-lyrics") { opts.fetchLyrics = false }
    var lyricsMerge = LyricsMergeSettings.default
    if args.contains("--translation") { lyricsMerge.includeTranslation = true }
    if args.contains("--no-translation") { lyricsMerge.includeTranslation = false }

    hr("专辑模式匹配（albummatch）")
    print("  目录     : \(root.path)")
    print("  文件     : \(urls.count) 个")
    print("  数据源   : \(opts.sourceIDs.joined(separator: " / "))")
    print("  阈值     : 专辑 \(opts.acceptThreshold) / 对齐 \(opts.alignAcceptThreshold)")
    print("  忽略现有标签: \(ignoreTags ? "是（只用文件名与文件夹）" : "否")")
    print("  调度     : " + (legacy ? "改前（组内串行、等所有源）"
                                    : "改后（组内并发 + 软截止 "
                                      + String(format: "%.0f s / 慢源 %.0f s）",
                                               opts.sourceSoftDeadline,
                                               opts.slowSourceSoftDeadline)))
    var lyricsLine = "  歌词     : " + (opts.fetchLyrics ? "开" : "关")
    if opts.fetchLyrics {
        lyricsLine += " · 翻译 " + (lyricsMerge.includeTranslation
            ? "开（\(lyricsMerge.mergeFormat)，最多 \(opts.translationSourceLimit) 源）" : "关")
        lyricsLine += " · 曲目级并发 \(opts.concurrency)"
    }
    print(lyricsLine)
    print("")

    let (files, readFailures) = TagService.readAll(urls)
    if !readFailures.isEmpty { print("  读取失败 \(readFailures.count) 个（已跳过）") }

    let groups = AlbumMatchService.groupByFolder(files)
    print("  分成 \(groups.count) 个文件夹组"
          + "，时长可信: \(groups.map { AlbumMatchService.durationsAreCredible($0.files) ? "是" : "否" }.joined(separator: "/"))")
    print("")

    let outcome = cnRunBlocking { () async -> ([AlbumMatchResult], BatchSummary) in
        await AlbumMatchService.matchAll(groups, options: opts) { p in
            FileHandle.standardError.write("  … \(p.completed)/\(p.total)\n".data(using: .utf8)!)
        }
    }
    guard case .success(let (matchedResults, summary)) = outcome else {
        print("  匹配过程异常"); exit(1)
    }
    var results = matchedResults

    for r in results {
        let title = r.folder.lastPathComponent
        print("╔══ 📁 \(title) " + String(repeating: "═", count: max(0, 50 - cnDisplayWidth(title))))
        print("║ 推断上下文 : \(r.context.summary)（艺术家来源：\(r.context.artistOrigin.rawValue)）")
        print("║")
        print("║ 专辑候选（\(r.albumCandidates.count) 张，按分降序）:")
        for (i, c) in r.albumCandidates.prefix(6).enumerated() {
            let mark = (r.chosen?.id == c.id) ? "★" : " "
            print("║  \(mark)[\(i + 1)] " + String(format: "%.3f", c.score)
                  + "  " + c.detail.summary
                  + "  源=\(c.detail.sourceID)"
                  + "  对齐 \(c.alignedCount)/\(c.fileCount)"
                  + "  共识 \(c.consensusHits)"
                  + "  id=\(c.id)")
            print("║        明细: " + c.breakdown.map(\.display).joined(separator: "  "))
            for n in c.notes { print("║        · \(n)") }
        }
        if r.albumCandidates.isEmpty { print("║   （无）") }
        print("║")

        if let chosen = r.chosen {
            print("║ 选中 : 《\(chosen.detail.displayTitle)》— \(chosen.detail.artist ?? "-")"
                  + "  \(chosen.detail.year ?? "-")  源=\(chosen.detail.sourceID)"
                  + "  分=" + String(format: "%.3f", chosen.score)
                  + "  id=\(chosen.id)")
            if let d = chosen.meanDurationDelta {
                print("║        平均时长差 " + String(format: "%.1f", d) + " 秒")
            }
        } else {
            print("║ 选中 : 无 —— \(r.ignoredReason ?? "未知原因")")
        }
        print("║")
        print("║ 逐文件对齐:")
        print("║   " + cnPad("文件名", 30) + cnPad("状态", 8) + cnPad("轨", 8)
              + cnPad("标题", 26) + "分/理由")
        for f in r.perFile {
            let name = f.url.lastPathComponent
            let st = f.status == .matched ? "✔ 对齐" : "○ 忽略"
            let no = f.best?.trackNumber ?? "-"
            let ti = f.best?.title ?? "-"
            let tail = f.status == .matched
                ? String(format: "%.2f", f.best?.matchScore ?? 0)
                : (f.errors.first?.message ?? "")
            print("║   " + cnPad(name, 30) + cnPad(st, 8) + cnPad(no, 8) + cnPad(ti, 26) + tail)
        }
        print("║")

        // ★ BJ 轮：取词结果。没有这一段就只能看写盘后的文件来判断「到底取到没有」。
        if opts.fetchLyrics {
            print("║ 歌词:")
            for f in r.perFile where f.status == .matched {
                let name = f.url.lastPathComponent
                guard let b = f.lyrics, !b.isEmpty else {
                    print("║   ✘ " + cnPad(name, 30) + "没取到")
                    continue
                }
                print("║   ✔ " + cnPad(name, 30)
                      + (b.hasTranslation ? "含翻译" : "仅原文")
                      + "  源=\(b.sourceID)"
                      + String(format: "  取词 %.1f s", f.lyricsLatency)
                      + (f.translationRounds > 0
                         ? String(format: "（补查轮 %.1f s）", f.translationLatency) : ""))
                let merged = lyricsMerge.merged(b) ?? ""
                for l in amLyricPreview(merged, 4) { print("║       | " + l) }
            }
            print("║")
        }
        print("║ 对齐率 : \(r.alignedCount)/\(r.fileCount)  = "
              + String(format: "%.0f%%", r.alignmentRate * 100))
        for e in r.errors.prefix(6) { print("║ ⚠ \(e.sourceID): \(e.message)") }
        print("╚" + String(repeating: "═", count: 58))
        print("")
    }

    // ── 按文件选写哪几个字段（复核表勾选的数据层等价物）──
    // 与逐首模式同一套参数：`--exclude-fields` 整轮，`--exclude-file N:field` 单个文件。
    // 单个文件的下标按**整轮所有已对齐文件的顺序**数（1 起），与下面写入表的顺序一致。
    let amGlobalExcluded = probeFieldList(args, "--exclude-fields")
    let amPerFileExcluded = probeExcludeFileMap(args)
    if !amGlobalExcluded.isEmpty || !amPerFileExcluded.isEmpty {
        print("")
        print("═══ 字段排除 ═══")
        if !amGlobalExcluded.isEmpty {
            print("  整轮排除 : " + amGlobalExcluded.map(\.localizedName).joined(separator: "、"))
        }
        for (idx, fs) in amPerFileExcluded.sorted(by: { $0.key < $1.key }) {
            print("  第 \(idx) 个已对齐文件另外排除 : " + fs.map(\.localizedName).joined(separator: "、"))
        }
        var seq = 0
        for gi in results.indices {
            for fi in results[gi].perFile.indices where results[gi].perFile[fi].status == .matched {
                seq += 1
                var excluded = amGlobalExcluded
                if let extra = amPerFileExcluded[seq] { excluded.formUnion(extra) }
                results[gi].perFile[fi].acceptedFields.subtract(excluded)
                let name = results[gi].perFile[fi].url.lastPathComponent
                let ex = results[gi].perFile[fi].excludedFields
                print("  [\(seq)] \(name) → 排除 "
                      + (ex.isEmpty ? "（无）"
                         : TagEdit.Field.allCases.filter { ex.contains($0) }
                             .map(\.localizedName).joined(separator: "、")))
            }
        }
    }

    print("")
    print("═══ 统计 ═══")
    print("  \(summary.description)")
    let total = results.reduce(0) { $0 + $1.fileCount }
    let aligned = results.reduce(0) { $0 + $1.alignedCount }
    print("  总对齐率: \(aligned)/\(total) = "
          + String(format: "%.1f%%", total > 0 ? Double(aligned) / Double(total) * 100 : 0))
    // BD 轮：与 automatch 同一张分桶表，好把「专辑模式」与「逐首模式」并排比。
    printOutcomeBuckets(results.map(\.sourceOutcomes),
                        tag: probeStringArg(args, "--tag") ?? "albummatch")

    // ★ BJ 轮分阶段耗时。口径与逐首模式共用 `StageTimings.summaryLine`，
    // 「慢」因此说得出慢在哪一段（专辑模式接上取词后这里会多出「歌词 y s」）。
    print("")
    hr("分阶段耗时")
    print("  " + summary.stages.summaryLine)
    if let c = summary.stages.concurrencyLine { print("  " + c) }

    // 可选：把结果真的写进文件。
    // 走的是 `BatchEngine.applyEdits` —— 与界面「应用选中项」**完全同一条路径**
    // （AppModel+AutoMatch.performAutoMatchWrite 里也是这一句），
    // 只是没有 AppModel 那层历史快照（probe 用副本跑，不需要撤销）。
    if write {
        // ★ BJ 轮：`--copies` —— 先复制到临时工作区再写，源目录一个字节都不碰
        // （口径同 `automatch --write`）。不给这个参数时保持原地写的老行为。
        let useCopies = args.contains("--copies")
        let keepCopies = args.contains("--keep")
        var work: URL?
        var dstOf: [URL: URL] = [:]
        if useCopies {
            let w = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mactagger-albummatch-write-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            work = w
            print("")
            print("  工作区 : \(w.path)\(keepCopies ? "（--keep：保留）" : "（收工自动删）")")
        }

        // **只排入勾中的字段**（`acceptedEdit`）—— 与界面「应用选中项」同一口径：
        // 复核表上划掉的那几枚 chip，在这里就是不进 payload 的那几个字段。
        var payload: [(url: URL, edit: TagEdit)] = []
        var before: [URL: Tags] = [:]
        // ★ BJ 轮：歌词是二段式单独取回来的，**不在 `edit.changes` 里**
        // （`acceptedEdit` 只管字段 + 封面）。App 那边由 `makeAlbumReviewItem` 在组装时
        // 把合并好的词并进改动表，probe 这里要原样照做一遍，
        // 否则「专辑模式写入后有没有译文」根本验不到。
        var mergedLyrics: [URL: String] = [:]
        var bundleOf: [URL: LyricsBundle] = [:]
        for r in results {
            for f in r.perFile where f.status == .matched {
                guard var e = f.acceptedEdit, !e.changes.isEmpty || f.lyrics != nil else { continue }
                var target = f.url
                if let w = work {
                    target = w.appendingPathComponent(f.url.lastPathComponent)
                    do { try FileManager.default.copyItem(at: f.url, to: target) }
                    catch {
                        print("  ✘ 复制失败 \(f.url.lastPathComponent)：\(error.localizedDescription)")
                        continue
                    }
                    dstOf[f.url] = target
                }
                if opts.fetchLyrics,
                   let text = lyricsMerge.merged(f.lyrics)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    e.set(.lyrics, text)
                    mergedLyrics[target] = text
                    if let b = f.lyrics { bundleOf[target] = b }
                }
                guard !e.changes.isEmpty else { continue }
                before[target] = (try? TagService.read(target))?.tags ?? Tags()
                payload.append((target, e))
            }
        }
        func dst(_ u: URL) -> URL { dstOf[u] ?? u }
        print("")
        print("═══ 写入（\(payload.count) 个文件）═══")
        let wr = cnRunBlocking { () async -> BatchSummary in
            await BatchEngine.applyEdits(payload,
                                         concurrency: BatchEngine.recommendedConcurrency(for: payload.map(\.url)),
                                         progress: nil)
        }
        if case .success(let sum) = wr { print("  \(sum.description)") }
        else { print("  写入异常") }

        // 被排除的字段必须还是写入前那个值。这一段就是「证明没写」的地方 ——
        // 只看落盘复核表是看不出「本该改却没改」的。
        if !amGlobalExcluded.isEmpty || !amPerFileExcluded.isEmpty {
            print("")
            print("═══ 排除字段对账（应保持写入前的原值）═══")
            var ok = 0, bad = 0
            for r in results {
                for f in r.perFile where f.status == .matched {
                    let excluded = f.excludedFields
                    guard !excluded.isEmpty, let old = before[dst(f.url)],
                          let after = (try? TagService.read(dst(f.url)))?.tags else { continue }
                    for field in TagEdit.Field.allCases where excluded.contains(field) {
                        let want = (f.edit?.changes.first { $0.field == field }?.value) ?? ""
                        let wasV = amTagValue(field, old)
                        let nowV = amTagValue(field, after)
                        let good = nowV == wasV
                        print("  \(good ? "✔" : "✘") \(f.url.lastPathComponent) 的\(field.localizedName)"
                              + "：仍是「\(nowV.isEmpty ? "（空）" : nowV)」"
                              + "（新值本应是「\(want)」）")
                        good ? (ok += 1) : (bad += 1)
                    }
                }
            }
            print("  排除对账：通过 \(ok)，失败 \(bad)")
        }

        print("")
        print("═══ 落盘复核（重新读文件）═══")
        print("  " + cnPad("文件名", 30) + cnPad("专辑", 26) + cnPad("艺术家", 12)
              + cnPad("年", 6) + cnPad("音轨", 8) + "标题")
        for (u, _) in payload {
            guard let back = try? TagService.read(u) else { print("  读取失败 \(u.lastPathComponent)"); continue }
            let t = back.tags
            print("  " + cnPad(u.lastPathComponent, 30)
                  + cnPad(t.album ?? "-", 26)
                  + cnPad(t.albumArtist ?? t.artist ?? "-", 12)
                  + cnPad(t.year ?? "-", 6)
                  + cnPad(t.trackString ?? "-", 8)
                  + (t.title ?? "-"))
        }

        // ★ BJ 轮：.lrc 落盘 —— 与 App 的「歌词文件选项」同一个执行器，
        // 好顺带验 `head` 出来那份也带译文。
        if !mergedLyrics.isEmpty {
            var fileOpts = LyricsFileOptions()
            fileOpts.enabled = true
            fileOpts.overwriteExisting = true
            var jobs: [LyricsFileJob] = []
            for (u, text) in mergedLyrics {
                guard let f = try? TagService.read(u) else { continue }
                jobs.append(LyricsFileJob(file: f, text: text, bundle: bundleOf[u]))
            }
            let (writtenFiles, _, _) = LyricsService.saveLyricsFiles(jobs, options: fileOpts)
            print("")
            print("  .lrc   : 写出 \(writtenFiles.count) 个")
        }

        // ★ BJ 轮：歌词落盘复核 —— 「三首都必须出现日文行后跟中文译文行」验在这里。
        // 只看标签表是看不出这件事的（LYRICS 不在那张表里）。
        if opts.fetchLyrics {
            print("")
            print("═══ 歌词落盘复核（重新读文件的 LYRICS 字段）═══")
            var withTrans = 0, withText = 0
            for (u, _) in payload.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
                let name = u.lastPathComponent
                guard let back = try? TagService.read(u),
                      let text = back.tags.lyrics, !text.isEmpty else {
                    print("  ✘ \(name)：LYRICS 为空")
                    continue
                }
                withText += 1
                // 「相邻两行同一时间戳」= 两行式译文的形状，与升级判定同一把尺子。
                let hasTrans = LyricsService.lrcContainsTranslationLines(LrcDocument.parse(text))
                if hasTrans { withTrans += 1 }
                print("  \(hasTrans ? "✔" : "✘") \(name)：\(hasTrans ? "含译文行" : "只有原文")"
                      + "（共 \(text.components(separatedBy: "\n").count) 行）")
                for l in amLyricPreview(text, 4) { print("      | " + l) }
            }
            print("  歌词复核：\(withText)/\(payload.count) 首有词，\(withTrans)/\(payload.count) 首含译文")
        }

        if let w = work, !keepCopies { try? FileManager.default.removeItem(at: w) }
    }

    // 翻唱 / Live 体检：写入的专辑名里一旦出现版本标记就是事故
    var suspicious: [String] = []
    for r in results {
        for f in r.perFile where f.status == .matched {
            let album = f.best?.album ?? ""
            let title = f.best?.title ?? ""
            if AlbumMatchService.hasVersionMarker(album) || AlbumMatchService.hasVersionMarker(title) {
                suspicious.append("\(f.url.lastPathComponent) → 《\(album)》/\(title)")
            }
        }
    }
    print("  翻唱/Live 体检: " + (suspicious.isEmpty
        ? "✔ 没有任何一首被匹配成 Live/Remix/翻唱版本"
        : "✘ \(suspicious.count) 首可疑 —— " + suspicious.joined(separator: "; ")))
}

// MARK: - 逐首模式对照（同一批文件，用于并列命中表）

func cmdAlbumCompare(_ path: String) {
    let root = URL(fileURLWithPath: path)
    amRegisterSources()
    var urls: [URL] = []
    if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in en where TagService.isSupported(url: u) { urls.append(u) }
    }
    urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    guard !urls.isEmpty else { print("目录里没有支持的音频文件"); exit(1) }

    let (files, _) = TagService.readAll(urls)

    hr("逐首模式对照（同一批文件）")
    var opts = AutoMatchOptions.recommended
    opts.fetchArtwork = false
    opts.concurrency = 2
    let outcome = cnRunBlocking { () async -> ([AutoMatchResult], BatchSummary) in
        await AutoMatchService.matchAll(files, options: opts) { p in
            FileHandle.standardError.write("  … \(p.completed)/\(p.total)\n".data(using: .utf8)!)
        }
    }
    guard case .success(let (results, summary)) = outcome else { print("异常"); exit(1) }

    print("  " + cnPad("文件名", 30) + cnPad("状态", 8) + cnPad("专辑", 28)
          + cnPad("标题", 22) + "分")
    var live = 0
    for r in results.sorted(by: { $0.url.path < $1.url.path }) {
        let st = r.status == .matched ? "✔" : "○"
        let album = r.best?.album ?? "-"
        let title = r.best?.title ?? "-"
        if r.status == .matched,
           AlbumMatchService.hasVersionMarker(album) || AlbumMatchService.hasVersionMarker(title) {
            live += 1
        }
        print("  " + cnPad(r.url.lastPathComponent, 30) + cnPad(st, 8)
              + cnPad(album, 28) + cnPad(title, 22)
              + String(format: "%.3f", r.best?.matchScore ?? 0))
    }
    print("")
    print("  \(summary.description)")
    print("  逐首模式里被匹配成 Live/Remix/翻唱的：\(live) 首")
}

// MARK: - 双碟对齐离线自检（albumdisc）
//
// 为什么要离线：线上源给回的《千と千尋》是**单碟 21 首**版，
// 真正的双碟形态（两张碟各有自己的第 7 首）在联网跑里根本复现不出来。
// 这里用一张合成的双碟曲目表把那个场景钉死，验证两件事：
//   ① 对齐必须一对一 —— 两个文件绝不能落到同一首曲目上；
//   ② 碟号得真的起作用 —— `1-07` 去第 1 碟、`2-07` 去第 2 碟。
// 顺带按界面的口径把音轨列打印出来（`碟-轨/该碟总数`），
// 好和复核窗的渲染图对账。

// MARK: - albumtie：专辑候选同分确定性（BP-E，离线）
//
// BJ 实跑 `米津玄師/Lemon` 第二次换了胜者、少对齐一首。这里离线复现两种抖动源，
// 并断言 `AlbumCandidate.isBetter` 在任何洗牌 / 加分求和顺序下都选同一张：
//  ① 分数浮点噪声：同一组加分换个顺序求和，Double 可以差 1e-16，旧谓词 `a.score != b.score`
//    就把「同分」判成「不同分」，平局判据一条都用不上；
//  ② 入池顺序：各源并发返回，候选数组的顺序每次都不一样。
// 旧谓词（BP-E 之前那一版）原样抄在下面做对照。

/// BP-E 之前的 `isBetter`，只给 albumtie 做对照。
private func legacyAlbumIsBetter(_ a: AlbumCandidate, _ b: AlbumCandidate) -> Bool {
    if a.score != b.score { return a.score > b.score }
    if a.alignedCount != b.alignedCount { return a.alignedCount > b.alignedCount }
    if a.consensusHits != b.consensusHits { return a.consensusHits > b.consensusHits }
    if a.detail.tracks.count != b.detail.tracks.count {
        return a.detail.tracks.count > b.detail.tracks.count
    }
    return a.id < b.id
}

func cmdAlbumTie() {
    hr("专辑候选同分确定性（albumtie，离线）")
    var ok = 0, bad = 0
    func check(_ cond: Bool, _ what: String, _ detail: String = "") {
        if cond { ok += 1 } else { bad += 1 }
        print("  \(cond ? "✔" : "✘") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
    func detail(_ src: String, _ id: String, _ title: String) -> AlbumDetail {
        AlbumDetail(sourceID: src, albumID: id, title: title, artist: "米津玄師", year: "2018",
                    trackCount: 3, tracks: (1...3).map { AlbumTrack(number: $0, title: "t\($0)") })
    }
    // 一组加分（名称 / 艺术家 / 年份 / 曲目数 / 共识），换顺序求和。
    let parts: [Double] = [0.41, 0.23, 0.17, 0.07, 0.03, 0.02]
    var rng = SystemRandomNumberGenerator()
    func noisy() -> Double { parts.shuffled(using: &rng).reduce(0, +) }
    let kinds = Set((0..<400).map { _ in noisy() })
    print("  同一组加分换顺序求和，得到 \(kinds.count) 种不同的 Double："
          + kinds.sorted().map { String(format: "%.17g", $0) }.joined(separator: " / "))

    func cand(_ src: String, _ id: String, aligned: Int) -> AlbumCandidate {
        AlbumCandidate(detail: detail(src, id, "Lemon"), score: noisy(), consensusHits: 2,
                       breakdown: [], alignedCount: aligned, fileCount: 3,
                       meanDurationDelta: nil, notes: [])
    }
    func pool() -> [AlbumCandidate] {
        // qq 那张同分但少对齐一首 —— BJ 第二次运行选中的就是这一类
        [cand("netease", "n-1", aligned: 3), cand("itunes", "i-1", aligned: 3),
         cand("musicbrainz", "m-1", aligned: 3), cand("qq", "q-1", aligned: 2)].shuffled(using: &rng)
    }

    var newWin: [String: Int] = [:], oldWin: [String: Int] = [:]
    for _ in 0..<500 {
        let p = pool()
        newWin[p.sorted(by: AlbumCandidate.isBetter).first!.id, default: 0] += 1
        oldWin[p.sorted(by: legacyAlbumIsBetter).first!.id, default: 0] += 1
    }
    func show(_ d: [String: Int]) -> String {
        d.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
    print("  500 轮（每轮重新求和 + 洗牌）胜者分布：旧谓词 \(show(oldWin))；新谓词 \(show(newWin))")
    print("  （旧谓词出现 \(oldWin.count) 种胜者"
          + (oldWin.keys.contains("qq:q-1") ? "，其中含少对齐一首的 qq:q-1" : "") + "）")
    check(newWin.count == 1 && newWin["itunes:i-1"] == 500,
          "新谓词：500 轮胜者恒为 itunes:i-1（同分同对齐同共识 → 源优先级）")

    // 同源同分同对齐：按专辑名定
    let a = AlbumCandidate(detail: detail("netease", "n-9", "Lemon"), score: 0.9, consensusHits: 1,
                           breakdown: [], alignedCount: 3, fileCount: 3, meanDurationDelta: nil, notes: [])
    var b = a
    b.detail = detail("netease", "n-2", "Lemon (Deluxe)")
    check(AlbumCandidate.isBetter(a, b) && !AlbumCandidate.isBetter(b, a),
          "同源同分同对齐：按专辑名（「Lemon」先于「Lemon (Deluxe)」，与 id 字典序相反也不受影响）")
    // 真分差（> 1e-6）照旧按分，不被后面的判据翻盘
    var hi = a
    hi.detail = detail("qq", "q-9", "Lemon"); hi.score = 0.9 + 1e-4; hi.alignedCount = 2
    check(AlbumCandidate.isBetter(hi, a), "真分差 1e-4 仍按分（高分的 qq 胜过对齐更多的 netease）")
    // 严格弱序：非自反、非对称
    let all = pool() + [a, b, hi]
    var strict = true
    for x in all {
        if AlbumCandidate.isBetter(x, x) { strict = false }
        for y in all where AlbumCandidate.isBetter(x, y) && AlbumCandidate.isBetter(y, x) { strict = false }
    }
    check(strict, "isBetter 是严格弱序（非自反、非对称），可安全交给 sort(by:)")
    print("\n  albumtie：\(ok) 项通过，\(bad) 项失败")
    if bad > 0 { exit(1) }
}

func cmdAlbumDisc() {
    let disc1 = 24, disc2 = 21
    let d1Titles = ["ひとりぼっちはやめた", "あの夏へ", "とおり道", "誰もいない料理店",
                    "夜来る", "竜の少年", "神さま達"]
    let d2Titles = ["湯婆婆", "小さなドラマ", "底なし穴", "6番目の駅", "ふたたび"]

    var tracks: [AlbumTrack] = []
    for n in 1...disc1 {
        tracks.append(AlbumTrack(number: n, disc: 1,
                                 title: n <= d1Titles.count ? d1Titles[n - 1] : "Disc1 Cue \(n)"))
    }
    for n in 1...disc2 {
        // 让第 2 碟的第 7、8 首正好是我们要找的那两首
        let t: String
        switch n {
        case 7:  t = "底なし穴"
        case 8:  t = "6番目の駅"
        case 9:  t = "ふたたび"
        default: t = n <= 3 ? d2Titles[n - 1] : "Disc2 Cue \(n)"
        }
        tracks.append(AlbumTrack(number: n, disc: 2, title: t))
    }
    // 第 1 碟也放一首「第 7 首」，与第 2 碟第 7 首同号不同曲——这正是会撞车的地方
    let detail = AlbumDetail(sourceID: "probe", albumID: "2disc",
                             title: "千と千尋の神隠し サウンドトラック",
                             artist: "久石譲", year: "2001",
                             trackCount: disc1 + disc2, discCount: 2, tracks: tracks)

    let dir = URL(fileURLWithPath: "/x/久石譲/千与千寻 サウンドトラック")
    // 关键用例：`1-07` 与 `2-07` 各自去自己那张碟的第 7 首。
    // 这正是用户实测里两行都显示「7/45」、根本分不清谁是谁的那一幕。
    let names = ["1-06 竜の少年.flac", "1-07 神さま達.flac",
                 "2-07 底なし穴.flac", "2-08 6番目の駅.flac", "2-09 ふたたび.flac"]
    let urls = names.map { dir.appendingPathComponent($0) }
    let files = urls.map {
        AudioFile(url: $0, tags: Tags(), technical: AudioTechnicalInfo())
    }
    let ctx = FolderContext.infer(directory: dir, fileURLs: urls)
    let group = FolderGroup(directory: dir, context: ctx, files: files)

    var opts = AlbumMatchOptions.recommended
    opts.ignoreExistingTags = true

    hr("双碟对齐自检（albumdisc）")
    print("  合成专辑 : \(detail.summary)  碟数 \(detail.discCount)"
          + "（碟1 \(disc1) 首 / 碟2 \(disc2) 首）")
    print("  文件     : \(names.count) 个，文件名带「碟-轨」")
    print("")

    let outcome = AlbumMatchService.align(group: group, context: ctx, detail: detail,
                                          durationsCredible: false, options: opts)

    // 每碟曲目数：界面就是这么数出「该碟总数」的
    let perDisc = Dictionary(grouping: detail.tracks, by: \.disc).mapValues(\.count)

    print("  文件名                     对到      音轨列显示    分     理由")
    var seen: [String: String] = [:]          // "disc-number" → 文件名
    var dup = 0
    for p in outcome.pairs {
        let name = p.fileURL.lastPathComponent
        guard let t = p.track else {
            print("  " + name.padded(26) + "（未对齐）")
            continue
        }
        let key = "\(t.disc)-\(t.number)"
        if let prev = seen[key] {
            dup += 1
            print("  ⛔ 重复占位：\(name) 与 \(prev) 都对到 \(key)")
        }
        seen[key] = name
        let total = perDisc[t.disc] ?? detail.tracks.count
        let shown = detail.discCount > 1
            ? "\(t.disc)-" + String(format: "%02d", t.number) + "/\(total)"
            : String(format: "%02d", t.number) + "/\(total)"
        // 数据层实际写入 TRACKNUMBER 的值，供对照
        let written = detail.candidate(for: t).trackNumber ?? "-"
        print("  " + name.padded(26) + (t.title).padded(10)
              + shown.padded(14) + String(format: "%.2f", p.score) + "   " + p.reason)
        print("      写入 TRACKNUMBER = \(written)   DISCNUMBER = "
              + (detail.candidate(for: t).discNumber ?? "-"))
    }
    print("")
    print("  对齐 \(outcome.alignedCount)/\(outcome.fileCount)")
    print(dup == 0 ? "  ✔ 一对一：没有任何两个文件落到同一首曲目"
                   : "  ⛔ 出现 \(dup) 处重复占位")
    let d1 = outcome.pairs.compactMap(\.track).filter { $0.disc == 1 }.count
    let d2 = outcome.pairs.compactMap(\.track).filter { $0.disc == 2 }.count
    print("  碟别分布：碟1 \(d1) 首 / 碟2 \(d2) 首"
          + (d1 == 2 && d2 == 3 ? "  ✔ 与文件名一致" : "  ⛔ 与文件名不一致"))
}

private extension String {
    /// 按显示宽度补空格（中日文按 2 格算），让上面那张表对得齐。
    func padded(_ w: Int) -> String {
        let width = reduce(0) { $0 + (($1.unicodeScalars.first?.value ?? 0) > 0x2000 ? 2 : 1) }
        return self + String(repeating: " ", count: max(1, w - width))
    }
}


/// 取某字段在一份标签里的当前值。= `AppModel.tagValue(_:in:)`。
func amTagValue(_ field: TagEdit.Field, _ tags: Tags) -> String {
    switch field {
    case .title:       return tags.title ?? ""
    case .artist:      return tags.artist ?? ""
    case .albumArtist: return tags.albumArtist ?? ""
    case .album:       return tags.album ?? ""
    case .year:        return tags.year ?? ""
    case .track:       return tags.trackString ?? ""
    case .disc:        return tags.discString ?? ""
    case .genre:       return tags.genre ?? ""
    case .comment:     return tags.comment ?? ""
    case .composer:    return tags.composer ?? ""
    case .lyricist:    return tags.lyricist ?? ""
    case .lyrics:      return tags.lyrics ?? ""
    }
}

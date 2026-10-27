//
//  LyricsProbe.swift
//  mactagger-probe — 歌词模块验证
//
//    lrc ops <file>          五种变换前后对比
//    lyric merge <搜索词>     联网取带翻译的歌，四种格式各渲染一遍
//

import Foundation
import CryptoKit   // lyric batch-file-demo 的音频 sha256

// MARK: - lrc ops

func cmdLrcOps(_ path: String) {
    let raw: String
    if path.lowercased().hasSuffix(".lrc") {
        guard let s = try? LyricsService.importLrc(from: URL(fileURLWithPath: path)) else {
            print("读取失败"); return
        }
        raw = s
    } else if let f = try? TagService.read(URL(fileURLWithPath: path)), let l = f.tags.lyrics {
        raw = l
    } else {
        // 没有素材就用内置样例，顺带测畸形输入容错
        raw = """
        [ti:测试歌曲]
        [ar:测试歌手]
        [00:00.000]第一行
        [00:12.345]第二行
        [00:18.50]
        [00:24:60]冒号分隔毫秒
        [00:30.00][01:05.00]重复副歌
        没有时间戳的行
        """
    }

    hr("LRC 五种变换")
    let doc = LrcDocument.parse(raw)
    print("  解析: 头部标签 \(doc.headerTags.count) 条，歌词 \(doc.lines.count) 行")
    print("")
    print("【原始】")
    print(indent(doc.render(millisecondDigits: 3)))

    let ops: [(String, LrcDocument)] = [
        ("删除时间轴", doc.removingTimestamps()),
        ("格式化时间轴（三位→二位）", doc.formattingTimestamps()),
        ("删除空白文字的行", doc.removingBlankLines()),
        ("删除头部标签", doc.removingHeaderTags()),
        ("调整时间轴 +2.0 秒", doc.shiftingTime(by: 2.0)),
        ("调整时间轴 -5.0 秒（钳到 0）", doc.shiftingTime(by: -5.0)),
    ]
    for (name, d) in ops {
        print("")
        print("【\(name)】")
        print(indent(d.render(millisecondDigits: 2)))
    }
}

private func indent(_ s: String) -> String {
    s.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
}

// MARK: - lyric merge

func cmdLyricMerge(_ term: String) {
    hr("翻译合并四格式 — 「\(term)」")

    guard let src = SourceRegistry.shared.source(id: "netease") else {
        print("网易云源未注册"); return
    }
    var q = TrackQuery()
    q.filename = term

    let outcome = cnRunBlocking { () async throws -> (TrackCandidate, LyricsBundle)? in
        let cands = try await src.searchTracks(q, limit: 8)
        for c in cands {
            if LyricsService.isInstrumental(c.title) { continue }
            if let b = try await src.fetchLyrics(c), b.translated?.isEmpty == false {
                return (c, b)
            }
        }
        return nil
    }

    guard case .success(let hit) = outcome, let (cand, bundle) = hit else {
        print("  没找到带翻译的候选（中文原创歌通常没有翻译词，换首日文/英文歌试试）")
        return
    }

    print("  选中: 《\(cand.title ?? "-")》— \(cand.artist ?? "-")   来源=网易云")
    print("  原词 \(bundle.plain?.count ?? 0) 字符 / 翻译 \(bundle.translated?.count ?? 0) 字符 / 逐字 \(bundle.wordByWord?.isEmpty == false ? "有" : "无")")
    print("")

    for fmt in TranslationMergeFormat.allCases {
        let merged = LyricsService.merge(plain: bundle.plain,
                                         translated: bundle.translated,
                                         format: fmt,
                                         separator: " ")
        print("【\(fmt.localizedName)】")
        let lines = (merged ?? "").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("[ti:") && !$0.hasPrefix("[ar:") && !$0.hasPrefix("[al:") && !$0.hasPrefix("[by:") }
        for l in lines.prefix(6) { print("    " + l) }
        print("    …（共 \(lines.count) 行）")
        print("")
    }
}

// MARK: - lyric export
//
//   lyric export <音频文件副本> [--format lrc|a2|txt|srt]
//                              [--location song|sub|sub:<名>|dir:<路径>|ask]
//                              [--naming same|artist-title|title-artist]
//                              [--encoding utf8|utf8bom|gb18030|utf16le]
//                              [--overwrite|--no-overwrite] [--a2-suffix] [--lines N]
//
// 会在磁盘上生成歌词文件，请对副本跑。逐字（wordByWord）是**人造**的：
// 从文件里已有的行时间轴歌词按字均分出 A2 时间戳，用来验证增强 LRC 这条路。

func cmdLyricExport(_ path: String, args: [String]) {
    let url = URL(fileURLWithPath: path)

    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    let file: AudioFile
    do { file = try TagService.read(url) }
    catch { print("读取失败：\(error.localizedDescription)"); return }

    let plain = file.tags.lyrics ?? ""
    guard !plain.isEmpty else {
        print("该文件没有歌词。请先跑 `mactagger-probe smoke <副本>` 写入带时间轴的歌词。")
        return
    }

    var options = LyricsFileOptions.default
    options.enabled = true

    switch value("--format") ?? "lrc" {
    case "lrc":            options.format = .lrc
    case "a2", "enhanced": options.format = .enhancedLrc
    case "txt":            options.format = .txt
    case "srt":            options.format = .srt
    case let other:        print("未知 --format \(other)"); return
    }

    let loc = value("--location") ?? "song"
    if loc == "song" {
        options.location = .songFolder
    } else if loc == "sub" {
        options.location = .songSubfolder(name: LyricsSaveLocation.defaultSubfolderName)
    } else if loc.hasPrefix("sub:") {
        options.location = .songSubfolder(name: String(loc.dropFirst(4)))
    } else if loc.hasPrefix("dir:") {
        options.location = .fixedDirectory(URL(fileURLWithPath: String(loc.dropFirst(4)),
                                               isDirectory: true))
    } else if loc == "ask" {
        options.location = .askEachTime
    } else {
        print("未知 --location \(loc)"); return
    }

    switch value("--naming") ?? "same" {
    case "same":         options.naming = .sameAsAudio
    case "artist-title": options.naming = .artistTitle
    case "title-artist": options.naming = .titleArtist
    case let other:      print("未知 --naming \(other)"); return
    }

    switch value("--encoding") ?? "utf8" {
    case "utf8":    options.encoding = .utf8
    case "utf8bom": options.encoding = .utf8BOM
    case "gb18030": options.encoding = .gb18030
    case "utf16le": options.encoding = .utf16LE
    case let other: print("未知 --encoding \(other)"); return
    }

    options.overwriteExisting = args.contains("--overwrite") && !args.contains("--no-overwrite")
    options.enhancedUsesA2Suffix = args.contains("--a2-suffix")
    let showLines = Int(value("--lines") ?? "6") ?? 6

    // 人造逐字：把每行按字均分到 2 秒窗口里，产出 A2 扩展。
    let bundle = LyricsBundle(sourceID: "probe",
                              plain: plain,
                              translated: nil,
                              wordByWord: syntheticWordByWord(from: plain))

    hr("lyric export — \(options.format.shortName) / \(loc)")
    print("  源文件    : \(url.path)")
    print("  格式      : \(options.format.rawValue)（.\(options.format.fileExtension)）"
          + (options.enhancedUsesA2Suffix ? "  + .a2 后缀" : ""))
    print("  位置      : \(options.location.kind.rawValue)"
          + (options.location.kind == .songSubfolder ? "（\(options.location.subfolderName)）" : "")
          + (options.location.kind == .fixedDirectory ? "（\(options.location.directoryURL?.path ?? "-")）" : ""))
    print("  命名/编码 : \(options.naming.rawValue) / \(options.encoding.localizedName)")
    print("  覆盖      : \(options.overwriteExisting ? "是" : "否")")
    print("  预计路径  : \(LyricsService.lyricsFileURL(for: file, options: options).path)")

    do {
        let r = try LyricsService.writeLyricsFile(plain, bundle: bundle,
                                                  for: file, options: options)
        let size = (try? Data(contentsOf: r.url).count) ?? -1
        print("  结果      : \(r.status.rawValue)"
              + (r.reason.map { "（\($0)）" } ?? ""))
        print("  实际路径  : \(r.url.path)")
        print("  文件大小  : \(size) 字节  存在=\(FileManager.default.fileExists(atPath: r.url.path))")

        guard let text = try? LyricsService.importLrc(from: r.url) else {
            print("  （读回失败）"); return
        }
        let lines = text.components(separatedBy: "\n")
        print("  前 \(showLines) 行：")
        for l in lines.prefix(showLines) { print("    | " + l) }
        print("    …（共 \(lines.count) 行）")
    } catch {
        print("  写出失败：\(error.localizedDescription)")
    }
}

/// 从行时间轴歌词造一段 A2 逐字歌词，供增强 LRC 验证用。
/// 每行按字数把 2 秒（或到下一行为止）均分。
func syntheticWordByWord(from plain: String) -> String {
    let doc = LrcDocument.parse(plain).removingBlankLines()
    var out: [String] = []
    for tag in doc.headerTags { out.append("[\(tag.key):\(tag.value)]") }

    let timed = doc.lines.filter { $0.hasTimestamp }
    for (i, line) in timed.enumerated() {
        guard let start = line.firstTimestamp else { continue }
        let next = i + 1 < timed.count ? (timed[i + 1].firstTimestamp ?? start + 2) : start + 2
        let span = max(0.2, min(next - start, 6))
        let chars = Array(line.text)
        guard !chars.isEmpty else { continue }
        let step = span / Double(chars.count)

        var s = "[" + LrcDocument.formatTimestamp(start, digits: 2) + "]"
        for (j, ch) in chars.enumerated() {
            s += "<" + LrcDocument.formatTimestamp(start + step * Double(j), digits: 2) + ">"
            s += String(ch)
        }
        out.append(s)
    }
    return out.joined(separator: "\n")
}

// MARK: - lyric write：端到端「下歌词 → 写进标签 → 读回来」
//
//   lyric write <音频文件副本> [--lines N] [--format twoLines|inline|...] [--no-translation]
//
// **请对副本跑**：它会真的把歌词写进文件的 LYRICS 标签。
// 存在的理由：BD 轮要验的那句话是「日文歌写完标签之后，读回来必须看得见中文翻译行」——
// 只验到 `LyricsBundle.translated` 非空是不够的，合并与写入这两步同样会丢翻译。

func cmdLyricWrite(_ path: String, args: [String]) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("文件不存在：\(path)"); exit(1)
    }
    let lines = probeIntArg(args, "--lines") ?? 8
    hr("下歌词 → 写标签 → 读回（lyric write）")
    print("  文件 : \(url.lastPathComponent)")

    guard let file = try? TagService.read(url) else { print("读取失败"); exit(1) }
    var options = LyricsFetchOptions()
    if args.contains("--no-translation") { options.includeTranslation = false }
    if let i = args.firstIndex(of: "--format"), i + 1 < args.count,
       let f = TranslationMergeFormat(rawValue: args[i + 1]) { options.mergeFormat = f }

    let q = AutoMatchService.makeQuery(from: file)
    print("  查询 : 标题=\(q.title ?? "-") 艺术家=\(q.artist ?? "-") 文件名=\(q.filename ?? "-")")
    print("  源顺序: \(options.sourceIDs.joined(separator: " → "))"
          + "　合并格式=\(options.mergeFormat.localizedName)"
          + "　要翻译=\(options.includeTranslation)")
    print("  这首值得要翻译？ \(LyricsService.wantsTranslation(q) ? "是（含假名/谚文/英文）" : "否（华语歌，一发即停）")")

    let started = Date()
    let r = cnRunBlocking { await LyricsService.fetch(for: file, options: options) }
    guard case .success(let res) = r else { print("内部错误"); exit(2) }
    print(String(format: "  耗时 : %.2f s", Date().timeIntervalSince(started)))
    print("  结果 : \(res.status.rawValue)　源=\(res.sourceID ?? "-")"
          + "　有翻译=\(res.hasTranslation ? "✔" : "✘")　有逐字=\(res.hasWordByWord ? "✔" : "✘")")
    print("  逐源 : \(res.sourceOutcomes.inlineSummary)")

    guard let merged = res.merged, !merged.isEmpty else {
        print("  ✘ 没有可写入的歌词"); exit(2)
    }

    var edit = TagEdit()
    edit.set(.lyrics, merged)
    guard let outcome = try? TagService.write(edit, to: url) else { print("  写入失败"); exit(2) }
    print("  写入 : \(outcome.isComplete ? "完整落盘 ✔" : "有字段被拒：\(outcome.rejectedKeys.joined(separator: ","))")"
          + "　\(merged.count) 字符")

    guard let after = try? TagService.read(url), let back = after.tags.lyrics else {
        print("  ✘ 读回失败"); exit(2)
    }
    let all = back.components(separatedBy: "\n")
        .filter { !$0.hasPrefix("[ti:") && !$0.hasPrefix("[ar:") && !$0.hasPrefix("[al:")
                  && !$0.hasPrefix("[by:") && !$0.hasPrefix("[offset:") }
    print("")
    print("  从文件读回的歌词（\(back.count) 字符 / \(all.count) 行），前 \(min(lines, all.count)) 行：")
    for l in all.prefix(lines) { print("    " + l) }

    // 「有没有中文翻译行」用**读回来的文本**判，不用内存里的 bundle。
    //
    // 判据必须是**双语共存**：既有假名行、又有「纯汉字无假名」行。
    // 只找汉字行会把华语歌的正文当成翻译（《稻香》整篇都是汉字），
    // 那样这条验收线就永远是 ✔，等于没验。
    func body(_ line: String) -> Substring { line.drop { $0 != "]" }.dropFirst() }
    let hasKanaLine = all.contains { line in
        body(line).unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
    let hasHanOnlyLine = all.contains { line in
        let t = body(line)
        return t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            && !t.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
            && !t.contains("：") && !t.contains(":")     // 排掉「作词 : X」这类署名行
    }
    print("")
    print("  日文（含假名）行：\(hasKanaLine ? "有" : "无")　纯汉字行：\(hasHanOnlyLine ? "有" : "无")")
    print("  ★ 读回的文本里出现中文翻译行（日汉双语共存）："
          + ((hasKanaLine && hasHanOnlyLine) ? "✔ 是" : "✘ 否"))
}

// MARK: - lyric resolve（BG 轮）
//
//   lyric resolve "<标题含版本后缀>" [--artist "<艺术家>"] [--duration <秒>]
//                                    [--sources a,b,c] [--no-transplant] [--lines N]
//
// 打印：marker 解析 → 各源候选（版本 / 译文有无 / 分数）→ 最终选择
//       → 移植对齐行数 → 前 N 行「时间戳 原词 / 翻译」。
// 全程只读联网，不碰任何本地文件。

func cmdLyricResolve(_ term: String, args: [String]) {
    var artist: String?
    var duration: TimeInterval = 0
    var sources = LyricsService.translationSourceOrder
    var transplant = true
    var lines = 8

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--artist":   if i + 1 < args.count { artist = args[i + 1]; i += 1 }
        case "--duration": if i + 1 < args.count { duration = TimeInterval(args[i + 1]) ?? 0; i += 1 }
        case "--sources":
            if i + 1 < args.count {
                sources = args[i + 1].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                i += 1
            }
        case "--no-transplant": transplant = false
        case "--lines":    if i + 1 < args.count { lines = Int(args[i + 1]) ?? 8; i += 1 }
        default: break
        }
        i += 1
    }

    cnHR("版本感知取词 「\(term)」\(artist.map { " — " + $0 } ?? "")")

    // ① marker 解析
    let v = VersionMarker.parse(term)
    print("【marker 解析】")
    print("  原标题  : \(v.original)")
    print("  正题    : \(v.baseTitle)")
    print("  版本后缀: \(v.summary)")
    if let d = v.liveDate { print("  Live 场次日期: \(d)") }
    if let e = v.liveEvent { print("  Live 场次名  : \(e)") }
    if !v.featured.isEmpty { print("  合作艺术家: \(v.featured.joined(separator: " / "))") }

    var q = TrackQuery()
    q.title = term
    q.artist = artist
    q.duration = duration

    let started = Date()
    let got = cnRunBlocking { () async throws -> LyricsResolution in
        await LyricsService.resolve(query: q, sourceIDs: sources,
                                    stopWhenSatisfied: false,
                                    transplant: transplant)
    }
    guard case .success(let r) = got else { print("内部错误"); exit(2) }
    let elapsed = Date().timeIntervalSince(started)

    print("")
    print("【送给各源的检索词】\(r.searchTerm)      （总耗时 \(String(format: "%.2f", elapsed))s）")

    // ② 各源候选
    print("")
    print("【各源候选】")
    print(cnPad("源", 10) + cnPad("匹到的标题", 34) + cnPad("版本", 18)
          + cnPad("版本分", 8) + cnPad("总分", 8) + cnPad("译文", 6)
          + cnPad("逐字", 6) + cnPad("条数", 6) + "耗时")
    print(String(repeating: "-", count: 108))
    for t in r.traces {
        if let e = t.error {
            print(cnPad(SourceOutcome.shortName(t.sourceID), 10) + "✘ " + e)
            continue
        }
        print(cnPad(SourceOutcome.shortName(t.sourceID), 10)
              + cnPad(t.pickedTitle ?? "（无候选）", 34)
              + cnPad(t.pickedVersion, 18)
              + cnPad(String(format: "%.2f", t.versionScore), 8)
              + cnPad(String(format: "%.3f", t.score), 8)
              + cnPad(t.hasTranslation ? "✔" : "✘", 6)
              + cnPad(t.hasWordByWord ? "✔" : "✘", 6)
              + cnPad("\(t.candidateCount)", 6)
              + String(format: "%.2fs", t.latency))
    }
    if r.filteredInstrumental > 0 {
        print("  （按「跳过伴奏版」滤掉 \(r.filteredInstrumental) 条）")
    }

    // ③ 最终选择
    print("")
    print("【最终选择】")
    guard let best = r.best, let b = best.bundle else {
        print("  ✘ 没有可用结果")
        for n in r.notes { print("  说明：\(n)") }
        exit(1)
    }
    let bestVersion = VersionMarker.parse(best.track.title)
    let vs = MatchScorer.versionSimilarity(best.track.title, query: v)
    print("  源      : \(SourceOutcome.shortName(best.track.sourceID))")
    print("  标题    : \(best.track.title ?? "-")")
    print("  专辑    : \(best.track.album ?? "-")   时长 \(cnFmtDuration(best.track.durationSeconds))")
    print("  版本    : \(bestVersion.summary)      版本分 \(String(format: "%.2f", vs))"
          + (vs >= LyricsService.versionAcceptThreshold ? "  ✔ 版本相符" : "  ✘ 版本不符"))
    print("  原词    : \(b.plain?.isEmpty == false ? "✔ \(b.plain!.count) 字符" : "✘ 无")")
    print("  翻译    : \(b.hasTranslation ? "✔ \(b.translated!.count) 字符" : "✘ 无")")
    print("  逐字    : \(b.wordByWord?.isEmpty == false ? "✔" : "✘")")
    print("  罗马音  : \(b.romanized?.isEmpty == false ? "✔" : "✘")")

    // ④ 移植
    print("")
    print("【译文移植】")
    if let t = r.transplant {
        print("  状态    : \(t.applied ? "✔ 已移植" : "✘ 未移植")")
        if let d = t.donorTitle { print("  供体    : 《\(d)》（\(SourceOutcome.shortName(t.donorSourceID ?? "-"))）") }
        print("  对齐    : \(t.aligned) 行对上 / \(t.unaligned) 行留空 / 本版本共 \(t.total) 行")
        print("  说明    : \(t.note)")
    } else if b.hasTranslation {
        print("  未移植 —— 本版本自带译文")
    } else {
        print("  未移植")
    }
    if let note = b.translationSourceNote { print("  bundle 注记: \(note)") }
    for n in r.notes { print("  说明    : \(n)") }
    if !r.errors.isEmpty {
        for e in r.errors { print("  错误    : \(e.sourceID) — \(e.message)") }
    }

    // ⑤ 前 N 行「时间戳 原词 / 翻译」
    print("")
    print("【前 \(lines) 行】")
    let plainLines = LrcDocument.parse(b.plain ?? "").lines.filter { !$0.isBlankText }
    let pairs = LyricsService.pairedLines(plain: b.plain ?? "", translated: b.translated)
    var shown = 0
    for (idx, l) in plainLines.enumerated() where shown < lines {
        guard let t = l.firstTimestamp else { continue }
        let tr = idx < pairs.count ? (pairs[idx].translation ?? "") : ""
        print(String(format: "  [%02d:%05.2f] ", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
              + l.text + (tr.isEmpty ? "   /   —" : "   /   " + tr))
        shown += 1
    }
    if shown == 0 { print("  （没有带时间戳的歌词行）") }
}

// MARK: - lyric marker（离线：只跑 VersionMarker.parse，不联网）
//
//   lyric marker ["<标题>" …]     不给参数就跑内置样例表（全部取自用户真实文件名）

func cmdLyricMarker(_ titles: [String]) {
    let samples = titles.isEmpty ? [
        "Family Song (Live At MUSIC STATION SUPER LIVE20171222)",
        "Family Song (Live At CDTV SP! Christmas音楽祭20171225)",
        "Family Song (Live At 第68届NHK紅白歌合戦20171231)",
        "Family Song (Live at Best Artist 2017)",
        "Family Song",
        "恋 (Live)", "恋 (2023 NHK SONGS现场)", "恋 (Love) (Live At 第67回NHK红白歌合战)",
        "Pop Virus (MV版)", "読書 (Remix)", "雨音 (House ver.)", "KIDS (House ver_)",
        "ギャグ (Inst_)", "さようならのうみ (Inst_)", "うちで踊ろう (Potluck Mix)",
        "くだらないの中に (Live at YELLOW VOYAGE)", "光の跡 (2024 FNS歌谣祭现场)",
        "アイデア (Live at 第69回NHK 紅白歌合戦)",
        // —— 以下**不该**被识别成版本后缀（剥错了就是把曲名改错）——
        "いきどまり (Dead End)", "うちで踊ろう (在家跳舞吧)", "おともだち (Odd Couple)",
        "パロディ (Parody)", "もしも (如果)", "光の跡 (Why)", "アイデア (IDEA)",
        "さらしもの(feat_ PUNPEE)", "Eden (feat. Cordae, DJ Jazzy Jeff)",
        "Lemon (《Unnatural》日剧主题曲)", "うちで踊ろう (Dancing On The Inside)",
        "Blank Space", "稻香",
        // —— 破折号 / 波浪号写法 ——
        "Song Name -Live-", "Song Name ～Acoustic～", "Song Name - Remix",
    ] : titles

    cnHR("VersionMarker.parse 离线样例（\(samples.count) 条）")
    print(cnPad("原标题", 46) + cnPad("正题", 24) + cnPad("版本后缀", 22) + "feat.")
    print(String(repeating: "-", count: 104))
    for t in samples {
        let v = VersionMarker.parse(t)
        print(cnPad(t, 46) + cnPad(v.baseTitle, 24)
              + cnPad(v.isStudio ? "—" : v.summary, 22)
              + (v.featured.isEmpty ? "—" : v.featured.joined(separator: "/")))
    }

    // 版本相似度对照：四场 Family Song 两两比
    cnHR("versionSimilarity 对照（查询 = 20171222 那场）")
    let q = VersionMarker.parse("Family Song (Live At MUSIC STATION SUPER LIVE20171222)")
    for c in ["Family Song (Live At MUSIC STATION SUPER LIVE20171222)",
              "Family Song (Live At CDTV SP! Christmas音楽祭20171225)",
              "Family Song (Live At 第68届NHK紅白歌合戦20171231)",
              "Family Song (Live at Best Artist 2017)",
              "Family Song"] {
        let s = MatchScorer.versionSimilarity(c, query: q)
        print(cnPad(c, 56) + String(format: "%.2f", s)
              + (s <= 0.0001 ? "   ✘ 判为不匹配（重罚 ×0.20）"
                 : s >= LyricsService.versionAcceptThreshold ? "   ✔ 相符" : "   ~ 次优"))
    }
}

// MARK: - lyric sanitize（BG 轮：落盘前清洗的字节级验证）
//
//   lyric sanitize <输入.lrc> [输出.lrc]
//
// 直接跑 `LyricsService.encodeLyricsData`（**所有歌词文件写出路径的唯一收口**），
// 打印清洗前后的字节统计：NUL / C0 控制符 / 零宽 / BOM / CRLF。
// 只写 `输出.lrc`（默认在输入旁边加 `.clean.lrc`），不碰任何别的文件。

func cmdLyricSanitize(_ inPath: String, _ outPath: String?) {
    let inURL = URL(fileURLWithPath: inPath)
    guard let raw = try? Data(contentsOf: inURL) else {
        print("读不到 \(inPath)"); exit(1)
    }
    let outURL = URL(fileURLWithPath: outPath
        ?? inURL.deletingPathExtension().path + ".clean.lrc")

    func stats(_ d: Data, _ label: String) {
        var nul = 0, c0 = 0, del = 0, crlf = 0
        var prev: UInt8 = 0
        for b in d {
            if b == 0x00 { nul += 1 }
            else if b < 0x20, b != 0x0A, b != 0x0D, b != 0x09 { c0 += 1 }
            else if b == 0x7F { del += 1 }
            if prev == 0x0D, b == 0x0A { crlf += 1 }
            prev = b
        }
        // 零宽与 BOM 是多字节序列，按字符串数
        let s = String(decoding: d, as: UTF8.self)
        let zw = s.unicodeScalars.filter { (0x200B...0x200D).contains($0.value) || $0.value == 0xFEFF }.count
        let strictOK = String(data: d, encoding: .utf8) != nil
        print("  \(label)：\(d.count) 字节  NUL=\(nul)  其它C0=\(c0)  DEL=\(del)  零宽/BOM=\(zw)  CRLF=\(crlf)"
              + "  严格UTF-8解码=\(strictOK ? "✔" : "✘")")
    }

    cnHR("歌词落盘清洗 \(inURL.lastPathComponent)")
    stats(raw, "清洗前")

    // 与真实写出链完全一致：先按 importLrc 的编码识别读成 String，再过 encodeLyricsData
    guard let text = try? LyricsService.importLrc(from: inURL) else {
        print("  importLrc 失败（连编码都识别不出来）"); exit(2)
    }
    guard let data = try? LyricsService.encodeLyricsData(text, encoding: .utf8) else {
        print("  encodeLyricsData 失败"); exit(2)
    }
    stats(data, "清洗后")
    try? data.write(to: outURL, options: .atomic)
    print("  已写出：\(outURL.path)")
}

// MARK: - lyric upgrade-demo（BI 轮：.lrc「复跑升级为含译文版」闭环）
//
//   lyric upgrade-demo [<音频文件副本>]
//
// 全程在**临时目录**里做：不给路径就完全合成一份 AudioFile（连音频都不需要）；
// 给了路径会先把音频**复制**进临时目录再用，源文件一个字节都不碰。
//
// 三组断言：
//   ① 先用无译文 bundle 写出 .lrc（模拟旧文件），再用含译文 bundle 复跑
//      （overwriteExisting = false）→ 必须 `upgraded`，且文件真出现译文行；
//   ② 在旧 .lrc 末尾追加 `# my note` 后复跑 → 必须 `skippedExisting`，且字节不变；
//   ③ overwriteExisting = true → 必须 `written`（老行为一点没变）。
//   ④（附加）正文行数差 > 35% 的「另一版本」→ 必须 `skippedExisting`。
//   ⑤（防回归）字节一致 → `unchanged`；旧文件已含译文 → `skippedExisting`。
//   ⑥（BJ 轮）**第三方自带的无译文 .lrc**（`[ti:]` 头 + 标题行 + 「词：/曲：」署名行）
//      → 必须 `upgraded`；⑥b 同一首但行数差 37% → 靠同曲判定仍 `upgraded`。
//   ⑦（BJ 轮）另一首歌的 .lrc（正文一行都对不上）→ 必须 `skippedExisting`、字节不变。

func cmdLyricUpgradeDemo(_ args: [String]) {
    var passed = 0
    var failed = 0

    func assert(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        print("  \(ok ? "✔" : "✘") \(label)\(detail.isEmpty ? "" : "  — " + detail)")
    }

    // ---- 临时工作目录 ----
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mactagger-lrc-upgrade-\(UUID().uuidString.prefix(8))",
                                isDirectory: true)
    do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    catch { print("临时目录创建失败：\(error.localizedDescription)"); return }

    // ---- 拿一个 AudioFile：有路径就复制进临时目录再读，没有就合成 ----
    var file: AudioFile
    if let src = args.first(where: { !$0.hasPrefix("--") }) {
        let srcURL = URL(fileURLWithPath: src)
        let dst = tmp.appendingPathComponent(srcURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: srcURL, to: dst)
            file = try TagService.read(dst)
        } catch {
            print("复制/读取失败：\(error.localizedDescription)"); return
        }
    } else {
        var tags = Tags()
        tags.title = "Demo Song"
        tags.artist = "Demo Artist"
        file = AudioFile(url: tmp.appendingPathComponent("Demo Song.flac"),
                         tags: tags,
                         technical: AudioTechnicalInfo())
    }

    // ---- 造词：8 行原词 + 8 行同时间戳译文 ----
    let stamps = [1.0, 5.0, 9.0, 13.0, 17.0, 21.0, 25.0, 29.0]
    let originals = ["あの日の僕らは", "何も知らなかった", "夜は長くて", "星は遠かった",
                     "君の声だけが", "ここに残ってる", "また会えるなら", "今度は笑って"]
    let translations = ["那天的我们", "什么都不知道", "夜很漫长", "星星很遥远",
                        "只有你的声音", "还留在这里", "如果还能再见", "这次要笑着"]
    func lrc(_ texts: [String]) -> String {
        texts.enumerated()
            .map { "[" + LrcDocument.formatTimestamp(stamps[$0.offset], digits: 2) + "]" + $0.element }
            .joined(separator: "\n")
    }
    let plain = lrc(originals)
    let plainTranslated = lrc(translations)

    let bundleNoTrans = LyricsBundle(sourceID: "probe", plain: plain, translated: nil)
    let bundleWithTrans = LyricsBundle(sourceID: "probe", plain: plain, translated: plainTranslated)

    var opts = LyricsFileOptions.default
    opts.enabled = true
    opts.format = .lrc
    opts.location = .fixedDirectory(tmp)
    opts.includeTranslation = true
    opts.mergeFormat = .twoLines
    opts.overwriteExisting = false          // ← 本轮的主角：默认就是关的

    let target = LyricsService.lyricsFileURL(for: file, options: opts)

    func write(_ b: LyricsBundle, overwrite: Bool) -> LyricsFileWriteResult? {
        var o = opts
        o.overwriteExisting = overwrite
        let text = LyricsService.mergedText(from: b, options: o)
        do { return try LyricsService.writeLyricsFile(text, bundle: b, for: file, options: o) }
        catch { print("  写出失败：\(error.localizedDescription)"); return nil }
    }
    func readBack() -> String { (try? LyricsService.importLrc(from: target)) ?? "" }
    func hasTranslationOnDisk() -> Bool {
        LyricsService.lrcContainsTranslationLines(LrcDocument.parse(readBack()))
    }
    func show(_ n: Int = 6) {
        let lines = readBack().components(separatedBy: "\n")
        print("    前 \(n) 行：")
        for l in lines.prefix(n) { print("      | " + l) }
        print("      …（共 \(lines.count) 行）")
    }

    hr("lyric upgrade-demo — .lrc 复跑升级为含译文版")
    print("  工作目录  : \(tmp.path)")
    print("  目标 .lrc : \(target.lastPathComponent)")
    print("  覆盖开关  : 默认 \(opts.overwriteExisting ? "开" : "关")（overwriteExisting）")

    // ================= ① 无译文旧文件 → 含译文新版 =================
    print("\n① 旧文件无译文 + 新文本有译文 + 没开覆盖 → 应当 upgraded")
    guard let r0 = write(bundleNoTrans, overwrite: false) else { return }
    assert("先写出「旧文件」= written", r0.status == .written, "实际 \(r0.status.rawValue)")
    assert("「旧文件」确实没有译文", !hasTranslationOnDisk())
    show(4)

    guard let r1 = write(bundleWithTrans, overwrite: false) else { return }
    assert("复跑 = upgraded", r1.status == .upgraded, "实际 \(r1.status.rawValue)（\(r1.reason ?? "-")）")
    assert("升级算「真写了盘」didWrite", r1.didWrite)
    assert("文件里出现译文行", hasTranslationOnDisk())
    assert("译文内容落到盘上", readBack().contains(translations[0]))
    show(6)

    // ================= ② 用户手改过 → 一个字节都不碰 =================
    print("\n② 旧文件被手改过（末尾一行 `# my note`）→ 应当 skippedExisting 且字节不变")
    _ = write(bundleNoTrans, overwrite: true)                    // 还原成无译文旧文件
    var edited = (try? Data(contentsOf: target)) ?? Data()
    edited.append(contentsOf: Array("\n# my note\n".utf8))
    do { try edited.write(to: target, options: .atomic) }
    catch { print("  追加失败：\(error.localizedDescription)"); return }
    let before = (try? Data(contentsOf: target)) ?? Data()

    guard let r2 = write(bundleWithTrans, overwrite: false) else { return }
    let after = (try? Data(contentsOf: target)) ?? Data()
    assert("复跑 = skippedExisting", r2.status == .skippedExisting,
           "实际 \(r2.status.rawValue)（\(r2.reason ?? "-")）")
    assert("文件字节完全不变", before == after, "\(before.count) → \(after.count) 字节")
    assert("手改的那行还在", readBack().contains("# my note"))
    print("    跳过原因  : \(r2.reason ?? "-")")

    // ================= ③ 开了覆盖 → 老行为不变 =================
    print("\n③ overwriteExisting = true → 应当 written（行为不变）")
    guard let r3 = write(bundleWithTrans, overwrite: true) else { return }
    assert("复跑 = written", r3.status == .written, "实际 \(r3.status.rawValue)")
    assert("手改的那行已被覆盖掉", !readBack().contains("# my note"))
    assert("文件里有译文行", hasTranslationOnDisk())
    show(6)

    // ============ ④（附加）行数差 > 20% = 疑非同一版本 → 不升级 ============
    print("\n④（附加闸门）旧文件 8 行 vs 新文本 4 行（差 50%）→ 应当 skippedExisting")
    _ = write(bundleNoTrans, overwrite: true)                    // 8 行无译文旧文件
    let shortBundle = LyricsBundle(sourceID: "probe",
                                   plain: lrc(Array(originals.prefix(4))),
                                   translated: lrc(Array(translations.prefix(4))))
    let before4 = (try? Data(contentsOf: target)) ?? Data()
    guard let r4 = write(shortBundle, overwrite: false) else { return }
    let after4 = (try? Data(contentsOf: target)) ?? Data()
    assert("复跑 = skippedExisting", r4.status == .skippedExisting,
           "实际 \(r4.status.rawValue)")
    assert("文件字节完全不变", before4 == after4)
    print("    跳过原因  : \(r4.reason ?? "-")")

    // ====== ⑤（防回归）.unchanged 与「旧文件已含译文」两条老路径 ======
    print("\n⑤（防回归）字节一致 → unchanged；旧文件已含译文 → skippedExisting")
    _ = write(bundleWithTrans, overwrite: true)                  // 盘上已是含译文版
    guard let r5 = write(bundleWithTrans, overwrite: false) else { return }
    assert("同一份文本复跑 = unchanged", r5.status == .unchanged,
           "实际 \(r5.status.rawValue)")

    // 旧文件已含译文，新文本也含译文但内容不同 → 不是「升级」，不能碰
    let otherTrans = LyricsBundle(sourceID: "probe", plain: plain,
                                  translated: lrc(translations.map { $0 + "（别家的译法）" }))
    let before5 = (try? Data(contentsOf: target)) ?? Data()
    guard let r6 = write(otherTrans, overwrite: false) else { return }
    let after5 = (try? Data(contentsOf: target)) ?? Data()
    assert("旧文件已含译文 = skippedExisting", r6.status == .skippedExisting,
           "实际 \(r6.status.rawValue)")
    assert("文件字节完全不变", before5 == after5)
    print("    跳过原因  : \(r6.reason ?? "-")")

    // ====== ⑥（BJ 轮）第三方无译文 .lrc：头部 + 标题行 + 署名行 → 应当 upgraded ======
    //
    // 夹具照用户给的真实样本结构搭（正文是自编的 12 行日文）：
    //     [ti:…] [ar:…] [al:] [by:] [offset:0]      ← 头部标签
    //     [00:00.00]曲名 (…) - 艺术家 (…)            ← 标题行，不是词
    //     [00:04.63]词：…  [00:09.26]曲：…  [00:13.9]编曲：…   ← 署名行，不是词
    //     [00:2x.xx]…正文 12 行…
    //
    // 老口径把那 4 行「不是词的词」一起数进去 → 旧 16 行 vs 新 12 行 = 25% > 20%，
    // 于是每一首都判 skippedExisting —— 用户说的「自带 lrc，下下来还是没翻译」。
    // 新口径只数正文 → 12 vs 12。
    print("\n⑥（BJ 轮）第三方头部 + 标题行 + 署名行的无译文 .lrc → 应当 upgraded")

    let jpStamps: [TimeInterval] = [23.10, 27.40, 31.80, 36.20, 40.60, 45.00,
                                    49.40, 53.80, 58.20, 62.60, 67.00, 71.40]
    let jpOriginals = ["街の灯りが滲んでいく", "傘もささずに歩いた", "君の名前を呼んでみる",
                       "返事のない交差点で", "季節はもう変わるのに", "僕だけが立ち止まる",
                       "あの日の約束の場所", "今も覚えているかな", "風が頬を撫でていく",
                       "涙はもう乾いたよ", "いつかまた会えるまで", "この歌を歌うから"]
    let jpTranslations = ["街灯的光晕渐渐晕开", "没有撑伞就那样走着", "试着呼唤你的名字",
                          "在无人应答的十字路口", "季节明明就要变了", "只有我停在原地",
                          "那天约好的地方", "你现在还记得吗", "风轻抚过脸颊",
                          "眼泪早就干了", "直到某天能再相见", "我都会唱着这首歌"]
    func stamp(_ t: TimeInterval) -> String {
        "[" + LrcDocument.formatTimestamp(t, digits: 2) + "]"
    }
    /// 第三方 .lrc 的完整长相：5 行头 + 标题行 + 3 行署名 + 12 行正文，**没有译文**。
    let thirdPartyLrc = ([
        "[ti:あの交差点 (Live At 日本武道館)]",
        "[ar:架空 太郎 (かくう たろう)]",
        "[al:]",
        "[by:]",
        "[offset:0]",
        stamp(0.00) + "あの交差点 (Live At 日本武道館) - 架空 太郎 (かくう たろう)",
        stamp(4.63) + "词：架空 太郎",
        stamp(9.26) + "曲：架空 太郎",
        stamp(13.90) + "编曲：架空 花子"
    ] + jpOriginals.enumerated().map { stamp(jpStamps[$0.offset]) + $0.element })
        .joined(separator: "\n") + "\n"

    /// 把第三方 .lrc 原样铺到目标路径上（模拟「用户下歌时自带的那一份」）。
    func layThirdPartyFile() {
        try? Data(thirdPartyLrc.utf8).write(to: target, options: .atomic)
    }
    func jpLrc(_ texts: [String], count: Int) -> String {
        (0..<count).map { stamp(jpStamps[$0]) + texts[$0] }.joined(separator: "\n")
    }

    layThirdPartyFile()
    let oldDoc = LrcDocument.parse(readBack())
    let oldAllLines = LyricsService.lrcOriginalLineCount(oldDoc, hasTranslation: false)
    let oldBodyLines = LyricsService.lrcBodyOriginalLineCount(oldDoc, hasTranslation: false)
    print("    夹具：\(oldDoc.headerTags.count) 个头部标签；"
          + "有时间戳的行 \(oldAllLines)（老口径）→ 正文 \(oldBodyLines) 行（新口径）")
    assert("头部标签被 LrcDocument 摘走了", oldDoc.headerTags.count == 5, "实际 \(oldDoc.headerTags.count)")
    assert("标题行 + 3 行署名不算正文", oldAllLines == 16 && oldBodyLines == 12,
           "老口径 \(oldAllLines) / 新口径 \(oldBodyLines)")
    assert("夹具本身没有译文", !hasTranslationOnDisk())
    assert("夹具没有自由文本行（不会被判成手改）",
           !LyricsService.lrcContainsFreeTextLines(oldDoc))
    show(4)

    let jpBundle = LyricsBundle(sourceID: "probe",
                                plain: jpLrc(jpOriginals, count: 12),
                                translated: jpLrc(jpTranslations, count: 12))
    guard let r7 = write(jpBundle, overwrite: false) else { return }
    assert("复跑 = upgraded", r7.status == .upgraded,
           "实际 \(r7.status.rawValue)（\(r7.reason ?? "-")）")
    assert("文件里出现译文行", hasTranslationOnDisk())
    assert("译文内容落到盘上", readBack().contains(jpTranslations[0]))
    print("    升级原因  : \(r7.reason ?? "-")")
    show(6)

    // ⑥b 同曲判定：旧文件正文 12 行 vs 新文本正文 19 行（差 37% > 35%），
    //     光看行数会被否 —— 靠「前 5 行对得上」放行。
    //     方向刻意是「新的更全」：同曲判定只免行数闸，**不免**「别拿短的盖长的」
    //     （那一条由 ④ 守着：旧 8 行 → 新 4 行内容也对得上，但仍必须跳过）。
    print("\n⑥b 同一首但行数差 37%（新文本多出 7 行副歌）→ 同曲判定应当放行")
    let longOriginals = jpOriginals + ["ラララ ラララ", "ラララ ラララ ラララ",
                                       "もう一度だけ", "君の声が聞きたい",
                                       "ラララ ラララ", "ラララ ラララ ラララ",
                                       "そしてまた歩き出す"]
    let longTranslations = jpTranslations + ["啦啦啦 啦啦啦", "啦啦啦 啦啦啦 啦啦啦",
                                             "只想再一次", "听见你的声音",
                                             "啦啦啦 啦啦啦", "啦啦啦 啦啦啦 啦啦啦",
                                             "然后再次迈开脚步"]
    let longStamps = jpStamps + [75.8, 80.2, 84.6, 89.0, 93.4, 97.8, 102.2]
    func longLrc(_ texts: [String]) -> String {
        texts.enumerated().map { stamp(longStamps[$0.offset]) + $0.element }
            .joined(separator: "\n")
    }
    layThirdPartyFile()                      // 旧文件回到 12 行正文的第三方版
    let longBundle = LyricsBundle(sourceID: "probe",
                                  plain: longLrc(longOriginals),
                                  translated: longLrc(longTranslations))
    let longBody = LyricsService.lrcBodyOriginalLineCount(
        LrcDocument.parse(LyricsService.mergedText(from: longBundle, options: opts)),
        hasTranslation: true)
    print("    旧文件正文 12 行 vs 新文本正文 \(longBody) 行 = 差 "
          + String(format: "%.0f%%", Double(longBody - 12) / Double(longBody) * 100))
    guard let r8 = write(longBundle, overwrite: false) else { return }
    assert("复跑 = upgraded（靠同曲判定）", r8.status == .upgraded,
           "实际 \(r8.status.rawValue)（\(r8.reason ?? "-")）")
    assert("升级理由写的是「判为同一首」", (r8.reason ?? "").contains("判为同一首"),
           r8.reason ?? "-")
    assert("文件里出现译文行", hasTranslationOnDisk())
    assert("多出来的那几行也落了盘", readBack().contains("そしてまた歩き出す"))
    print("    升级原因  : \(r8.reason ?? "-")")

    // ====== ⑦（BJ 轮）不同曲：正文对不上 + 行数差大 → skippedExisting ======
    print("\n⑦（BJ 轮）另一首歌的 .lrc（正文一行都对不上）→ 应当 skippedExisting 且字节不变")
    let otherOriginals = ["夏の終わりの匂いがする", "自転車を押して坂道を",
                          "誰も知らない秘密基地", "錆びた看板の向こうへ",
                          "叫んでみても届かない", "空はどこまでも青い"]
    let otherStamps: [TimeInterval] = [12.0, 18.0, 24.0, 30.0, 36.0, 42.0]
    let otherThirdParty = ([
        "[ti:夏の終わり]",
        "[ar:架空 花子]",
        "[offset:0]",
        stamp(0.00) + "夏の終わり - 架空 花子",
        stamp(3.50) + "作词：架空 花子",
        stamp(7.00) + "作曲：架空 花子"
    ] + otherOriginals.enumerated().map { stamp(otherStamps[$0.offset]) + $0.element })
        .joined(separator: "\n") + "\n"
    try? Data(otherThirdParty.utf8).write(to: target, options: .atomic)
    let otherBody = LyricsService.lrcBodyOriginalLineCount(LrcDocument.parse(readBack()),
                                                           hasTranslation: false)
    print("    旧文件正文 \(otherBody) 行（另一首）vs 新文本正文 12 行")
    let before7 = (try? Data(contentsOf: target)) ?? Data()
    guard let r9 = write(jpBundle, overwrite: false) else { return }
    let after7 = (try? Data(contentsOf: target)) ?? Data()
    assert("复跑 = skippedExisting", r9.status == .skippedExisting,
           "实际 \(r9.status.rawValue)（\(r9.reason ?? "-")）")
    assert("文件字节完全不变", before7 == after7, "\(before7.count) → \(after7.count) 字节")
    assert("原来那首的词还在", readBack().contains(otherOriginals[0]))
    print("    跳过原因  : \(r9.reason ?? "-")")

    // ---- 收尾 ----
    print("\n  合计：\(passed) 项通过 / \(failed) 项失败  → \(failed == 0 ? "全部通过 ✔" : "存在失败 ✘")")
    if args.contains("--keep") {
        print("  （--keep：临时目录保留在 \(tmp.path)）")
    } else {
        try? FileManager.default.removeItem(at: tmp)
        print("  （临时目录已清理）")
    }
    if failed > 0 { exit(1) }
}

// MARK: - lyric batch-file-demo（BL 轮：批量复核表「仅保存文件」的数据层闭环）
//
//   lyric batch-file-demo <音频> [<音频2> <音频3>] [--keep]
//   （只给 1 个就把同一个文件复制 3 份；源文件一个字节都不碰，全程在临时目录）
//
// 复现 `AppModel.applyLyricsBatchSelection` 的 `.filesOnly` 分支里 TagKit 能测的那一段：
//   ① 合并文本：`LyricsService.merge(bundle, options: LyricsMergeOptions())` + trim
//      —— 与 `AppModel.makeBatchItem` 产出复核行 `newLyrics` 的口径逐字相同（含译文，双行）；
//   ② 每项一个 `LyricsFileJob(file:, text: 合并文本)` → `LyricsService.saveLyricsFiles`
//      （默认选项：歌曲所在文件夹 / 同名 / UTF-8 / 不覆盖）；
//   ③ 四元组统计，口径与 App 的 `LyricsFileTally` 相同：
//      written / upgraded / skippedExisting（含 unchanged）/ failed；
//      再按作业顺序把 results 回填到音频 URL（与 `saveBatchLyricsFiles` 同一回填法）。
// 三个副本：
//   A 没有 .lrc                          → 必须 written
//   B 有本程序早先写出的**无译文** .lrc     → 必须 upgraded（BI 轮纠错式升级）
//   C 已有**含译文** .lrc（译文措辞不同）   → 必须 skippedExisting，且 .lrc 字节不变
// 另断言：三个音频文件整文件 sha256 前后一致（仅存文件 = 标签一个字节都不动）。

func cmdLyricBatchFileDemo(_ args: [String]) {
    var passed = 0
    var failed = 0
    func assert(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        print("  \(ok ? "✔" : "✘") \(label)\(detail.isEmpty ? "" : "  — " + detail)")
    }
    func sha256(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url) else { return "（读不出）" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    let keep = args.contains("--keep")
    let sources = args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
    guard !sources.isEmpty else {
        print("用法: lyric batch-file-demo <音频> [<音频2> <音频3>] [--keep]")
        return
    }
    let fm = FileManager.default
    for s in sources where !fm.fileExists(atPath: s.path) {
        print("找不到：\(s.path)"); return
    }

    let tmp = fm.temporaryDirectory
        .appendingPathComponent("mactagger-batch-file-\(UUID().uuidString.prefix(8))", isDirectory: true)
    do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
    catch { print("临时目录创建失败：\(error.localizedDescription)"); return }
    defer {
        if keep { print("\n  （--keep）工作目录保留：\(tmp.path)") }
        else { try? fm.removeItem(at: tmp) }
    }

    // ---- 三个副本 ----
    let names = ["A-无lrc", "B-旧无译文lrc", "C-已含译文lrc"]
    var copies: [URL] = []
    for (i, name) in names.enumerated() {
        let src = sources[min(i, sources.count - 1)]
        let dst = tmp.appendingPathComponent(name).appendingPathExtension(src.pathExtension)
        do { try fm.copyItem(at: src, to: dst) }
        catch { print("复制失败：\(error.localizedDescription)"); return }
        copies.append(dst)
    }

    // ---- 造词：8 行原词 + 同时间戳译文（与 upgrade-demo 同一套）----
    let stamps = [1.0, 5.0, 9.0, 13.0, 17.0, 21.0, 25.0, 29.0]
    let originals = ["あの日の僕らは", "何も知らなかった", "夜は長くて", "星は遠かった",
                     "君の声だけが", "ここに残ってる", "また会えるなら", "今度は笑って"]
    let translations = ["那天的我们", "什么都不知道", "夜很漫长", "星星很遥远",
                        "只有你的声音", "还留在这里", "如果还能再见", "这次要笑着"]
    // C 旁边那份「用户早就有的含译文 .lrc」：译文措辞不同 → 字节不同，但同样含译文。
    let otherTranslations = ["那一天的我们", "一无所知", "长夜漫漫", "繁星遥远",
                             "唯有你的声音", "仍在此处", "若能再相见", "下次笑着吧"]
    func lrc(_ texts: [String]) -> String {
        texts.enumerated()
            .map { "[" + LrcDocument.formatTimestamp(stamps[$0.offset], digits: 2) + "]" + $0.element }
            .joined(separator: "\n")
    }
    let bundle = LyricsBundle(sourceID: "probe", plain: lrc(originals), translated: lrc(translations))
    let mergeOptions = LyricsMergeOptions()        // 批量下载默认：合并译文、原文一行译文一行

    // ① 合并文本 —— 与 AppModel.makeBatchItem 同一口径
    let merged = LyricsService.merge(bundle, options: mergeOptions)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var fileOptions = LyricsFileOptions.default    // 歌曲所在文件夹 / 同名 / UTF-8 / 不覆盖
    fileOptions.enabled = true

    hr("lyric batch-file-demo — 批量复核表「仅保存文件」")
    print("  工作目录  : \(tmp.path)")
    print("  文件选项  : \(fileOptions.format.shortName) · 歌曲所在文件夹 · 同名 · \(fileOptions.encoding.localizedName) · 覆盖=\(fileOptions.overwriteExisting ? "开" : "关")")
    print("  合并文本  : \(merged.components(separatedBy: "\n").count) 行（含译文），前 4 行：")
    for l in merged.components(separatedBy: "\n").prefix(4) { print("      | " + l) }

    // ---- 读入 AudioFile，记下音频字节指纹 ----
    var files: [AudioFile] = []
    for u in copies {
        do { files.append(try TagService.read(u)) }
        catch { print("读取失败 \(u.lastPathComponent)：\(error.localizedDescription)"); return }
    }
    let lrcURLs = files.map { LyricsService.lyricsFileURL(for: $0, options: fileOptions) }

    // ---- 预置：B 的无译文旧 .lrc（本程序写出的）、C 的含译文 .lrc ----
    let bundleNoTrans = LyricsBundle(sourceID: "probe", plain: lrc(originals), translated: nil)
    let bundleOther = LyricsBundle(sourceID: "probe", plain: lrc(originals), translated: lrc(otherTranslations))
    do {
        _ = try LyricsService.writeLyricsFile(
            LyricsService.merge(bundleNoTrans, options: mergeOptions), for: files[1], options: fileOptions)
        _ = try LyricsService.writeLyricsFile(
            LyricsService.merge(bundleOther, options: mergeOptions), for: files[2], options: fileOptions)
    } catch { print("预置 .lrc 失败：\(error.localizedDescription)"); return }
    let cBefore = try? Data(contentsOf: lrcURLs[2])

    let before = copies.map(sha256)
    let lyricsBefore = files.map { $0.tags.lyrics }
    print("\n  预置后：")
    for (i, u) in copies.enumerated() {
        print("    \(u.lastPathComponent)  .lrc \(fm.fileExists(atPath: lrcURLs[i].path) ? "有" : "无")"
              + "  sha256 \(before[i].prefix(16))…")
    }

    // ② 落盘 —— 与 AppModel.saveBatchLyricsFiles 同一调用
    let jobs = files.map { LyricsFileJob(file: $0, text: merged) }
    let (_, results, summary) = LyricsService.saveLyricsFiles(jobs, options: fileOptions)

    // ③ 四元组（口径 = LyricsFileTally）
    var written = 0, upgraded = 0, skippedExisting = 0, skippedEmpty = 0
    for r in results {
        switch r.status {
        case .written:                     written += 1
        case .upgraded:                    upgraded += 1
        case .skippedExisting, .unchanged: skippedExisting += 1
        case .skippedEmpty:                skippedEmpty += 1
        }
    }
    let failedCount = summary.failed
    print("\n  统计：已保存文件 \(written) · 升级为含译文 \(upgraded) · 已存在跳过 \(skippedExisting) · 失败 \(failedCount)"
          + (skippedEmpty > 0 ? " · 内容为空未存 \(skippedEmpty)" : ""))

    // 回填：按作业顺序、跳过失败项（= saveBatchLyricsFiles 的回填法）
    let failedURLs = Set(summary.failures.map(\.url))
    var perItem: [URL: LyricsFileWriteResult] = [:]
    var next = results.makeIterator()
    for job in jobs where !failedURLs.contains(job.file.url) {
        if let r = next.next() { perItem[job.file.url] = r }
    }
    print("  逐项：")
    for u in copies {
        let r = perItem[u]
        print("    \(u.lastPathComponent) → \(r?.status.rawValue ?? "失败")  \(r?.url.lastPathComponent ?? "")"
              + (r?.reason.map { "（\($0)）" } ?? ""))
    }

    print("\n断言")
    assert("written = 1", written == 1, "实际 \(written)")
    assert("upgraded = 1", upgraded == 1, "实际 \(upgraded)")
    assert("skippedExisting = 1", skippedExisting == 1, "实际 \(skippedExisting)")
    assert("failed = 0", failedCount == 0, "实际 \(failedCount)")
    assert("A → written", perItem[copies[0]]?.status == .written)
    assert("B → upgraded", perItem[copies[1]]?.status == .upgraded)
    assert("C → skippedExisting", perItem[copies[2]]?.status == .skippedExisting,
           perItem[copies[2]]?.reason ?? "")
    func onDiskHasTranslation(_ u: URL) -> Bool {
        let text = (try? LyricsService.importLrc(from: u)) ?? ""
        return LyricsService.lrcContainsTranslationLines(LrcDocument.parse(text))
    }
    assert("A 的 .lrc 已落盘且含译文", fm.fileExists(atPath: lrcURLs[0].path) && onDiskHasTranslation(lrcURLs[0]))
    assert("B 的 .lrc 已升级为含译文", onDiskHasTranslation(lrcURLs[1]))
    assert("A 的 .lrc 内容 = 合并文本（UTF-8 读回逐字一致）",
           ((try? String(contentsOf: lrcURLs[0], encoding: .utf8)) ?? "")
               .trimmingCharacters(in: .whitespacesAndNewlines) == merged)
    assert("C 的 .lrc 字节不变", cBefore != nil && (try? Data(contentsOf: lrcURLs[2])) == cBefore)

    let after = copies.map(sha256)
    print("\n  音频 sha256（前 → 后）：")
    for (i, u) in copies.enumerated() {
        print("    \(u.lastPathComponent)")
        print("      前 \(before[i])")
        print("      后 \(after[i])  \(before[i] == after[i] ? "一致" : "✘ 不一致")")
    }
    assert("三个音频文件 sha256 前后完全一致", before == after)
    let lyricsAfter = copies.map { (try? TagService.read($0))?.tags.lyrics }
    assert("三个音频文件的歌词标签前后一致（重读）", lyricsAfter == lyricsBefore)

    print("\n结果：\(passed) 项通过，\(failed) 项失败")
    if failed > 0 { exit(1) }
}

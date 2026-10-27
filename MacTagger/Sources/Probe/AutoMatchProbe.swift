//
//  AutoMatchProbe.swift
//  mactagger-probe — 自动匹配标签验证
//
//  用法：mactagger-probe automatch <file或dir>
//        [--exclude-fields disc,track]   整轮排除这几个字段（= 复核表「全部字段 ▾」里关掉）
//        [--exclude-file 2:disc]         只排除第 2 个文件的碟号（= 那一行点划线 chip），可重复
//        [--write] [--keep]              把结果真写进**副本**（源目录零改动），写完 read 复核
//

import Foundation

// MARK: - 参数小工具（AX 轮压测用）

/// `--concurrency 8` → 8
func probeIntArg(_ args: [String], _ flag: String) -> Int? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Int(args[i + 1])
}

/// `--deadline 4` → 4.0
func probeDoubleArg(_ args: [String], _ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

/// `--sources itunes,netease` → ["itunes","netease"]
func probeListArg(_ args: [String], _ flag: String) -> [String]? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let list = args[i + 1].split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return list.isEmpty ? nil : list
}

func cmdAutoMatch(_ path: String, args: [String] = []) {
    let showCandidates = args.contains("--show-candidates")
    let failing = probeFailSourceIDs(args)
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        print("路径不存在：\(path)"); exit(1)
    }

    // 收集待匹配文件
    var urls: [URL] = []
    if isDir.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: nil)) ?? []
        urls = items.filter { TagService.isSupported(url: $0) }.sorted { $0.path < $1.path }
    } else {
        urls = [url]
    }
    guard !urls.isEmpty else { print("没有可处理的音频文件"); exit(1) }

    // 注册数据源（--fail-source 指定的源会被换成必定抛错的替身）
    let failKind = probeFailKind(args)
    probeRegisterSources(failing: failing,
                         reason: probeFailReason(args, kind: failKind), kind: failKind)

    hr("自动匹配标签（automatch）")
    print("  待处理 : \(urls.count) 个文件")
    print("  数据源 : \(AutoMatchOptions.recommended.sourceIDs.joined(separator: " → "))")
    print("  阈值   : \(AutoMatchOptions.recommended.acceptThreshold)")
    if !failing.isEmpty {
        print("  故障注入 : \(failing.joined(separator: " ")) → \(failKind.rawValue)"
              + "（\(probeFailReason(args, kind: failKind))）")
    }
    print("")

    let (files, readFailures) = TagService.readAll(urls)
    if !readFailures.isEmpty {
        print("  读取失败 \(readFailures.count) 个（已跳过）")
    }

    // ★ AX 轮压测的三组对照全靠这几个开关：
    //   ① 改前 = `--legacy`（等所有源、署名回落多源、并发 4、组内串行）
    //   ② 改后默认 = 不加开关
    //   ③ 改后关署名 = `--no-credits`
    // 用**同一份语料同一条命令**跑三次，比的才是同一件事。
    let legacy = args.contains("--legacy")
    var opts = legacy ? AutoMatchOptions.legacy : AutoMatchOptions.recommended
    opts.fetchArtwork = true
    // 压测要量的是「每首多久」，文件级并发照选项走（旧组 4 / 新组 8）；
    // `--concurrency N` 可覆盖，用来单独隔离「并发」这一个变量。
    if let c = probeIntArg(args, "--concurrency") { opts.concurrency = c }
    if let d = probeDoubleArg(args, "--deadline") {
        opts.sourceSoftDeadline = d
        opts.slowSourceSoftDeadline = d * 2
    }
    if args.contains("--no-credits") { opts.fetchCredits = false }
    // ★ BH 轮：验「勾了翻译，自动匹配写出去的到底有没有译文」。
    // `--lyrics` 开取词，`--translation` / `--no-translation` 控合并翻译。
    if args.contains("--lyrics") { opts.fetchLyrics = true }
    if args.contains("--no-lyrics") { opts.fetchLyrics = false }
    if args.contains("--translation") { opts.lyricsMerge.includeTranslation = true }
    if args.contains("--no-translation") { opts.lyricsMerge.includeTranslation = false }
    if let n = probeIntArg(args, "--translation-sources") { opts.translationSourceLimit = n }
    // AZ 轮：`--no-early` 关掉「已有高分候选就取消其余源」。
    // 只有一个用途 —— 证明**排序**的确定性时必须先把**取池**的随机性拿掉：
    // 提前收工按各源返回的先后决定谁进池，池子本身每轮都不一样，
    // 拿它去比「三轮胜出者一不一致」比的根本不是排序。正式路径读不到这个开关。
    if args.contains("--no-early") { opts.earlyAcceptScore = 2 }
    if let s = probeListArg(args, "--sources") { opts.sourceIDs = s }
    // 简繁归一：`--zh s` 全部转简体，`--zh t` 转繁体，不给就 `.none`（旧行为）。
    // 用它验「iTunes 中区空 → 回退港区拿到繁体 → 写进来的是简体」这条链。
    opts.chineseVariant = probeZhPolicy(args)
    if !opts.chineseVariant.isIdentity {
        print("  简繁归一 : \(zhDirectionText(opts.chineseVariant))"
              + "（\(ChineseVariant.isAvailable ? "OpenCC 可用" : "OpenCC 不可用，将原样返回")）")
    }

    let deadlineText: String = opts.sourceSoftDeadline > 0
        ? String(format: "%.0f s（慢源 %.0f s）", opts.sourceSoftDeadline, opts.slowSourceSoftDeadline)
        : "关"
    let earlyText: String = opts.earlyAcceptScore <= 1
        ? String(format: "≥%.2f 且 ≥%d 源", opts.earlyAcceptScore, opts.earlyAcceptMinSources)
        : "关"
    var configLine = "  配置   : " + (legacy ? "改前（--legacy）" : "改后")
    configLine += " · 并发 \(opts.concurrency)"
    configLine += " · 软截止 " + deadlineText
    configLine += " · 提前收工 " + earlyText
    configLine += " · 署名 " + (opts.fetchCredits ? "开" : "关")
    configLine += " · 歌词 " + (opts.fetchLyrics ? "开" : "关")
    if opts.fetchLyrics {
        configLine += " · 翻译 " + (opts.lyricsMerge.includeTranslation
            ? "开（\(opts.lyricsMerge.mergeFormat)，最多 \(opts.translationSourceLimit) 源）" : "关")
    }
    if opts.earlyAcceptScore > 1 { configLine += " · 提前收工 关（--no-early）" }
    print(configLine)
    print("  实际源 : \(opts.sourceIDs.joined(separator: " → "))")
    print("")

    let wallStart = Date()
    let outcome = cnRunBlocking { () async -> ([AutoMatchResult], BatchSummary) in
        await AutoMatchService.matchAll(files, options: opts) { p in
            FileHandle.standardError.write("  … \(p.completed)/\(p.total)\n".data(using: .utf8)!)
        }
    }
    let wall = Date().timeIntervalSince(wallStart)

    guard case .success(let (matched, summary)) = outcome else {
        print("  匹配过程异常"); exit(1)
    }
    var results = matched

    // ── 按文件选写哪几个字段（复核表勾选的数据层等价物）──
    //
    // `--exclude-fields` 是整轮的（对应复核表工具条上的「全部字段 ▾」），
    // `--exclude-file N:field` 是**单个文件**的（对应那一行上点一下划线 chip）。
    // 两者叠加：整轮关掉的加上这一行单独关掉的，就是这个文件的排除集。
    let globalExcluded = probeFieldList(args, "--exclude-fields")
    let perFileExcluded = probeExcludeFileMap(args)
    if !globalExcluded.isEmpty || !perFileExcluded.isEmpty {
        print("═══ 字段排除 ═══")
        if !globalExcluded.isEmpty {
            print("  整轮排除 : " + globalExcluded.map(\.localizedName).joined(separator: "、"))
        }
        for (idx, fs) in perFileExcluded.sorted(by: { $0.key < $1.key }) {
            print("  第 \(idx) 个文件另外排除 : " + fs.map(\.localizedName).joined(separator: "、"))
        }
        for i in results.indices {
            var excluded = globalExcluded
            if let extra = perFileExcluded[i + 1] { excluded.formUnion(extra) }
            results[i].acceptedFields.subtract(excluded)
        }
        print("")
    }

    for (i, r) in results.enumerated() {
        let name = r.url.lastPathComponent
        print("─── [\(i + 1)] \(name) " + String(repeating: "─", count: max(0, 46 - cnDisplayWidth(name))))

        // 原标签
        if let before = try? TagService.read(r.url) {
            let t = before.tags
            print("  原标签 : 标题=\(fmt(t.title)) 艺术家=\(fmt(t.artist)) 专辑=\(fmt(t.album)) 年=\(fmt(t.year)) 轨=\(fmt(t.trackString))")
        }

        print("  状态   : \(statusText(r.status))   候选 \(r.candidateCount) 条，查了 \(r.triedSources.count) 个源")

        // A1：逐源结果条 —— 界面顶部那一行 chips 的文字形态，逐字一致。
        if !r.sourceOutcomes.isEmpty {
            print("  结果条 : " + r.sourceOutcomes.inlineSummary)
            for o in r.sourceOutcomes where o.status.isFailure {
                print("           ✘ \(o.displayName)：\(o.detail ?? "未知") "
                      + String(format: "(%.2f s)", o.latency))
            }
        }

        if let b = r.best {
            print("  最佳   : 《\(b.title ?? "-")》— \(b.artist ?? "-")")
            print("           专辑=\(b.album ?? "-") 年=\(b.year ?? "-") 轨=\(b.trackNumber ?? "-") 时长=\(cnFmtDuration(b.durationSeconds))")
            print("           来源=\(b.sourceID)  匹配分=\(String(format: "%.3f", b.matchScore))")
        }

        if let e = r.edit, !e.changes.isEmpty {
            let pairs = e.changes.map { "\($0.field.localizedName)=\($0.value ?? "∅")" }
            print("  将写入 : \(pairs.joined(separator: "  "))")
            // 有排除时把「实际会写的」单列一行：与上一行一对照，
            // 就能一眼看出哪个字段被划掉了。
            let excluded = r.excludedFields
            if !excluded.isEmpty {
                let kept = (r.acceptedEdit?.changes ?? [])
                    .map { "\($0.field.localizedName)=\($0.value ?? "∅")" }
                print("  已排除 : " + TagEdit.Field.allCases.filter { excluded.contains($0) }
                        .map(\.localizedName).joined(separator: "、"))
                print("  实际写 : " + (kept.isEmpty ? "（无）" : kept.joined(separator: "  ")))
            }
        } else if r.status == .matched {
            print("  将写入 : （无字段变化）")
        }

        if let art = r.artwork {
            print("  封面   : \(art.count) 字节" + (r.acceptArtwork ? "" : "（已排除，不写）"))
        }

        // AX 轮：时间花在哪。界面展开行显示的就是这一句，逐字一致。
        print(String(format: "  耗时   : %.2f s   ", r.elapsed) + r.timingLine)

        // B1：保留下来的候选（复核表「换候选 ▾」菜单里的那一串）
        if showCandidates {
            if r.candidates.isEmpty {
                print("  候选   : （无）")
            } else {
                print("  候选 top \(r.candidates.count)（菜单里逐条的文字）：")
                for (j, c) in r.candidates.enumerated() {
                    let mark = (j == 0) ? "✓" : " "
                    print(String(format: "   %@ %2d. %@ · %@ — %@ · %@ · %@ · %@ · %.3f",
                                 mark, j + 1,
                                 SourceOutcome.shortName(c.sourceID),
                                 c.title ?? "未知标题",
                                 c.artist ?? "未知艺术家",
                                 c.album ?? "—",
                                 c.year ?? "—",
                                 cnFmtDuration(c.durationSeconds),
                                 c.matchScore))
                }
            }
        }

        for err in r.errors {
            print("  ⚠ \(err.sourceID): \(err.message)")
        }
        print("")
    }

    print("═══ 统计 ═══")
    print("  \(summary.description)")
    // A1：某个源整轮失败率 ≥50% 时，统计后面追加的那一行
    let perFile = results.map(\.sourceOutcomes)
    if let note = SourceOutcomeAggregator.batchNote(perFile) {
        print("  \(note)")
    }
    print("  整轮结果条 : " + SourceOutcomeAggregator.merge(perFile).inlineSummary)
    // BD 轮：把「失败」拆开。用户说的「QQ / iTunes 一直失败」到底是超时、0 条、
    // 还是我们自己软截止跳过 —— 不拆开就只能得出「时好时坏」。
    printOutcomeBuckets(perFile, tag: probeStringArg(args, "--tag") ?? "automatch")
    autoMatchTimingReport(results, wall: wall)
    autoMatchQualityTable(results)
    print("")
    print("  说明：「忽略」= 有候选但最高分低于阈值 \(opts.acceptThreshold)，")
    print("        本服务不会硬套一个低分候选覆盖用户标签。")

    // ★ BH 轮分阶段耗时。用户说「慢」，不分阶段报数就只能靠猜。
    print("")
    hr("分阶段耗时")
    print("  " + summary.stages.summaryLine)
    if let c = summary.stages.concurrencyLine { print("  " + c) }
    print("")

    if args.contains("--write") {
        autoMatchWriteToCopies(results, keep: args.contains("--keep"), options: opts)
    }
}

// MARK: - --write：把结果写进副本并读回复核

/// **绝不碰源文件**：一律先复制到临时目录，再往副本上写。
/// 这条与 `pacer` / `propagate` 等既有子命令同一个规矩。
private func autoMatchWriteToCopies(_ results: [AutoMatchResult], keep: Bool,
                                    options: AutoMatchOptions = .recommended) {
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-automatch-write-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    print("")
    hr("写入副本并读回复核（--write）")
    print("  工作区 : \(work.path)\(keep ? "（--keep：保留）" : "（收工自动删）")")
    print("")

    var copies: [(src: URL, dst: URL, result: AutoMatchResult)] = []
    for r in results where r.status == .matched {
        let dst = work.appendingPathComponent(r.url.lastPathComponent)
        do { try FileManager.default.copyItem(at: r.url, to: dst) }
        catch { print("  ✘ 复制失败 \(r.url.lastPathComponent)：\(error.localizedDescription)"); continue }
        copies.append((r.url, dst, r))
    }
    guard !copies.isEmpty else {
        print("  没有已匹配的文件可写。")
        if !keep { try? FileManager.default.removeItem(at: work) }
        return
    }

    // 写前的原样，用来证明「被排除的字段一个字都没动」。
    var before: [URL: Tags] = [:]
    for c in copies { before[c.dst] = (try? TagService.read(c.dst))?.tags ?? Tags() }

    var pass = 0, failCount = 0
    // ★ BH 轮：歌词是二段式单独取回来的，**不在 `edit.changes` 里**（`acceptedEdit`
    // 只管字段 + 封面）。App 那边由复核表在组装时把合并好的词并进改动表，
    // probe 这里要原样照做一遍，否则「写入后有没有译文」根本验不到。
    var mergedLyrics: [URL: String] = [:]
    for c in copies {
        guard var edit = c.result.acceptedEdit else { continue }
        if options.fetchLyrics,
           let text = options.lyricsMerge.merged(c.result.lyrics)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            edit.set(.lyrics, text)
            mergedLyrics[c.dst] = text
        }
        do { _ = try TagService.write(edit, to: c.dst) }
        catch { print("  ✘ 写入失败 \(c.dst.lastPathComponent)：\(error.localizedDescription)"); failCount += 1 }
    }

    // .lrc 落盘：与 App 的「歌词文件选项」同一个执行器，好验 `head` 是不是也带译文。
    if !mergedLyrics.isEmpty {
        var fileOpts = LyricsFileOptions()
        fileOpts.enabled = true
        fileOpts.overwriteExisting = true
        var jobs: [LyricsFileJob] = []
        for c in copies {
            guard let text = mergedLyrics[c.dst],
                  let f = try? TagService.read(c.dst) else { continue }
            jobs.append(LyricsFileJob(file: f, text: text, bundle: c.result.lyrics))
        }
        let (written, _, _) = LyricsService.saveLyricsFiles(jobs, options: fileOpts)
        print("  .lrc   : 写出 \(written.count) 个")
        print("")
    }

    for c in copies {
        let name = c.dst.lastPathComponent
        print("─── \(name) " + String(repeating: "─", count: max(0, 46 - cnDisplayWidth(name))))
        guard let after = (try? TagService.read(c.dst))?.tags else {
            print("  ✘ 读回失败"); failCount += 1; continue
        }
        let old = before[c.dst] ?? Tags()
        let excluded = c.result.excludedFields
        let wanted = Dictionary(uniqueKeysWithValues:
            (c.result.edit?.changes ?? []).map { ($0.field, $0.value ?? "") })

        for f in TagEdit.Field.allCases {
            guard let want = wanted[f], !want.isEmpty else { continue }
            let now = tagFieldValue(f, after)
            let was = tagFieldValue(f, old)
            if excluded.contains(f) {
                // 被排除 → 必须还是写入前那个值（而不是新值）
                let ok = now == was
                print("  \(ok ? "✔" : "✘") \(f.localizedName) 已排除：仍是「\(now)」"
                      + (ok ? "" : "（写前是「\(was)」，新值是「\(want)」—— 被写进去了！）"))
                ok ? (pass += 1) : (failCount += 1)
            } else {
                let ok = now == want
                print("  \(ok ? "✔" : "✘") \(f.localizedName) 已写入：「\(was)」→「\(now)」"
                      + (ok ? "" : "（本应是「\(want)」）"))
                ok ? (pass += 1) : (failCount += 1)
            }
        }
        if c.result.artwork != nil {
            let has = !after.artworks.isEmpty
            let hadBefore = !old.artworks.isEmpty
            if c.result.acceptArtwork {
                print("  \(has ? "✔" : "✘") 封面已写入：\(after.artworks.count) 张")
                has ? (pass += 1) : (failCount += 1)
            } else {
                let ok = has == hadBefore
                print("  \(ok ? "✔" : "✘") 封面已排除：写前 \(old.artworks.count) 张，写后 \(after.artworks.count) 张")
                ok ? (pass += 1) : (failCount += 1)
            }
        }
    }

    print("")
    print("  统计口径（复核表脚注）：将修改 "
          + "\(copies.filter { ($0.result.acceptedEdit?.changes.count ?? 0) > 0 }.count) 个文件，共 "
          + "\(copies.reduce(0) { $0 + ($1.result.acceptedEdit?.changes.count ?? 0) }) 处字段"
          + "（不含封面）")
    print("  复核 : 通过 \(pass)，失败 \(failCount)")
    if !keep { try? FileManager.default.removeItem(at: work) }
}

/// 取某字段在一份标签里的当前值。= `AppModel.tagValue(_:in:)`。
private func tagFieldValue(_ field: TagEdit.Field, _ tags: Tags) -> String {
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

// MARK: - 字段排除的参数解析

/// `--exclude-fields disc,track` → [.disc, .track]
/// 认字段的 rawValue（DISCNUMBER）、中文名（碟号）与常用简称（disc/track/…）。
func probeFieldList(_ args: [String], _ flag: String) -> Set<TagEdit.Field> {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return [] }
    return Set(args[i + 1].split(separator: ",").compactMap { probeParseField(String($0)) })
}

/// `--exclude-file 2:disc`（可重复）→ [2: [.disc]]。下标 1 起，与打印出的 `[1] [2]` 对齐。
func probeExcludeFileMap(_ args: [String]) -> [Int: Set<TagEdit.Field>] {
    var out: [Int: Set<TagEdit.Field>] = [:]
    var i = 0
    while i < args.count {
        defer { i += 1 }
        guard args[i] == "--exclude-file", i + 1 < args.count else { continue }
        let spec = args[i + 1]
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let idx = Int(parts[0]) else { continue }
        let fields = Set(parts[1].split(separator: ",").compactMap { probeParseField(String($0)) })
        guard !fields.isEmpty else { continue }
        out[idx, default: []].formUnion(fields)
    }
    return out
}

func probeParseField(_ raw: String) -> TagEdit.Field? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    let lower = s.lowercased()
    for f in TagEdit.Field.allCases {
        if f.rawValue.lowercased() == lower { return f }
        if f.localizedName == s { return f }
    }
    switch lower {
    case "disc", "discnumber", "discno":   return .disc
    case "track", "tracknumber", "trackno": return .track
    case "title":       return .title
    case "artist":      return .artist
    case "albumartist": return .albumArtist
    case "album":       return .album
    case "year", "date": return .year
    case "genre":       return .genre
    case "comment":     return .comment
    case "composer":    return .composer
    case "lyricist":    return .lyricist
    case "lyrics":      return .lyrics
    default:            return nil
    }
}

private func statusText(_ s: AutoMatchResult.Status) -> String {
    switch s {
    case .matched: return "✔ 已匹配"
    case .ignored: return "○ 忽略（低于阈值或无候选）"
    case .failed:  return "✘ 失败（数据源全挂）"
    case .noQuery: return "○ 无可用查询条件"
    }
}

// MARK: - 耗时报表（AX 轮压测的主表）

/// 三组对照要比的四件事：总耗时、每首平均、各源被软截止跳过几次、命中质量有没有退化。
/// 前三件在这里出表；第四件由 `autoMatchQualityTable` 打「专辑/年份」逐首清单，
/// 三组的清单**逐行对照**即可，不必人肉记。
func autoMatchTimingReport(_ results: [AutoMatchResult], wall: TimeInterval) {
    guard !results.isEmpty else { return }

    let each = results.map(\.elapsed).sorted()
    let sum = each.reduce(0, +)
    let avg = sum / Double(each.count)
    let p50 = each[each.count / 2]
    let p90 = each[min(each.count - 1, Int(Double(each.count) * 0.9))]
    let creditsTotal = results.reduce(0) { $0 + $1.creditsLatency }

    print("")
    print("═══ 耗时 ═══")
    print(String(format: "  批量墙钟 : %.2f s（%d 首，并发跑完）", wall, results.count))
    print(String(format: "  每首平均 : %.2f s   中位 %.2f s   p90 %.2f s   最慢 %.2f s",
                 avg, p50, p90, each.last ?? 0))
    print(String(format: "  署名合计 : %.2f s（占单首耗时之和的 %.0f%%）",
                 creditsTotal, sum > 0 ? creditsTotal / sum * 100 : 0))

    // 逐源：平均延迟 + 被跳过次数。「跳过」正是软截止起没起作用的直接证据。
    var lat: [String: [TimeInterval]] = [:]
    var skip: [String: Int] = [:]
    var hits: [String: Int] = [:]
    for r in results {
        for o in r.sourceOutcomes {
            lat[o.sourceID, default: []].append(o.latency)
            if o.status.isSkipped { skip[o.sourceID, default: 0] += 1 }
            if o.status.hitCount > 0 { hits[o.sourceID, default: 0] += 1 }
        }
    }
    print("  逐源     :")
    for id in lat.keys.sorted() {
        let l = lat[id] ?? []
        let a = l.isEmpty ? 0 : l.reduce(0, +) / Double(l.count)
        print(String(format: "    %-14@ 平均 %5.2f s   有结果 %2d/%2d   软截止跳过 %2d",
                     SourceOutcome.displayName(id) as NSString,
                     a, hits[id] ?? 0, l.count, skip[id] ?? 0))
    }

    // 署名来源分布：证明「复用歌词 / 缓存」这两条便宜路径确实在生效。
    var notes: [String: Int] = [:]
    for r in results { notes[r.creditsNote ?? "—", default: 0] += 1 }
    if notes.count > 1 || notes.keys.first != "—" {
        print("  署名来源 : " + notes.sorted { $0.value > $1.value }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: " · "))
    }
}

/// 命中质量清单：三组各打一份，逐行比对即可判断「有没有退化」。
func autoMatchQualityTable(_ results: [AutoMatchResult]) {
    print("")
    print("═══ 命中质量（三组逐行对照用）═══")
    for r in results.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
        let b = r.best
        print(String(format: "  %-34@ %@ | %@ | %@ | %.3f | %@",
                     r.url.deletingPathExtension().lastPathComponent as NSString,
                     (b?.title ?? "—") as NSString,
                     (b?.album ?? "—") as NSString,
                     (b?.year ?? "—") as NSString,
                     b?.matchScore ?? 0,
                     SourceOutcome.shortName(b?.sourceID ?? "—") as NSString))
    }
}

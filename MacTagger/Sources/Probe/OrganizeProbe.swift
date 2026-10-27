//
//  OrganizeProbe.swift
//  mactagger-probe — 「按标签整理到文件夹」验证
//
//    organize <dir> "<模板>" [--root <dir>] [--dry] [--apply] [--undo]
//        --dry    只打印目录树与逐文件原→新（默认）
//        --apply  真的搬，搬完打印实际目录树
//        --undo   撤消最近一批整理，撤完打印实际目录树
//        --root   指定目标根（不给就是「就地整理」：以每个文件当前所在目录为根）
//        --skip-missing / --skip-conflict / --no-companions / --no-art / --keep-empty
//        --delete-source   跨卷复制成功后删源（默认不删）
//
//  语料由 `organize-seed <dir>` 造：两个艺术家 × 两张专辑 × 3 首，
//  含多碟 2/2、缺专辑、两首会重名到同一目标、一首带同名 .lrc、目录里一张 cover.jpg。
//

import Foundation

// MARK: - 目录树打印

/// `find` 的 Swift 版：打印真实磁盘上的目录树（验收用，不看计划、只看盘）。
func printDiskTree(_ root: URL, indent: String = "  ") {
    let fm = FileManager.default
    func walk(_ dir: URL, _ prefix: String) {
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            print("\(prefix)\(isDir.boolValue ? "📁 " : "· ")\(name)")
            if isDir.boolValue { walk(url, prefix + "   ") }
        }
    }
    print("\(indent)📁 \(root.lastPathComponent)/")
    walk(root, indent + "   ")
}

/// 打印计划里的预览树（界面 OutlineGroup 画的就是这棵）。
private func printPlanTree(_ nodes: [OrganizeTreeNode], prefix: String = "    ") {
    for n in nodes {
        let mark: String
        switch n.kind {
        case .root:              mark = "📁"
        case .folder(let isNew): mark = isNew ? "📁+" : "📁"
        case .file:              mark = "·"
        }
        var tail = ""
        if !n.isFile { tail = "  (\(n.fileCount) 个文件)" }
        if n.isCrossVolume { tail += "  [跨卷]" }
        if let r = n.status?.reason { tail += "  （\(r)）" }
        if !n.notes.isEmpty { tail += "  ⚠︎ " + n.notes.joined(separator: "；") }
        print("\(prefix)\(mark) \(n.name)\(tail)")
        if let kids = n.children { printPlanTree(kids, prefix: prefix + "   ") }
    }
}

// MARK: - 历史库路径同步核验

/// 打印历史库里**路径落在 `dir` 之下**的记录，用来验证 `updateFilePath` 有没有跟上搬运。
private func dumpHistoryUnder(_ dir: URL, label: String) {
    guard let store = try? TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL()),
          let all = try? store.allHistory(limit: 500) else {
        print("  \(label)：历史库不可用")
        return
    }
    let hits = all.filter { $0.filePath.hasPrefix(dir.path) || $0.filePath.hasPrefix(dir.standardizedFileURL.path) }
    print("  \(label)：命中 \(hits.count) 条")
    for h in hits { print("      #\(h.serial) \(h.filePath)") }
}

// MARK: - organize

func cmdOrganize(_ dirPath: String, _ raw: String, args: [String]) {

    let dir = URL(fileURLWithPath: dirPath, isDirectory: true).standardizedFileURL
    let apply = args.contains("--apply")
    let undo = args.contains("--undo")
    let rootArg = args.firstIndex(of: "--root").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

    var options = OrganizeOptions.default
    if args.contains("--skip-missing")  { options.missing = .skipFile }
    if args.contains("--skip-conflict") { options.conflict = .skip }
    if args.contains("--no-companions") { options.moveCompanions = false }
    if args.contains("--no-art")        { options.moveFolderArtwork = false }
    if args.contains("--keep-empty")    { options.deleteEmptySourceFolders = false }
    if args.contains("--delete-source") { options.deleteSourceAfterCrossVolumeCopy = true }

    // —— 撤消分支 ——
    if undo {
        hr("撤消最近一批整理")
        guard let journal = RenameJournal.shared else { print("  日志不可用"); return }
        guard let batch = journal.lastBatch() else { print("  没有可撤消的批次"); return }
        print("  批次时间  : \(batch.date)")
        print("  批次种类  : \(batch.kind.localizedName)")
        print("  条目      : 主文件 \(batch.fileCount) 个，伴随 \(batch.companionCount) 个，"
              + "跨卷复制 \(batch.copyCount) 个")
        print("  本批建目录: \(batch.createdDirectories.count) 个")
        guard batch.kind == .organize else {
            print("  ✗ 最近一批不是「整理到文件夹」，拒绝撤消（用 rename-undo）")
            return
        }
        let history = try? TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL())
        let outcome = journal.undoLastBatch(history: history)
        print("")
        for (from, to) in outcome.restored {
            print("    ← \(from.lastPathComponent)  ⇐  \(to.path)")
        }
        for u in outcome.deletedCopies { print("    ✕ 删副本 \(u.path)") }
        for f in outcome.summary.failures {
            print("    ✗ \(f.url.lastPathComponent)：\(f.error.localizedDescription)")
        }
        print("")
        print("  删掉的空目录: \(outcome.removedDirectories.count) 个")
        for d in outcome.removedDirectories { print("      - \(d.path)") }
        print("  结果      : \(outcome.summary.description)")
        print("  剩余批次  : \(journal.batchCount())")
        if args.contains("--hist") { dumpHistoryUnder(dir, label: "撤消后历史库路径") }
        print("")
        print("  撤消后的实际目录树（find 口径）：")
        printDiskTree(dir)
        return
    }

    hr("按标签整理到文件夹\(apply ? "" : "（预览，不落盘）")")
    print("  源目录  : \(dir.path)")
    print("  模板    : \(raw)")
    print("  目标根  : \(rootArg ?? "（就地整理：每个文件当前所在目录）")")
    print("  缺字段  : \(options.missing.localizedName)")
    print("  重名    : \(options.conflict.localizedName)")

    if let problem = FilenameTemplate.validatePath(raw) {
        print("  ✗ 模板不合法：\(problem)")
        return
    }
    guard let template = try? FilenameTemplate.parse(raw, mode: .rename) else {
        print("  ✗ 模板无法解析"); return
    }
    print("  层级    : " + template.levels.enumerated().map { i, level in
        let text = level.map { seg -> String in
            switch seg {
            case .literal(let s):  return s
            case .parameter(let f): return f.token
            }
        }.joined()
        return i == template.levels.count - 1 ? "文件名「\(text)」" : "第\(i + 1)级「\(text)」"
    }.joined(separator: " / "))

    // 递归收集音频（整理的典型场景就是「一堆嵌套目录」）。
    let audioExts = Set(TagService.supportedExtensions.map { $0.lowercased() })
    var urls: [URL] = []
    if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
        for case let u as URL in e where audioExts.contains(u.pathExtension.lowercased()) {
            urls.append(u.standardizedFileURL)
        }
    }
    urls.sort { $0.path < $1.path }
    guard !urls.isEmpty else { print("  目录里没有可识别的音频文件"); return }

    var items: [(url: URL, tags: Tags)] = []
    for u in urls {
        guard let f = try? TagService.read(u) else { continue }
        items.append((u, f.tags))
    }
    print("  文件数  : \(items.count)")

    let root: OrganizeRoot = rootArg
        .map { .fixed(URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL) }
        ?? .eachFileFolder
    let plan = LibraryOrganizer.plan(items: items, template: template, root: root, options: options)

    if let e = plan.ruleError { print("  ✗ \(e)"); return }

    print("")
    print("  预览目录树（📁+ = 本次新建）：")
    printPlanTree(plan.tree)

    print("")
    print("  逐文件 原 → 新：")
    for p in plan.items {
        let mark: String
        switch p.status {
        case .ready:     mark = p.isCrossVolume ? "⇒" : "→"
        case .unchanged: mark = "·"
        case .skipped:   mark = "⊘"
        case .invalid:   mark = "✗"
        }
        let tail = p.status.reason.map { "   （\($0)）" } ?? ""
        let note = p.notes.isEmpty ? "" : "   ⚠︎ " + p.notes.joined(separator: "；")
        print("    \(mark) \(p.sourceURL.path)")
        print("        \(p.status.isReady ? p.targetURL.path : "—")\(tail)\(note)")
        for c in p.companions {
            print("        ＋ \(c.from.lastPathComponent)  ⇒  \(c.to.path)")
        }
    }
    if !plan.folderArtworkMoves.isEmpty {
        print("")
        print("  文件夹封面（整组搬走才跟着走）：")
        for (from, to) in plan.folderArtworkMoves { print("    🖼 \(from.path)\n        \(to.path)") }
    }

    print("")
    print("  新建目录 \(plan.newDirectories.count) 个：")
    for d in plan.newDirectories { print("      + \(d.path)") }
    print("")
    print("  统计    : \(plan.summaryLine)")
    print("            可执行 \(plan.readyCount) · 跳过 \(plan.skippedCount) · "
          + "已在位 \(plan.unchangedCount) · 失败 \(plan.invalidCount) · 跨卷 \(plan.crossVolumeCount)")

    guard apply else {
        print("")
        print("  （--dry，未落盘。加 --apply 才真的搬）")
        return
    }

    let history = try? TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL())

    // `--hist`：给前两个可执行文件各记一条历史，搬完再查，验证路径同步跟得上。
    if args.contains("--hist") {
        for item in plan.readyItems.prefix(2) {
            let tags = items.first { $0.url == item.sourceURL }?.tags ?? Tags()
            if let serial = try? history?.record(filePath: item.sourceURL.path, tags: tags) {
                print("  历史种子: #\(serial ?? "?") \(item.sourceURL.path)")
            }
        }
        dumpHistoryUnder(dir, label: "搬运前历史库路径")
    }

    let outcome = LibraryOrganizer.execute(plan, options: options,
                                           journal: RenameJournal.shared, history: history)
    print("")
    if args.contains("--hist") { dumpHistoryUnder(dir, label: "搬运后历史库路径") }
    print("  结果    : \(outcome.summary.description)")
    print("  同卷移动: \(outcome.moved.count)   跨卷复制: \(outcome.copied.count)   "
          + "伴随/封面: \(outcome.movedCompanions.count)")
    print("  新建目录: \(outcome.createdDirectories.count)   删空目录: \(outcome.removedEmptyDirectories.count)")
    for d in outcome.removedEmptyDirectories { print("      - \(d.path)") }
    for f in outcome.summary.failures {
        print("    ✗ \(f.url.lastPathComponent)：\(f.error.localizedDescription)")
    }
    print("  日志    : 共 \(RenameJournal.shared?.batchCount() ?? 0) 批")

    print("")
    print("  落盘后的实际目录树（find 口径）：")
    printDiskTree(dir)
    if let r = rootArg {
        let rootURL = URL(fileURLWithPath: r, isDirectory: true)
        if rootURL.standardizedFileURL.path != dir.path {
            print("")
            print("  目标根的实际目录树：")
            printDiskTree(rootURL)
        }
    }
}

// MARK: - organize-seed（造语料）

/// 在 `dir` 下平铺造 12 个音频副本 + 一张 cover.jpg，标签按验收清单写好。
///
/// 语料设计（对应验收项）：
///   · 两个艺术家 × 两张专辑 × 3 首                 → 目录结构
///   · 03 号一首碟号 2/2                            → 多碟才出现碟号段
///   · 一首缺专辑                                    → 落「未知专辑」
///   · 两首标题/艺术家/专辑全同                      → 重名加 (2)
///   · 第一首带同名 .lrc                             → 伴随文件跟随
///   · 目录下一张 cover.jpg                          → 整组搬走时跟随
func cmdOrganizeSeed(_ dirPath: String, _ samplePath: String) {
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
    let sample = URL(fileURLWithPath: samplePath)
    let fm = FileManager.default
    hr("造整理语料")

    guard fm.fileExists(atPath: sample.path) else { fail("样本文件不存在：\(sample.path)") }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = sample.pathExtension

    /// (文件名, 标题, 艺术家, 专辑艺术家, 专辑, 年份, 音轨, 碟号/总碟)
    let spec: [(String, String, String, String, String?, String, Int, String?)] = [
        ("a01", "夜曲",     "周杰伦", "周杰伦", "十一月的萧邦", "2005", 1,  nil),
        ("a02", "发如雪",   "周杰伦", "周杰伦", "十一月的萧邦", "2005", 2,  nil),
        ("a03", "黑色毛衣", "周杰伦", "周杰伦", "十一月的萧邦", "2005", 10, nil),
        ("a04", "稻香",     "周杰伦", "周杰伦", "魔杰座",       "2008", 3,  nil),
        ("a05", "给我一首歌的时间", "周杰伦", "周杰伦", "魔杰座", "2008", 1, nil),
        ("a06", "花海",     "周杰伦", "周杰伦", "魔杰座",       "2008", 5,  "2/2"),   // 多碟
        ("b01", "小酒窝",   "林俊杰", "林俊杰", "JJ 陆",        "2008", 4,  nil),
        ("b02", "背对背拥抱", "林俊杰", "林俊杰", "JJ 陆",      "2008", 7,  nil),
        ("b03", "西界",     "林俊杰", "林俊杰", "JJ 陆",        "2008", 12, nil),
        ("b04", "无题",     "林俊杰", "林俊杰", nil,            "2010", 2,  nil),     // 缺专辑
        ("c01", "重名曲",   "陈奕迅", "陈奕迅", "U87",          "2005", 6,  nil),     // 与 c02 同目标
        ("c02", "重名曲",   "陈奕迅", "陈奕迅", "U87",          "2005", 6,  nil),
    ]

    for (name, title, artist, albumArtist, album, year, track, disc) in spec {
        let url = dir.appendingPathComponent("\(name).\(ext)")
        try? fm.removeItem(at: url)
        do { try fm.copyItem(at: sample, to: url) }
        catch { print("  ✗ 复制失败 \(name)：\(error.localizedDescription)"); continue }

        var edit = TagEdit()
        edit.set(.title, title)
        edit.set(.artist, artist)
        edit.set(.albumArtist, albumArtist)
        edit.set(.album, album)
        edit.set(.year, year)
        edit.set(.track, String(track))
        edit.set(.disc, disc)
        do {
            _ = try TagService.write(edit, to: url)
            let back = try TagService.read(url)
            print("  ✓ \(url.lastPathComponent)  标题=\(fmt(back.tags.title)) "
                  + "艺术家=\(fmt(back.tags.artist)) 专辑=\(fmt(back.tags.album)) "
                  + "音轨=\(fmt(back.tags.trackString)) 碟=\(fmt(back.tags.discString))")
        } catch {
            print("  ✗ 写标签失败 \(name)：\(error.localizedDescription)")
        }
    }

    // 伴随文件：a01.lrc
    let lrc = dir.appendingPathComponent("a01.lrc")
    try? "[00:00.00]夜曲\n[00:05.00]一群嗜血的蚂蚁\n".write(to: lrc, atomically: true, encoding: .utf8)
    print("  ✓ 伴随文件 \(lrc.lastPathComponent)")

    // 最小合法 JPEG，够 FolderArtwork.locate 认出来。
    var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
    jpeg.append(Data(repeating: 0x20, count: 256))
    jpeg.append(Data([0xFF, 0xD9]))

    // ① 平铺目录里的 cover.jpg：这个目录装着 4 张专辑，封面**不该**跟任何一组走。
    let cover = dir.appendingPathComponent("cover.jpg")
    try? jpeg.write(to: cover)
    print("  ✓ 平铺目录封面 \(cover.lastPathComponent)（\(jpeg.count) 字节，多专辑混放，预期不跟随）")

    // ② 一个「一目录一专辑」的子目录：整组会搬走，封面**应该**跟着走，
    //    搬空之后这个目录还应该被「删空文件夹」收掉。
    let albumDir = dir.appendingPathComponent("孙燕姿 - 逆光", isDirectory: true)
    try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
    let albumSpec: [(String, String, Int)] = [
        ("d01", "逆光",       1),
        ("d02", "我怀念的",   3),
        ("d03", "跳舞的梵谷", 8),
    ]
    for (name, title, track) in albumSpec {
        let url = albumDir.appendingPathComponent("\(name).\(ext)")
        try? fm.removeItem(at: url)
        do { try fm.copyItem(at: sample, to: url) }
        catch { print("  ✗ 复制失败 \(name)：\(error.localizedDescription)"); continue }
        var edit = TagEdit()
        edit.set(.title, title)
        edit.set(.artist, "孙燕姿")
        edit.set(.albumArtist, "孙燕姿")
        edit.set(.album, "逆光")
        edit.set(.year, "2007")
        edit.set(.track, String(track))
        do {
            _ = try TagService.write(edit, to: url)
            print("  ✓ 孙燕姿 - 逆光/\(url.lastPathComponent)  标题=\"\(title)\" 音轨=\(track)")
        } catch {
            print("  ✗ 写标签失败 \(name)：\(error.localizedDescription)")
        }
    }
    let albumCover = albumDir.appendingPathComponent("folder.jpg")
    try? jpeg.write(to: albumCover)
    print("  ✓ 专辑目录封面 孙燕姿 - 逆光/folder.jpg（整组搬走，预期跟随 + 源目录被删）")

    print("")
    print("  语料就绪：")
    printDiskTree(dir)
}

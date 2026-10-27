//
//  main.swift
//  mactagger-probe — 命令行验证工具
//
//  用途：不依赖 GUI 就能验证桥接层、生成 17 格式能力矩阵、跑冒烟流程。
//
//  子命令：
//    env                     打印 TagLib 版本与支持的扩展名
//    read <file>             完整读取并打印
//    smoke <file>            读 → 改 → 写 → 复核（会修改传入文件，请用副本）
//    matrix <dir>            对目录内所有音频跑活体能力探测，输出 Markdown 表
//    history                 SQLite 历史库自检（用临时库）
//    robust <dir>            畸形文件健壮性测试（必须不崩溃）
//    encoding <file>         遍历各 legacy 编码策略读取同一文件
//    volume <path>           打印该路径所在卷的 removable/ejectable/internal 判定
//    pacer <dir> [--simulate-slow] [--mixed] [--seq] [--no-pacer]
//                            可移动存储写入节流器实测（副本上做，源目录零改动）
//    propagate <dir> [--overwrite] [--field album=…] [--keep]
//                            「统一 / 补齐标签」：临时目录造 kun 场景，打印字段值分布、
//                            计划、应用后复核，外加进度条字节口径前后对照
//    folderctx [path]        从路径推断专辑上下文 + 跑内置用例表
//    sources health [--fail-source qq]
//    sources limiter [sourceID] [--n 60] [--concurrency 4] [--interval 秒] [--both]
//                            限速器并发正确性：不发网络请求，只量发包节拍，
//                            断言相邻发包间隔的最小值 ≥ interval×0.95
//                            逐源健康探测：固定探测曲各打一枪，打印三态表与结果条
//    automatch <dir> [--show-candidates] [--fail-source qq]
//                    [--exclude-fields disc,track] [--exclude-file 2:disc] [--write] [--keep]
//                            自动匹配：逐源结果条 + 每文件 top10 候选；
//                            后三个开关演示「按文件选写哪几个字段」（复核表勾选的数据层等价物）
//    quickfilter <样本音频> <封面图> [--keep]
//                            快捷筛选（无封面/无歌词…，多选取交集）与封面/歌词列排序的模型层自检
//    fieldpick [--keep]      按文件选写字段的**离线**闭环：造结果 → 排除 → 写盘 → 读回复核
//    album <sourceID> <词>   联网打印专辑候选与整碟曲目表
//    albummatch <dir> [--ignore-tags] [--write] [--copies] [--keep] [--lyrics] [--translation|--no-translation] [--sources a,b]
//                            专辑模式（按文件夹）匹配：打分、选中专辑、逐文件对齐
//    albumdisc               双碟对齐离线自检：一对一 + 碟号归属 + 音轨列显示
//    albumtie                专辑候选同分确定性离线自检（分数浮点噪声 + 入池顺序，BP-E）
//    tracknum                音轨号/碟号「写入值」离线自检：该碟内序号/该碟曲目数
//    albumcompare <dir>      同一批文件跑逐首模式，与专辑模式并列对照
//    writecost <dir> <image> [--appflow] [--keep]
//                            写入代价预估 vs 实测（副本上做，源目录零改动）
//    clearbatch <dir> [--keep]
//                            带进度的批量清除演示（副本上做）
//    padding <dir> <image> [--keep]
//    padding inspect <file>              打印文件头元数据区结构与当前填充
//    padding reserve <file副本> [--bytes N]
//                            把文件头填充扩到 N 字节（默认 512 KB），并复核技术参数
//    padding demo <flac副本> <大图>       预留填充五步演示（嵌封面→扩填充→换封面→改标题→越上限）
//    policy demo <dir> <大图> [--keep]
//                            封面策略 + 预留填充六步演示（副本上做，源目录零改动）
//    folderart <dir> <image> [--folder|--album] [--overwrite]
//                            往目录下每个含音频的文件夹写一张封面（音频零改动）
//    folderart-locate <dir>  列出每个文件夹已有的封面文件
//                            TagLib 整文件重写后留下多少填充（决定下次写图要不要再重写）
//    zh env                  OpenCC 环境自检 + 四个方向的样例转换
//    zh convert --to s|t "<文本>"
//                            单串简繁转换
//    zh batch <dir> --tags|--filenames --to s|t [--apply] [--undo] [--keep]
//                            批量简繁转换（副本上做，源目录零改动）
//

import Foundation

// MARK: - 输出工具

func out(_ s: String = "") { print(s) }
func hr(_ title: String) {
    out()
    out("=== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
}

func fmt(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "nil" }

@discardableResult
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("错误：" + msg + "\n").utf8))
    exit(1)
}

// MARK: - 子命令实现

func cmdEnv() {
    hr("环境")
    out("TagLib 版本        : \(TagService.taglibVersion)")
    let exts = TagService.supportedExtensions
    out("TagLib 支持扩展名  : \(exts.count) 种")
    out("  " + exts.joined(separator: " "))
    out()
    let target = ["flac", "ape", "wav", "aiff", "wv", "tta", "mp3", "mp4", "m4a",
                  "ogg", "mpc", "opus", "wma", "dsf", "dff", "aac", "tak"]
    out("原版 17 格式在 TagLib 扩展名表中的命中情况：")
    for t in target {
        let hit = exts.contains(t)
        out(String(format: "  %-5s %@", (t as NSString).utf8String!, hit ? "✔ 在列表内" : "✘ 不在列表内"))
    }
}

func dump(_ file: AudioFile) {
    out("路径        : \(file.url.path)")
    out("只读        : \(file.isReadOnly)")
    out("标签容器    : \(file.tagContainers.joined(separator: ", "))")
    out("--- 技术参数 ---")
    let t = file.technical
    out("时长        : \(t.formattedDuration)  (\(t.durationMilliseconds) ms)")
    out("编码 / 容器 : \(t.codecName) / \(t.containerName)")
    out("比特率      : \(t.bitrateKbps) kbps")
    out("采样率      : \(t.sampleRate) Hz")
    out("声道        : \(t.channels)")
    out("位深        : \(t.bitsPerSample) bit")
    out("无损        : \(t.isLossless)")
    out("文件大小    : \(t.fileSizeBytes) 字节")
    out("--- 标签 ---")
    let g = file.tags
    out("标题        : \(fmt(g.title))")
    out("艺术家      : \(fmt(g.artist))")
    out("专辑艺术家  : \(fmt(g.albumArtist))")
    out("专辑        : \(fmt(g.album))")
    out("年份        : \(fmt(g.year))")
    out("音轨        : \(fmt(g.trackString))")
    out("碟号        : \(fmt(g.discString))")
    out("流派        : \(fmt(g.genre))")
    out("作曲        : \(fmt(g.composer))")
    out("注释        : \(fmt(g.comment))")
    out("歌词        : \(fmt(g.lyrics.map { $0.replacingOccurrences(of: "\n", with: "\\n") }))")
    out("封面        : \(g.artworks.count) 张")
    for (i, a) in g.artworks.enumerated() {
        out("  [\(i)] \(a.type.localizedName) \(a.mimeType ?? "?") \(a.byteCount) 字节 desc=\(fmt(a.caption)) 尺寸声明=\(a.declaredWidth)x\(a.declaredHeight)")
    }
    if !g.rawProperties.isEmpty {
        out("--- TagLib 原始属性 ---")
        for k in g.rawProperties.keys.sorted() {
            out("  \(k) = \((g.rawProperties[k] ?? []).joined(separator: " | "))")
        }
    }
    if !g.unsupportedProperties.isEmpty {
        out("不支持的键  : \(g.unsupportedProperties.joined(separator: ", "))")
    }
    if !file.diagnostics.isEmpty {
        out("--- TagLib 诊断 ---")
        file.diagnostics.forEach { out("  ! \($0)") }
    }
}

func cmdRead(_ path: String) {
    hr("读取 \((path as NSString).lastPathComponent)")
    do { dump(try TagService.read(URL(fileURLWithPath: path))) }
    catch { fail(error.localizedDescription) }
}

/// 一次完整的读→改→写→复核。返回是否成功。
@discardableResult
func cmdSmoke(_ path: String, quiet: Bool = false) -> Bool {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    if !quiet { hr("冒烟验证 \(name)") }

    // 1. 读
    let before: AudioFile
    do { before = try TagService.read(url) }
    catch { out("① 读失败：\(error.localizedDescription)"); return false }
    if !quiet {
        out("① 写前读取:")
        out("   标题=\(fmt(before.tags.title)) 艺术家=\(fmt(before.tags.artist)) 专辑=\(fmt(before.tags.album)) 音轨=\(fmt(before.tags.trackString)) 封面=\(before.tags.artworks.count)")
        out("   技术参数: \(before.technical.summary) 时长 \(before.technical.formattedDuration)")
        out("   标签容器: \(before.tagContainers.joined(separator: ", "))")
    }

    // 2. 改（含中文与 Unicode，验证 UTF-8 往返）
    let stamp = Int(Date().timeIntervalSince1970)
    var draft = before.tags
    draft.title = "冒烟标题-\(stamp)-Ünïcode"
    draft.artist = "测试艺术家 / Test Artist"
    draft.album = "专辑《验证》"
    draft.albumArtist = "专辑艺术家"
    draft.year = "2026"
    draft.trackNumber = 7
    draft.trackTotal = 12
    draft.discNumber = 1
    draft.discTotal = 2
    draft.genre = "民谣"
    draft.composer = "作曲者"
    draft.comment = "由 mactagger-probe 写入"
    draft.lyrics = "[00:00.00]第一行\n[00:05.00]第二行"

    let edit = TagEdit.diff(from: before.tags, to: draft)
    if !quiet {
        out("② 差异编辑集（只写这些字段）:")
        out("   " + edit.changes.map { "\($0.field.rawValue)=\($0.value ?? "<删除>")" }
            .joined(separator: ", "))
    }

    // 3. 写
    let outcome: WriteOutcome
    do { outcome = try TagService.write(edit, to: url) }
    catch { out("③ 写失败：\(error.localizedDescription)"); return false }
    if !quiet {
        out("③ 写入返回: " + (outcome.isComplete ? "完全成功"
                             : "部分成功，被拒字段 \(outcome.rejectedKeys.joined(separator: ","))"))
    }

    // 4. 复核
    let after: AudioFile
    do { after = try TagService.read(url) }
    catch { out("④ 复核读失败：\(error.localizedDescription)"); return false }

    var mismatches: [String] = []
    func check(_ label: String, _ expected: String?, _ actual: String?) {
        let e = (expected?.isEmpty ?? true) ? nil : expected
        let a = (actual?.isEmpty ?? true) ? nil : actual
        if e != a { mismatches.append("\(label): 期望 \(fmt(e))，实得 \(fmt(a))") }
    }
    check("TITLE", draft.title, after.tags.title)
    check("ARTIST", draft.artist, after.tags.artist)
    check("ALBUM", draft.album, after.tags.album)
    check("ALBUMARTIST", draft.albumArtist, after.tags.albumArtist)
    check("DATE", draft.year, after.tags.year)
    check("TRACKNUMBER", draft.trackString, after.tags.trackString)
    check("DISCNUMBER", draft.discString, after.tags.discString)
    check("GENRE", draft.genre, after.tags.genre)
    check("COMPOSER", draft.composer, after.tags.composer)
    check("COMMENT", draft.comment, after.tags.comment)
    check("LYRICS", draft.lyrics, after.tags.lyrics)

    // 被格式拒绝的字段不算失败
    let rejected = Set(outcome.rejectedKeys)
    mismatches = mismatches.filter { line in
        !rejected.contains(where: { line.hasPrefix($0 + ":") })
    }

    if !quiet {
        out("④ 写后复核读取:")
        out("   标题=\(fmt(after.tags.title))")
        out("   艺术家=\(fmt(after.tags.artist))  专辑=\(fmt(after.tags.album))")
        out("   专辑艺术家=\(fmt(after.tags.albumArtist))  年份=\(fmt(after.tags.year))")
        out("   音轨=\(fmt(after.tags.trackString))  碟号=\(fmt(after.tags.discString))")
        out("   流派=\(fmt(after.tags.genre))  作曲=\(fmt(after.tags.composer))")
        out("   注释=\(fmt(after.tags.comment))")
        out("   歌词=\(fmt(after.tags.lyrics.map { $0.replacingOccurrences(of: "\n", with: "\\n") }))")
        out("   标签容器=\(after.tagContainers.joined(separator: ", "))")
    }

    // 5. 封面写入
    var artworkOK = false
    let png = onePixelPNG()
    var artEdit = TagEdit()
    artEdit.artworkAction = .replace([Artwork(data: png, mimeType: "image/png",
                                              caption: "smoke", type: .frontCover)])
    if (try? TagService.write(artEdit, to: url)) != nil,
       let arts = try? TagService.readArtworks(url), arts.count == 1,
       arts[0].data == png {
        artworkOK = true
    }
    if !quiet { out("⑤ 封面写入并回读: " + (artworkOK ? "成功" : "失败/不支持")) }

    let ok = mismatches.isEmpty
    if !quiet {
        if ok { out("⑥ 复核结论: 全部字段一致 ✔") }
        else {
            out("⑥ 复核结论: 有 \(mismatches.count) 处不一致 ✘")
            mismatches.forEach { out("   - \($0)") }
        }
    }
    return ok
}

func onePixelPNG() -> Data {
    Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,
          0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
          0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,0xDE,0x00,0x00,0x00,
          0x0C,0x49,0x44,0x41,0x54,0x08,0xD7,0x63,0xF8,0xCF,0xC0,0x00,
          0x00,0x03,0x01,0x01,0x00,0x18,0xDD,0x8D,0xB0,0x00,0x00,0x00,
          0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82])
}

/// 原版 MusicTag 支持的 17 种格式，按报告顺序。
let kTargetFormats = ["flac", "ape", "wav", "aiff", "wv", "tta", "mp3", "mp4", "m4a",
                      "ogg", "mpc", "opus", "wma", "dsf", "dff", "aac", "tak"]

func cmdMatrix(_ dir: String) {
    let fm = FileManager.default
    let dirURL = URL(fileURLWithPath: dir)
    guard let items = try? fm.contentsOfDirectory(at: dirURL,
                                                  includingPropertiesForKeys: nil) else {
        fail("无法读取目录 \(dir)")
    }
    // ext -> url
    var byExt: [String: URL] = [:]
    for u in items where !u.hasDirectoryPath {
        let e = u.pathExtension.lowercased()
        if kTargetFormats.contains(e) && byExt[e] == nil { byExt[e] = u }
    }

    hr("17 格式能力矩阵（实测）")
    out("测试目录: \(dirURL.path)")
    out("TagLib  : \(TagService.taglibVersion)")
    out()
    out("| 格式 | 测试文件 | TagLib 认扩展名 | 能读 | 能写 | 封面 | 容器/编码 | 时长 | 备注 |")
    out("|---|---|:-:|:-:|:-:|:-:|---|---|---|")

    var readable = 0, writable = 0, artworkable = 0

    for ext in kTargetFormats {
        let recognized = TagService.supportedExtensions.contains(ext)
        guard let url = byExt[ext] else {
            out("| \(ext.uppercased()) | — | \(recognized ? "是" : "否") | — | — | — | — | — | 未生成测试文件 |")
            continue
        }
        let p = TagService.probe(url)
        if p.canRead { readable += 1 }
        if p.canWrite { writable += 1 }
        if p.canWriteArtwork { artworkable += 1 }
        let dur = p.durationMs > 0 ? String(format: "%.2fs", Double(p.durationMs)/1000.0) : "—"
        let codec = p.canRead ? "\(p.container) / \(p.codec)" : "—"
        var note = p.note
        if note.isEmpty { note = "—" }
        note = note.replacingOccurrences(of: "|", with: "/")
        out("| \(ext.uppercased()) | \(url.lastPathComponent) | \(recognized ? "是" : "否") | \(p.canRead ? "✔" : "✘") | \(p.canWrite ? "✔" : "✘") | \(p.canWriteArtwork ? "✔" : "✘") | \(codec) | \(dur) | \(note) |")
    }

    out()
    out("合计：可读 \(readable)/17，可写 \(writable)/17，封面可写 \(artworkable)/17")
}

func cmdHistory() {
    hr("SQLite 历史库自检")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-history-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: tmp) }

    do {
        let store = try TagsHistoryStore(databaseURL: tmp)
        out("① 建库成功: \(tmp.path)")
        out("   初始 thserial_prefix = \(try store.serialPrefix())")

        var t1 = Tags()
        t1.title = "旧标题"; t1.artist = "旧艺术家"; t1.album = "旧专辑"
        t1.year = "1999"; t1.trackNumber = 3; t1.trackTotal = 12
        t1.discNumber = 1; t1.discTotal = 2
        let s1 = try store.record(filePath: "/tmp/a.mp3", tags: t1)
        out("② 写入历史 1，流水号 = \(s1)（长度 \(s1.count)）")

        var t2 = t1; t2.title = "第二次的旧标题"
        let s2 = try store.record(filePath: "/tmp/a.mp3", tags: t2)
        out("   写入历史 2，流水号 = \(s2)")
        let s3 = try store.record(filePath: "/tmp/b.flac", tags: t1)
        out("   写入历史 3（另一文件），流水号 = \(s3)")
        out("   总记录数 = \(try store.entryCount())")

        let h = try store.history(forFilePath: "/tmp/a.mp3")
        out("③ 按 filepath 查询 /tmp/a.mp3 → \(h.count) 条")
        for e in h {
            out("   \(e.serial)  \(e.createdAtRaw)  标题=\(fmt(e.title)) 音轨=\(fmt(e.trackString))")
        }
        if let first = h.first {
            let undo = first.undoEdit
            out("   撤销编辑集: " + undo.changes.map { "\($0.field.rawValue)=\($0.value ?? "<删除>")" }
                .joined(separator: ", "))
            out("   还原成 Tags: 标题=\(fmt(first.restoredTags.title)) 音轨号=\(first.restoredTags.trackNumber.map(String.init) ?? "nil") 总数=\(first.restoredTags.trackTotal.map(String.init) ?? "nil")")
        }

        let moved = try store.updateFilePath(from: "/tmp/a.mp3", to: "/tmp/renamed.mp3")
        out("④ 重命名同步 filepath → 影响 \(moved) 行")
        out("   /tmp/renamed.mp3 历史 = \(try store.history(forFilePath: "/tmp/renamed.mp3").count) 条")

        let del = try store.delete(filePath: "/tmp/renamed.mp3")
        out("⑤ 按 filepath 删除 → \(del) 行；剩余 \(try store.entryCount()) 条")

        try store.clearAll(resetPrefixTo: 0)
        out("⑥ 清空全部并重置前缀 → 剩余 \(try store.entryCount()) 条，thserial_prefix = \(try store.serialPrefix())")
        store.close()
        out("⑦ 关闭成功 ✔")
    } catch {
        out("自检失败：\(error.localizedDescription)")
        exit(1)
    }
}

func cmdRobust(_ dir: String) {
    hr("畸形文件健壮性测试（不得崩溃）")
    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: dir)

    // 这个测试**会写**（每个夹具都试一次 TagService.write），所以必须先整目录复制到
    // 临时目录再跑，永不改动传入目录 —— 与 `matrix` / `batch` 的做法一致。
    // 曾经它是就地改写的：跑完一次，testdata/malformed/ 里一半夹具的标题就变成了
    // 「健壮性测试」，基线 sha 从此记的是被污染过的内容（见 AK 报告）。
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-robust-\(getpid())-\(Int(Date().timeIntervalSince1970))",
                                isDirectory: true)
    do {
        try fm.copyItem(at: sourceURL, to: work)
    } catch {
        fail("无法复制目录 \(dir) → 临时工作区：\(error.localizedDescription)")
    }
    // 只读夹具（readonly.mp3 是 0444）会让整棵临时树删不干净，收工前放开权限。
    // 用 0755 而不是 0644：树里还有个 `a_directory.mp3`（伪装成文件的目录），
    // 目录丢了 x 位就再也进不去、也删不掉。
    defer {
        if let all = fm.enumerator(at: work, includingPropertiesForKeys: nil) {
            for case let u as URL in all {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            }
        }
        try? fm.removeItem(at: work)
    }

    let dirURL = work
    guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else {
        fail("无法读取目录 \(work.path)")
    }
    out("源目录  : \(sourceURL.path)（只读，全部读写都在副本上）")
    out("工作副本: \(work.path)")
    out()
    // 夹具目录里还躺着一份 `BASELINE.sha256`（`tools/verify_fixtures.sh` 的比对基线），
    // 它不是夹具，别算进 n/n。
    let bookkeeping: Set<String> = ["BASELINE.sha256", ".DS_Store"]
    var pass = 0, total = 0
    for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where !u.hasDirectoryPath && !bookkeeping.contains(u.lastPathComponent) {
        total += 1
        var line = String(format: "  %-34@", u.lastPathComponent as NSString)
        do {
            let f = try TagService.read(u)
            line += " → 读成功  容器=\(f.technical.containerName) 标题=\(fmt(f.tags.title))"
            if !f.diagnostics.isEmpty { line += " 诊断=\(f.diagnostics.count)条" }
        } catch let e as TagError {
            line += " → 返回错误（未崩溃）: \(e.localizedDescription)"
        } catch {
            line += " → 返回错误（未崩溃）: \(error.localizedDescription)"
        }
        // 再试写，同样不得崩溃
        var edit = TagEdit()
        edit.set(.title, "健壮性测试")
        do { _ = try TagService.write(edit, to: u); line += " | 写: 成功" }
        catch { line += " | 写: 已拒绝" }
        pass += 1
        out(line)
    }
    out()
    out("结论：\(total) 个畸形/异常文件，全部走完读+写路径且进程存活 → \(pass)/\(total) ✔")
}

func cmdEncoding(_ path: String) {
    hr("遗留编码策略对比 \((path as NSString).lastPathComponent)")
    let url = URL(fileURLWithPath: path)
    for e in [LegacyTextEncoding.strict, .gb18030, .big5, .shiftJIS, .utf8, .autoDetect] {
        TagService.legacyEncoding = e
        do {
            let f = try TagService.read(url)
            out(String(format: "  %-28@ 标题=%@ 艺术家=%@ 专辑=%@",
                       e.localizedName as NSString,
                       fmt(f.tags.title), fmt(f.tags.artist), fmt(f.tags.album)))
        } catch {
            out("  \(e.localizedName): 读取失败 \(error.localizedDescription)")
        }
    }
    TagService.legacyEncoding = .strict
}


// MARK: - 异步桥（main.swift 顶层同步调用 async API）

final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

func runAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached {
        box.value = await body()
        sem.signal()
    }
    sem.wait()
    return box.value!
}

// MARK: - import 子命令

func pad(_ s: String, _ n: Int) -> String {
    // 中文按 2 列宽计算，保证表格对齐
    var w = 0
    for ch in s {
        w += ch.unicodeScalars.contains { $0.value > 0x2000 } ? 2 : 1
    }
    return s + String(repeating: " ", count: max(0, n - w))
}

func rel(_ url: URL, _ base: String) -> String {
    let p = url.path
    if p.hasPrefix(base) {
        let cut = p.index(p.startIndex, offsetBy: base.count)
        return String(p[cut...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    return url.lastPathComponent
}

func printImportResult(_ r: ImportResult, base: String, showFiles: Bool = true) {
    if showFiles {
        out("  成功 \(r.files.count) 个：")
        out("    | \(pad("文件", 30)) | \(pad("扩展名", 8)) | \(pad("时长", 9)) | \(pad("编码", 12)) | \(pad("标题", 20)) |")
        out("    |-\(String(repeating: "-", count: 30))-|-\(String(repeating: "-", count: 8))-|-\(String(repeating: "-", count: 9))-|-\(String(repeating: "-", count: 12))-|-\(String(repeating: "-", count: 20))-|")
        for f in r.files {
            out("    | \(pad(rel(f.url, base), 30)) | \(pad(f.fileExtension, 8)) | \(pad(f.technical.formattedDuration, 9)) | \(pad(f.technical.codecName, 12)) | \(pad(f.tags.title ?? "—", 20)) |")
        }
    }
    if !r.skipped.isEmpty {
        out("  忽略 \(r.skipped.count) 个：")
        for s in r.skipped.sorted(by: { $0.url.path < $1.url.path }) {
            out("    | \(pad(rel(s.url, base), 30)) | \(s.reason)")
        }
    }
    if !r.failures.isEmpty {
        out("  失败 \(r.failures.count) 个：")
        for f in r.failures {
            out("    | \(pad(rel(f.url, base), 30)) | \(f.error.localizedDescription)")
        }
    }
    out("  → \(r.summary)" + (r.isCancelled ? "   [已取消，部分结果]" : ""))
}

func cmdImport(_ dir: String) {
    hr("ImportService 导入扫描实测")
    let base = URL(fileURLWithPath: dir).standardizedFileURL.path
    out("扫描根目录: \(base)")
    out("默认白名单(\(ImportOptions.defaultExtensionList.count) 项): \(ImportOptions.default.extensionListString)")
    out("最短时长可选项: " + ImportOptions.minimumDurationChoices
        .map { $0.map { "\(Int($0))秒" } ?? "不过滤" }.joined(separator: " / "))

    let root = URL(fileURLWithPath: dir)

    struct Case { var name: String; var opt: ImportOptions }
    var cases: [Case] = []

    cases.append(Case(name: "① 默认（递归 + 忽略MP4视频 + 不限时长）", opt: .default))

    var noSub = ImportOptions.default
    noSub.includeSubdirectories = false
    cases.append(Case(name: "② 不含子目录", opt: noSub))

    var minDur = ImportOptions.default
    minDur.minimumDuration = 10
    cases.append(Case(name: "③ 最短时长 10 秒", opt: minDur))

    var keepVideo = ImportOptions.default
    keepVideo.ignoreVideoMP4 = false
    cases.append(Case(name: "④ 不忽略 MP4 视频", opt: keepVideo))

    var narrow = ImportOptions.default
    narrow.allowedExtensions = ImportOptions.parseExtensionList(".FLAC, mp3")
    cases.append(Case(name: "⑤ 白名单只留 flac,mp3（演示自定义 + 大小写/点号容错）", opt: narrow))

    for c in cases {
        out()
        out("\(c.name)")
        out("   选项: 递归=\(c.opt.includeSubdirectories ? "是" : "否")  最短时长=\(c.opt.minimumDurationDescription)  忽略MP4视频=\(c.opt.ignoreVideoMP4 ? "是" : "否")  并发=\(c.opt.concurrency)  白名单=\(c.opt.isExtensionListDefault ? "默认(\(c.opt.allowedExtensions.count))" : c.opt.extensionListString)")
        var ticks: [String] = []
        let opt = c.opt
        let r = runAsync {
            await ImportService.scan(urls: [root], options: opt) { done, total in
                if done == 0 || done == total || done % 4 == 0 { }
            }
        }
        _ = ticks
        printImportResult(r, base: base)
    }

    // ⑥ 还原默认白名单
    out()
    out("⑥ 还原默认白名单")
    var custom = ImportOptions.default
    custom.allowedExtensions = ["mp3"]
    out("   自定义后: \(custom.extensionListString)  isDefault=\(custom.isExtensionListDefault)")
    custom.resetExtensionsToDefault()
    out("   还原后  : \(custom.extensionListString)  isDefault=\(custom.isExtensionListDefault)")

    // ⑦ 进度回调真实序列
    out()
    out("⑦ 进度回调实测（默认选项）")
    let recorder = ProgressRecorder()
    let r7 = runAsync {
        await ImportService.scan(urls: [root], options: .default) { d, t in recorder.add(d, t) }
    }
    out("   回调序列: \(recorder.snapshot().map { "\($0.0)/\($0.1)" }.joined(separator: " → "))")
    out("   最终: \(r7.summary)")

    // ⑧ 取消
    out()
    out("⑧ 取消实测（扫描开始后立刻取消）")
    let cancelled = runAsync { () async -> ImportResult in
        let t = Task { await ImportService.scan(urls: [root], options: .default, progress: nil) }
        t.cancel()
        return await t.value
    }
    out("   isCancelled=\(cancelled.isCancelled)  成功=\(cancelled.files.count)  → \(cancelled.summary)")

    // ⑨ MP4 轨道判定明细
    out()
    out("⑨ MP4 轨道判定明细")
    let fm = FileManager.default
    let mp4s = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["mp4", "m4a", "m4v", "mov"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    out("    | \(pad("文件", 26)) | \(pad("handler 轨道", 20)) | 判定 |")
    for u in mp4s {
        let h = MP4Inspector.handlerTypes(at: u)
        let hs = h.map { $0.sorted().joined(separator: ",") } ?? "<解析失败>"
        let cls: String
        switch MP4Inspector.classify(u) {
        case .audioOnly: cls = "纯音频，收录"
        case .videoFile: cls = "视频文件，忽略"
        case .noAudioTrack: cls = "无音频轨，忽略"
        case .unknown: cls = "无法判定，放行"
        }
        out("    | \(pad(u.lastPathComponent, 26)) | \(pad(hs, 20)) | \(cls) |")
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int)] = []
    func add(_ d: Int, _ t: Int) { lock.lock(); items.append((d, t)); lock.unlock() }
    func snapshot() -> [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return items }
}


// MARK: - batch 子命令

final class BatchProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int, String?)] = []
    private var threads = Set<String>()
    func add(_ p: BatchProgress) {
        lock.lock()
        items.append((p.completed, p.total, p.currentPath))
        threads.insert(Thread.current.description)
        lock.unlock()
    }
    func snapshot() -> [(Int, Int, String?)] { lock.lock(); defer { lock.unlock() }; return items }
    func threadCount() -> Int { lock.lock(); defer { lock.unlock() }; return threads.count }
}

func printSummary(_ s: BatchSummary, base: String) {
    out("   结果文案: \(s.description)")
    out("   耗时: \(String(format: "%.3f", s.elapsed)) 秒   未开工: \(s.unprocessed)   取消: \(s.isCancelled)")
    if !s.ignoredItems.isEmpty {
        out("   忽略明细:")
        for i in s.ignoredItems { out("     - \(rel(i.url, base))  ← \(i.reason)") }
    }
    if !s.failures.isEmpty {
        out("   失败明细:")
        for f in s.failures { out("     - \(rel(f.url, base))  ← \(f.error.localizedDescription)") }
    }
    if !s.rejections.isEmpty {
        out("   字段被格式拒收（仍算成功）:")
        for r in s.rejections { out("     - \(rel(r.url, base))  ← \(r.keys.joined(separator: ","))") }
    }
}

func cmdBatch(_ dir: String) {
    hr("BatchEngine 批量引擎实测")

    // 全部在临时副本上做，绝不动源语料
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-batch-\(UUID().uuidString)")
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: dir)
        for u in (try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
            where !u.hasDirectoryPath {
            try? fm.copyItem(at: u, to: work.appendingPathComponent(u.lastPathComponent))
        }
    } catch { fail("准备工作副本失败：\(error.localizedDescription)") }
    defer { try? fm.removeItem(at: work) }
    let base = work.standardizedFileURL.path
    out("工作副本目录: \(base)（跑完自动删除，源语料零改动）")

    let scan = runAsync { await ImportService.scan(urls: [work], options: .default, progress: nil) }
    var targets = scan.files.map(\.url).sorted { $0.lastPathComponent < $1.lastPathComponent }
    out("参与批量的文件: \(targets.count) 个 — \(targets.map(\.lastPathComponent).joined(separator: ", "))")

    // ---------- ① 正常批量写 + 空编辑集忽略 + 不存在文件失败 ----------
    out()
    out("① applyEdits：正常写 \(targets.count) 个 + 1 个空编辑集（应忽略）+ 1 个不存在文件（应失败）")
    var jobs: [(url: URL, edit: TagEdit)] = []
    for (i, u) in targets.enumerated() {
        var e = TagEdit()
        e.set(.title, "批量标题-\(i + 1)")
        e.set(.artist, "批量艺术家")
        e.set(.album, "批量专辑《验证》")
        e.set(.year, "2026")
        e.set(.track, "\(i + 1)/\(targets.count)")
        jobs.append((u, e))
    }
    if let first = targets.first { jobs.append((first, TagEdit())) }          // 空编辑集
    jobs.append((work.appendingPathComponent("不存在的文件.mp3"), {
        var e = TagEdit(); e.set(.title, "X"); return e
    }()))

    let rec = BatchProgressRecorder()
    let s1 = runAsync { await BatchEngine.applyEdits(jobs, concurrency: 4) { rec.add($0) } }
    printSummary(s1, base: base)
    out("   进度回调 \(rec.snapshot().count) 次: " +
        rec.snapshot().map { "\($0.0)/\($0.1)" }.joined(separator: " → "))
    out("   回调发生在 \(rec.threadCount()) 个不同线程上（并发度 4 生效）")

    // ---------- ② 回读复核 ----------
    out()
    out("② 写后回读复核")
    out("    | \(pad("文件", 24)) | \(pad("标题", 18)) | \(pad("艺术家", 14)) | \(pad("音轨", 8)) |")
    var okCount = 0
    for (i, u) in targets.enumerated() {
        guard let f = try? TagService.read(u) else { out("    | \(pad(u.lastPathComponent, 24)) | 读取失败 |"); continue }
        let expect = "批量标题-\(i + 1)"
        if f.tags.title == expect { okCount += 1 }
        out("    | \(pad(u.lastPathComponent, 24)) | \(pad(f.tags.title ?? "—", 18)) | \(pad(f.tags.artist ?? "—", 14)) | \(pad(f.tags.trackString ?? "—", 8)) |")
    }
    out("   标题逐项对上: \(okCount)/\(targets.count)")

    // ---------- ③ 并发度对照 ----------
    out()
    out("③ 并发度对照（每轮各写一批**互不相同**的副本，避免同文件写竞争）")
    let farm = work.appendingPathComponent("_farm")
    try? fm.createDirectory(at: farm, withIntermediateDirectories: true)
    var farmFiles: [URL] = []
    for round in 0..<24 {
        for u in targets {
            let dst = farm.appendingPathComponent("\(round)-\(u.lastPathComponent)")
            if (try? fm.copyItem(at: u, to: dst)) != nil { farmFiles.append(dst) }
        }
    }
    out("   副本农场: \(farmFiles.count) 个互不相同的文件")
    out("    | 并发度 | 耗时(秒) | 每秒文件数 | 结果 | 回读校验 |")
    for width in [1, 2, 4, 8] {
        var js: [(url: URL, edit: TagEdit)] = []
        for u in farmFiles {
            var e = TagEdit()
            e.set(.title, "并发\(width)")
            e.set(.comment, u.lastPathComponent)
            js.append((u, e))
        }
        let s = runAsync { await BatchEngine.applyEdits(js, concurrency: width, progress: nil) }
        // 逐个回读，确认并发写没有串台（COMMENT 必须等于自己的文件名）
        var good = 0
        for u in farmFiles {
            if let f = try? TagService.read(u),
               f.tags.title == "并发\(width)",
               f.tags.comment == u.lastPathComponent { good += 1 }
        }
        let rate = s.elapsed > 0 ? Double(farmFiles.count) / s.elapsed : 0
        out("    | \(pad("\(width)", 6)) | \(pad(String(format: "%.3f", s.elapsed), 8)) | \(pad(String(format: "%.0f", rate), 10)) | \(pad(s.description, 38)) | \(good)/\(farmFiles.count) |")
    }

    // ---------- ④ 取消 ----------
    out()
    out("④ 取消实测（派发后立刻 cancel）")
    var many: [(url: URL, edit: TagEdit)] = []
    for _ in 0..<20 { for u in targets { var e = TagEdit(); e.set(.comment, "cancel-test"); many.append((u, e)) } }
    let s4 = runAsync { () async -> BatchSummary in
        let t = Task { await BatchEngine.applyEdits(many, concurrency: 4, progress: nil) }
        t.cancel()
        return await t.value
    }
    out("   计划 \(many.count) 项 → \(s4.description)   isCancelled=\(s4.isCancelled)  未开工=\(s4.unprocessed)")

    // ---------- ⑤ 批量导出封面 ----------
    out()
    out("⑤ exportArtworks：先给前 2 个文件写入封面，再批量导出")
    let png = onePixelPNG()
    var withArt: [URL] = []
    for u in targets.prefix(2) {
        var e = TagEdit()
        e.artworkAction = .replace([Artwork(data: png, mimeType: "image/png", caption: "batch", type: .frontCover)])
        if (try? TagService.write(e, to: u)) != nil { withArt.append(u) }
    }
    out("   成功写入封面的文件: \(withArt.map(\.lastPathComponent).joined(separator: ", "))")
    let expDir = work.appendingPathComponent("_covers")
    let s5 = runAsync { await BatchEngine.exportArtworks(targets, to: expDir, concurrency: 4, progress: nil) }
    printSummary(s5, base: base)
    let exported = ((try? fm.contentsOfDirectory(at: expDir, includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    out("   实际落盘文件: \(exported.map { "\($0.lastPathComponent)(\((try? Data(contentsOf: $0))?.count ?? 0)B)" }.joined(separator: ", "))")

    // ---------- ⑥ 批量清标签 ----------
    out()
    out("⑥ stripAll：清空全部标签容器后复核")
    let s6 = runAsync { await BatchEngine.stripAll(targets, concurrency: 4, progress: nil) }
    printSummary(s6, base: base)
    var cleared = 0
    for u in targets {
        if let f = try? TagService.read(u),
           (f.tags.title ?? "").isEmpty, (f.tags.artist ?? "").isEmpty { cleared += 1 }
    }
    out("   复核：标题+艺术家都已清空的文件 \(cleared)/\(targets.count)")

    targets = []
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    out("""
    mactagger-probe — MacTagger 桥接层验证工具

    用法:
      mactagger-probe env
      mactagger-probe read     <file>
      mactagger-probe smoke    <file>       # 会修改该文件，请传副本
      mactagger-probe matrix   <dir>
      mactagger-probe history
      mactagger-probe robust   <dir>
      mactagger-probe encoding <file>
      mactagger-probe import   <dir>
      mactagger-probe batch    <dir>       # 在临时副本上跑，不动源文件
      mactagger-probe undo     <file>      # 有封面→换封面→撤销，请用副本
      mactagger-probe undo-nocover <file>  # 无封面→加封面→撤销应移除，请用副本
      mactagger-probe artproc  <image>
      mactagger-probe artsearch <搜索词>
      mactagger-probe artprop  <dir>
      mactagger-probe artseed  <image> <audio...>   # 会修改这些音频，请用副本
      mactagger-probe bigcover <音频副本> [--mb 17] [--m4a <m4a副本>] [--keep]
                                           # 超大封面上限 AT-04：拒写 / 自动压缩 / 限内 / MP4 对照
      mactagger-probe tpl cases            # 「文件名 ↔ 标签」模板引擎用例表
      mactagger-probe tpl validate "<模板>" [rename]
      mactagger-probe tpl parse    "<模板>" "<文件名>"
      mactagger-probe tpl render   "<模板>" <音频文件>
      mactagger-probe rename   <dir> "<模板>" [--dry]
      mactagger-probe rename-undo
      mactagger-probe settags  <file> title=… artist=… track=…
      mactagger-probe lrc ops  <file>
      mactagger-probe lyric merge  <搜索词>
      mactagger-probe lyric export <音频文件副本>   # 会生成歌词文件，请用副本
             [--format lrc|a2|txt|srt] [--location song|sub|sub:<名>|dir:<路径>|ask]
             [--naming same|artist-title|title-artist]
             [--encoding utf8|utf8bom|gb18030|utf16le]
             [--overwrite|--no-overwrite] [--a2-suffix] [--lines N]
      mactagger-probe lyric upgrade-demo [<音频文件副本>] [--keep]
             # .lrc 「复跑升级为含译文版」四组断言，全程在临时目录，不给路径也能跑
      mactagger-probe lyric batch-file-demo <音频副本> [<音频2> <音频3>] [--keep]
             # 批量复核表「仅保存文件」：合并文本 → saveLyricsFiles → 四元组 + 音频 sha256 不变
    """)
    exit(0)
}

// MARK: - undo：撤销服务（含封面/歌词旁存回滚）

func cmdUndo(_ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("撤销服务验证 \((path as NSString).lastPathComponent)")

    guard let original = try? TagService.read(url) else {
        print("  无法读取文件"); return
    }

    // 独立的临时旁存目录，不污染真实应用数据
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-undo-probe-\(UUID().uuidString)")
    let dbURL = tmpRoot.appendingPathComponent("history.sqlite")
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    guard let history = try? TagsHistoryStore(databaseURL: dbURL),
          let sideCar = try? SideCarStore(root: tmpRoot.appendingPathComponent("sidecar")) else {
        print("  初始化历史库/旁存仓库失败"); return
    }

    // ① 造一个「原始状态」：标题 + 歌词 + 封面
    var seed = TagEdit()
    seed.set(.title, "撤销测试-原始标题")
    seed.set(.artist, "原始艺术家")
    seed.set(.lyrics, "[00:00.00]原始歌词第一行\n[00:05.00]原始歌词第二行")
    let seedArt = Artwork(data: makeTestPNG(color: 0), mimeType: "image/png", type: .frontCover)
    seed.artworkAction = .replace([seedArt])
    guard (try? TagService.write(seed, to: url)) != nil,
          let before = try? TagService.read(url) else {
        print("  写入原始状态失败"); return
    }
    print("① 原始状态:")
    print("   标题=\(before.tags.title ?? "nil")  艺术家=\(before.tags.artist ?? "nil")")
    print("   歌词=\(String((before.tags.lyrics ?? "").prefix(24)).replacingOccurrences(of: "\n", with: "\\n"))…")
    print("   封面=\(before.tags.artworks.count) 张 / \(before.tags.artworks.first?.byteCount ?? 0) 字节")

    // ② 记录 + 旁存，然后做破坏性修改（改标题、换歌词、换封面）
    var edit = TagEdit()
    edit.set(.title, "撤销测试-被改标题")
    edit.set(.lyrics, "[00:00.00]被覆盖的歌词")
    let newArt = Artwork(data: makeTestPNG(color: 255), mimeType: "image/png", type: .frontCover)
    edit.artworkAction = .replace([newArt])

    guard let rec = try? UndoService.recordBeforeWrite(url: url, current: before, edit: edit,
                                                       history: history, sideCar: sideCar) else {
        print("  记录历史失败"); return
    }
    print("② 记录历史: serial=\(rec.serial)  旁存封面/歌词=\(rec.hasSideCar ? "是" : "否")")

    guard (try? TagService.write(edit, to: url)) != nil,
          let modified = try? TagService.read(url) else {
        print("  写入修改失败"); return
    }
    print("③ 修改后:")
    print("   标题=\(modified.tags.title ?? "nil")")
    print("   歌词=\(String((modified.tags.lyrics ?? "").prefix(24)))")
    print("   封面=\(modified.tags.artworks.count) 张 / \(modified.tags.artworks.first?.byteCount ?? 0) 字节")

    // ③ 撤销
    guard let entries = try? history.history(forFilePath: url.path), let entry = entries.first else {
        print("  取历史失败"); return
    }
    guard let outcome = try? UndoService.undo(to: entry, sideCar: sideCar) else {
        print("  撤销失败"); return
    }
    print("④ 撤销执行: 回滚字段=\(outcome.restoredFields) 项  歌词=\(outcome.restoredLyrics ? "已回滚" : "未回滚")  封面=\(outcome.restoredArtworks) 张")

    guard let after = try? TagService.read(url) else { print("  复核读取失败"); return }
    print("⑤ 撤销后复核:")
    print("   标题=\(after.tags.title ?? "nil")")
    print("   歌词=\(String((after.tags.lyrics ?? "").prefix(24)).replacingOccurrences(of: "\n", with: "\\n"))…")
    print("   封面=\(after.tags.artworks.count) 张 / \(after.tags.artworks.first?.byteCount ?? 0) 字节")

    let titleOK  = after.tags.title == before.tags.title
    let lyricsOK = after.tags.lyrics == before.tags.lyrics
    let artOK    = after.tags.artworks.first?.data == before.tags.artworks.first?.data
    print("")
    print("  文本字段回滚: \(titleOK ? "✔" : "�’")")
    print("  歌词回滚    : \(lyricsOK ? "✔" : "✘")  ← 原版历史表不存歌词，靠旁存补齐")
    print("  封面回滚    : \(artOK ? "✔" : "✘")  ← 原版历史表不存封面，靠旁存补齐")
    print("")
    print("  结论: \(titleOK && lyricsOK && artOK ? "三者全部正确回滚 ✔" : "存在未回滚项 ✘")")

    // 旁存清理策略
    let sizeBefore = sideCar.totalBytes()
    let pruned = UndoService.maintain(history: history, sideCar: sideCar, keepCount: 0, maxBytes: 0)
    print("")
    print("  旁存清理: 清理前 \(sizeBefore) 字节 → 删除 \(pruned.removed) 个快照，释放 \(pruned.freedBytes) 字节")
}

// MARK: - undo-nocover：原本无封面 → 写入封面 → 撤销应回到无封面

/// 覆盖 cmdUndo 覆盖不到的那一半：`cmdUndo` 是「有封面 → 换封面 → 撤销」，
/// 旁存里有旧封面字节可以 `.replace` 回去；本命令是「**没有**封面 → 加封面 → 撤销」，
/// 旁存里一张图都没有，只能靠 `recordBeforeWrite` 打下的哨兵标记让 undo 走 `.removeAll`。
/// 少了那个标记，撤销后封面会赖在文件里 —— 这正是本命令要守住的回归点。
func cmdUndoNoCover(_ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("撤销：原本无封面 \((path as NSString).lastPathComponent)")

    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-undo-nocover-\(UUID().uuidString)")
    let dbURL = tmpRoot.appendingPathComponent("history.sqlite")
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    guard let history = try? TagsHistoryStore(databaseURL: dbURL),
          let sideCar = try? SideCarStore(root: tmpRoot.appendingPathComponent("sidecar")) else {
        print("  初始化历史库/旁存仓库失败"); return
    }

    // ① 造一个确定的「无封面」起点：先把可能存在的封面清掉
    var seed = TagEdit()
    seed.set(.title, "无封面撤销测试")
    seed.artworkAction = .removeAll
    guard (try? TagService.write(seed, to: url)) != nil,
          let before = try? TagService.read(url) else {
        print("  清空封面失败"); return
    }
    print("① 起点（应为无封面）:")
    print("   标题=\(before.tags.title ?? "nil")")
    print("   封面=\(before.tags.artworks.count) 张")
    guard before.tags.artworks.isEmpty else {
        print("  ✘ 起点仍有封面，本用例前提不成立"); return
    }

    // ② 记录历史 + 旁存，然后写入一张封面
    var edit = TagEdit()
    edit.set(.title, "无封面撤销测试-已加图")
    let newArt = Artwork(data: makeTestPNG(color: 128), mimeType: "image/png", type: .frontCover)
    edit.artworkAction = .replace([newArt])

    guard let rec = try? UndoService.recordBeforeWrite(url: url, current: before, edit: edit,
                                                       history: history, sideCar: sideCar) else {
        print("  记录历史失败"); return
    }
    print("② 记录历史: serial=\(rec.serial)  有旁存=\(rec.hasSideCar ? "是" : "否")")

    // 哨兵标记必须真的落进旁存，否则第 ④ 步注定失败
    var sentinelOK = false
    var sentinelText = "（缺失）"
    if let side = try? sideCar.load(serial: rec.serial),
       let stored = side.extraFields["__artworkCleared"] {
        sentinelOK = true
        sentinelText = stored ?? "nil"
    }
    print("   旁存哨兵 __artworkCleared = \(sentinelText)")

    guard (try? TagService.write(edit, to: url)) != nil,
          let modified = try? TagService.read(url) else {
        print("  写入封面失败"); return
    }
    print("③ 写入封面后:")
    print("   标题=\(modified.tags.title ?? "nil")")
    print("   封面=\(modified.tags.artworks.count) 张 / \(modified.tags.artworks.first?.byteCount ?? 0) 字节")
    let addedOK = modified.tags.artworks.count == 1

    // ③ 撤销
    guard let entries = try? history.history(forFilePath: url.path), let entry = entries.first else {
        print("  取历史失败"); return
    }
    guard let outcome = try? UndoService.undo(to: entry, sideCar: sideCar) else {
        print("  撤销失败"); return
    }
    print("④ 撤销执行: 回滚字段=\(outcome.restoredFields) 项  封面=\(outcome.restoredArtworks) 张（旁存无图，应为 0）")

    guard let after = try? TagService.read(url) else { print("  复核读取失败"); return }
    print("⑤ 撤销后复核:")
    print("   标题=\(after.tags.title ?? "nil")")
    print("   封面=\(after.tags.artworks.count) 张")

    let titleOK = after.tags.title == before.tags.title
    let coverOK = after.tags.artworks.isEmpty
    print("")
    print("  写入前无封面      : \(before.tags.artworks.isEmpty ? "✔" : "✘")")
    print("  旁存记下哨兵标记  : \(sentinelOK ? "✔" : "✘")  ← recordBeforeWrite 必须写入 __artworkCleared")
    print("  写入后确有 1 张   : \(addedOK ? "✔" : "✘")")
    print("  文本字段回滚      : \(titleOK ? "✔" : "✘")")
    print("  封面被移除回 0 张 : \(coverOK ? "✔" : "✘")  ← 缺哨兵时这里会留着封面")
    print("")
    let allOK = before.tags.artworks.isEmpty && sentinelOK && addedOK && titleOK && coverOK
    print("  结论: \(allOK ? "无封面撤销正确 ✔" : "存在未回滚项 ✘")")
}

/// 生成一张极小的合法 PNG（1x1，灰度值可变），用于封面回滚比对。
func makeTestPNG(color: UInt8) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        let typeBytes = Array(type.utf8)
        out += typeBytes + payload
        var crc = crc32Compute(typeBytes + payload).bigEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        return out
    }
    // IHDR: 1x1, 8bit, 灰度
    bytes += chunk("IHDR", [0,0,0,1, 0,0,0,1, 8, 0, 0, 0, 0])
    // IDAT: zlib 存储块，内容 = 滤波字节 0 + 像素
    let raw: [UInt8] = [0x00, color]
    var idat: [UInt8] = [0x78, 0x01, 0x01, 0x02, 0x00, 0xFD, 0xFF]
    idat += raw
    var adler: UInt32 = {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }().bigEndian
    withUnsafeBytes(of: &adler) { idat.append(contentsOf: $0) }
    bytes += chunk("IDAT", idat)
    bytes += chunk("IEND", [])
    return Data(bytes)
}

func crc32Compute(_ data: [UInt8]) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        table[i] = c
    }
    var crc: UInt32 = 0xFFFFFFFF
    for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFFFFFF
}



// MARK: - detect：编码自动识别

func cmdDetect(_ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("编码自动识别 \((path as NSString).lastPathComponent)")

    let ranked = EncodingRepair.preview(url)
    guard !ranked.isEmpty else { print("  无法读取文件"); return }

    print("  各候选编码得分（由高到低）：")
    print("")
    print("  | 排名 | 编码 | 得分 | 解出的文本 |")
    print("  |---|---|---:|---|")
    for (i, c) in ranked.enumerated() {
        let mark = i == 0 ? "**★**" : "\(i + 1)"
        print("  | \(mark) | \(c.encoding.localizedName) | \(String(format: "%.2f", c.score)) | \(c.sample) |")
    }
    print("")
    let best = EncodingRepair.detect(url)
    print("  判定结果: \(best.localizedName)")
}


// MARK: - undoextra：验证历史表覆盖不到的字段能否撤回

func cmdUndoExtra(_ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("撤销：历史表外字段 \((path as NSString).lastPathComponent)")

    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-undoextra-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    guard let history = try? TagsHistoryStore(databaseURL: tmpRoot.appendingPathComponent("h.sqlite")),
          let sideCar = try? SideCarStore(root: tmpRoot.appendingPathComponent("sc")) else {
        print("  初始化失败"); return
    }

    // ① 原始状态：只设「历史表外」的三个字段
    var seed = TagEdit()
    seed.set(.title, "原标题")
    seed.set(.albumArtist, "原专辑艺术家")
    seed.set(.genre, "原风格")
    seed.set(.composer, "原作曲")
    guard (try? TagService.write(seed, to: url)) != nil,
          let before = try? TagService.read(url) else { print("  写入失败"); return }
    print("① 原始: 专辑艺术家=\(fmt(before.tags.albumArtist)) 风格=\(fmt(before.tags.genre)) 作曲=\(fmt(before.tags.composer))")

    // ② 模拟自动匹配：一次性改这些字段
    var edit = TagEdit()
    edit.set(.title, "匹配后标题")
    edit.set(.albumArtist, "匹配后专辑艺术家")
    edit.set(.genre, "匹配后风格")
    edit.set(.composer, "匹配后作曲")

    guard let rec = try? UndoService.recordBeforeWrite(url: url, current: before, edit: edit,
                                                       history: history, sideCar: sideCar) else {
        print("  记录失败"); return
    }
    print("② 记录: serial=\(rec.serial) 旁存=\(rec.hasSideCar ? "是" : "否")")

    guard (try? TagService.write(edit, to: url)) != nil,
          let after = try? TagService.read(url) else { print("  写入失败"); return }
    print("③ 改后: 专辑艺术家=\(fmt(after.tags.albumArtist)) 风格=\(fmt(after.tags.genre)) 作曲=\(fmt(after.tags.composer))")

    // ③ 撤销
    guard let entries = try? history.history(forFilePath: url.path), let e = entries.first,
          (try? UndoService.undo(to: e, sideCar: sideCar)) != nil,
          let done = try? TagService.read(url) else { print("  撤销失败"); return }
    print("④ 撤销后: 专辑艺术家=\(fmt(done.tags.albumArtist)) 风格=\(fmt(done.tags.genre)) 作曲=\(fmt(done.tags.composer))")

    print("")
    let checks: [(String, Bool)] = [
        ("标题（历史表内）", done.tags.title == before.tags.title),
        ("专辑艺术家（表外）", done.tags.albumArtist == before.tags.albumArtist),
        ("风格（表外）", done.tags.genre == before.tags.genre),
        ("作曲（表外）", done.tags.composer == before.tags.composer),
    ]
    for (n, ok) in checks { print("  \(n): \(ok ? "✔ 已回滚" : "✘ 未回滚")") }
    print("")
    print("  结论: \(checks.allSatisfy { $0.1 } ? "全部正确回滚 ✔" : "存在未回滚项 ✘")")
}

switch cmd {

case "env":      cmdEnv()
case "read":     guard args.count > 1 else { fail("缺少文件路径") }; cmdRead(args[1])
case "smoke":    guard args.count > 1 else { fail("缺少文件路径") }
                 exit(cmdSmoke(args[1]) ? 0 : 2)
case "matrix":   guard args.count > 1 else { fail("缺少目录") }; cmdMatrix(args[1])
case "history":  cmdHistory()
case "robust":   guard args.count > 1 else { fail("缺少目录") }; cmdRobust(args[1])
case "encoding": guard args.count > 1 else { fail("缺少文件路径") }; cmdEncoding(args[1])
case "import":   guard args.count > 1 else { fail("缺少目录") }; cmdImport(args[1])
case "batch":    guard args.count > 1 else { fail("缺少目录") }; cmdBatch(args[1])
case "undoextra": guard args.count > 1 else { fail("缺少文件路径") }; cmdUndoExtra(args[1])
case "undo-nocover": guard args.count > 1 else { fail("缺少文件路径") }; cmdUndoNoCover(args[1])
case "undo":     guard args.count > 1 else { fail("缺少文件路径") }; cmdUndo(args[1])
case "detect":   guard args.count > 1 else { fail("缺少文件路径") }; cmdDetect(args[1])
case "source":   guard args.count > 2 else { fail("用法: source <sourceID> <搜索词>") }
                 intlCmdSource(args[1], args[2...].joined(separator: " "))
case "lrc":      guard args.count > 2, args[1] == "ops" else { fail("用法: lrc ops <file>") }
                 cmdLrcOps(args[2])
case "lyric":
    if args.count == 2, args[1] == "marker" { cmdLyricMarker([]); exit(0) }
    if args.count == 2, args[1] == "upgrade-demo" { cmdLyricUpgradeDemo([]); exit(0) }
    if args.count == 2, args[1] == "batch-file-demo" { cmdLyricBatchFileDemo([]); exit(0) }
    guard args.count > 2 else { fail("用法: lyric marker [\"<标题>\" …] | lyric merge <搜索词> | lyric export <音频文件副本> [选项] | lyric write <音频文件副本> [--lines N] | lyric upgrade-demo [<音频文件副本>] [--keep] | lyric resolve \"<标题含版本后缀>\" [--artist X] [--duration 秒] [--sources a,b] [--no-transplant] [--lines N]") }
    switch args[1] {
    case "merge":  cmdLyricMerge(args[2...].joined(separator: " "))
    case "export": cmdLyricExport(args[2], args: Array(args[3...]))
    case "write":  cmdLyricWrite(args[2], args: Array(args[3...]))
    case "resolve": cmdLyricResolve(args[2], args: Array(args[3...]))
    case "marker":  cmdLyricMarker(Array(args[2...]))
    case "sanitize": cmdLyricSanitize(args[2], args.count > 3 ? args[3] : nil)
    case "upgrade-demo": cmdLyricUpgradeDemo(Array(args[2...]))
    case "batch-file-demo": cmdLyricBatchFileDemo(Array(args[2...]))
    default:       fail("未知的 lyric 子命令 \(args[1])")
    }
case "zh":
    guard args.count > 1 else {
        fail("用法: zh env | zh convert --to s|t \"<文本>\" | zh batch <dir> --tags|--filenames --to s|t [--apply] [--undo] [--keep]")
    }
    switch args[1] {
    case "env":     cmdZhEnv()
    case "convert": cmdZhConvert(Array(args.dropFirst(2)))
    case "batch":   guard args.count > 2 else {
                        fail("用法: zh batch <dir> --tags|--filenames --to s|t [--apply] [--undo] [--keep]")
                    }
                    cmdZhBatch(args[2], args: Array(args.dropFirst(3)))
    default:        fail("未知的 zh 子命令 \(args[1])")
    }
case "automatch": guard args.count > 1 else {
                      fail("用法: automatch <file或dir> [--show-candidates] [--fail-source qq] [--zh s|t|none]")
                  }
                  cmdAutoMatch(args[1], args: Array(args.dropFirst(2)))
case "ranktie": guard args.count > 1 else {
                    fail("用法: ranktie \"<查询串>\" [--shuffles N] [--sources a,b,c]")
                }
                cmdRankTie(args[1], args: Array(args.dropFirst(2)))
case "qqrank": guard args.count > 1 else {
                   fail("用法: qqrank \"<查询串>\" [--artist <艺术家>] [--limit N]")
               }
               cmdQQRank(args[1], args: Array(args.dropFirst(2)))
case "qqempty": cmdQQEmpty(args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil,
                           args: Array(args.dropFirst(1)))
case "qqclean": cmdQQClean()
case "sources":
    guard args.count > 1 else {
        fail("用法: sources health | sources stress <sourceID> | sources circuit"
             + " | sources ratelimit [sourceID] | sources limiter [sourceID] --n 60 --concurrency 4")
    }
    switch args[1] {
    case "health":  cmdSourcesHealth(args: Array(args.dropFirst(2)))
    case "stress":  cmdSourcesStress(args: args)
    case "circuit": cmdSourcesCircuit(args: args)
    case "ratelimit": cmdSourcesRateLimit(args: args)
    case "limiter":  cmdSourcesLimiter(args: args)
    case "halfopen": cmdSourcesHalfOpen(args: args)      // BP-G：半开探测失败不锁死（离线）
    default: fail("用法: sources health | sources stress <sourceID> | sources circuit | sources halfopen"
                  + " | sources ratelimit [sourceID] | sources limiter [sourceID] --n 60 --concurrency 4")
    }
case "cnsource": guard args.count > 2 else { fail("用法: cnsource <sourceID> <搜索词>") }
                 cmdCNSource(args[1], args[2...].joined(separator: " "))
case "cnlyric":  guard args.count > 2 else { fail("用法: cnlyric <sourceID> <搜索词>") }
                 cmdCNLyric(args[1], args[2...].joined(separator: " "))
case "lyricdecrypt":
                 probeRegisterSources()
                 cmdLyricDecrypt(args.count > 1 ? args[1] : nil,
                                 args.count > 2 ? args[2...].joined(separator: " ") : nil)
case "artwork":  guard args.count > 2 else { fail("用法: artwork <sourceID> <搜索词>") }
                 intlCmdArtwork(args[1], args[2...].joined(separator: " "))
case "artproc":  guard args.count > 1 else { fail("用法: artproc <image>") }
                 cmdArtProc(args[1])
case "artsearch": guard args.count > 1 else { fail("用法: artsearch <搜索词>") }
                  cmdArtSearch(args[1...].joined(separator: " "))
case "artprop":  guard args.count > 1 else { fail("用法: artprop <dir>") }
                 cmdArtProp(args[1])
case "bigcover": guard args.count > 1 else {
                     fail("用法: bigcover <音频副本> [--mb 17] [--m4a <m4a副本>] [--keep]")
                 }
                 cmdBigCover(args[1], args: Array(args.dropFirst(2)))
case "propagate": guard args.count > 1 else {
                     fail("用法: propagate <dir> [--overwrite] [--field album=…] [--keep]")
                 }
                 cmdPropagate(args[1], args: Array(args.dropFirst(2)))
case "artseed":  guard args.count > 2 else { fail("用法: artseed <image> <audio...>") }
                 cmdArtSeed(args[1], Array(args[2...]))
case "volume":   guard args.count > 1 else { fail("用法: volume <path>") }
                 cmdVolume(args[1])
case "pacer":    guard args.count > 1 else { fail("用法: pacer <dir> [--simulate-slow] [--mixed] [--seq] [--no-pacer]") }
                 cmdPacer(args[1],
                          simulateSlow: args.contains("--simulate-slow"),
                          mixed: args.contains("--mixed"),
                          sequential: args.contains("--seq"),
                          disablePacer: args.contains("--no-pacer"))
case "tpl":
    guard args.count > 1 else { fail("用法: tpl cases | tpl validate <模板> [rename] | tpl parse <模板> <文件名> | tpl render <模板> <文件>") }
    switch args[1] {
    case "cases":    cmdTplCases()
    case "validate": guard args.count > 2 else { fail("用法: tpl validate \"<模板>\" [rename]") }
                     cmdTplValidate(args[2], args.count > 3 ? args[3] : nil)
    case "parse":    guard args.count > 3 else { fail("用法: tpl parse \"<模板>\" \"<文件名>\"") }
                     cmdTplParse(args[2], args[3])
    case "render":   guard args.count > 3 else { fail("用法: tpl render \"<模板>\" <音频文件>") }
                     cmdTplRender(args[2], args[3])
    default:         fail("未知的 tpl 子命令 \(args[1])")
    }
case "rename":   guard args.count > 2 else { fail("用法: rename <dir> \"<模板>\" [--dry]") }
                 cmdRename(args[1], args[2], dryRun: args.contains("--dry"))
case "rename-undo": cmdRenameUndo()
case "organize": guard args.count > 2 else {
                     fail("""
                          用法: organize <dir> "<模板>" [--root <dir>] [--dry] [--apply] [--undo]
                                organize <dir> "-" --undo        （撤消最近一批整理）
                                可选: --skip-missing --skip-conflict --no-companions --no-art
                                      --keep-empty --delete-source
                          """)
                 }
                 cmdOrganize(args[1], args[2], args: Array(args.dropFirst(3)))
case "organize-seed": guard args.count > 2 else { fail("用法: organize-seed <dir> <样本音频>") }
                 cmdOrganizeSeed(args[1], args[2])
case "settags":  guard args.count > 2 else { fail("用法: settags <file> title=… artist=… track=…") }
                 cmdSetTags(args[1], Array(args[2...]))
case "folderctx": cmdFolderContext(args.count > 1 ? args[1] : nil)
case "album":    guard args.count > 2 else { fail("用法: album <sourceID> \"<专辑> <艺术家>\"") }
                 cmdAlbumFetch(args[1], args[2...].joined(separator: " "))
case "albummatch": guard args.count > 1 else { fail("用法: albummatch <dir> [--ignore-tags] [--write] [--copies] [--keep] [--lyrics] [--translation|--no-translation] [--sources a,b]") }
                 cmdAlbumMatch(args[1],
                               ignoreTags: args.contains("--ignore-tags"),
                               sourcesCSV: args.firstIndex(of: "--sources").flatMap {
                                   $0 + 1 < args.count ? args[$0 + 1] : nil
                               },
                               write: args.contains("--write"),
                               args: args)
case "import2":  guard args.count > 1 else {
                     fail("用法: import2 <dir> [--threshold N] [--cancel-after-ms N] [--concurrency N] [--batch N] [--min-duration N] [--auto-read auto|always|never] [--restore] [--leading N] [--priority-check] [--no-read] [--resume] [--materialize] [--quiet]")
                 }
                 cmdImport2(args[1], args: Array(args.dropFirst(2)))
case "albumdisc":  cmdAlbumDisc()
case "albumtie":   cmdAlbumTie()
case "tracknum":   cmdTrackNumberWrite()
case "albumcompare": guard args.count > 1 else { fail("用法: albumcompare <dir>") }
                 cmdAlbumCompare(args[1])
case "writecost": guard args.count > 2 else { fail("用法: writecost <dir> <image> [--appflow] [--keep]") }
                 cmdWriteCost(args[1], args[2],
                              appFlow: args.contains("--appflow"),
                              batchCount: args.firstIndex(of: "--batch").flatMap {
                                  $0 + 1 < args.count ? Int(args[$0 + 1]) : 46
                              } ?? 0,
                              keep: args.contains("--keep"))
case "clearbatch": guard args.count > 1 else { fail("用法: clearbatch <dir> [--keep]") }
                 cmdClearBatch(args[1], keep: args.contains("--keep"))
case "mainthread-clear":
                 guard args.count > 1 else {
                     fail("用法: mainthread-clear <dir> [--legacy] [--save] [--count N] [--cover-mb N] [--block MS] [--keep]")
                 }
                 cmdMainThreadClear(args[1], args: Array(args.dropFirst(2)))
case "padding":
    // 旧用法 `padding <dir> <image>`（PerfProbe 的重写后填充实测）原样保留；
    // 新增三个子命令走 PaddingProbe。
    guard args.count > 2 else {
        fail("""
             用法:
               padding inspect <file>
               padding reserve <file副本> [--bytes N]
               padding demo    <flac副本> <大图>
               padding onemove <dir> <大图> [--cover-kb N] [--legacy] [--new] [--keep]
               padding <dir> <image> [--keep]      （旧：重写后填充实测）
             """)
    }
    switch args[1] {
    case "inspect": cmdPaddingInspect(args[2])
    case "reserve": cmdPaddingReserve(args[2], args: Array(args.dropFirst(3)))
    case "identity": cmdPaddingIdentity(Array(args.dropFirst(2)))   // BP-G：扩填充不丢 xattr/标签、不拆硬链接
    case "demo":    guard args.count > 3 else { fail("用法: padding demo <flac副本> <大图>") }
                    cmdPaddingDemo(args[2], args[3])
    case "limit":   guard args.count > 3 else { fail("用法: padding limit <flac副本> <大图> [--cover-kb N] [--targets a,b,c]") }
                    cmdPaddingLimit(args[2], args[3], args: Array(args.dropFirst(4)))
    case "onemove": guard args.count > 3 else {
                        fail("用法: padding onemove <dir> <大图> [--cover-kb N] [--legacy] [--new] [--keep]")
                    }
                    cmdPaddingOneMove(args[2], args[3], args: Array(args.dropFirst(4)))
    default:        cmdPadding(args[1], args[2], keep: args.contains("--keep"))
    }
case "policy":
    guard args.count > 3, args[1] == "demo" else {
        fail("用法: policy demo <dir> <大图> [--keep]")
    }
    cmdPolicyDemo(args[2], args[3], keep: args.contains("--keep"))
case "folderart": guard args.count > 2 else {
                     fail("用法: folderart <dir> <image> [--folder|--album] [--overwrite]")
                 }
                 cmdFolderArt(args[1], args[2], args: Array(args.dropFirst(3)))
case "folderart-locate": guard args.count > 1 else { fail("用法: folderart-locate <dir>") }
                 cmdFolderArtLocate(args[1])
case "quickfilter": guard args.count > 2 else {
                     fail("用法: quickfilter <样本音频> <封面图> [--keep]")
                 }
                 cmdQuickFilter(args[1], args[2], args: Array(args.dropFirst(3)))
case "fieldpick": cmdFieldPick(args: Array(args.dropFirst(1)))
default:         fail("未知子命令 \(cmd)")
}

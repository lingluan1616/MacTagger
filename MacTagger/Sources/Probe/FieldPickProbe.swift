//
//  FieldPickProbe.swift
//  mactagger-probe — 「按文件选写哪几个字段」的离线闭环自检
//
//  用法：mactagger-probe fieldpick [--sample <音频>] [--image <封面>] [--keep]
//
//  ── 验的是什么 ──
//  用户原话：「全部匹配后有些文件不想写碟号、有些不想写音轨号，现在改不了。」
//  复核表上的每一枚划线 chip，最终都落到 `AutoMatchResult.acceptedFields` 上，
//  再由 `acceptedEdit` 决定进不进 `TagEdit`。这条链**不联网也能验完**：
//  造三个副本 → 各自排除不同字段 → 真写盘 → 读回来逐字段对账。
//
//  三个文件刻意排除不同的东西，正是用户描述的那个场景：
//    01：全写（对照组）
//    02：不写碟号
//    03：不写音轨号 + 不写封面
//  验收判据：**被排除的字段保持原样、没被排除的确实变了、统计口径与之一致**。
//

import Foundation

// MARK: - 子命令

func cmdFieldPick(args: [String]) {
    let keep = args.contains("--keep")
    let samplePath = probeStringArg(args, "--sample")
        ?? probeTestdataPath("sample.flac")
    let imagePath = probeStringArg(args, "--image")
        ?? probeTestdataPath("import/cover.jpg")

    let sample = URL(fileURLWithPath: samplePath)
    guard FileManager.default.fileExists(atPath: sample.path) else { fail("样本音频不存在：\(samplePath)") }
    let cover = (try? Data(contentsOf: URL(fileURLWithPath: imagePath))) ?? Data()

    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-fieldpick-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { if !keep { try? FileManager.default.removeItem(at: work) } }

    hr("按文件选写哪几个字段（fieldpick，离线）")
    print("  样本   : \(sample.path)")
    print("  封面   : \(imagePath)（\(cover.count) 字节）")
    print("  工作区 : \(work.path)\(keep ? "（--keep：保留）" : "（收工自动删）")")
    print("")

    // ── 造三个副本，写入一份「原标签」──
    // 原标签刻意每个字段都非空：这样「没写」与「写了个空」在读回来时分得清。
    let ext = sample.pathExtension
    var urls: [URL] = []
    for i in 1...3 {
        let dst = work.appendingPathComponent(String(format: "%02d.%@", i, ext))
        do { try FileManager.default.copyItem(at: sample, to: dst) }
        catch { fail("复制失败：\(error.localizedDescription)") }
        var edit = TagEdit()
        edit.set(.title, "原标题 \(i)")
        edit.set(.artist, "原艺术家")
        edit.set(.album, "原专辑")
        edit.set(.year, "1999")
        edit.set(.track, "\(i)")
        edit.set(.disc, "9/9")
        edit.set(.genre, "原风格")
        do { _ = try TagService.write(edit, to: dst) }
        catch { fail("写原标签失败：\(error.localizedDescription)") }
        urls.append(dst)
    }

    // ── 造一条「匹配结果」──
    // 不联网：直接手搭 `TrackCandidate`，走的仍是 `asTagEdit` 那条正式路径，
    // 与 `AutoMatchService.match` 落到 `result.edit` 上的是同一个函数。
    func makeResult(_ url: URL, index: Int) -> AutoMatchResult {
        var cand = TrackCandidate(sourceID: "probe", nativeID: "n\(index)", albumID: "a1")
        cand.title = "新标题 \(index)"
        cand.artist = "新艺术家"
        cand.album = "新专辑"
        cand.albumArtist = "新专辑艺术家"
        cand.year = "2024"
        cand.trackNumber = "\(index)/3"
        cand.discNumber = "1/2"
        cand.genre = "新风格"
        cand.matchScore = 0.95

        var r = AutoMatchResult(url: url,
                                status: .matched,
                                best: cand,
                                edit: cand.asTagEdit(),
                                artwork: cover.isEmpty ? nil : cover,
                                lyrics: nil,
                                triedSources: ["probe"],
                                candidateCount: 1,
                                errors: [])
        // = 数据层收工那一下：默认全勾（本次会改动的字段全集）。
        r.resetAcceptedFieldsToAll()
        return r
    }

    var results = urls.enumerated().map { makeResult($0.element, index: $0.offset + 1) }

    print("═══ 默认勾选（= 本次会改动的字段全集）═══")
    for r in results {
        print("  \(r.url.lastPathComponent)  勾中 \(r.acceptedFields.count) 个字段："
              + sortedNames(r.acceptedFields)
              + "  封面 " + (r.acceptArtwork ? "写" : "不写"))
    }
    print("")

    // ── 逐文件排除 ──
    // 02：不写碟号；03：不写音轨号 + 不写封面。01 保持全写作对照。
    results[1].acceptedFields.remove(.disc)
    results[2].acceptedFields.remove(.track)
    results[2].acceptArtwork = false

    print("═══ 逐文件排除（复核表上点划线 chip 的等价物）═══")
    for r in results {
        let ex = r.excludedFields
        print("  \(r.url.lastPathComponent)  排除 "
              + (ex.isEmpty ? "（无）" : sortedNames(ex))
              + (r.acceptArtwork ? "" : " + 封面"))
    }
    print("")

    var pass = 0, failCount = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  \(ok ? "✔" : "✘") \(name)  \(detail)")
        if ok { pass += 1 } else { failCount += 1 }
    }

    // ── 组装出真正要写的 TagEdit ──
    print("═══ acceptedEdit：被排除的字段不进 TagEdit ═══")
    for r in results {
        let all = Set((r.edit?.changes ?? []).map(\.field))
        let picked = Set((r.acceptedEdit?.changes ?? []).map(\.field))
        let artWrites: Bool
        if case .replace = r.acceptedEdit?.artworkAction { artWrites = true } else { artWrites = false }
        print("  \(r.url.lastPathComponent)  全集 \(all.count) → 实写 \(picked.count)："
              + sortedNames(picked) + "  封面 " + (artWrites ? "写" : "不写"))
        check("\(r.url.lastPathComponent) 实写字段 == 勾中字段",
              picked == r.acceptedFields,
              "勾中 \(sortedNames(r.acceptedFields))")
        check("\(r.url.lastPathComponent) 排除的字段一个都没混进去",
              picked.isDisjoint(with: r.excludedFields),
              r.excludedFields.isEmpty ? "本文件无排除" : "排除 " + sortedNames(r.excludedFields))
        check("\(r.url.lastPathComponent) 封面开关生效",
              artWrites == (r.acceptArtwork && r.artwork != nil),
              "acceptArtwork=\(r.acceptArtwork)")
    }
    print("")

    // ── 真写盘 ──
    for r in results {
        guard let edit = r.acceptedEdit else { continue }
        do { _ = try TagService.write(edit, to: r.url) }
        catch { fail("写入失败（\(r.url.lastPathComponent)）：\(error.localizedDescription)") }
    }

    // ── 读回来逐字段对账 ──
    print("═══ 写入后读回（read）══")
    print("  文件      标题        专辑      年份   音轨    碟号    封面")
    var after: [URL: Tags] = [:]
    for r in results {
        guard let f = try? TagService.read(r.url) else { fail("读回失败：\(r.url.lastPathComponent)") }
        after[r.url] = f.tags
        let t = f.tags
        print(String(format: "  %@   %-10@  %-8@  %-5@  %-6@  %-6@  %@",
                     r.url.lastPathComponent as NSString,
                     (t.title ?? "—") as NSString,
                     (t.album ?? "—") as NSString,
                     (t.year ?? "—") as NSString,
                     (t.trackString ?? "—") as NSString,
                     (t.discString ?? "—") as NSString,
                     t.artworks.isEmpty ? "无" : "\(t.artworks.count) 张"))
    }
    print("")

    print("═══ 逐字段对账 ═══")
    // 01：全写
    if let t = after[urls[0]] {
        check("01 音轨号已写（1/3）", t.trackString == "1/3", "读到 \(t.trackString ?? "nil")")
        check("01 碟号已写（1/2）", t.discString == "1/2", "读到 \(t.discString ?? "nil")")
        check("01 封面已写", !t.artworks.isEmpty, "读到 \(t.artworks.count) 张")
    }
    // 02：不写碟号 → 碟号必须还是原来的 9/9，其余照写
    if let t = after[urls[1]] {
        check("02 碟号**未被写**（仍是 9/9）", t.discString == "9/9",
              "读到 \(t.discString ?? "nil")（新值本应是 1/2）")
        check("02 音轨号照写（2/3）", t.trackString == "2/3", "读到 \(t.trackString ?? "nil")")
        check("02 标题照写", t.title == "新标题 2", "读到 \(t.title ?? "nil")")
        check("02 封面照写", !t.artworks.isEmpty, "读到 \(t.artworks.count) 张")
    }
    // 03：不写音轨号 + 不写封面
    if let t = after[urls[2]] {
        check("03 音轨号**未被写**（仍是 3）", t.trackString == "3",
              "读到 \(t.trackString ?? "nil")（新值本应是 3/3）")
        check("03 封面**未被写**", t.artworks.isEmpty, "读到 \(t.artworks.count) 张")
        check("03 碟号照写（1/2）", t.discString == "1/2", "读到 \(t.discString ?? "nil")")
        check("03 标题照写", t.title == "新标题 3", "读到 \(t.title ?? "nil")")
    }

    // ── 统计口径 ──
    print("")
    print("═══ 统计口径（复核表脚注「将修改 N 个文件，共 M 处」）═══")
    let fileCount = results.filter { ($0.acceptedEdit?.changes.count ?? 0) > 0 || artCounts($0) > 0 }.count
    let changeTotal = results.reduce(0) { $0 + ($1.acceptedEdit?.changes.count ?? 0) + artCounts($1) }
    let fullTotal = results.reduce(0) { $0 + ($1.edit?.changes.count ?? 0) + ($1.artwork != nil ? 1 : 0) }
    print("  不排除时： \(results.count) 个文件，共 \(fullTotal) 处")
    print("  排除之后： \(fileCount) 个文件，共 \(changeTotal) 处")
    check("统计跟着排除走（少了 3 处：碟号 + 音轨号 + 封面）",
          changeTotal == fullTotal - 3,
          "\(fullTotal) → \(changeTotal)")

    print("")
    print("═══ 小结 ═══")
    print("  通过 \(pass)，失败 \(failCount)")
    if failCount > 0 { exit(1) }
}

// MARK: - 小工具

private func artCounts(_ r: AutoMatchResult) -> Int {
    if case .replace = r.acceptedEdit?.artworkAction { return 1 }
    return 0
}

private func sortedNames(_ fields: Set<TagEdit.Field>) -> String {
    TagEdit.Field.allCases.filter { fields.contains($0) }
        .map(\.localizedName).joined(separator: "、")
}

/// `--sample <路径>` → "<路径>"
func probeStringArg(_ args: [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// 找仓库里的 `testdata/<relative>`：先从当前目录逐级往上找，再从可执行文件所在目录
/// 逐级往上找（DerivedData 里跑 CLI 时用不上，但从仓库根或 `MacTagger/` 下跑都能命中）。
/// 都找不到就返回相对当前目录的 `testdata/<relative>`，由调用方报「样本不存在」。
func probeTestdataPath(_ relative: String) -> String {
    let fm = FileManager.default
    var roots: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)]
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        roots.append(exe.deletingLastPathComponent())
    }
    for root in roots {
        var dir = root.standardizedFileURL
        while true {
            let candidate = dir.appendingPathComponent("testdata").appendingPathComponent(relative)
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
    }
    return "testdata/" + relative
}

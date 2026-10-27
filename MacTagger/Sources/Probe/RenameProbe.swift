//
//  RenameProbe.swift
//  mactagger-probe — 「文件名 ↔ 标签」模板引擎与重命名验证
//
//    tpl cases                       内置用例表逐条跑（含每条校验规则的反例）
//    tpl validate "<模板>" [rename]   只校验，打印中文原因
//    tpl parse    "<模板>" "<文件名>"  模板 → 解析出的字段
//    tpl render   "<模板>" <音频文件>  标签 → 新文件名
//    rename <dir> "<模板>" [--dry]    目录内批量重命名（--dry 只看预览）
//    rename-undo                     撤消最近一批重命名
//

import Foundation

// MARK: - 小工具

private var tplPassed = 0
private var tplFailed = 0

private func check(_ name: String, expected: String, actual: String) {
    let ok = expected == actual
    if ok { tplPassed += 1 } else { tplFailed += 1 }
    print("  \(ok ? "✓" : "✗") \(name)")
    print("      期望: \(expected)")
    print("      实际: \(actual)")
}

/// 把字段字典排成稳定的可比字符串：`@5=03 @2=周杰伦 @1=稻香` 按编号升序。
private func describe(_ map: [FilenameField: String]) -> String {
    map.keys.sorted { $0.rawValue < $1.rawValue }
        .map { "\($0.token)=\(map[$0] ?? "")" }
        .joined(separator: " ")
}

private func validateText(_ raw: String, _ mode: FilenameRelationMode) -> String {
    FilenameTemplate.validate(raw, mode: mode) ?? "通过"
}

private func parseText(_ raw: String, _ filename: String) -> String {
    do {
        let t = try FilenameTemplate.parse(raw, mode: .updateTags)
        return describe(try t.match(filename: filename))
    } catch let e as FilenameTemplateError {
        return "错误：" + e.message
    } catch {
        return "错误：" + error.localizedDescription
    }
}

private func renderText(_ raw: String, _ tags: Tags, mode: FilenameRelationMode = .rename) -> String {
    do {
        let t = try FilenameTemplate.parse(raw, mode: mode)
        return RenameService.sanitizeComponent(t.render(tags: tags))
    } catch let e as FilenameTemplateError {
        return "错误：" + e.message
    } catch {
        return "错误：" + error.localizedDescription
    }
}

private func makeTags(title: String? = nil, artist: String? = nil, album: String? = nil,
                      albumArtist: String? = nil, year: String? = nil,
                      track: Int? = nil, disc: Int? = nil, comment: String? = nil) -> Tags {
    var t = Tags()
    t.title = title; t.artist = artist; t.album = album; t.albumArtist = albumArtist
    t.year = year; t.trackNumber = track; t.discNumber = disc; t.comment = comment
    return t
}

// MARK: - 用例表

func cmdTplCases() {
    hr("模板引擎用例表")
    tplPassed = 0; tplFailed = 0

    let demo = makeTags(title: "稻香", artist: "周杰伦", album: "魔杰座",
                        albumArtist: "周杰伦", year: "2008-10-15", track: 3, disc: 1,
                        comment: "第一行\n第二行")

    print("【一】校验规则（含每条规则的反例）")
    check("01 正常模板（解析模式）",
          expected: "通过", actual: validateText("@5 - @2 - @1", .updateTags))
    check("02 正常模板（重命名模式）",
          expected: "通过", actual: validateText("@5 - @2 - @1", .rename))
    check("03 反例·模板为空",
          expected: "模板不能为空", actual: validateText("   ", .updateTags))
    check("04 反例·一个参数都没有",
          expected: "模板中至少要有一个参数（例如 @1 标题）",
          actual: validateText("纯文本没有参数", .updateTags))
    check("05 反例·参数不能重复",
          expected: "参数不能重复：@1 标题 出现了不止一次",
          actual: validateText("@1 - @1", .updateTags))
    check("06 反例·参数不能相邻",
          expected: "参数不能相邻：@1@2 之间必须有分隔符，否则无法切分",
          actual: validateText("@1@2", .updateTags))
    check("07 反例·重命名模式不能用 @0",
          expected: "「重命名文件」模式下不能使用 @0（它只用于丢弃内容，无法生成文件名）",
          actual: validateText("@0 - @1", .rename))
    check("08 解析模式可以用 @0",
          expected: "通过", actual: validateText("@0 - @1", .updateTags))
    check("09 反例·参数编号越界 @9",
          expected: "无法识别的参数 @9，可用参数为 @0–@8",
          actual: validateText("@9 - @1", .updateTags))
    check("10 反例·@ 后面没有编号",
          expected: "「@」后面缺少参数编号，可用参数为 @0–@8（要输入字面的 @ 请写 @@）",
          actual: validateText("@ - @1", .updateTags))
    check("11 反例·两位数编号 @12",
          expected: "无法识别的参数 @12，可用参数为 @0–@8",
          actual: validateText("@12 - @1", .updateTags))
    check("12 @@ 转义成字面 @",
          expected: "通过", actual: validateText("@@ @1", .updateTags))

    print("")
    print("【二】解析（文件名 → 标签）")
    check("13 三段模板",
          expected: "@1=稻香 @2=周杰伦 @5=03",
          actual: parseText("@5 - @2 - @1", "03 - 周杰伦 - 稻香.mp3"))
    check("14 @0 通配丢弃前缀",
          expected: "@1=稻香 @2=周杰伦",
          actual: parseText("@0 - @2 - @1", "无用前缀 - 周杰伦 - 稻香.flac"))
    check("15 反例·文件名与模板不匹配",
          expected: "错误：文件名与模板不匹配",
          actual: parseText("@2 - @1", "没有分隔符的名字.mp3"))
    check("16 中括号分隔 + 年份",
          expected: "@1=稻香 @2=周杰伦 @6=2008",
          actual: parseText("[@6] @2 - @1", "[2008] 周杰伦 - 稻香.mp3"))
    check("17 碟号 + 音轨号",
          expected: "@1=稻香 @4=1 @5=03",
          actual: parseText("@4-@5 @1", "1-03 稻香.m4a"))

    print("")
    print("【三】渲染（标签 → 文件名）")
    check("18 三段模板，音轨补零",
          expected: "03 - 周杰伦 - 稻香", actual: renderText("@5 - @2 - @1", demo))
    check("19 空字段跳过并清理前面的分隔符",
          expected: "周杰伦 - 稻香",
          actual: renderText("@5 - @2 - @1", makeTags(title: "稻香", artist: "周杰伦")))
    check("20 中间字段为空，清理它前面的分隔符",
          expected: "03 - 稻香",
          actual: renderText("@5 - @2 - @1", makeTags(title: "稻香", track: 3)))
    check("21 开头参数为空，清理它后面的分隔符",
          expected: "周杰伦 - 稻香",
          actual: renderText("@4. @2 - @1", makeTags(title: "稻香", artist: "周杰伦")))
    check("22 年份只取前四位",
          expected: "2008 - 稻香", actual: renderText("@6 - @1", demo))
    check("23 注释里的换行换成空格",
          expected: "第一行 第二行", actual: renderText("@7", demo))
    check("24 非法字符 / 与 : 被替换成全角",
          expected: "AC／DC：回声",
          actual: renderText("@1", makeTags(title: "AC/DC:回声")))
    check("25 全部字段为空 → 空文件名",
          expected: "", actual: renderText("@5 - @2 - @1", Tags()))
    check("26 专辑艺术家 + 专辑",
          expected: "周杰伦 - 魔杰座 - 稻香", actual: renderText("@8 - @3 - @1", demo))

    print("")
    print("【四】正则方式")
    let goodRule = FilenameRegexRule(pattern: "^(\\d+) - (.+) - (.+)$",
                                     groupFields: [1: .track, 2: .artist, 3: .title])
    check("27 正则校验通过",
          expected: "通过",
          actual: goodRule.validationMessage(mode: .updateTags) ?? "通过")
    check("28 反例·捕获组不能为空",
          expected: "捕获组不能为空：至少要给一个捕获组指定字段",
          actual: FilenameRegexRule(pattern: "^(.+)$", groupFields: [:])
                    .validationMessage(mode: .updateTags) ?? "通过")
    check("29 反例·捕获组不能重复（同字段被两组占用）",
          expected: "捕获组不能重复：标题 同时被第 1 组、第 2 组占用",
          actual: FilenameRegexRule(pattern: "^(.+) - (.+)$", groupFields: [1: .title, 2: .title])
                    .validationMessage(mode: .updateTags) ?? "通过")
    check("30 反例·组号不存在",
          expected: "第 3 组不存在：正则中只有 1 个捕获组",
          actual: FilenameRegexRule(pattern: "^(.+)$", groupFields: [3: .title])
                    .validationMessage(mode: .updateTags) ?? "通过")
    check("31 反例·正则无法编译",
          expected: "正则表达式有误，无法编译",
          actual: FilenameRegexRule(pattern: "^(.+", groupFields: [1: .title])
                    .validationMessage(mode: .updateTags) ?? "通过")
    check("32 正则解析文件名",
          expected: "@1=稻香 @2=周杰伦 @5=03",
          actual: (try? goodRule.match(filename: "03 - 周杰伦 - 稻香.mp3")).map(describe) ?? "错误")
    check("33 正则重命名：捕获组替换成标签值",
          expected: "03 - 周杰伦 - 稻香",
          actual: (try? goodRule.renderRename(currentName: "07 - unknown - song.mp3", tags: demo)) ?? "错误")

    print("")
    print("【五】文件名净化")
    check("34 斜杠与冒号",
          expected: "a／b：c", actual: RenameService.sanitizeComponent("a/b:c"))
    check("35 首尾空白与尾部句点",
          expected: "稻香", actual: RenameService.sanitizeComponent("  稻香..  "))
    check("36 前导点（避免生成隐藏文件）",
          expected: "hidden", actual: RenameService.sanitizeComponent(".hidden"))

    print("")
    print("=== 汇总：通过 \(tplPassed) / 共 \(tplPassed + tplFailed)，失败 \(tplFailed) ===")
    if tplFailed > 0 { exit(2) }
}

// MARK: - 单条命令

func cmdTplValidate(_ raw: String, _ modeArg: String?) {
    let mode: FilenameRelationMode = (modeArg == "rename") ? .rename : .updateTags
    hr("校验模板")
    print("  模板  : \(raw)")
    print("  模式  : \(mode.localizedName)")
    print("  结果  : \(validateText(raw, mode))")
    if let t = try? FilenameTemplate.parse(raw, mode: mode) {
        print("  正则  : \(t.regexPattern)")
        print("  参数  : " + t.fields.map(\.buttonLabel).joined(separator: " / "))
    }
}

func cmdTplParse(_ raw: String, _ filename: String) {
    hr("解析文件名")
    print("  模板    : \(raw)")
    print("  文件名  : \(filename)")
    do {
        let t = try FilenameTemplate.parse(raw, mode: .updateTags)
        print("  正则    : \(t.regexPattern)")
        let map = try t.match(filename: filename)
        for f in map.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("    \(f.buttonLabel.padding(toLength: 14, withPad: " ", startingAt: 0)) = \(map[f] ?? "")")
        }
    } catch let e as FilenameTemplateError {
        print("  失败    : \(e.message)")
    } catch {
        print("  失败    : \(error.localizedDescription)")
    }
}

func cmdTplRender(_ raw: String, _ path: String) {
    let url = URL(fileURLWithPath: path)
    hr("渲染文件名")
    print("  模板    : \(raw)")
    print("  文件    : \(url.lastPathComponent)")
    guard let file = try? TagService.read(url) else { print("  读取失败"); return }
    let g = file.tags
    print("  标签    : 标题=\(fmt(g.title)) 艺术家=\(fmt(g.artist)) 专辑=\(fmt(g.album)) 音轨=\(fmt(g.trackString)) 年份=\(fmt(g.year))")
    do {
        let t = try FilenameTemplate.parse(raw, mode: .rename)
        let base = RenameService.sanitizeComponent(t.render(tags: g))
        let ext = url.pathExtension
        print("  新文件名: \(ext.isEmpty ? base : base + "." + ext)")
    } catch let e as FilenameTemplateError {
        print("  失败    : \(e.message)")
    } catch {
        print("  失败    : \(error.localizedDescription)")
    }
}

// MARK: - rename / rename-undo

private func audioFiles(in dir: URL) -> [URL] {
    let exts = Set(TagService.supportedExtensions)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.sorted()
        .map { dir.appendingPathComponent($0) }
        .filter { exts.contains($0.pathExtension.lowercased()) }
}

func cmdRename(_ dirPath: String, _ raw: String, dryRun: Bool) {
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
    hr("批量重命名\(dryRun ? "（预览，不落盘）" : "")")
    print("  目录    : \(dir.path)")
    print("  模板    : \(raw)")

    let template: FilenameTemplate
    do { template = try FilenameTemplate.parse(raw, mode: .rename) }
    catch let e as FilenameTemplateError { print("  模板不合法：\(e.message)"); return }
    catch { print("  模板不合法：\(error.localizedDescription)"); return }

    let urls = audioFiles(in: dir)
    guard !urls.isEmpty else { print("  目录里没有可识别的音频文件"); return }

    var items: [(url: URL, tags: Tags)] = []
    for u in urls {
        guard let f = try? TagService.read(u) else { continue }
        items.append((u, f.tags))
    }

    let plans = RenameService.plan(items: items, template: template, options: .default)
    print("")
    print("  预览：")
    for p in plans {
        let mark: String
        switch p.status {
        case .ready:        mark = "→"
        case .unchanged:    mark = "·"
        case .invalid:      mark = "✗"
        }
        let tail = p.status.reason.map { "   （\($0)）" } ?? ""
        print("    \(mark) \(p.currentName)  ⇒  \(p.newName.isEmpty ? "—" : p.newName)\(tail)")
        for c in p.companions {
            print("        ＋ \(c.from.lastPathComponent)  ⇒  \(c.to.lastPathComponent)")
        }
    }

    guard !dryRun else {
        let ready = plans.filter { $0.status.isReady }.count
        print("")
        print("  可执行 \(ready) 项（--dry，未落盘）")
        return
    }

    let history = try? TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL())
    let outcome = RenameService.apply(plans, journal: RenameJournal.shared, history: history)
    print("")
    print("  结果    : \(outcome.summary.description)")
    for f in outcome.summary.failures {
        print("    ✗ \(f.url.lastPathComponent)：\(f.error.localizedDescription)")
    }
    if !outcome.movedCompanions.isEmpty {
        print("  伴随文件: 同步搬运 \(outcome.movedCompanions.count) 个")
    }
    print("  日志    : 共 \(RenameJournal.shared?.batchCount() ?? 0) 批")
}

func cmdRenameUndo() {
    hr("撤消最近一批重命名")
    guard let journal = RenameJournal.shared else { print("  日志不可用"); return }
    guard let batch = journal.lastBatch() else { print("  没有可撤消的重命名批次"); return }
    print("  批次时间: \(batch.date)")
    print("  条目    : 主文件 \(batch.fileCount) 个，伴随文件 \(batch.companionCount) 个")

    let history = try? TagsHistoryStore(databaseURL: try TagsHistoryStore.defaultDatabaseURL())
    let outcome = journal.undoLastBatch(history: history)
    print("")
    for (from, to) in outcome.restored {
        print("    ← \(from.lastPathComponent)  ⇒  \(to.lastPathComponent)")
    }
    for f in outcome.summary.failures {
        print("    ✗ \(f.url.lastPathComponent)：\(f.error.localizedDescription)")
    }
    print("")
    print("  结果    : \(outcome.summary.description)")
    print("  剩余批次: \(journal.batchCount())")
}

// MARK: - settags（端到端造数据用）

/// `settags <file> title=… artist=… track=… album=… year=… disc=… comment=… albumartist=…`
///
/// `smoke` 写的是固定值，端到端要「每个文件标签都不同」，所以补一个能精确写字段的入口。
func cmdSetTags(_ path: String, _ pairs: [String]) {
    let url = URL(fileURLWithPath: path)
    var edit = TagEdit()
    var applied: [String] = []
    for pair in pairs {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let key = parts[0].lowercased()
        let value = parts[1].isEmpty ? nil : parts[1]
        switch key {
        case "title":       edit.set(.title, value)
        case "artist":      edit.set(.artist, value)
        case "album":       edit.set(.album, value)
        case "albumartist": edit.set(.albumArtist, value)
        case "year":        edit.set(.year, value)
        case "track":       edit.set(.track, value)
        case "disc":        edit.set(.disc, value)
        case "genre":       edit.set(.genre, value)
        case "comment":     edit.set(.comment, value)
        case "lyrics":      edit.set(.lyrics, value?.replacingOccurrences(of: "\\n", with: "\n"))
        // 多行歌词从文件读，命令行里塞不下也不好转义
        case "lyricsfile":
            guard let path = value,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            edit.set(.lyrics, text)
        default: continue
        }
        applied.append(pair)
    }
    guard !edit.isEmpty else { fail("没有可识别的字段，用法: settags <file> title=… artist=… track=…") }
    do {
        _ = try TagService.write(edit, to: url)
        let back = try TagService.read(url)
        print("\(url.lastPathComponent)  ← \(applied.joined(separator: " "))")
        print("   复核: 标题=\(fmt(back.tags.title)) 艺术家=\(fmt(back.tags.artist)) 音轨=\(fmt(back.tags.trackString))")
    } catch {
        fail("写入失败：\(error.localizedDescription)")
    }
}

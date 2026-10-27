//
//  ChineseProbe.swift
//  mactagger-probe — 简繁转换（OpenCC）与批量转换的验证子命令
//
//  用法：
//    mactagger-probe zh env
//        打印 OpenCC 是否装上、配置目录、以及四个方向的样例转换
//    mactagger-probe zh convert --to s|t "<文本>"
//        单串转换
//    mactagger-probe zh batch <dir> --tags|--filenames --to s|t [--apply] [--undo] [--keep]
//        在**临时副本**上跑批量转换。源目录零改动 —— 与 pacer / writecost 等
//        既有子命令同一条铁律：probe 绝不碰用户的原始文件。
//

import Foundation

// MARK: - 参数

private func zhPolicy(_ args: [String]) -> ChineseVariantPolicy {
    guard let i = args.firstIndex(of: "--to"), i + 1 < args.count else { return .simplified }
    switch args[i + 1].lowercased() {
    case "s", "simp", "simplified", "简", "简体":  return .simplified
    case "t", "trad", "traditional", "繁", "繁体": return .traditional
    default: return .simplified
    }
}

/// `--zh s|t|none`。其他子命令（automatch 等）共用这一个解析。
func probeZhPolicy(_ args: [String]) -> ChineseVariantPolicy {
    guard let i = args.firstIndex(of: "--zh"), i + 1 < args.count else { return .none }
    switch args[i + 1].lowercased() {
    case "s", "simp", "simplified":  return .simplified
    case "t", "trad", "traditional": return .traditional
    default: return .none
    }
}

/// 把策略说成人话：`繁→简` / `简→繁`。
func zhDirectionText(_ p: ChineseVariantPolicy) -> String {
    switch p {
    case .simplified:  return "繁→简"
    case .traditional: return "简→繁"
    case .none:        return "不转换"
    }
}

// MARK: - env

func cmdZhEnv() {
    hr("OpenCC 环境")
    out("可用            : \(ChineseVariant.isAvailable ? "是" : "否")")
    out("配置目录        : \(ChineseVariant.configDirectory ?? "（未找到）")")
    out("搜索过的目录    : \(MTOpenCC.searchedDirectories.joined(separator: "  "))")
    if let why = ChineseVariant.unavailableReason { out("不可用原因      : \(why)") }
    out("进程级默认策略  : \(ChineseVariant.onlineDefault.rawValue)")

    out()
    out("样例：")
    let samples = ["周杰倫 國語流行樂 鄧麗君 香港之戀",
                   "周杰伦 国语流行乐 邓丽君 香港之恋",
                   "Taylor Swift - Blank Space",
                   ""]
    for s in samples {
        let toS = ChineseVariant.convert(s, to: .simplified)
        let toT = ChineseVariant.convert(s, to: .traditional)
        out("  原文  : \(fmt(s))")
        out("  繁→简 : \(fmt(toS))")
        out("  简→繁 : \(fmt(toT))")
        out()
    }
}

// MARK: - convert

func cmdZhConvert(_ args: [String]) {
    let policy = zhPolicy(args)
    // 去掉 --to 与它的值，剩下的全当文本（允许不加引号地分词传进来）
    var words: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a == "--to" { skip = true; continue }
        words.append(a)
    }
    let text = words.joined(separator: " ")
    guard !text.isEmpty else { fail("用法: zh convert --to s|t \"<文本>\"") }

    hr("简繁转换（\(zhDirectionText(policy))）")
    out("引擎    : \(ChineseVariant.environmentSummary)")
    let result = ChineseVariant.convert(text, to: policy)
    out("原文    : \(text)")
    out("结果    : \(result)")
    out("是否改变: \(result != text ? "是" : "否")")
    if !ChineseVariant.isAvailable {
        out()
        out("！引擎不可用，上面的「结果」是原样返回的入参（这是设计好的降级行为）。")
        exit(2)
    }
}

// MARK: - batch

/// 把目录里的音频拷进临时目录。返回 (副本目录, 副本文件列表)。
private func zhCopyToTemp(_ dir: URL) -> (URL, [URL]) {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    let audio = items.filter { TagService.isSupported(url: $0) }.sorted { $0.path < $1.path }
    guard !audio.isEmpty else { fail("目录里没有可处理的音频文件：\(dir.path)") }

    let temp = fm.temporaryDirectory
        .appendingPathComponent("mactagger-zh-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: temp, withIntermediateDirectories: true)

    var copies: [URL] = []
    for src in audio {
        let dst = temp.appendingPathComponent(src.lastPathComponent)
        do { try fm.copyItem(at: src, to: dst); copies.append(dst) }
        catch { out("  ! 拷贝失败：\(src.lastPathComponent) — \(error.localizedDescription)") }
        // 同名 .lrc / 图片也拷一份，好验证伴随文件跟着改名
        let base = src.deletingPathExtension().lastPathComponent
        for ext in ["lrc", "jpg", "png"] {
            let c = src.deletingLastPathComponent().appendingPathComponent("\(base).\(ext)")
            guard fm.fileExists(atPath: c.path) else { continue }
            try? fm.copyItem(at: c, to: temp.appendingPathComponent(c.lastPathComponent))
        }
    }
    return (temp, copies)
}

func cmdZhBatch(_ path: String, args: [String]) {
    let policy = zhPolicy(args)
    let wantsFilenames = args.contains("--filenames")
    let wantsTags = args.contains("--tags") || !wantsFilenames
    let apply = args.contains("--apply") || args.contains("--undo")
    let wantsUndo = args.contains("--undo")
    let keep = args.contains("--keep")

    var isDir: ObjCBool = false
    let src = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
        fail("需要一个目录：\(path)")
    }

    hr("批量简繁转换 · \(wantsTags ? "标签" : "文件名") · \(zhDirectionText(policy))")
    out("引擎    : \(ChineseVariant.environmentSummary)")
    out("源目录  : \(src.path)（**只读**，全部操作在副本上做）")

    let (temp, copies) = zhCopyToTemp(src)
    out("副本目录: \(temp.path)")
    out("副本文件: \(copies.count) 个")
    out()

    if wantsTags {
        zhBatchTags(copies, policy: policy, apply: apply, undo: wantsUndo)
    } else {
        zhBatchFilenames(copies, policy: policy, apply: apply, undo: wantsUndo)
    }

    if keep {
        out()
        out("副本保留在：\(temp.path)")
    } else {
        try? FileManager.default.removeItem(at: temp)
        out()
        out("副本已清理。")
    }
}

// MARK: 标签

private func zhBatchTags(_ urls: [URL], policy: ChineseVariantPolicy, apply: Bool, undo: Bool) {
    let (files, failures) = TagService.readAll(urls)
    if !failures.isEmpty { out("  读取失败 \(failures.count) 个（已跳过）") }

    let plan = ChineseConversionService.planTags(files.map { ($0.url, $0.tags) }, to: policy)
    out("计划    : \(plan.summary)")
    out()
    out("预览（原 → 新）：")
    var lastFile = ""
    for c in plan.changes {
        if c.fileName != lastFile { out("  ── \(c.fileName)"); lastFile = c.fileName }
        out("     \(c.field.localizedName)：\(c.old)  →  \(c.new)")
    }
    guard apply, !plan.isEmpty else { return }

    out()
    out("应用中…")
    let summary = probeRunBlockingVoid {
        await BatchEngine.applyEdits(plan.edits, concurrency: 2, progress: nil)
    }
    out("写入结果: \(summary.description)")

    out()
    out("复核（回读磁盘）：")
    let (after, _) = TagService.readAll(plan.edits.map(\.url))
    for f in after {
        out("  ── \(f.url.lastPathComponent)")
        for field in ChineseConversionService.defaultFields {
            guard let v = f.tags.value(for: field), !v.isEmpty else { continue }
            let expected = ChineseVariant.convert(v, to: policy)
            let ok = expected == v      // 已经是目标字形 → 幂等
            out("     \(field.localizedName)：\(v)  \(ok ? "✔" : "✘ 仍需转换")")
        }
    }

    guard undo else { return }
    out()
    out("撤消：标签转换走的是 App 的 `performTagPropagation` 五步链（历史库旁存 → 撤消标签保存）。")
    out("     probe 这里不接历史库，用「再转回去」验证转换本身可逆：")
    let back: ChineseVariantPolicy = policy == .simplified ? .traditional : .simplified
    let plan2 = ChineseConversionService.planTags(after.map { ($0.url, $0.tags) }, to: back)
    out("     反向计划：\(plan2.summary)")
}

// MARK: 文件名

private func zhBatchFilenames(_ urls: [URL], policy: ChineseVariantPolicy, apply: Bool, undo: Bool) {
    let plans = ChineseConversionService.planFilenames(urls, to: policy)
    out("计划    : \(ChineseConversionService.summary(for: plans))")
    out()
    out("预览（原 → 新）：")
    for p in plans {
        let mark: String
        switch p.status {
        case .ready:            mark = "→"
        case .unchanged:        mark = "＝"
        case .invalid:          mark = "✘"
        }
        out("  \(mark) \(p.currentName)"
            + (p.status.isReady ? "  →  \(p.newName)" : "")
            + (p.status.reason.map { "   （\($0)）" } ?? ""))
        for c in p.companions {
            out("      伴随：\(c.from.lastPathComponent)  →  \(c.to.lastPathComponent)")
        }
    }
    guard apply, plans.contains(where: { $0.status.isReady }) else { return }

    // 用一份**临时日志**，绝不碰用户的 ~/Library/.../rename-journal.json
    let journalURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mactagger-zh-journal-\(UUID().uuidString.prefix(8)).json")
    let journal = RenameJournal(fileURL: journalURL)
    defer { try? FileManager.default.removeItem(at: journalURL) }

    out()
    out("应用中…（重命名日志用临时文件，不动用户的日志）")
    let outcome = RenameService.apply(plans, journal: journal)
    out("重命名结果: \(outcome.summary.description)")

    let dir = urls.first?.deletingLastPathComponent()
    out()
    out("复核（ls 副本目录）：")
    zhListDir(dir)

    guard undo else { return }
    out()
    out("撤消重命名（journal.undoLastBatch）…")
    let back = journal.undoLastBatch()
    out("撤消结果  : \(back.summary.description)")
    out()
    out("复核（ls 副本目录，应已改回原名）：")
    zhListDir(dir)
}

private func zhListDir(_ dir: URL?) {
    guard let dir else { return }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    for n in names { out("  \(n)") }
}

// MARK: - 同步桥

/// main.swift 是顶层代码、不能 await；这里给批量写入用一个最小同步桥。
private final class ZhBox<T>: @unchecked Sendable { var value: T? }

func probeRunBlockingVoid<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ZhBox<T>()
    Task { box.value = await body(); sem.signal() }
    sem.wait()
    return box.value!
}

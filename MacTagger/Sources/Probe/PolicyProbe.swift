//
//  PolicyProbe.swift
//  mactagger-probe — 封面策略 + 预留填充的端到端演示
//
//      mactagger-probe policy demo <dir> <大图> [--keep]
//
//  六步，全部走**产品代码**（`ArtworkPolicy` + `BatchEngine.applyEdits(paddingPolicy:)`），
//  不另写一套逻辑，否则验证的就不是 App 真正会跑的东西：
//
//    ① embed 模式写一张 1.5 MB 封面      → 整文件重写，写完自动预留填充
//    ② 再换一张**同尺寸**封面            → 应当原地、大小不变、毫秒级
//    ③ 再换一张 300 KB 小封面            → 预估应提前报「因填充超限将被收缩重写」
//    ④ folderFile 模式                   → 音频大小 / mtime **零改动**，每个目录一张 cover.jpg
//    ⑤ both 模式                         → 音频照写 + 文件夹图片也落
//    ⑥ M4A                               → 全程跟着写，预留填充静默跳过（格式不支持）
//
//  `<dir>` 只读：所有文件先复制进临时工作目录（保留子目录结构），结束即删。
//

import Foundation

// MARK: - 小工具（poli 前缀，避免与同目录其它 probe 撞名）

private func poliMB(_ b: Int64) -> String { String(format: "%.2f MB", Double(b) / 1_048_576) }
private func poliKB(_ b: Int64) -> String { String(format: "%.0f KB", Double(b) / 1024) }
private func poliMS(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000) }

/// 一个文件在某一刻的全部可观测量。
private struct PoliSnapshot {
    var url: URL
    var size: Int64
    var mtime: Date?
    var audioOffset: Int64
    var padding: Int64
    var artworkBytes: Int

    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

private func poliSnapshot(_ url: URL) -> PoliSnapshot {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let info = PaddingReserver.inspect(url)
    let art = (try? TagService.readArtworks(url))?.first?.byteCount ?? 0
    return PoliSnapshot(url: url,
                        size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                        mtime: attrs?[.modificationDate] as? Date,
                        audioOffset: info.audioOffset,
                        padding: info.currentPadding,
                        artworkBytes: art)
}

/// 并发回调里收集每个文件的完成时刻（`applyEdits` 只给总耗时）。
private final class PoliTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(path: String, at: Date)] = []
    let started = Date()

    func mark(_ path: String?) {
        guard let path else { return }
        lock.lock(); marks.append((path, Date())); lock.unlock()
    }

    /// 逐个文件的耗时（并发度 1 时即为该文件自身的耗时，含它的预留填充）。
    func durations() -> [String: TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: TimeInterval] = [:]
        var prev = started
        for m in marks {
            out[m.path] = m.at.timeIntervalSince(prev)
            prev = m.at
        }
        return out
    }
}

private func poliArtwork(_ data: Data, name: String) -> Artwork {
    ArtworkProcessor.refreshedMetadata(
        Artwork(data: data, mimeType: ArtworkProcessor.mimeType(data) ?? "image/jpeg",
                caption: name, type: .frontCover))
}

/// 压出一张「大约 target 字节」的小封面。
///
/// 走产品代码 `ArtworkProcessor.process`，按 JPEG 质量二分——直接传 `maxBytes` 会一路
/// 降质降到远低于目标（噪声图尤其明显：给 300 KB 上限能压到 170 KB），
/// 演示里要的是「差不多就是 300 KB 的那一张」。
private func poliShrink(_ data: Data, target: Int) -> Data {
    var lo = 0.05, hi = 1.0, best = data
    for _ in 0..<12 {
        let q = (lo + hi) / 2
        guard let r = try? ArtworkProcessor.process(
            data, options: ArtworkProcessOptions(maxEdge: 0, format: .jpeg,
                                                 jpegQuality: q, maxBytes: 0)) else { break }
        if r.data.count > target { hi = q } else { lo = q; best = r.data }
        if abs(r.data.count - target) < target / 20 { return r.data }
    }
    return best
}

/// 同尺寸不同内容的一张图（验证「换封面」而不是「换大小」）。
private func poliVariant(of data: Data) -> Data {
    var d = data
    guard d.count > 4096 else { return d }
    let start = d.count / 2
    for i in start..<min(start + 2048, d.count) { d[i] = UInt8.random(in: 0...255) }
    return d
}

/// 把源目录连同子目录结构复制一份到临时工作区。**源目录只读。**
private func poliStage(_ dir: URL) -> (work: URL, files: [URL]) {
    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-policy-\(getpid())-\(Int(Date().timeIntervalSince1970))",
                                isDirectory: true)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)

    var files: [URL] = []
    let exts = Set(["flac", "mp3", "m4a", "mp4", "ogg", "opus", "wav", "aiff", "ape", "wv"])
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = e?.nextObject() as? URL {
        guard exts.contains(u.pathExtension.lowercased()) else { continue }
        let rel = u.path.replacingOccurrences(of: dir.path + "/", with: "")
        let dst = work.appendingPathComponent(rel)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // APFS 上 copyItem 走 clonefile（写时复制），几十 MB 也是瞬间。
        do { try fm.copyItem(at: u, to: dst); files.append(dst) }
        catch { out("  ! 复制失败 \(u.lastPathComponent)：\(error.localizedDescription)") }
    }
    return (work, files.sorted { $0.path < $1.path })
}

/// 同步跑一遍 `BatchEngine.applyEdits`（probe 是命令行，直接等）。
private func poliApply(_ payload: [(url: URL, edit: TagEdit)],
                       padding: PaddingPolicy?) -> (BatchSummary, [String: TimeInterval]) {
    guard !payload.isEmpty else { return (BatchSummary(), [:]) }
    let timer = PoliTimer()
    let sem = DispatchSemaphore(value: 0)
    var summary = BatchSummary()
    Task {
        // 并发度 1：要的是**每个文件各自**的耗时，并发会让它们互相污染。
        let s = await BatchEngine.applyEdits(payload, concurrency: 1, paddingPolicy: padding) { p in
            timer.mark(p.currentPath)
        }
        summary = s
        sem.signal()
    }
    sem.wait()
    return (summary, timer.durations())
}

/// 一步的结果表。
private func poliTable(_ before: [PoliSnapshot],
                       _ after: [PoliSnapshot],
                       durations: [String: TimeInterval],
                       reserved: Set<URL>,
                       preferred: Int) {
    out("| 文件 | 大小 前→后 | Δ | 音频起点 前→后 | 耗时 | PADDING 前→后 | 推荐预留 | 判定 |")
    out("|---|---|---|---|---|---|---|---|")
    for (b, a) in zip(before, after) {
        let delta = a.size - b.size
        let moved = b.audioOffset != a.audioOffset || delta != 0
        let target = PaddingReserver.canReserve(a.url)
            ? poliKB(Int64(PaddingReserver.recommendedTarget(fileBytes: a.size,
                                                             currentPadding: a.padding,
                                                             preferred: preferred)))
            : "—"
        var verdict: [String] = []
        verdict.append(moved ? "整文件重写" : "原地")
        if reserved.contains(a.url) { verdict.append("已预留") }
        else if !PaddingReserver.canReserve(a.url) { verdict.append("不支持预留") }
        out("| \(b.folder)/\(b.name)"
            + " | \(poliMB(b.size)) → \(poliMB(a.size))"
            + " | \(delta >= 0 ? "+" : "")\(delta)"
            + " | \(b.audioOffset) → \(a.audioOffset)"
            + " | \(poliMS(durations[a.url.path] ?? 0))"
            + " | \(poliKB(b.padding)) → \(poliKB(a.padding))"
            + " | \(target)"
            + " | \(verdict.joined(separator: " + ")) |")
    }
}

// MARK: - policy demo

func cmdPolicyDemo(_ dirPath: String, _ imagePath: String, keep: Bool) {
    let dir = URL(fileURLWithPath: dirPath)
    guard let bigImage = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
        fail("读不到图片 \(imagePath)")
    }

    hr("封面策略 + 预留填充 六步演示")
    let (work, files) = poliStage(dir)
    guard !files.isEmpty else {
        try? FileManager.default.removeItem(at: work)
        fail("目录里没有可用的音频文件")
    }
    defer {
        if keep { out("\n工作目录已保留：\(work.path)") }
        else {
            try? FileManager.default.removeItem(at: work)
            out("\n已删除临时工作目录 \(work.path)")
        }
    }

    // 三张封面：大图、同尺寸变体、300 KB 小图（小图用产品代码压出来）。
    let sameSize = poliVariant(of: bigImage)
    let smallImage = poliShrink(bigImage, target: 300 * 1024)
    guard smallImage.count < bigImage.count / 2 else {
        try? FileManager.default.removeItem(at: work)
        fail("压不出 300 KB 级的小封面（原图 \(bigImage.count) 字节，压出 \(smallImage.count) 字节）")
    }

    let padding = PaddingPolicy(enabled: true,
                                preferredBytes: PaddingReserver.defaultReserveBytes)
    out("工作目录  : \(work.path)")
    out("文件      : \(files.count) 个 —— " + files.map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }.joined(separator: "、"))
    out("大封面    : \(bigImage.count) 字节（\(poliKB(Int64(bigImage.count)))）")
    out("同尺寸变体: \(sameSize.count) 字节")
    out("小封面    : \(smallImage.count) 字节（\(poliKB(Int64(smallImage.count)))）")
    out("预留策略  : 开启，设置上限 \(poliKB(Int64(padding.preferredBytes)))"
        + "（实际按每个文件 min(文件/100, 1 MB) × 0.95 压值）")

    /// 走一遍完整链路：策略改写 → applyEdits（含预留）→ 文件夹封面落地。
    func runStep(_ title: String,
                 note: String,
                 policy: ArtworkPolicy,
                 image: Data?,
                 label: String,
                 titleField: String? = nil) {
        hr(title)
        out(note)

        var raw: [(url: URL, edit: TagEdit)] = []
        for url in files {
            var e = TagEdit()
            if let t = titleField { e.set(.title, t) }
            if let image { e.artworkAction = .replace([poliArtwork(image, name: label)]) }
            raw.append((url, e))
        }

        // ① 封面策略：改写编辑集 + 收集文件夹任务（产品代码，App 走的是同一个函数）
        let (payload, jobs) = policy.apply(to: raw)

        // ② 预估：确认框里那句话就是这么来的
        let plan = TagService.estimatedWriteCost(payload, padding: padding)
        out("\n【预估】音频侧 \(payload.count) 个文件"
            + "，整文件重写 \(plan.fullRewriteCount) 个（\(poliMB(plan.totalRewriteBytes))）"
            + "，收缩重写 \(plan.shrinkCount) 个，顺带预留 \(plan.reserveCount) 个")
        out("      确认框文案：" + (plan.warningText ?? "（无整文件重写，不提示）"))
        if let t = policy.plannedText(jobs: jobs) { out("      封面策略文案：" + t) }

        let before = files.map(poliSnapshot)
        let (summary, durations) = poliApply(payload, padding: padding)
        let folder = policy.run(jobs)
        let after = files.map(poliSnapshot)

        out("\n【实测】\(summary.description)"
            + String(format: "，音频写入总耗时 %.2f s", summary.elapsed))
        poliTable(before, after, durations: durations,
                  reserved: Set(summary.reserves.map(\.url)), preferred: padding.preferredBytes)

        if !summary.reserves.isEmpty {
            out("\n预留填充：")
            for r in summary.reserves {
                out("  · \(r.url.lastPathComponent) → PADDING \(poliKB(r.paddingAfter))"
                    + "，额外搬动 \(poliMB(r.movedBytes))")
            }
        }
        for f in summary.reserveSkips { out("  · 预留跳过 \(f.url.lastPathComponent)：\(f.message)") }
        for f in summary.reserveFailures { out("  ! 预留失败 \(f.url.lastPathComponent)：\(f.message)") }
        let skippedFormats = files.filter { !PaddingReserver.canReserve($0) }.map(\.lastPathComponent)
        if !skippedFormats.isEmpty {
            out("  · 静默跳过预留（格式不支持）：\(skippedFormats.joined(separator: "、"))")
        }
        if !folder.isEmpty {
            out("\n文件夹封面：\(folder.statusNote ?? "-")")
            for name in folder.fileNames { out("  · \(name)") }
        }
        // 封面确实换成了新的那张？读回来对一下字节数。
        let arts = after.map(\.artworkBytes)
        out("\n读回封面字节：" + arts.map { "\($0)" }.joined(separator: " / "))
    }

    // ---------------------------------------------------------------- ①
    runStep("① embed 模式 · 首次写 1.5 MB 封面",
            note: "预期：塞不进 FLAC 头部那几 KB 的 PADDING → 整文件重写；写完自动把填充扩到位。",
            policy: ArtworkPolicy(mode: .embed),
            image: bigImage, label: "cover-big", titleField: "策略演示 ①")

    // ---------------------------------------------------------------- ②
    runStep("② embed 模式 · 换一张同尺寸封面",
            note: "预期：新封面塞得进「旧封面腾出的位置 + 已预留的填充」→ 原地、大小不变、~0 ms。",
            policy: ArtworkPolicy(mode: .embed),
            image: sameSize, label: "cover-same")

    // ---------------------------------------------------------------- ③
    runStep("③ embed 模式 · 换成 300 KB 小封面",
            note: "预期：塞得进，但剩余填充 = 原填充 + 旧封面 − 新封面 会超过 TagLib 的 1% 线，"
                + "预估应提前报「因填充超限将被收缩重写」；实际发生后应再补一次预留。",
            policy: ArtworkPolicy(mode: .embed),
            image: smallImage, label: "cover-small")

    // ---------------------------------------------------------------- ④
    let beforeFolder = files.map(poliSnapshot)
    runStep("④ folderFile 模式 · 封面只落文件夹图片",
            note: "预期：音频侧编辑集被清空 → 一个文件都不打开；每个目录写一张 cover.jpg。",
            policy: ArtworkPolicy(mode: .folderFile, naming: .coverJpg, overwrite: true),
            image: bigImage, label: "cover-folder")
    let afterFolder = files.map(poliSnapshot)
    out("\n【零改动复核】音频文件大小 / mtime：")
    var untouched = 0
    for (b, a) in zip(beforeFolder, afterFolder) {
        let same = b.size == a.size && b.mtime == a.mtime && b.artworkBytes == a.artworkBytes
        if same { untouched += 1 }
        out("  \(same ? "✔" : "✘") \(b.folder)/\(b.name)"
            + "  大小 \(b.size) → \(a.size)"
            + "  mtime \(b.mtime.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-")"
            + " → \(a.mtime.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-")"
            + "  内嵌封面 \(b.artworkBytes) → \(a.artworkBytes) 字节")
    }
    out("  结论：\(untouched)/\(files.count) 个音频文件一个字节都没动"
        + (untouched == files.count ? " ✔" : " ✘"))
    out("\n目录里现有的文件夹封面：")
    for (folder, url) in FolderArtwork.locateAll(for: files).sorted(by: { $0.key.path < $1.key.path }) {
        let n = (try? Data(contentsOf: url))?.count ?? 0
        out("  · \(folder.lastPathComponent)/\(url.lastPathComponent)  \(n) 字节")
    }

    // ---------------------------------------------------------------- ⑤
    runStep("⑤ both 模式 · 两边都写",
            note: "预期：音频侧照常写封面（能原地就原地），同时每个目录再落一张 folder.jpg。"
                + "用的是小封面的同尺寸变体——字节数一样、内容不同，便于确认标签确实被改写过。",
            policy: ArtworkPolicy(mode: .both, naming: .folderJpg, overwrite: true),
            image: poliVariant(of: smallImage), label: "cover-both")

    // ---------------------------------------------------------------- ⑥
    hr("⑥ M4A 与 writecost 口径")
    let m4a = files.filter { $0.pathExtension.lowercased() == "m4a" }
    for url in m4a {
        let s = poliSnapshot(url)
        out("\(url.lastPathComponent)：写入正常（封面 \(s.artworkBytes) 字节）"
            + "，canReserve=\(PaddingReserver.canReserve(url))"
            + " → 预留填充静默跳过，不报错、不算失败")
    }
    // 同一批文件、同一张封面，两种模式下 writecost 的口径对照。
    var raw: [(url: URL, edit: TagEdit)] = []
    for url in files {
        var e = TagEdit()
        e.artworkAction = .replace([poliArtwork(bigImage, name: "writecost")])
        raw.append((url, e))
    }
    for mode in [ArtworkEmbedMode.embed, .folderFile, .both] {
        let p = ArtworkPolicy(mode: mode)
        let (applied, jobs) = p.apply(to: raw)
        let plan = TagService.estimatedWriteCost(applied, padding: padding)
        out("\(mode.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
            + " 音频侧 \(applied.count) 个文件"
            + " · 整文件重写 \(plan.fullRewriteCount) 个（\(poliMB(plan.totalRewriteBytes))）"
            + " · 顺带预留 \(plan.reserveCount) 个"
            + " · 文件夹任务 \(jobs.count) 组")
    }
}

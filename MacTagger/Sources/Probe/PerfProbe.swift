//
//  PerfProbe.swift
//  mactagger-probe — 写入代价预估实测 / 带进度的批量清除演示
//
//  两个子命令：
//    writecost  <dir> <image> [--appflow] [--keep]
//        把 <dir> 里的音频**复制**到临时工作目录，逐个写入 <image> 作封面，
//        对照 `TagService.estimatedWriteCost` 的预估与实测（耗时、写前写后大小、inode）。
//        连写三轮：① 首次写入 ② 再写同一张 ③ 换一张同尺寸的，
//        用来验证 TagLib 整文件重写后会不会把 PADDING 补足。
//        `--appflow` 额外量化 App 侧的附加开销（撤销旁存 / 写后重读）。
//
//    clearbatch <dir> [--keep]
//        同样在临时副本上：先播种标签 + 封面，再走 `BatchEngine.stripAll`，
//        逐行打印进度回调收到的内容（验证清除路径确实有进度可显示）。
//
//  安全约定：**永远在临时目录的副本上操作**，源目录零改动；结束自动删除
//  （`--keep` 时保留并打印路径）。历史库与旁存仓库也都建在临时目录里，
//  不碰用户的应用支持目录。
//

import Foundation

// MARK: - 小工具

private let kAudioExts: Set<String> = ["flac", "mp3", "m4a", "mp4", "ogg", "opus", "wav",
                                       "aiff", "ape", "wv", "tta", "dsf", "mpc", "wma"]

private func perfAudioFiles(in dir: URL) -> [URL] {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return items
        .filter { !$0.hasDirectoryPath && kAudioExts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func perfFileSize(_ url: URL) -> Int64 {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (a?[.size] as? NSNumber)?.int64Value ?? 0
}

private func perfInode(_ url: URL) -> UInt64 {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (a?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

private func perfMB(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_048_576) }

/// 秒 → 毫秒字符串
private func perfMS(_ s: Double) -> String { String(format: "%.1f", s * 1000) }

@discardableResult
private func perfTime<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t0 = DispatchTime.now()
    let v = try body()
    let dt = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000_000
    return (v, dt)
}

/// 把 `dir` 里的音频复制到一个新的临时工作目录，返回 (工作目录, 副本列表)。
private func perfStage(_ dir: URL, tag: String, count: Int? = nil) -> (URL, [URL]) {
    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-\(tag)-\(getpid())-\(Int(Date().timeIntervalSince1970))",
                                isDirectory: true)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    var copies: [URL] = []
    let sources = perfAudioFiles(in: dir)
    guard !sources.isEmpty else { return (work, []) }
    let want = count ?? sources.count
    for i in 0..<want {
        let src = sources[i % sources.count]
        let name = i < sources.count
            ? src.lastPathComponent
            : src.deletingPathExtension().lastPathComponent + "-\(i).\(src.pathExtension)"
        let dst = work.appendingPathComponent(name)
        // APFS 上 copyItem 走 clonefile，是写时复制：几乎不占时间也不占空间。
        do { try fm.copyItem(at: src, to: dst); copies.append(dst) }
        catch { out("  ! 复制失败 \(src.lastPathComponent)：\(error.localizedDescription)") }
    }
    return (work, copies)
}

private func perfCleanup(_ work: URL, keep: Bool) {
    if keep {
        out("\n工作目录已保留：\(work.path)")
    } else {
        try? FileManager.default.removeItem(at: work)
        out("\n已删除临时工作目录 \(work.path)")
    }
}

/// 生成一张「字节数完全相同、内容不同」的图片：保留前 64 字节（魔数/头），
/// 把中段 1 KB 换成随机字节。用来验证「换一张同尺寸封面」会不会再次整文件重写。
private func perfVariant(of data: Data) -> Data {
    var d = data
    guard d.count > 2048 else { return d }
    let start = d.count / 2
    for i in start..<min(start + 1024, d.count) { d[i] = UInt8.random(in: 0...255) }
    return d
}

private func perfArtwork(_ data: Data, name: String) -> Artwork {
    let isPNG = data.count > 8 && data[0] == 0x89 && data[1] == 0x50
    return Artwork(data: data,
                   mimeType: isPNG ? "image/png" : "image/jpeg",
                   caption: name,
                   type: .frontCover)
}

// MARK: - writecost

func cmdWriteCost(_ dirPath: String, _ imagePath: String, appFlow: Bool, batchCount: Int, keep: Bool) {
    let dir = URL(fileURLWithPath: dirPath)
    let imageURL = URL(fileURLWithPath: imagePath)
    guard let image = try? Data(contentsOf: imageURL) else { fail("读不到图片 \(imagePath)") }

    hr("写入代价预估 vs 实测")
    out("源目录    : \(dir.path)（只读，全部操作在副本上）")
    out("封面      : \(imageURL.lastPathComponent)  \(image.count) 字节 (\(perfMB(Int64(image.count))) MB)")
    out("并发度    : 1（逐个测量，避免互相干扰）")

    let (work, files) = perfStage(dir, tag: "writecost")
    guard !files.isEmpty else { perfCleanup(work, keep: keep); fail("目录里没有可测的音频文件") }
    out("工作目录  : \(work.path)")
    out("文件数    : \(files.count)")

    // ---------------------------------------------------------------- 三轮写入
    struct Row {
        var name: String
        var round: Int
        var predictedFullRewrite: Bool
        var slack: Int64
        var need: Int64
        var predictedBytes: Int64
        var before: Int64
        var after: Int64
        var inodeChanged: Bool
        var seconds: Double
    }
    var rows: [Row] = []

    let variant = perfVariant(of: image)
    let rounds: [(Int, Data, String)] = [
        (1, image,   "首次写入"),
        (2, image,   "再写同一张"),
        (3, variant, "换一张同尺寸的"),
    ]

    for (roundNo, payload, label) in rounds {
        out("\n--- 第 \(roundNo) 轮：\(label)（\(payload.count) 字节） ---")
        for url in files {
            var edit = TagEdit()
            edit.artworkAction = .replace([perfArtwork(payload, name: "perf-r\(roundNo)")])

            let est = TagService.estimatedWriteCost(url: url, edit: edit)
            let before = perfFileSize(url)
            let ino0 = perfInode(url)
            let (_, dt) = perfTime { try? TagService.write(edit, to: url) }
            let after = perfFileSize(url)
            let ino1 = perfInode(url)

            rows.append(Row(name: url.lastPathComponent,
                            round: roundNo,
                            predictedFullRewrite: est.fullRewrite,
                            slack: est.slackBytes,
                            need: est.needBytes,
                            predictedBytes: est.rewriteBytes,
                            before: before,
                            after: after,
                            inodeChanged: ino0 != ino1,
                            seconds: dt))
            out(String(format: "  %-18s 预估:%@ 空闲=%6lld 需要=%8lld 搬动≈%7@MB | 实测 %8@ms  %@MB→%@MB  Δ=%+lld  inode:%@",
                       (url.lastPathComponent as NSString).utf8String!,
                       est.fullRewrite ? "重写" : "原地",
                       est.slackBytes, est.needBytes, perfMB(est.rewriteBytes),
                       perfMS(dt), perfMB(before), perfMB(after),
                       after - before,
                       ino0 == ino1 ? "不变" : "变了"))
            if roundNo == 1 { out("      判据: \(est.note)") }
        }
    }

    // ---------------------------------------------------------------- 汇总表
    hr("实测表（Markdown）")
    out("| 轮次 | 文件 | 预估 | 可复用空闲(B) | 本次需要(B) | 预估搬动(MB) | 写前(MB) | 写后(MB) | 大小变化 | inode | 实测耗时(ms) | 折算(MB/s) |")
    out("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows {
        let mbps = r.seconds > 0 ? String(format: "%.0f", Double(r.after) / r.seconds / 1_048_576) : "-"
        out("| \(r.round) | \(r.name) | \(r.predictedFullRewrite ? "整文件重写" : "原地改写") | \(r.slack) | \(r.need) | \(perfMB(r.predictedBytes)) | \(perfMB(r.before)) | \(perfMB(r.after)) | \(r.after - r.before >= 0 ? "+" : "")\(r.after - r.before) | \(r.inodeChanged ? "变" : "不变") | \(perfMS(r.seconds)) | \(mbps) |")
    }

    hr("按轮次汇总")
    for roundNo in 1...3 {
        let rs = rows.filter { $0.round == roundNo }
        guard !rs.isEmpty else { continue }
        let total = rs.reduce(0.0) { $0 + $1.seconds }
        let avg = total / Double(rs.count)
        let grew = rs.filter { $0.after != $0.before }.count
        let predicted = rs.filter(\.predictedFullRewrite).count
        let bytes = rs.reduce(Int64(0)) { $0 + $1.after }
        out(String(format: "第 %d 轮：总耗时 %.2f s，均 %@ ms/首；预估整文件重写 %d/%d；实测大小变化 %d/%d；等效吞吐 %.0f MB/s",
                   roundNo, total, perfMS(avg), predicted, rs.count, grew, rs.count,
                   Double(bytes) / total / 1_048_576))
    }

    // 相关性：耗时到底跟「文件大小」还是「图片大小」走？
    hr("耗时相关性")
    let r1 = rows.filter { $0.round == 1 }
    if r1.count >= 2 {
        let sizes = r1.map { Double($0.before) }
        let times = r1.map(\.seconds)
        out(String(format: "第 1 轮：文件大小 %.1f–%.1f MB，耗时 %@–%@ ms，皮尔逊相关系数 r(文件大小, 耗时) = %.3f",
                   (sizes.min() ?? 0) / 1_048_576, (sizes.max() ?? 0) / 1_048_576,
                   perfMS(times.min() ?? 0), perfMS(times.max() ?? 0),
                   perfPearson(sizes, times)))
        out("（图片大小在同一轮里是常数，无法算相关；跨图片对照请分别跑三张图。）")
    }

    // ---------------------------------------------------------------- 端到端批量
    if batchCount > 0 { perfBatchRun(sourceDir: dir, image: image, fileCount: batchCount, keep: keep) }

    // ---------------------------------------------------------------- App 侧附加开销
    // 注意：必须用**全新副本**测。跑完上面三轮后文件里已经有一张 2 MB 封面、
    // 标签区也已扩到 2 MB，再写就是原地改写（1 ms），量不到真实场景的比例。
    if appFlow { perfAppFlowBreakdown(sourceDir: dir, image: image) }

    perfCleanup(work, keep: keep)
}

private func perfPearson(_ xs: [Double], _ ys: [Double]) -> Double {
    let n = Double(xs.count)
    guard n > 1 else { return 0 }
    let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    var num = 0.0, dx = 0.0, dy = 0.0
    for i in xs.indices {
        num += (xs[i] - mx) * (ys[i] - my)
        dx += (xs[i] - mx) * (xs[i] - mx)
        dy += (ys[i] - my) * (ys[i] - my)
    }
    return (dx > 0 && dy > 0) ? num / (dx * dy).squareRoot() : 0
}

// MARK: - App 侧附加开销拆解

/// 把 `AppModel.performSave` 那条链路上的每一段单独计时：
/// ① `recordUndoSnapshot` 里的 `TagService.readArtworks`（把旧封面读出来）
/// ② `UndoService.recordBeforeWrite`（历史表 + 旁存落盘）
/// ③ `TagService.write`（真正的 TagLib 保存）
/// ④ `afterBatch` 的 `TagService.readAll`（写后整批重读，会把新封面又解一遍）
private func perfAppFlowBreakdown(sourceDir: URL, image: Data) {
    hr("App 侧附加开销拆解（模拟 performSave 全链路）")

    // 用全新副本：文件此刻还是原始的 8 KB PADDING，写 2 MB 封面必然整文件重写 ——
    // 这才是用户「给 46 首写封面」的真实场景。
    let (work, files) = perfStage(sourceDir, tag: "appflow-src")
    defer { try? FileManager.default.removeItem(at: work) }
    guard !files.isEmpty else { out("  ! 没有可测文件"); return }
    out("  样本: \(files.count) 个全新副本（PADDING 仍是原始值），封面 \(image.count) 字节")

    // 第一遍先播种一张同样大的旧封面，模拟「覆盖已有封面」——
    // 用户的场景是给已经有图/没图的文件写新图，这里两种都量：
    // 下面的循环先记录「文件当前没有封面」的情形，旁存里没有旧图可读。

    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-appflow-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    guard let history = try? TagsHistoryStore(databaseURL: sandbox.appendingPathComponent("h.sqlite")),
          let sideCar = try? SideCarStore(root: sandbox.appendingPathComponent("sidecar")) else {
        out("  ! 临时历史库/旁存仓库建不起来，跳过")
        return
    }

    var tReadArtworks = 0.0, tRecord = 0.0, tWrite = 0.0, tReload = 0.0
    var sideCarBytes: Int64 = 0

    for url in files {
        // 界面上的 FileRow 不驻留封面二进制，旁存前要先把旧封面读回来 —— 这一步在
        // 「覆盖 2 MB 封面」的场景里 = 每首多读一张 2 MB 的图。
        var current = (try? TagService.read(url)) ?? AudioFile(url: url,
                                                               tags: Tags(),
                                                               technical: AudioTechnicalInfo(),
                                                               tagContainers: [],
                                                               isReadOnly: false,
                                                               diagnostics: [])
        current.tags.artworks = []
        let (arts, dtA) = perfTime { (try? TagService.readArtworks(url)) ?? [] }
        tReadArtworks += dtA
        current.tags.artworks = arts

        var edit = TagEdit()
        edit.artworkAction = .replace([perfArtwork(image, name: "appflow")])

        let (_, dtR) = perfTime {
            try? UndoService.recordBeforeWrite(url: url, current: current, edit: edit,
                                               history: history, sideCar: sideCar)
        }
        tRecord += dtR

        let (_, dtW) = perfTime { try? TagService.write(edit, to: url) }
        tWrite += dtW
    }

    let (_, dtL) = perfTime { _ = TagService.readAll(files) }
    tReload = dtL
    sideCarBytes = sideCar.totalBytes()

    let extra = tReadArtworks + tRecord + tReload
    let total = extra + tWrite
    out(String(format: "  ① readArtworks（旁存前把旧封面读回来） : %8.3f s  (%5.1f%%)", tReadArtworks, tReadArtworks / total * 100))
    out(String(format: "  ② recordBeforeWrite（历史表+旁存落盘） : %8.3f s  (%5.1f%%)", tRecord, tRecord / total * 100))
    out(String(format: "  ③ TagService.write（TagLib 真正保存）  : %8.3f s  (%5.1f%%)", tWrite, tWrite / total * 100))
    out(String(format: "  ④ afterBatch 的 readAll（写后整批重读） : %8.3f s  (%5.1f%%)", tReload, tReload / total * 100))
    out(String(format: "  ————————————————————————————————"))
    out(String(format: "  TagLib 保存占比 %.1f%%，我们自己的附加开销占比 %.1f%%（合计 %.3f s / %.3f s）",
               tWrite / total * 100, extra / total * 100, extra, total))
    out("  旁存仓库落盘 \(perfMB(sideCarBytes)) MB（\(files.count) 首 × 旧封面）")
}

// MARK: - clearbatch

func cmdClearBatch(_ dirPath: String, keep: Bool) {
    let dir = URL(fileURLWithPath: dirPath)
    hr("带进度的批量清除标签（BatchEngine.stripAll）")
    out("源目录 : \(dir.path)（只读，全部操作在副本上）")

    let (work, files) = perfStage(dir, tag: "clearbatch")
    guard !files.isEmpty else { perfCleanup(work, keep: keep); fail("目录里没有可测的音频文件") }
    out("工作目录: \(work.path)")

    // 播种：写点标签 + 一张小封面，保证「清除」确有内容可清。
    out("\n播种标签与封面…")
    let seed = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(seed)
    for url in files {
        var e = TagEdit()
        e.set(.title, "清除进度演示")
        e.set(.artist, "probe")
        e.set(.album, "clearbatch")
        e.artworkAction = .replace([Artwork(data: png, mimeType: "image/png",
                                            caption: "seed", type: .frontCover)])
        _ = try? TagService.write(e, to: url)
    }
    out("  已播种 \(files.count) 个文件")

    // 真正的批量清除：逐条打印进度回调收到的内容。
    out("\n开始清除（进度回调逐行打印）：")
    let started = Date()
    let sem = DispatchSemaphore(value: 0)
    var result: BatchSummary?
    Task {
        let s = await BatchEngine.stripAll(files,
                                           concurrency: BatchEngine.recommendedConcurrency(for: files)) { p in
            var line = String(format: "  [进度] 清除标签… %d/%d", p.completed, p.total)
            if let path = p.currentPath { line += " · " + (path as NSString).lastPathComponent }
            if p.bytesTotal > 0 {
                line += String(format: " · %@/%@ MB", perfMB(p.bytesDone), perfMB(p.bytesTotal))
                if let t = p.throughputText { line += " · " + t }
                if let e = p.etaText { line += " · " + e }
            }
            if let n = p.note { line += " · " + n }
            out(line)
        }
        result = s
        sem.signal()
    }
    sem.wait()
    let elapsed = Date().timeIntervalSince(started)

    out("\n结果: \(result?.description ?? "-")  耗时 \(String(format: "%.2f", elapsed)) s")
    // 复核：标签真被清了吗？
    var leftovers = 0
    for url in files {
        if let f = try? TagService.read(url) {
            let t = f.tags
            if t.title != nil || t.artist != nil || t.album != nil { leftovers += 1 }
        }
        if let a = try? TagService.readArtworks(url), !a.isEmpty { leftovers += 1 }
    }
    out("复核: \(leftovers == 0 ? "全部清空 ✔" : "还有 \(leftovers) 处残留 ✘")")

    perfCleanup(work, keep: keep)
}

// MARK: - 端到端批量写入（验证 MB/s 与剩余时间）

/// 按用户的真实场景跑一遍：N 个文件、一张封面、走 `BatchEngine.applyEdits`，
/// 打印进度回调里的 MB/s 与剩余时间，最后拿实测跟 `estimatedWriteCost` 的预估对账。
func perfBatchRun(sourceDir: URL, image: Data, fileCount: Int, keep: Bool) {
    hr("端到端批量写入（BatchEngine.applyEdits）")
    let (work, files) = perfStage(sourceDir, tag: "batchrun", count: fileCount)
    guard !files.isEmpty else { perfCleanup(work, keep: keep); return }

    let payload: [(url: URL, edit: TagEdit)] = files.map { url in
        var e = TagEdit()
        e.set(.title, "批量封面写入测试")
        e.artworkAction = .replace([perfArtwork(image, name: "batch")])
        return (url, e)
    }

    let plan = TagService.estimatedWriteCost(payload)
    out("文件数        : \(files.count)")
    out("封面          : \(image.count) 字节")
    out("并发度        : \(BatchEngine.recommendedConcurrency(for: files))（内置卷 4 / 可移动卷 1）")
    out("预估整文件重写: \(plan.fullRewriteCount)/\(files.count)")
    out("预估搬动字节  : \(TagService.humanBytes(plan.totalRewriteBytes))")
    out("预估耗时      : \(TagService.humanDuration(plan.estimatedSeconds))"
        + String(format: "（按 %.0f MB/s 折算）", BatchEngine.rewriteThroughput(for: files) / 1_048_576))
    out("确认框文案    : \(plan.warningText ?? "（无整文件重写，不提示）")")

    out("\n进度回调逐行打印：")
    let started = Date()
    let sem = DispatchSemaphore(value: 0)
    var summary: BatchSummary?
    Task {
        let s = await BatchEngine.applyEdits(payload,
                                             concurrency: BatchEngine.recommendedConcurrency(for: files)) { p in
            var line = String(format: "  [进度] 保存标签… %d/%d", p.completed, p.total)
            if let path = p.currentPath { line += " · " + (path as NSString).lastPathComponent }
            if p.bytesTotal > 0 {
                line += String(format: " · %@/%@ MB", perfMB(p.bytesDone), perfMB(p.bytesTotal))
                if let t = p.throughputText { line += " · " + t }
                if let e = p.etaText { line += " · " + e }
            }
            if let n = p.note { line += " · " + n }
            out(line)
        }
        summary = s
        sem.signal()
    }
    sem.wait()
    let elapsed = Date().timeIntervalSince(started)

    out("\n结果          : \(summary?.description ?? "-")")
    out(String(format: "实测总耗时    : %.2f s（预估 %.2f s，偏差 %+.0f%%）",
               elapsed, plan.estimatedSeconds,
               plan.estimatedSeconds > 0 ? (elapsed / plan.estimatedSeconds - 1) * 100 : 0))
    out(String(format: "实测有效吞吐  : %.0f MB/s", Double(plan.totalRewriteBytes) / elapsed / 1_048_576))
    out(String(format: "校准后吞吐    : %.0f MB/s（下次预估会用这个）",
               BatchEngine.rewriteThroughput(for: files) / 1_048_576))
    perfCleanup(work, keep: keep)
}

// MARK: - padding：TagLib 重写后到底留下多少填充

/// 量「TagLib 整文件重写之后，标签区里还剩多少可原地复用的空闲字节」。
///
/// 这个数字决定了下一次写封面还用不用整文件重写，也是「要不要主动预留填充」这个
/// 产品决策的依据。做法：用 `estimatedWriteCost` 传空编辑集（payload = 0、不回收封面），
/// 返回的 `slackBytes` 就是纯空闲（FLAC 的 PADDING / ID3v2 的空隙 / MP4 的 free），
/// **不含**当前封面占的位置。
func cmdPadding(_ dirPath: String, _ imagePath: String, keep: Bool) {
    let dir = URL(fileURLWithPath: dirPath)
    guard let image = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
        fail("读不到图片 \(imagePath)")
    }

    hr("TagLib 重写后留下的填充实测")
    out("封面: \(image.count) 字节")

    let (work, files) = perfStage(dir, tag: "padding")
    guard !files.isEmpty else { perfCleanup(work, keep: keep); fail("目录里没有可测的音频文件") }

    /// 纯空闲字节：空编辑集 → payload 0、不回收封面。
    func freeBytes(_ url: URL) -> (Int64, String) {
        let e = TagService.estimatedWriteCost(url: url, edit: TagEdit())
        return (e.slackBytes, e.note)
    }

    out("\n| 文件 | 容器 | 初始空闲(B) | 写 1 次后空闲(B) | 写 2 次后空闲(B) | 文件大小变化 |")
    out("|---|---|---|---|---|---|")
    for url in files {
        let (f0, note0) = freeBytes(url)
        let s0 = perfFileSize(url)

        var edit = TagEdit()
        edit.artworkAction = .replace([perfArtwork(image, name: "padding")])
        _ = try? TagService.write(edit, to: url)
        let (f1, note1) = freeBytes(url)
        let s1 = perfFileSize(url)

        _ = try? TagService.write(edit, to: url)
        let (f2, note2) = freeBytes(url)
        let s2 = perfFileSize(url)

        let est = TagService.estimatedWriteCost(url: url, edit: edit)
        out("| \(url.lastPathComponent) | \(est.container) | \(f0) | \(f1) | \(f2) | \(s0) → \(s1) → \(s2) |")
        out("|   ↳ 判据 | | \(note0) | \(note1) | \(note2) | |")
    }
    perfCleanup(work, keep: keep)
}

// MARK: - mainthread-clear：主线程停顿实测（清除 / 保存两条路径的「记录撤消数据」阶段）
//
// 要证明的事：`AppModel` 的清除与保存路径在真正写文件之前，都要先逐条记一份撤销快照
// （读旧封面 + 写历史表 + 写旁存）。这段原来跑在 @MainActor 的 `Task {}` 里，
// 磁盘 IO 直接压在主线程上；循环里的 `Task.yield()` 只是把续体重新排进**主队列**，
// CFRunLoop 的主队列排空又是「一次排到空」，于是整段快照期间 runloop 一次都轮不到 ——
// 定时器不响、辅助功能查询挂起、进度浮层拿不到任何中间值。
//
// 量法：在主线程上挂一个 50 ms 的心跳 Timer，记录相邻两次触发之间的最大间隔。
// 主线程被占住多久，最大间隔就是多少。
//
//   mainthread-clear <dir> [--legacy] [--save] [--count N] [--cover-mb N] [--block MS] [--keep]
//
//     默认       = 修复后的写法：每条快照的磁盘部分甩进 `Task.detached`，主线程只留进度上报
//     --legacy   = 修复前的写法：快照在 @MainActor 上同步跑，中间 `Task.yield()`
//     --save     = 走保存路径（快照 + `BatchEngine.applyEdits` 写新封面），默认走清除路径
//
// 与 App 的关系：probe 目标看不见 `Sources/App`，所以这里按 `AppModel.writeUndoSnapshot`
// 的实现逐句复刻了同一段 IO（读旧封面 → `UndoService.recordBeforeWrite`），
// 调度方式（detached vs 主线程同步）也与两条路径改动前后完全一致。

/// 主线程心跳：记录相邻两次触发的最大间隔 = 主线程被占住的最长时间。
private final class PerfHeartbeat {
    private var timer: Timer?
    private var last = Date()
    private(set) var maxGap: Double = 0
    private(set) var ticks: Int = 0
    /// 超过这个门限的停顿单独记下来，方便看是「一次大停顿」还是「一路都卡」。
    private(set) var stalls: [Double] = []
    let interval: Double

    init(interval: Double = 0.05) { self.interval = interval }

    func start() {
        last = Date()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.last)
            self.last = now
            self.ticks += 1
            if gap > self.maxGap { self.maxGap = gap }
            if gap > self.interval * 2 { self.stalls.append(gap) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

/// 一个可在主线程上翻的完成标志（probe 全程单线程 runloop，够用）。
private final class PerfDoneFlag { var value = false }

/// `AppModel.writeUndoSnapshot` 的逐句复刻（probe 看不见 App 目标）。
private func perfSnapshotIO(file: AudioFile,
                            edit: TagEdit,
                            history: TagsHistoryStore,
                            sideCar: SideCarStore) -> Bool {
    do {
        // FileRow 不驻留封面二进制，本次真会动封面时先从磁盘把旧封面读回来。
        var current = file
        current.tags.artworks = []
        var keeps = false
        if case .keep = edit.artworkAction { keeps = true }
        if !keeps { current.tags.artworks = (try? TagService.readArtworks(file.url)) ?? [] }
        _ = try UndoService.recordBeforeWrite(url: file.url, current: current, edit: edit,
                                              history: history, sideCar: sideCar)
        return true
    } catch {
        return false
    }
}

/// 生成一张指定大小的假 PNG（8 字节魔数 + 随机字节）。只用来占字节数，不需要能解码。
private func perfBigCover(megabytes: Int) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let n = max(0, megabytes * 1_048_576 - d.count)
    var chunk = Data(count: 65_536)
    chunk.withUnsafeMutableBytes { raw in
        guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for i in 0..<raw.count { p[i] = UInt8.random(in: 0...255) }
    }
    while d.count < n { d.append(chunk.prefix(min(chunk.count, n - d.count))) }
    return d
}

func cmdMainThreadClear(_ dirPath: String, args: [String]) {
    let legacy   = args.contains("--legacy")
    let saveMode = args.contains("--save")
    let keep     = args.contains("--keep")
    let count    = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 12
    let coverMB  = args.firstIndex(of: "--cover-mb").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 15
    // 阳性对照：在 @MainActor 上故意睡 N 毫秒。心跳如果读不出这一下，说明心跳本身
    // 是坏的、「最大停顿 57 ms」这个结论也就不成立。跑真实测量前先跑一次这个。
    let blockMS  = args.firstIndex(of: "--block").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0

    hr("主线程停顿实测：\(saveMode ? "保存" : "清除")路径的「记录撤消数据」阶段")
    out("调度方式  : \(legacy ? "修复前（@MainActor 上同步跑快照 + Task.yield）" : "修复后（Task.detached 甩到后台线程）")")
    out("源目录    : \(dirPath)（只读，全部操作在副本上）")

    let dir = URL(fileURLWithPath: dirPath)
    let fm = FileManager.default
    // 只挑三种「封面写得进、且我们做过结构解析」的容器，保证每个副本都真带一张大图。
    let prefer: Set<String> = ["flac", "mp3", "m4a"]
    var sources = perfAudioFiles(in: dir).filter { prefer.contains($0.pathExtension.lowercased()) }
    if sources.isEmpty { sources = perfAudioFiles(in: dir) }
    guard !sources.isEmpty else { fail("目录里没有可测的音频文件") }

    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-mtclear-\(getpid())-\(Int(Date().timeIntervalSince1970))",
                                isDirectory: true)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    var files: [URL] = []
    for i in 0..<count {
        let src = sources[i % sources.count]
        let dst = work.appendingPathComponent(
            src.deletingPathExtension().lastPathComponent + "-\(i).\(src.pathExtension)")
        do { try fm.copyItem(at: src, to: dst); files.append(dst) }
        catch { out("  ! 复制失败 \(src.lastPathComponent)：\(error.localizedDescription)") }
    }
    guard !files.isEmpty else { perfCleanup(work, keep: keep); fail("一个副本都没建起来") }
    out("工作目录  : \(work.path)")
    out("文件数    : \(files.count)")

    // ---- 播种：每个副本嵌一张 coverMB 大的封面（快照阶段就得把它们一张张读回来）
    let cover = perfBigCover(megabytes: coverMB)
    out("播种封面  : \(perfMB(Int64(cover.count))) MB/首，合计 \(perfMB(Int64(cover.count) * Int64(files.count))) MB")
    let (_, seedSec) = perfTime { () -> Void in
        for url in files {
            var e = TagEdit()
            e.set(.title, "主线程停顿实测")
            e.set(.artist, "probe")
            e.artworkAction = .replace([perfArtwork(cover, name: "seed")])
            _ = try? TagService.write(e, to: url)
        }
    }
    out(String(format: "播种耗时  : %.2f s", seedSec))

    // ---- 临时历史库 / 旁存仓库（绝不碰用户的应用支持目录）
    let sandbox = work.appendingPathComponent("undo", isDirectory: true)
    try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    guard let history = try? TagsHistoryStore(databaseURL: sandbox.appendingPathComponent("h.sqlite")),
          let sideCar = try? SideCarStore(root: sandbox.appendingPathComponent("sidecar")) else {
        perfCleanup(work, keep: keep); fail("临时历史库/旁存仓库建不起来")
    }

    // ---- 本次要记的编辑集：清除 = 全字段删除 + 移除全部封面；保存 = 换一张新封面
    var edit = TagEdit()
    if saveMode {
        edit.set(.title, "保存路径实测")
        edit.artworkAction = .replace([perfArtwork(perfVariant(of: cover), name: "new")])
    } else {
        for f in TagEdit.Field.allCases { edit.remove(f) }
        edit.artworkAction = .removeAll
    }
    let payload: [(url: URL, edit: TagEdit)] = files.map { ($0, edit) }

    // 界面上的 FileRow：封面二进制不驻留内存。
    let rows: [AudioFile] = files.map { url in
        var f = (try? TagService.read(url)) ?? AudioFile(url: url, tags: Tags(),
                                                        technical: AudioTechnicalInfo(),
                                                        tagContainers: [], isReadOnly: false,
                                                        diagnostics: [])
        f.tags.artworks = []
        return f
    }

    // ---- 跑起来：主线程只挂心跳，工作全在 @MainActor 的 Task 里（与 App 一致）
    out("\n开始（主线程 50 ms 心跳计时器已启动，进度回调逐行打印，时间戳 = 距开始毫秒）：")
    let beat = PerfHeartbeat(interval: 0.05)
    let done = PerfDoneFlag()
    let t0 = Date()
    func stamp() -> String { String(format: "%7.0fms", Date().timeIntervalSince(t0) * 1000) }

    var notes: [String] = []
    var failures = 0
    var summaryText = "-"
    var phase1Sec = 0.0
    var phase2Sec = 0.0

    beat.start()

    Task { @MainActor in
        // ⓪ 阳性对照（--block N）：在主线程上实打实堵 N 毫秒，验证心跳读得出停顿。
        if blockMS > 0 {
            out("  [\(stamp())] [阳性对照] 主线程 Thread.sleep \(blockMS) ms…")
            Thread.sleep(forTimeInterval: Double(blockMS) / 1000)
            out("  [\(stamp())] [阳性对照] 醒了")
        }

        // ① 记录撤消数据
        let p1 = Date()
        for (i, f) in rows.enumerated() {
            let ok: Bool
            if legacy {
                // 修复前：磁盘 IO 就在主线程上，靠 Task.yield 假装「让出」。
                ok = perfSnapshotIO(file: f, edit: edit, history: history, sideCar: sideCar)
            } else {
                // 修复后：IO 甩到后台，主线程在这里挂起等结果。
                ok = await Task.detached(priority: .userInitiated) {
                    perfSnapshotIO(file: f, edit: edit, history: history, sideCar: sideCar)
                }.value
            }
            if !ok { failures += 1 }
            let note = "记录撤消数据 \(i + 1)/\(rows.count)"
            notes.append(note)
            out("  [\(stamp())] [进度] \(note) · \(f.url.lastPathComponent)")
            await Task.yield()
        }
        phase1Sec = Date().timeIntervalSince(p1)

        // ② 真正落盘
        let p2 = Date()
        let summary: BatchSummary
        if saveMode {
            summary = await BatchEngine.applyEdits(
                payload, concurrency: BatchEngine.recommendedConcurrency(for: files)) { p in
                let note = "\(saveModeLabel(true)) \(p.completed)/\(p.total)"
                Task { @MainActor in
                    notes.append(note)
                    out("  [\(stamp())] [进度] \(note)"
                        + (p.currentPath.map { " · " + ($0 as NSString).lastPathComponent } ?? ""))
                }
            }
        } else {
            summary = await BatchEngine.stripAll(
                files, concurrency: BatchEngine.recommendedConcurrency(for: files)) { p in
                let note = "\(saveModeLabel(false)) \(p.completed)/\(p.total)"
                Task { @MainActor in
                    notes.append(note)
                    out("  [\(stamp())] [进度] \(note)"
                        + (p.currentPath.map { " · " + ($0 as NSString).lastPathComponent } ?? ""))
                }
            }
        }
        phase2Sec = Date().timeIntervalSince(p2)
        summaryText = summary.description
        done.value = true
    }

    // 主线程在这里空转 runloop：心跳定时器与主队列（@MainActor）都靠它派发。
    // 主线程一旦被占住，定时器就打不响 —— 这正是我们要量的东西。
    let deadline = Date().addingTimeInterval(900)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    beat.stop()
    let elapsed = Date().timeIntervalSince(t0)

    // ---- 结论
    hr("结果")
    out("调度方式          : \(legacy ? "修复前（主线程同步快照）" : "修复后（后台线程快照）")")
    out(String(format: "① 记录撤消数据阶段: %.2f s", phase1Sec))
    out(String(format: "② 落盘阶段        : %.2f s", phase2Sec))
    out(String(format: "总耗时            : %.2f s", elapsed))
    out("批处理结果        : \(summaryText)（历史记录失败 \(failures) 条）")
    out(String(format: "心跳              : 间隔 %.0f ms，共触发 %d 次（理想约 %d 次）",
               beat.interval * 1000, beat.ticks, Int(elapsed / beat.interval)))
    out(String(format: "**主线程最大停顿  : %.0f ms**", beat.maxGap * 1000))
    out("超过 100 ms 的停顿: \(beat.stalls.filter { $0 > 0.1 }.count) 次"
        + (beat.stalls.isEmpty ? "" : "，最大 " + String(format: "%.0f ms", (beat.stalls.max() ?? 0) * 1000)))
    out("判定              : " + (beat.maxGap < 0.1 ? "< 100 ms ✔ 主线程未被磁盘 IO 占用"
                                                    : "≥ 100 ms ✘ 主线程被占用"))
    out("\n进度回调命中的中间值序列（共 \(notes.count) 条）：")
    out("  " + notes.joined(separator: " → "))

    history.close()
    perfCleanup(work, keep: keep)
}

private func saveModeLabel(_ save: Bool) -> String { save ? "保存标签…" : "清除标签…" }

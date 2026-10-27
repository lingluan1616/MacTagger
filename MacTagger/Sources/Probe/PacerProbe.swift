//
//  PacerProbe.swift
//  mactagger-probe — 可移动存储写入优化验证
//
//  用法：
//    mactagger-probe volume <path>              打印该路径所在卷的 removable/ejectable/internal 判定
//    mactagger-probe pacer <dir> [--simulate-slow] [--mixed] [--seq] [--no-pacer]
//        对目录内文件的**副本**反复写标签，打印每次写入的形态 / 字节 / 耗时 / 指标 / EMA / 是否触发暂停。
//
//        --simulate-slow 在指定窗口内人为 usleep 拉低速度，
//                        验证「降速 → 暂停 2s → 4s → 8s → 恢复 → 退避重置」这条状态机。
//        --mixed         用**真实混合语料**（六种格式各 3 份副本，dsf 1.4MB ↔ ogg 13KB，跨度 ~108 倍）
//                        跑一遍，证明两类独立判定下不再出现「5000 倍吞吐差」式的误判。
//                        混合模式**不预热**，于是第一轮全是整文件重写（吞吐类），
//                        第二轮起全是原地改写（耗时类），一条日志同时练到两类跟踪器。
//        --seq           顺序语料：先 8 份 dsf 再 8 份 wav（零注入），
//                        分桶 / 不分桶各跑一遍做对照，验证按格式分桶消除跨格式误判。
//        --no-pacer      把用户总开关 BatchEngine.adaptivePacingEnabled 关掉，
//                        验证关闭态下同样的降速曲线**一次都不暂停**。
//    mactagger-probe pacer --scenarios [--legacy]
//        三场景**合成时序**对照（不碰文件系统、不碰 UserDefaults，虚拟时钟秒级跑完）：
//        ① 缓存后持续低速  ② 真·热降速  ③ 开关关闭。
//        --legacy 走旧策略路径（×2 增长、封顶 20 s、无有效性判定/预算/基线收敛），出改前数字。
//
//  源语料零改动：全部在临时目录的副本上做，跑完自动删除。
//

import Foundation

// MARK: - volume 子命令

func cmdVolume(_ path: String) {
    hr("卷属性判定 volume")

    let url = URL(fileURLWithPath: path)
    out("查询路径: \(url.standardizedFileURL.path)")
    out("存在    : \(FileManager.default.fileExists(atPath: url.path) ? "是" : "否（会向上找最近的存在祖先目录）")")
    out()

    let t = VolumeInfo.traits(of: url)
    out("卷名                    : \(t.name ?? "（取不到）")")
    out("卷根路径                : \(t.volumePath ?? "（取不到）")")
    func f(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "nil（该卷不提供）" }
    out("volumeIsRemovable       : \(f(t.isRemovable))")
    out("volumeIsEjectable       : \(f(t.isEjectable))")
    out("volumeIsInternal        : \(f(t.isInternal))")
    out("volumeIsLocal           : \(f(t.isLocal))")
    out()
    out("→ isSlowMedia（可移动/外置/网络）: \(t.isSlowMedia ? "是" : "否")")
    out("→ BatchEngine.recommendedConcurrency: \(BatchEngine.recommendedConcurrency(for: [url]))"
        + "（内置盘 \(BatchEngine.defaultConcurrency) / 可移动 \(BatchEngine.removableConcurrency)）")

    hr("本机已挂载卷一览（/Volumes）")
    let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
    if vols.isEmpty { out("/Volumes 下没有条目") }
    for v in vols.sorted() {
        let vu = URL(fileURLWithPath: "/Volumes").appendingPathComponent(v)
        out("  \(pad(v, 24)) \(VolumeInfo.traits(of: vu).summary)")
    }
    out("  \(pad("/（启动卷）", 24)) \(VolumeInfo.traits(of: URL(fileURLWithPath: "/")).summary)")
}

// MARK: - pacer 参数

/// 模拟降速时每次写入额外注入的耗时（微秒）。
private let kInjectedSlowUS: UInt32 = 20_000

/// 受控模式（等大副本）：总写入次数与注入窗口。
private let kCtrlTotal = 22, kCtrlSlowFrom = 8, kCtrlSlowTo = 16
/// 混合模式（六格式各 3 份）：
/// - 先预热一轮（不采样），把标签区填充建起来 + 把页缓存捂热，
///   否则「第一次碰这个文件」的冷启动开销（实测 2~3 倍）会被误当成介质变慢；
/// - 第 1–36 次写**大注释**撑大标签区 → 强制整文件重写，**不注入延迟**，
///   用来证明 dsf(1.4MB) ↔ ogg(13KB) 这 102 倍体量跨度下**不会误判**；
/// - 第 37 次起改写小字段 → 原地改写，第 45–53 次注入延迟跑状态机。
private let kMixedTotal = 60
private let kMixedBulkUntil = 36
private let kMixedSlowFrom = 45, kMixedSlowTo = 53
/// 混合语料取这六种格式（必须含最大的 dsf 与最小的 ogg，跨度最大）。
private let kMixedFormats = ["dsf", "wav", "wv", "flac", "mp3", "ogg"]
private let kMixedCopies = 3

/// 一条写入样本，供事后做「新旧口径对比」。
private struct PacerSample {
    var index: Int
    var name: String
    var kind: WritePacer.WriteKind
    var bytes: Int
    var duration: TimeInterval
    var injected: Bool
    /// 旧口径：不分形态，一律 字节/耗时。
    var legacyThroughput: Double { duration > 0 ? Double(bytes) / duration : 0 }
}

// MARK: - pacer 子命令

func cmdPacer(_ dir: String, simulateSlow: Bool, mixed: Bool, sequential: Bool, disablePacer: Bool) {
    // `pacer --scenarios [--legacy]`：三场景合成对照，**不碰文件系统、不碰 UserDefaults**。
    // 参数直接从 CommandLine 读 —— 这样不用动 main.swift 的分发表（args[1] 会被当成 dir 传进来）。
    if dir == "--scenarios" || CommandLine.arguments.contains("--scenarios") {
        cmdPacerScenarios(legacy: CommandLine.arguments.contains("--legacy"))
        return
    }

    hr("写入节流器 WritePacer 实测"
       + (mixed ? "（--mixed 真实混合语料）" : "（受控等大副本）")
       + (simulateSlow ? "（--simulate-slow 模拟降速）" : "")
       + (disablePacer ? "（--no-pacer 总开关关闭）" : ""))

    // 用户总开关：probe 进程内改，跑完恢复
    let savedSwitch = BatchEngine.adaptivePacingEnabled
    BatchEngine.adaptivePacingEnabled = !disablePacer
    defer { BatchEngine.adaptivePacingEnabled = savedSwitch }
    out("用户总开关 \(BatchEngine.adaptivePacingDefaultsKey) = \(BatchEngine.adaptivePacingEnabled)"
        + (disablePacer ? "  ← 已关闭，应当一次都不暂停" : "  （缺省即 true）"))

    if sequential { cmdPacerSequential(dir); return }

    let fm = FileManager.default
    let src = URL(fileURLWithPath: dir)
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-pacer-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        for u in (try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
        where !u.hasDirectoryPath && TagService.isSupported(url: u) {
            try? fm.copyItem(at: u, to: work.appendingPathComponent(u.lastPathComponent))
        }
    } catch { fail("准备工作副本失败：\(error.localizedDescription)") }
    defer { try? fm.removeItem(at: work) }

    var targets = ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
        .filter { !$0.hasDirectoryPath }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !targets.isEmpty else { fail("目录里没有 TagLib 支持的音频文件：\(dir)") }

    out("源目录    : \(src.standardizedFileURL.path)（只读，零改动）")
    out("工作副本  : \(work.path)（跑完自动删除）")
    out("参与文件  : \(targets.count) 个 — \(targets.map(\.lastPathComponent).joined(separator: ", "))")
    out()
    out("源目录卷  : \(VolumeInfo.traits(of: src).summary)")
    out("副本卷    : \(VolumeInfo.traits(of: work).summary)")
    let srcURLs = targets.map { src.appendingPathComponent($0.lastPathComponent) }
    out("源目录推荐并发度 : \(BatchEngine.recommendedConcurrency(for: srcURLs))"
        + "  · 节流器自动开关 = \(WritePacer.Config.automatic(for: srcURLs).enabled ? "启用" : "关闭")")
    out("副本推荐并发度   : \(BatchEngine.recommendedConcurrency(for: targets))"
        + "  · 节流器自动开关 = \(WritePacer.Config.automatic(for: targets).enabled ? "启用" : "关闭")")

    // ---------- 组装状态机语料 ----------
    let sequence: [URL]
    let total: Int, slowFrom: Int, slowTo: Int

    if mixed {
        // 六种格式各 3 份副本，**不预热** —— 第 1 轮全是整文件重写（吞吐类），
        // 第 2 轮起全是原地改写（耗时类），一条日志同时练到两类跟踪器。
        var corpus: [URL] = []
        for ext in kMixedFormats {
            guard let seed = targets.first(where: { $0.pathExtension.lowercased() == ext }) else {
                out("⚠︎ 语料里没有 .\(ext)，跳过"); continue
            }
            for i in 1...kMixedCopies {
                let dst = work.appendingPathComponent(String(format: "mix-%@-%d.%@", ext, i, ext))
                try? fm.removeItem(at: dst)
                if (try? fm.copyItem(at: seed, to: dst)) != nil { corpus.append(dst) }
            }
        }
        guard corpus.count >= 6 else { fail("混合语料准备失败") }
        sequence = corpus
        total = kMixedTotal; slowFrom = kMixedSlowFrom; slowTo = kMixedSlowTo

        // 预热：建立标签区填充 + 捂热页缓存（不采样）。
        // 不预热的话每个文件的第一次写都带冷启动开销（实测 2~3 倍），会污染基线。
        for (i, u) in corpus.enumerated() {
            var e = TagEdit(); e.set(.title, "预热-\(i)"); e.set(.artist, "pacer")
            _ = try? TagService.write(e, to: u)
        }

        hr("混合语料（已预热；第 1–\(kMixedBulkUntil) 次撑大标签区强制整文件重写，之后转原地改写）")
        out("  \(pad("文件", 22)) 字节")
        for u in corpus where u.lastPathComponent.hasSuffix("-1." + u.pathExtension) {
            out("  \(pad(u.lastPathComponent, 22)) \(BatchEngine.fileSizeInBytes(u))")
        }
        let sizes = corpus.map { BatchEngine.fileSizeInBytes($0) }
        out(String(format: "  体积跨度: %d ~ %d 字节 = %.0f 倍",
                   sizes.min() ?? 0, sizes.max() ?? 0,
                   Double(sizes.max() ?? 1) / Double(max(1, sizes.min() ?? 1))))
    } else {
        // 受控模式：先预热（把标签区填充建起来），再用同一文件的 8 份**等大副本**跑状态机。
        hr("预热（不采样）：给每个副本先写一次标签，建立标签区填充")
        for (i, u) in targets.enumerated() {
            let before = BatchEngine.fileSizeInBytes(u)
            var e = TagEdit(); e.set(.title, "预热-\(i)"); e.set(.artist, "pacer"); e.set(.album, "预热专辑")
            let t0 = Date()
            let ok = (try? TagService.write(e, to: u)) != nil
            let ms = Date().timeIntervalSince(t0) * 1000
            let after = BatchEngine.fileSizeInBytes(u)
            out(String(format: "  %@ %@ %d → %d 字节 (Δ%d)  %.2f ms",
                       pad(u.lastPathComponent, 20), ok ? "✔" : "✘", before, after, after - before, ms))
        }

        let seed = targets.max(by: { BatchEngine.fileSizeInBytes($0) < BatchEngine.fileSizeInBytes($1) })!
        let ext = seed.pathExtension
        var clones: [URL] = []
        for i in 1...8 {
            let dst = work.appendingPathComponent(String(format: "pacer-%02d.%@", i, ext))
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: seed, to: dst)) != nil { clones.append(dst) }
        }
        guard !clones.isEmpty else { fail("等大副本准备失败") }
        for (i, u) in clones.enumerated() {
            var e = TagEdit(); e.set(.title, "克隆预热-\(i)"); _ = try? TagService.write(e, to: u)
        }
        out()
        out("状态机受控样本: \(clones.count) 份 \(seed.lastPathComponent) 的等大副本，"
            + "每份 \(BatchEngine.fileSizeInBytes(clones[0])) 字节（字节恒定 → 判据只反映耗时）")
        sequence = clones
        total = kCtrlTotal; slowFrom = kCtrlSlowFrom; slowTo = kCtrlSlowTo
    }

    // ---------- 手工驱动状态机 ----------
    hr("逐次写入 + WritePacer 两类独立判定")
    out("原地改写（大小不变）按**耗时**判: 前 5 次中位数定基线，EMA 耗时 > 基线 × 3.0 且最新样本也慢 → 降速")
    out("整文件重写（大小变化）按**吞吐**判: 前 5 次中位数定基线，EMA 吞吐 < 基线 × 0.35 且最新样本也慢 → 降速")
    out("判定降速要求：该类**连续 3 笔**越阈 + EMA 也越阈（缺一不可）")
    out("两类各自维护基线/EMA，互不污染；暂停与指数退避共用一套：2s 起每次 ×1.5、上限 8s，"
        + "某类连续 10 次正常即重置退避（3 次正常清掉界面提示）")
    out("暂停后还要**结账**：暂停前 3 笔均值 vs 暂停后 3 笔均值，提升 < 1.5× 即判「这就是卡的持续速度」，"
        + "放宽基线 + 进冷却期不再等；累计暂停另有「≤ 写入墙钟 25%」的总预算")
    out("体量门槛: 整文件重写但体量 < 256 KB 时，传输时间被固定开销淹没 → 改按耗时判")
    if mixed {
        out("分段: 第 1–\(kMixedBulkUntil) 次撑大标签区（整文件重写，**不注入延迟**，用于验证无误判）；"
            + "第 \(kMixedBulkUntil + 1) 次起原地改写")
    }
    if simulateSlow {
        out("模拟: 第 \(slowFrom)–\(slowTo) 次写入额外注入 \(kInjectedSlowUS / 1000) ms 延迟")
    }
    out()
    out("  #  文件                 形态  字节      耗时      本次指标    EMA         基线        阈值        连慢 状态")

    let notes = NoteRecorder()
    let samples = SampleRecorder()

    runAsync { () async -> Void in
        let pacer = WritePacer(config: WritePacer.Config.always.gated()) { text in notes.add(text) }

        for i in 1...total {
            let u = sequence[(i - 1) % sequence.count]

            // ① 节流：真正 await 暂停的地方
            let waitStart = Date()
            await pacer.waitIfThrottled()
            let waited = Date().timeIntervalSince(waitStart)
            if waited > 0.05 {
                out(String(format: "     ⏸  触发暂停，实际睡了 %.2f 秒 —— %@",
                           waited, notes.lastPauseText ?? ""))
                out(String(format: "     ▶  %@", notes.lastResumeText ?? "已恢复写入"))
            }

            // ② 写入并计时（模拟降速的 usleep 计入耗时内）
            let sizeBefore = BatchEngine.fileSizeInBytes(u)
            var e = TagEdit()
            if mixed && i <= kMixedBulkUntil {
                // 写一段越来越长的注释，逼标签区扩容 → 整文件重写
                e.set(.comment, String(repeating: "填充", count: 5_000 + i * 200))
                e.set(.title, "膨胀-\(i)")
            } else {
                e.set(.title, "节流测试-\(i)-\(Int(Date().timeIntervalSince1970))")
            }
            let inject = simulateSlow && i >= slowFrom && i <= slowTo
            let t0 = DispatchTime.now()
            let ok = (try? TagService.write(e, to: u)) != nil
            if inject { usleep(kInjectedSlowUS) }
            let dt = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000_000
            let sizeAfter = BatchEngine.fileSizeInBytes(u)

            // ③ 采样：形态由「写入前后大小是否相同」决定，节流器内部判
            var outcome: WritePacer.SampleOutcome? = nil
            if ok {
                outcome = await pacer.record(bytesBefore: sizeBefore, bytesAfter: sizeAfter,
                                             duration: dt, format: u.pathExtension.lowercased())
            }
            let st = await pacer.stats()
            let k = outcome?.kind ?? .fullRewrite
            let ts = outcome?.stats ?? st.fullRewrite
            samples.add(PacerSample(index: i, name: u.lastPathComponent, kind: k,
                                    bytes: max(sizeBefore, sizeAfter), duration: dt, injected: inject))

            func m(_ v: Double?) -> String {
                guard let v, v.isFinite else { return "—" }
                return String(format: k == .inPlace ? "%.2fms" : "%.0fMB/s", k.display(v))
            }
            let phase: String
            if ts.baseline == nil {
                phase = "建立基线(\(ts.totalSamples)/5)"
            } else if st.isThrottled {
                phase = "⚠︎ \(st.throttleSource?.label ?? "")"
                      + (st.throttleBucket.map { "[\($0)]" } ?? "")
                      + "判定降速，下次写入前暂停 \(Int(st.nextPause))s"
            } else if ts.normalStreak >= 3 && st.consecutiveSlowdowns == 0 && st.pauseCount > 0 {
                phase = "正常（退避已重置）"
            } else {
                phase = "正常"
            }

            out(String(format: "  %2d %@ %@ %8d %8.2fms %11@ %11@ %11@ %11@  %d   %@",
                       i, pad(u.lastPathComponent, 20),
                       k == .inPlace ? "原地" : "重写",
                       max(sizeBefore, sizeAfter), dt * 1000,
                       m(ts.last) as NSString, m(ts.ema) as NSString,
                       m(ts.baseline) as NSString, m(ts.threshold) as NSString,
                       ts.consecutiveSlow, phase))
        }

        let final = await pacer.stats()
        out()
        out("两类跟踪器最终状态（耗时类按格式分桶）：")
        for b in final.sortedLatencyBuckets { out("  " + b.summary) }
        out("  " + final.fullRewrite.summary)
        out("小结: 暂停 \(final.pauseCount) 次，累计暂停 \(String(format: "%.1f", final.totalPaused)) 秒；"
            + "结束时连续降速计数 = \(final.consecutiveSlowdowns)"
            + (final.consecutiveSlowdowns == 0 ? "（退避已重置 ✔）" : ""))
        if disablePacer {
            out("总开关关闭态判定: 暂停次数 = \(final.pauseCount) "
                + (final.pauseCount == 0 ? "✔ 一次都没暂停（统计照常记录）" : "✘ 不应该暂停"))
        }
        out("上报过的提示行（BatchProgress.note）：")
        let ns = notes.snapshot()
        if ns.isEmpty { out("  （无）") }
        for (i, n) in ns.enumerated() { out("  \(i + 1). \(n ?? "<清空>")") }
    }

    // ---------- 新旧口径对比（混合语料最能说明问题）----------
    legacyVsSplitComparison(samples.snapshot(), mixed: mixed)

    // ---------- 吞吐类的独立验证（内置盘上没有传输主导区间，只能造时序）----------
    throughputClassSyntheticCheck()

    // ---------- 接进 BatchEngine 的端到端验证 ----------
    hr("端到端：BatchEngine.applyEdits 走节流器")
    targets = ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
        .filter { !$0.hasDirectoryPath
                  && !$0.lastPathComponent.hasPrefix("pacer-")
                  && !$0.lastPathComponent.hasPrefix("mix-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let jobs: [(url: URL, edit: TagEdit)] = targets.enumerated().map { (i, u) in
        var e = TagEdit(); e.set(.title, "端到端-\(i + 1)"); e.set(.artist, "pacer-e2e")
        return (u, e)
    }
    let seen = NoteRecorder()
    let conc = BatchEngine.recommendedConcurrency(for: targets)
    out("并发度 = \(conc)（副本在临时目录 → 内置卷 → 走 defaultConcurrency）")
    let s = runAsync {
        await BatchEngine.applyEdits(jobs, concurrency: conc, pacing: .always) { p in
            if let n = p.note { seen.add(n) }
        }
    }
    out("结果: \(s.description)  耗时 \(String(format: "%.2f", s.elapsed)) 秒")
    let ns = seen.snapshot().compactMap { $0 }
    out("进度回调里收到的 note: \(ns.isEmpty ? "无（本轮没有降速，符合内置盘预期）" : ns.joined(separator: " | "))")

    var okCount = 0
    for (i, u) in targets.enumerated() {
        if let f = try? TagService.read(u), f.tags.title == "端到端-\(i + 1)" { okCount += 1 }
    }
    out("回读复核: 标题逐项对上 \(okCount)/\(targets.count) \(okCount == targets.count ? "✔" : "✘")")

    // ---------- 取消语义 ----------
    cancelDuringPauseDemo(targets, label: mixed ? "六格式混合语料" : "等大副本语料")
}

// MARK: - 新旧口径对比

/// 用同一批样本，对比「旧口径：不分形态一律算吞吐」与「新口径：两类分开判」的离散程度。
private func legacyVsSplitComparison(_ all: [PacerSample], mixed: Bool) {
    hr("新旧口径对比（只统计**未注入延迟**的正常样本）")

    let normal = all.filter { !$0.injected }
    let inPlace = normal.filter { $0.kind == .inPlace }
    let rewrite = normal.filter { $0.kind == .fullRewrite }

    func ratio(_ lo: Double, _ hi: Double) -> String {
        lo > 0 ? String(format: "%.0f 倍", hi / lo) : "—"
    }

    // 旧口径：所有正常样本一律 字节/耗时
    if let lo = normal.min(by: { $0.legacyThroughput < $1.legacyThroughput }),
       let hi = normal.max(by: { $0.legacyThroughput < $1.legacyThroughput }) {
        out("旧口径（不分形态，一律「字节/耗时」当吞吐）：")
        out(String(format: "  最低 %8.2f MB/s  ← %@", lo.legacyThroughput / 1_048_576, lo.name))
        out(String(format: "  最高 %8.2f MB/s  ← %@", hi.legacyThroughput / 1_048_576, hi.name))
        out("  离散度 = \(ratio(lo.legacyThroughput, hi.legacyThroughput))"
            + "  ← 全是文件大小造成的，跟卡快不快无关；基线 × 0.35 的阈值在这种离散度下必然误判")
    }
    out()
    out("新口径（两类分开）：")
    if let lo = inPlace.min(by: { $0.duration < $1.duration }),
       let hi = inPlace.max(by: { $0.duration < $1.duration }) {
        out(String(format: "  原地改写按耗时  最快 %6.2f ms（%@）  最慢 %6.2f ms（%@）  离散度 = %@",
                   lo.duration * 1000, lo.name, hi.duration * 1000, hi.name,
                   ratio(lo.duration, hi.duration)))
        out("    判定阈值是基线 × 3.0，离散度低于 3 倍就不会误判")
    } else {
        out("  原地改写：本轮无正常样本")
    }
    if let lo = rewrite.min(by: { $0.legacyThroughput < $1.legacyThroughput }),
       let hi = rewrite.max(by: { $0.legacyThroughput < $1.legacyThroughput }) {
        out(String(format: "  整文件重写按吞吐 最低 %8.2f MB/s（%@）  最高 %8.2f MB/s（%@）  离散度 = %@",
                   lo.legacyThroughput / 1_048_576, lo.name,
                   hi.legacyThroughput / 1_048_576, hi.name,
                   ratio(lo.legacyThroughput, hi.legacyThroughput)))
        out("    这一类里字节数确实约等于真实写入量，吞吐是有物理意义的")
    } else {
        out("  整文件重写：本轮无正常样本")
    }
    if mixed {
        out()
        let dsf = normal.filter { $0.name.contains("dsf") && $0.kind == .inPlace }
        let ogg = normal.filter { $0.name.contains("ogg") && $0.kind == .inPlace }
        if let d = dsf.first, let o = ogg.first {
            out("dsf ↔ ogg 直接对照（原地改写）：")
            out(String(format: "  %@ %d 字节  旧口径 %.2f MB/s  新口径 %.2f ms",
                       d.name, d.bytes, d.legacyThroughput / 1_048_576, d.duration * 1000))
            out(String(format: "  %@ %d 字节  旧口径 %.2f MB/s  新口径 %.2f ms",
                       o.name, o.bytes, o.legacyThroughput / 1_048_576, o.duration * 1000))
            out("  旧口径吞吐比 = \(ratio(min(d.legacyThroughput, o.legacyThroughput), max(d.legacyThroughput, o.legacyThroughput)))"
                + "；新口径耗时比 = \(ratio(min(d.duration, o.duration), max(d.duration, o.duration)))")
        }
    }
}

// MARK: - 顺序语料实验（验证按格式分桶）

/// 先写 8 份 dsf、再写 8 份 wav，**零注入延迟**。
///
/// 这是按格式分桶要解决的正题：dsf 的原地改写只动 ID3 尾部（快），
/// wav 要动 RIFF 块（慢约 3~5 倍）。基线由前半段的 dsf 建立之后，
/// **不分桶**的话后半段 wav 会被拿去和 dsf 的基线比 → 误判降速；
/// **分桶**之后 wav 有自己的基线，不受 dsf 影响。
/// 同一批语料、同一套参数，只切 `bucketByFormat` 跑两遍做对照。
func cmdPacerSequential(_ dir: String) {
    hr("顺序语料实验：先 8 份 dsf，再 8 份 wav（零注入）")

    let fm = FileManager.default
    let src = URL(fileURLWithPath: dir)
    let work = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mactagger-seq-\(UUID().uuidString)")
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    func seed(_ ext: String) -> URL? {
        (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension.lowercased() == ext }
    }
    guard let dsfSeed = seed("dsf"), let wavSeed = seed("wav") else {
        fail("语料目录里需要同时有 .dsf 与 .wav")
    }

    func copies(_ s: URL, _ tag: String, _ n: Int) -> [URL] {
        (1...n).compactMap { i in
            let d = work.appendingPathComponent(String(format: "%@-%02d.%@", tag, i, s.pathExtension))
            return (try? fm.copyItem(at: s, to: d)) != nil ? d : nil
        }
    }
    let dsfs = copies(dsfSeed, "seq-dsf", 8)
    let wavs = copies(wavSeed, "seq-wav", 8)
    guard dsfs.count == 8, wavs.count == 8 else { fail("副本准备失败") }
    let sequence = dsfs + wavs

    // 预热：写一段固定的大注释，把标签区撑到接近真实音乐库的规模
    //（歌词/注释/封面都会让标签区变大，格式间的结构差异要在这个规模上才看得出来），
    // 同时捂热缓存。之后状态机只改标题 → 大小不变 → 全是原地改写。
    let payload = String(repeating: "填充", count: 60_000)     // ~360 KB UTF-8
    for (i, u) in sequence.enumerated() {
        var e = TagEdit(); e.set(.title, "预热-\(i)"); e.set(.comment, payload)
        _ = try? TagService.write(e, to: u)
        _ = try? TagService.write(e, to: u)                    // 第二次确保填充稳定
    }
    out("语料: 8 份 \(dsfSeed.lastPathComponent)（\(BatchEngine.fileSizeInBytes(dsfs[0])) 字节）"
        + " + 8 份 \(wavSeed.lastPathComponent)（\(BatchEngine.fileSizeInBytes(wavs[0])) 字节）")
    out("写入顺序: 前 8 笔全是 dsf（基线由它建立），后 8 笔全是 wav。全程零注入延迟。")
    out("标签区已撑到 ~360 KB 注释（贴近真实音乐库：有歌词/注释/内嵌封面），"
        + "耗时下限放宽到 10 µs 以免把亚毫秒级的格式差异夹平。")

    for bucketing in [true, false] {
        hr(bucketing ? "① 按格式分桶（bucketByFormat = true，生产默认）"
                     : "② 不分桶对照（bucketByFormat = false）")
        out("  #  文件             格式 形态 耗时      本次指标  EMA       基线      阈值      连慢 状态")

        runAsync { () async -> Void in
            // minSampleDuration 调到 10 µs：本机原地改写在亚毫秒量级，
            // 用生产默认的 0.5 ms 下限会把格式间的真实差异整个抹平（实测两格式都被夹成 0.50ms）。
            let cfg = WritePacer.Config(initialPause: 2, maxPause: 2,
                                        minSampleDuration: 0.00001,
                                        bucketByFormat: bucketing)
            let pacer = WritePacer(config: cfg)
            var pauses = 0

            for (i, u) in sequence.enumerated() {
                let waitStart = Date()
                await pacer.waitIfThrottled()
                if Date().timeIntervalSince(waitStart) > 0.05 {
                    pauses += 1
                    out("     ⏸  触发暂停（本轮零注入延迟 → 这是**误判**）")
                }

                let before = BatchEngine.fileSizeInBytes(u)
                var e = TagEdit(); e.set(.title, "顺序-\(i)-\(Int(Date().timeIntervalSince1970))")
                let t0 = DispatchTime.now()
                let ok = (try? TagService.write(e, to: u)) != nil
                let dt = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000_000
                let after = BatchEngine.fileSizeInBytes(u)

                guard ok, let oc = await pacer.record(bytesBefore: before, bytesAfter: after,
                                                      duration: dt,
                                                      format: u.pathExtension.lowercased())
                else { continue }
                let st = await pacer.stats()
                let ts = oc.stats
                func m(_ v: Double?) -> String {
                    guard let v, v.isFinite else { return "—" }
                    // 单位必须跟着形态走：耗时类是 ms，吞吐类是 MB/s
                    return String(format: oc.kind == .inPlace ? "%.2fms" : "%.0fMB/s",
                                  oc.kind.display(v))
                }
                let phase = ts.baseline == nil
                    ? "建基线(\(ts.totalSamples)/5)"
                    : (st.isThrottled ? "⚠︎ 判定降速[桶=\(st.throttleBucket ?? "-")]" : "正常")
                out(String(format: "  %2d %@ %@ %@ %8.2fms %9@ %9@ %9@ %9@  %d   %@",
                           i + 1, pad(u.lastPathComponent, 16),
                           pad(u.pathExtension, 4),
                           oc.kind == .inPlace ? "耗时" : "吞吐", dt * 1000,
                           m(ts.last) as NSString, m(ts.ema) as NSString,
                           m(ts.baseline) as NSString, m(ts.threshold) as NSString,
                           ts.consecutiveSlow, phase))
            }

            let f = await pacer.stats()
            out()
            for b in f.sortedLatencyBuckets { out("  " + b.summary) }
            out("  暂停次数 = \(f.pauseCount)"
                + (bucketing
                   ? (f.pauseCount == 0 ? "  ✔ 零注入下零误判" : "  ✘ 分桶后仍误判")
                   : (f.pauseCount > 0 ? "  ← 不分桶时 wav 被 dsf 的基线误判（正是分桶要解决的问题）"
                                       : "  （本机本轮两格式差距不足以触发，见下方说明）")))
        }
    }
}

// MARK: - 吞吐类合成时序验证

/// 内置 SSD 写的是页缓存，**再大的文件也是固定开销主导**（1.4 MB 整文件重写只要 0.35 ms），
/// 根本不存在「传输主导」区间，所以吞吐类在本机真实语料上不会启用 —— 这是正确行为。
/// 为了仍然验证吞吐类本身的状态机，这里**直接喂造出来的时序**，
/// 数值按一张真实 TF 卡来编：正常 15 MB/s，掉速后 2 MB/s。
private func throughputClassSyntheticCheck() {
    hr("吞吐类验证（合成时序，模拟真实 TF 卡；非本机实测）")

    let fileBytes = 4 * 1024 * 1024          // 4 MB 的曲目
    let goodRate = 15.0 * 1024 * 1024        // 15 MB/s
    let badRate  = 2.0 * 1024 * 1024         // 2 MB/s（掉出 SLC 缓存）
    out("造样本: 每首 \(fileBytes / 1024 / 1024) MB 整文件重写（大小变化）；"
        + "正常 15 MB/s → 每次 \(String(format: "%.0f", Double(fileBytes) / goodRate * 1000)) ms，"
        + "掉速 2 MB/s → 每次 \(String(format: "%.0f", Double(fileBytes) / badRate * 1000)) ms")
    out()
    out("  #  形态    耗时       本次指标     EMA          基线         阈值         状态")

    runAsync { () async -> Void in
        // 暂停设成 0.2 秒，只验状态机不浪费时间
        let cfg = WritePacer.Config(initialPause: 0.2, maxPause: 0.2)
        let pacer = WritePacer(config: cfg)

        func step(_ i: Int, rate: Double) async {
            let dur = Double(fileBytes) / rate
            await pacer.waitIfThrottled()
            let oc = await pacer.record(bytesBefore: fileBytes - 2048,
                                        bytesAfter: fileBytes,
                                        duration: dur, format: "mp3")
            let st = await pacer.stats()
            let k = oc?.kind ?? .fullRewrite
            let ts = oc?.stats ?? st.fullRewrite
            func m(_ v: Double?) -> String {
                guard let v, v.isFinite else { return "—" }
                return String(format: k == .inPlace ? "%.2fms" : "%.2fMB/s", k.display(v))
            }
            let phase = ts.baseline == nil ? "建立基线(\(ts.totalSamples)/5)"
                      : (st.isThrottled ? "⚠︎ \(st.throttleSource?.label ?? "")判定降速" : "正常")
            out(String(format: "  %2d %@ %8.0fms %12@ %12@ %12@ %12@  %@",
                       i, k == .inPlace ? "耗时类" : "吞吐类", dur * 1000,
                       m(ts.last) as NSString, m(ts.ema) as NSString,
                       m(ts.baseline) as NSString, m(ts.threshold) as NSString, phase))
        }

        for i in 1...7 { await step(i, rate: goodRate) }      // 建基线 + 正常
        for i in 8...12 { await step(i, rate: badRate) }      // 掉速
        // 回血段给到 12 笔：新策略下退避阶梯要连续 backoffResetStreak（10）次正常样本才清零
        // （`recoveryStreak` 3 只负责清掉界面提示行）。旧版这里只喂 6 笔，
        // 在新语义下测不到「阶梯归零」这条。
        for i in 13...24 { await step(i, rate: goodRate) }    // 回血

        let f = await pacer.stats()
        out()
        out("  " + f.fullRewrite.summary)
        out("  暂停 \(f.pauseCount) 次（有效 \(f.effectivePauses) / 无效 \(f.ineffectivePauses)）；"
            + "结束时连续降速计数 = \(f.consecutiveSlowdowns)")
        let effective = f.effectivePauses >= 1 && f.ineffectivePauses == 0
        let ok = f.fullRewrite.totalSamples >= 15 && f.pauseCount >= 1
                 && f.consecutiveSlowdowns == 0 && effective
        out("  判定: "
            + (f.fullRewrite.totalSamples >= 15 ? "✔ 样本确实进了吞吐类" : "✘ 样本没进吞吐类")
            + "；" + (f.pauseCount >= 1 ? "✔ 掉速被识别并暂停" : "✘ 掉速没被识别")
            + "；" + (effective ? "✔ 这次暂停被判定为有效（暂停后确实回血）"
                                : "✘ 暂停有效性判定不对（有效 \(f.effectivePauses) / 无效 \(f.ineffectivePauses)）")
            + "；" + (f.consecutiveSlowdowns == 0 ? "✔ 回血后退避已重置" : "✘ 退避未重置"))
        out("  总结论: \(ok ? "吞吐类状态机正确 ✔" : "存在不符合项 ✘")")
    }
}

// MARK: - 「暂停中取消」演示

/// 两条保证：
/// 1. **取消只在文件之间生效**：`TagService.write` 是同步 C++ 调用，一旦开写必定写完。
/// 2. **暂停等待期间收到取消立即退出**：不睡满，也不再写下一个文件。
///
/// 演示**自己制造暂停窗口**，不依赖卷类型、不依赖语料：
/// - 强制打开节流器总开关（跑完恢复），显式传配置，不走 `automatic(for:)` 的卷判定；
/// - 先**预测量**每个副本的写入耗时，然后把**最快的排第 1**（用它定基线）、
///   其余按耗时**降序**（最慢的排第 2），把基线与第 2 笔的落差拉到最大；
/// - 配置调到极敏感（基线 1 笔、EMA 全跟最新、阈值 1.01 倍、连续 1 笔即判定、不分桶），
///   于是第 2 笔必然越阈 → 第 3 个文件写之前必然进入 8 秒暂停。
///
/// **判定前先自检暂停是否真的发生**：没发生（介质太快，连注入都压不住）就如实说明并跳过，
/// 绝不拿「开启态」的断言去套一个根本没有暂停窗口的运行。
private func cancelDuringPauseDemo(_ files: [URL], label: String) {
    hr("取消语义：暂停期间取消（\(label)）")

    guard files.count >= 3 else { out("文件不足 3 个，跳过"); return }

    // 强制启用节流器：本演示要的是暂停窗口，与卷类型无关
    let saved = BatchEngine.adaptivePacingEnabled
    BatchEngine.adaptivePacingEnabled = true
    defer { BatchEngine.adaptivePacingEnabled = saved }
    out("已强制启用节流器总开关（本演示自造暂停窗口，与卷类型无关；跑完恢复原值）")

    // ① 预测量：每个副本写一次，量耗时（同时把标签区填充建好，后续都是原地改写）
    var timing: [(url: URL, dur: TimeInterval)] = []
    for (i, u) in files.enumerated() {
        var e = TagEdit(); e.set(.title, "预测量-\(i)")
        let t0 = DispatchTime.now()
        _ = try? TagService.write(e, to: u)
        let dt = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000_000
        timing.append((u, dt))
    }
    // ② 排序：最快的第 1（定基线），其余降序（最慢的第 2）
    let sortedAsc = timing.sorted { $0.dur < $1.dur }
    guard let fastest = sortedAsc.first else { out("预测量失败，跳过"); return }
    let rest = sortedAsc.dropFirst().sorted { $0.dur > $1.dur }
    let order = [fastest] + rest

    out("预测量耗时（用于排序，保证第 2 笔必然慢于基线）:")
    for (i, t) in order.prefix(4).enumerated() {
        out(String(format: "  %d. %@ %.2f ms%@", i + 1, pad(t.url.lastPathComponent, 20),
                   t.dur * 1000, i == 0 ? "   ← 最快，用它定基线" : (i == 1 ? "   ← 最慢，第 2 笔" : "")))
    }

    let marker = "取消演示-\(Int(Date().timeIntervalSince1970))"
    let jobs: [(url: URL, edit: TagEdit)] = order.map { t in
        var e = TagEdit(); e.set(.title, marker); return (t.url, e)
    }

    // ③ 极敏感配置 + 8 秒暂停；不分桶（要的是跨格式落差）、不夹耗时下限（要真实差异）
    let cfg = WritePacer.Config(enabled: true, baselineSamples: 1, emaAlpha: 1.0,
                                slowdownRatio: 1.0, latencyRatio: 1.01,
                                minSamplesForDecision: 1,
                                initialPause: 8, maxPause: 8,
                                minSampleDuration: 0.000001,
                                bucketByFormat: false)
    let notes = NoteRecorder()

    let began = Date()
    let summary = runAsync { () async -> BatchSummary in
        let t = Task { () -> BatchSummary in
            await BatchEngine.applyEdits(jobs, concurrency: 1, pacing: cfg) { p in
                if let n = p.note { notes.add(n) }
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        out("  → 1.0 秒时发出取消")
        t.cancel()
        return await t.value
    }
    let wall = Date().timeIntervalSince(began)

    var written = 0, untouched = 0, broken = 0
    for t in order {
        guard let f = try? TagService.read(t.url) else { broken += 1; continue }
        if f.tags.title == marker { written += 1 } else { untouched += 1 }
    }

    let pauseNotes = notes.snapshot().compactMap { $0 }
    let pauseHappened = pauseNotes.contains { $0.contains("暂停") }

    out()
    out(String(format: "总耗时 %.2f 秒", wall))
    out("结果: \(summary.description)  isCancelled=\(summary.isCancelled)")
    out("暂停提示: \(pauseNotes.isEmpty ? "（无）" : pauseNotes.joined(separator: " | "))")
    out()
    out("逐文件回读复核（共 \(order.count) 个）:")
    out("  已完整写入 : \(written)")
    out("  未开工     : \(untouched)")
    out("  读不出来（写坏了）: \(broken)")
    out()

    // ---- 判定前先自检前提 ----
    out("前提自检: 本轮\(pauseHappened ? "**确实形成了**" : "**未形成**")暂停窗口")
    guard pauseHappened else {
        out("  本轮未形成暂停窗口（介质太快，连极敏感配置也压不出降速），"
            + "「暂停中取消」这条断言不适用，跳过。")
        out("  取消语义本身由 `mactagger-probe batch` 的取消用例覆盖"
            + "（300 项派发后立刻 cancel → 成功 0 项、isCancelled=true）。")
        out("  仍可断言: " + (broken == 0 ? "✔ 没有任何文件被写坏" : "✘ 有文件读不出来"))
        out("总结论: \(broken == 0 ? "符合预期（本项跳过）✔" : "存在不符合项 ✘")")
        return
    }

    let noBroken = broken == 0
    let stopped = written < order.count
    let interrupted = wall < 6
    out("  → 按「节流器开启、存在 8 秒暂停窗口」断言:")
    out("  " + (noBroken ? "✔ 没有任何文件被写坏（取消不中断正在写的文件）" : "✘ 有文件读不出来"))
    out("  " + (stopped ? "✔ 取消后确实没再写下一个（写完 \(written)/\(order.count)）" : "✘ 取消没拦住后续写入"))
    out("  " + (interrupted ? "✔ 暂停被立即打断（未睡满 8 秒）" : "✘ 暂停没被打断"))
    out("总结论: \(noBroken && stopped && interrupted ? "全部符合预期 ✔" : "存在不符合项 ✘")")
}

// MARK: - 记录器

final class NoteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []

    func add(_ text: String?) { lock.lock(); items.append(text); lock.unlock() }

    func snapshot() -> [String?] { lock.lock(); defer { lock.unlock() }; return items }

    var lastPauseText: String? {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap { $0 }.last(where: { $0.contains("暂停") })
    }

    var lastResumeText: String? {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap { $0 }.last(where: { $0.contains("恢复写入") })
    }
}

private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PacerSample] = []
    func add(_ s: PacerSample) { lock.lock(); items.append(s); lock.unlock() }
    func snapshot() -> [PacerSample] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - 三场景合成对照（pacer --scenarios [--legacy]）
//
// 为什么用合成时序而不是真写文件：这三条曲线要的是**存储介质的物理形态**
// （SLC 缓存 → 持续速度、热降速 → 回血），本机内置 SSD 写的是页缓存，
// 造不出来；而真的插 TF 卡跑一轮又没法复现「改前 2→4→8→16→20」的 700 秒等待。
// 所以直接按真实 TF 卡的数量级喂样本，并给节流器注入**空 sleeper**（虚拟时钟）：
// 暂停时长按名义值记账，秒级就能跑完 120 个样本 + 旧策略 38 次暂停的对照。

/// 一条合成样本：整文件重写，`bytes` 字节、以 `rate` 字节/秒的速度写完。
private struct PacerSimStep {
    var bytes: Int
    var rate: Double
    /// 这一笔属于哪个阶段（打在事件列里）。
    var phase: String
}

private func simMB(_ mb: Double) -> Double { mb * 1_048_576 }

/// 场景配置：新策略用生产默认值，旧策略把 `adaptiveStrategy` 关掉。
private func simConfig(legacy: Bool, enabled: Bool = true) -> WritePacer.Config {
    legacy
        ? WritePacer.Config(enabled: enabled, initialPause: 2, maxPause: 20, adaptiveStrategy: false)
        : WritePacer.Config(enabled: enabled)      // 生产默认：2 s 起、封顶 8 s、×1.5、预算 25%
}

/// 一次场景跑的结果（供末尾汇总表）。
private struct PacerSimResult {
    var title: String
    var strategy: String
    var samples: Int
    var pauseCount: Int
    var pauseSeconds: [TimeInterval]
    var totalPaused: TimeInterval
    var writeWall: TimeInterval
    var finalBaselineMBps: Double?
    var verdicts: [String]
    var budgetStopped: Bool
    var pauseAtSample: [Int]
}

/// 跑一条合成曲线，逐笔打印（前 12 笔 + 每 20 笔 + 所有事件行），最后汇总。
private func runPacerSim(title: String,
                         detail: String,
                         steps: [PacerSimStep],
                         cfg: WritePacer.Config,
                         ext: String = "flac") -> PacerSimResult {
    out()
    out("── \(title) ── \(cfg.enabled ? (cfg.adaptiveStrategy ? "新策略" : "旧策略 --legacy") : "开关关闭")")
    out("   语料: \(detail)")
    out(String(format: "   配置: 初始暂停 %.0fs 封顶 %.0fs 增长 ×%.1f | 预算 %.0f%% | 冷却 %.0fs 或 %d MB | 收敛每 %d 样本 | 有效性 K=%d ≥%.1f×",
               cfg.initialPause, cfg.maxPause,
               cfg.adaptiveStrategy ? cfg.pauseGrowth : 2.0,
               cfg.pauseBudgetRatio * 100, cfg.cooldownSeconds,
               cfg.cooldownBytes / 1_048_576, cfg.baselineRecalcEvery,
               cfg.effectivenessWindow, cfg.effectivenessRatio)
        + (cfg.adaptiveStrategy ? "" : "  ← 这些新机制在旧策略下全部不生效"))
    out("    #  阶段      速率      耗时      本次指标   EMA       基线      阈值      事件")

    return runAsync { () async -> PacerSimResult in
        let pacer = WritePacer(config: cfg, note: nil, sleeper: { _ in })   // 空 sleeper = 虚拟时钟
        var lastPauseCount = 0
        var lastBaseline: Double?
        var budgetShown = false
        var verdicts: [String] = []
        var pauseAt: [Int] = []

        func mbps(_ v: Double?) -> String {
            guard let v, v.isFinite else { return "—" }
            return String(format: "%.1f", v / 1_048_576)
        }

        for (i, s) in steps.enumerated() {
            let dur = Double(s.bytes) / s.rate
            var events: [String] = []

            await pacer.waitIfThrottled()
            let mid = await pacer.stats()
            if mid.pauseCount > lastPauseCount {
                let p = mid.pauseSeconds.last ?? 0
                pauseAt.append(i + 1)
                events.append(String(format: "⏸ 暂停#%d %.1fs（累计 %.1fs，占写入墙钟 %.0f%%）",
                                     mid.pauseCount, p, mid.totalPaused, mid.pauseRatio * 100))
                lastPauseCount = mid.pauseCount
            }
            if mid.budgetStopped, !budgetShown {
                budgetShown = true
                events.append(String(format: "🚫 预算耗尽停等（已暂停 %.1fs > 写入墙钟 %.1fs × %.0f%%）",
                                     mid.totalPaused, mid.writeWallClock, cfg.pauseBudgetRatio * 100))
            }

            let oc = await pacer.record(bytesBefore: s.bytes - 4096, bytesAfter: s.bytes,
                                        duration: dur, format: ext)
            let ts = oc?.stats
            if let v = oc?.verdict {
                let line = String(format: "%@ 暂停前 %.1f MB/s → 暂停后 %.1f MB/s = %.2f×%@",
                                  v.effective ? "✔ 暂停有效" : "✘ 暂停无效",
                                  v.displayBefore, v.displayAfter, v.improvement,
                                  v.newBaseline.map { String(format: "，基线放宽到 %.1f MB/s", $0 / 1_048_576) } ?? "")
                events.append(line)
                verdicts.append(line)
            }
            if let b = ts?.baseline, let lb = lastBaseline, abs(b - lb) > 1 {
                if oc?.verdict == nil {
                    events.append(String(format: "↓ 基线收敛 %.1f → %.1f MB/s（近期中位 %@ MB/s）",
                                         lb / 1_048_576, b / 1_048_576, mbps(ts?.recentMedian)))
                }
            }
            lastBaseline = ts?.baseline

            let show = i < 12 || !events.isEmpty || (i + 1) % 20 == 0 || i == steps.count - 1
            if show {
                out(String(format: "  %3d  %@ %7.1fMB/s %7.0fms %9@ %9@ %9@ %9@  %@",
                           i + 1, pad(s.phase, 8), s.rate / 1_048_576, dur * 1000,
                           mbps(ts?.last) as NSString, mbps(ts?.ema) as NSString,
                           mbps(ts?.baseline) as NSString, mbps(ts?.threshold) as NSString,
                           events.joined(separator: " | ")))
            }
        }

        let f = await pacer.stats()
        out(String(format: "   汇总: 样本 %d | 暂停 %d 次 %@ | 总暂停 %.1f 秒 | 写入墙钟 %.1f 秒（暂停占 %.0f%%）| 最终基线 %@ MB/s",
                   f.fullRewrite.totalSamples, f.pauseCount,
                   f.pauseSeconds.isEmpty ? "[]"
                       : "[" + f.pauseSeconds.map { String(format: "%.1f", $0) }.joined(separator: ", ") + "]",
                   f.totalPaused, f.writeWallClock, f.pauseRatio * 100,
                   mbps(f.fullRewrite.baseline)))
        if f.pauseCount > 0 {
            out("   暂停发生在第 \(pauseAt.map(String.init).joined(separator: "、")) 个样本前"
                + "；有效 \(f.effectivePauses) 次 / 无效 \(f.ineffectivePauses) 次"
                + (f.budgetStopped ? "；已因预算停等" : ""))
        }

        return PacerSimResult(title: title,
                              strategy: cfg.enabled ? (cfg.adaptiveStrategy ? "改后" : "改前(legacy)") : "开关关闭",
                              samples: f.fullRewrite.totalSamples,
                              pauseCount: f.pauseCount,
                              pauseSeconds: f.pauseSeconds,
                              totalPaused: f.totalPaused,
                              writeWall: f.writeWallClock,
                              finalBaselineMBps: f.fullRewrite.baseline.map { $0 / 1_048_576 },
                              verdicts: verdicts,
                              budgetStopped: f.budgetStopped,
                              pauseAtSample: pauseAt)
    }
}

// ---- 三条曲线 ----

/// ① 缓存后持续低速：前 5 样本 80 MB/s（命中 SLC 缓存），之后稳定 18 MB/s，共 120 样本，4 MB/首。
private func simSteps1() -> [PacerSimStep] {
    let bytes = 4 * 1024 * 1024
    var v: [PacerSimStep] = []
    for _ in 1...5   { v.append(PacerSimStep(bytes: bytes, rate: simMB(80), phase: "SLC缓存")) }
    for _ in 6...120 { v.append(PacerSimStep(bytes: bytes, rate: simMB(18), phase: "持续速度")) }
    return v
}

/// ② 真·热降速：80 MB/s → 突降 5 MB/s（3 笔）→ 暂停后回到 60 MB/s（4 笔），反复 3 轮。
/// 文件按 24 MB/首（一张高码率专辑的单曲量级）—— 掉速时每笔要写 4.8 秒，
/// 暂停几秒才在「总暂停 ≤ 写入墙钟 25%」的预算里说得通；4 MB 的小文件掉到 5 MB/s 时
/// 一笔才 0.8 秒，为它等 2 秒本来就不划算，预算拦下来是对的。
private func simSteps2() -> [PacerSimStep] {
    let bytes = 24 * 1024 * 1024
    var v: [PacerSimStep] = []
    for _ in 1...5 { v.append(PacerSimStep(bytes: bytes, rate: simMB(80), phase: "正常")) }
    for _ in 1...3 {
        for _ in 1...3 { v.append(PacerSimStep(bytes: bytes, rate: simMB(5),  phase: "热降速")) }
        for _ in 1...4 { v.append(PacerSimStep(bytes: bytes, rate: simMB(60), phase: "回血")) }
    }
    return v
}

/// ③ 开关关闭：曲线同 ①，用户把「写入时自适应等待存储卡恢复」关掉。
private func simSteps3() -> [PacerSimStep] { simSteps1() }

/// ④ 补充：同 ② 的热降速形态，但文件只有 4 MB。
/// 掉速时一笔才 0.8 秒，为它等 2 秒本来就不划算 —— 用来验证「总暂停预算」这条兜底：
/// 第一次暂停走豁免，第二次就被预算拦下，改推「已停止等待」。
private func simSteps4() -> [PacerSimStep] {
    let bytes = 4 * 1024 * 1024
    var v: [PacerSimStep] = []
    for _ in 1...5 { v.append(PacerSimStep(bytes: bytes, rate: simMB(80), phase: "正常")) }
    for _ in 1...3 {
        for _ in 1...3 { v.append(PacerSimStep(bytes: bytes, rate: simMB(5),  phase: "热降速")) }
        for _ in 1...4 { v.append(PacerSimStep(bytes: bytes, rate: simMB(60), phase: "回血")) }
    }
    return v
}

func cmdPacerScenarios(legacy: Bool) {
    hr("WritePacer 三场景合成对照" + (legacy ? "（--legacy 旧策略 = 改前）" : "（新策略 = 改后）"))
    out("说明: 合成时序 + 空 sleeper（虚拟时钟），**不写任何文件、不改任何设置**；")
    out("      暂停时长按名义值记账 —— 旧策略那 700 秒级的等待真睡一遍要十几分钟。")
    out("      用户总开关当前值（只读）: \(BatchEngine.adaptivePacingDefaultsKey) = \(BatchEngine.adaptivePacingEnabled)")

    var results: [PacerSimResult] = []

    hr("场景 ① 缓存后持续低速（前 5 笔 80 MB/s，之后稳定 18 MB/s，共 120 笔 × 4 MB）")
    out("预期(改后): 最多 1–2 次暂停、总暂停 ≤ 写入墙钟 25%、基线收敛到 18 MB/s 附近、随后 0 次暂停")
    out("预期(改前): 2/4/8/16/20 一路翻倍，总暂停 > 60 秒")
    let r1 = runPacerSim(title: "场景 ①",
                         detail: "120 笔整文件重写，每笔 4 MB；前 5 笔 80 MB/s，之后恒定 18 MB/s",
                         steps: simSteps1(), cfg: simConfig(legacy: legacy))
    results.append(r1)
    if legacy {
        let head = Array(r1.pauseSeconds.prefix(5)).map { String(format: "%.0f", $0) }.joined(separator: "/")
        let doubling = head.hasPrefix("2/4/8/16/20")
        out("   判定: " + (r1.pauseSeconds.count >= 5 && doubling ? "✔ 前五次暂停 \(head) 确实在翻倍" : "✘ 未复现翻倍（\(head)）")
            + "；" + (r1.totalPaused > 60 ? String(format: "✔ 总暂停 %.0f 秒 > 60 秒", r1.totalPaused)
                                          : String(format: "✘ 总暂停只有 %.0f 秒", r1.totalPaused)))
    } else {
        let few = r1.pauseCount <= 2
        let budget = r1.totalPaused <= r1.writeWall * 0.25
        let converged = (r1.finalBaselineMBps ?? 0) >= 15 && (r1.finalBaselineMBps ?? 0) <= 25
        let quiet = (r1.pauseAtSample.max() ?? 0) <= 20
        out("   判定: " + (few ? "✔ 暂停 \(r1.pauseCount) 次（≤2）" : "✘ 暂停 \(r1.pauseCount) 次")
            + "；" + (budget ? String(format: "✔ 总暂停 %.1fs ≤ 25%% 预算", r1.totalPaused) : "✘ 超预算")
            + "；" + (converged ? String(format: "✔ 基线收敛到 %.1f MB/s", r1.finalBaselineMBps ?? 0)
                               : String(format: "✘ 基线 %.1f MB/s 未收敛到 18 附近", r1.finalBaselineMBps ?? 0))
            + "；" + (quiet ? "✔ 第 \(r1.pauseAtSample.max() ?? 0) 笔之后再没暂停过" : "✘ 后段仍在暂停"))
    }

    hr("场景 ② 真·热降速（80 → 突降 5 MB/s，暂停后回到 60 MB/s，反复 3 轮，24 MB/笔）")
    out("预期(改后): 仍能暂停并回血；暂停 2 → 3 → 4.5 秒（×1.5 增长），不超过 8 秒")
    let r2 = runPacerSim(title: "场景 ②",
                         detail: "26 笔整文件重写，每笔 24 MB；5 笔 80 MB/s 建基线，之后「3 笔 5 MB/s + 4 笔 60 MB/s」×3",
                         steps: simSteps2(), cfg: simConfig(legacy: legacy))
    results.append(r2)
    if !legacy {
        let seq = r2.pauseSeconds.map { String(format: "%.1f", $0) }.joined(separator: " → ")
        let want = r2.pauseSeconds.count == 3
            && abs(r2.pauseSeconds[0] - 2) < 0.01
            && abs(r2.pauseSeconds[1] - 3) < 0.01
            && abs(r2.pauseSeconds[2] - 4.5) < 0.01
        let capped = (r2.pauseSeconds.max() ?? 0) <= 8
        let recovered = r2.verdicts.allSatisfy { $0.contains("暂停有效") } && !r2.verdicts.isEmpty
        out("   判定: " + (want ? "✔ 暂停序列 \(seq)（×1.5）" : "✘ 暂停序列 \(seq)")
            + "；" + (capped ? "✔ 未超 8 秒封顶" : "✘ 超过封顶")
            + "；" + (recovered ? "✔ 每次暂停都判定为有效（确实回血）" : "✘ 有暂停被判无效"))
    } else {
        out("   判定（改前对照）: 暂停序列 ["
            + r2.pauseSeconds.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            + "]，旧策略在「恰好 3 次正常样本」就把退避清零，所以这条曲线上反而涨不起来 ——"
            + "旧策略的病灶在场景 ①（持续低速）而不在这里。")
    }

    hr("场景 ③ 开关关闭（曲线同 ①，用户把「写入时自适应等待存储卡恢复」关掉）")
    out("预期: 0 次暂停（统计照常记录，供日志诊断）")
    let r3 = runPacerSim(title: "场景 ③",
                         detail: "同场景 ①，但 Config.enabled = false（= gated() 在用户关掉开关时的结果）",
                         steps: simSteps3(), cfg: simConfig(legacy: legacy, enabled: false))
    results.append(r3)
    out("   判定: " + (r3.pauseCount == 0 ? "✔ 一次都没暂停" : "✘ 竟然暂停了 \(r3.pauseCount) 次")
        + "；" + (r3.samples == 120 ? "✔ 120 个样本照常统计" : "✘ 统计漏了样本"))

    hr("场景 ④（补充）小文件热降速：验证「总暂停预算」兜底（4 MB/笔，其余同 ②）")
    out("预期(改后): 第 1 次暂停走豁免，之后累计暂停超出写入墙钟 25% → 停止等待，改推「已停止等待」文案")
    let r4 = runPacerSim(title: "场景 ④",
                         detail: "26 笔整文件重写，每笔 4 MB；掉速时一笔仅 0.8 秒，等 2 秒不划算",
                         steps: simSteps4(), cfg: simConfig(legacy: legacy))
    results.append(r4)
    if !legacy {
        out("   判定: " + (r4.budgetStopped ? "✔ 预算触发了停止等待" : "✘ 预算没拦住")
            + "；" + (r4.pauseCount <= 2 ? "✔ 只暂停了 \(r4.pauseCount) 次" : "✘ 暂停 \(r4.pauseCount) 次"))
    } else {
        out("   改前对照: 暂停 \(r4.pauseCount) 次、总暂停 \(String(format: "%.1f", r4.totalPaused)) 秒"
            + "（写入墙钟只有 \(String(format: "%.1f", r4.writeWall)) 秒，旧策略没有预算这回事）")
    }

    hr("汇总表（\(legacy ? "改前 legacy" : "改后")）")
    out("  场景            样本  暂停次数  每次暂停(秒)                 总暂停(秒)  写入墙钟(秒)  暂停占比  最终基线(MB/s)")
    for r in results {
        let seq = r.pauseSeconds.isEmpty ? "—"
            : r.pauseSeconds.prefix(8).map { String(format: "%.1f", $0) }.joined(separator: ",")
              + (r.pauseSeconds.count > 8 ? ",…(共\(r.pauseSeconds.count)次)" : "")
        out(String(format: "  %@ %5d %7d  %@ %10.1f %12.1f %8.0f%% %12@",
                   pad(r.title + "/" + r.strategy, 16), r.samples, r.pauseCount,
                   pad(seq, 28), r.totalPaused, r.writeWall,
                   r.writeWall > 0 ? r.totalPaused / r.writeWall * 100 : 0,
                   (r.finalBaselineMBps.map { String(format: "%.1f", $0) } ?? "—") as NSString))
    }
}

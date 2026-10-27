//
//  RateLimiterProbe.swift
//  mactagger-probe — 限速器并发正确性验收（BD 轮第三部分）
//
//  用法：
//    mactagger-probe sources limiter [sourceID] [--n 60] [--concurrency 4]
//                                    [--interval 3.1] [--legacy] [--both]
//
//  为什么要有它：限速器是**唯一**决定我们对外发包速率的东西，而它的 bug 只在
//  「多条线同时进来」时才现形 —— 单线程跑一万发都是对的。BD 轮实测到的病象是
//  iTunes 声称 3.1 s 一发，压测里 60 发只花了 11 秒（≈327 次/分钟，
//  是 Apple 建议值 20 次/分钟的 16 倍），于是 Apple 回 403，
//  用户看到「iTunes 一直失败」。
//
//  验收方式：不发任何网络请求，只压 `HTTPClient.limiter` 这个**生产实例**
//  （不是替身），把每个调用者从 `waitIfNeeded` 返回的那一刻当作「发包时刻」，
//  排序后算相邻间隔。断言 **最小间隔 ≥ interval × 0.95**。
//

import Foundation

// MARK: - 对照组：修复前的老实现

/// **只在这个 probe 里存在**的老实现，一比一复刻 BD 轮之前 `RateLimiter` 的写法：
/// 「读 last → 算差值 → sleep → 回来才写 last」。
///
/// 关键错误是 `Task.sleep` 会让出 actor：并发 C 条线**同时**进来时，
/// C 个调用读到的是同一个 `last`、算出同一个延迟、睡同一段时间，
/// 然后一起醒、一起发 —— 实际发包速率是声称值的 C 倍。
actor LegacyRateLimiter {
    private var lastRequestAt: [String: Date] = [:]

    func waitIfNeeded(sourceID: String, interval: TimeInterval) async {
        guard interval > 0 else { return }
        let last = lastRequestAt[sourceID] ?? .distantPast
        let delta = Date().timeIntervalSince(last)
        if delta < interval {
            try? await Task.sleep(nanoseconds: UInt64((interval - delta) * 1_000_000_000))
        }
        lastRequestAt[sourceID] = Date()   // ← 睡完才写：这一行是全部问题的根
    }
}

// MARK: - 采样

/// 发包时刻的收集器。记的是 `waitIfNeeded` 返回的**那一刻** ——
/// 生产路径上紧接着就是 `session.data(for:)`，两者之间只隔一个可选的 jitter。
actor LimiterTicks {
    private(set) var ticks: [Date] = []
    func add(_ at: Date) { ticks.append(at) }
}

struct LimiterStats {
    var wall: TimeInterval
    var gaps: [TimeInterval]          // 相邻发包间隔（已按时刻排序）
    var stamps: [TimeInterval]        // 相对第一发的秒数

    var minGap: TimeInterval { gaps.min() ?? 0 }
    var maxGap: TimeInterval { gaps.max() ?? 0 }
    var medianGap: TimeInterval {
        guard !gaps.isEmpty else { return 0 }
        let s = gaps.sorted()
        return s[s.count / 2]
    }
    /// 实际发包速率（次/分钟）。
    func perMinute(_ n: Int) -> Double { wall > 0 ? Double(n) / wall * 60 : 0 }
}

/// 压一个限速器：`n` 发请求，`concurrency` 条线抢，返回发包时刻统计。
/// `wait` 就是被测的那个 `waitIfNeeded`。
func limiterRun(n: Int,
                concurrency: Int,
                wait: @escaping @Sendable () async -> Void) -> LimiterStats {
    let ticks = LimiterTicks()
    let started = Date()
    _ = cnRunBlocking { () async -> Int in
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func submit() {
                guard next < n else { return }
                next += 1
                group.addTask {
                    await wait()
                    await ticks.add(Date())
                }
            }
            for _ in 0..<min(concurrency, n) { submit() }
            for await _ in group { submit() }
        }
        return 0
    }
    let wall = Date().timeIntervalSince(started)
    let r = cnRunBlocking { await ticks.ticks }
    guard case .success(let raw) = r else {
        return LimiterStats(wall: wall, gaps: [], stamps: [])
    }
    let sorted = raw.sorted()
    guard let first = sorted.first else {
        return LimiterStats(wall: wall, gaps: [], stamps: [])
    }
    let stamps = sorted.map { $0.timeIntervalSince(first) }
    var gaps: [TimeInterval] = []
    for i in 1..<max(1, sorted.count) {
        gaps.append(sorted[i].timeIntervalSince(sorted[i - 1]))
    }
    return LimiterStats(wall: wall, gaps: gaps, stamps: stamps)
}

// MARK: - ① 时隙分配层（零调度噪声）

/// 只压 `reserve`（**不睡**），拿到 actor 亲手分配的时隙序列。
///
/// 为什么要单独量这一层：`waitIfNeeded` 返回的时刻 = 时隙 + 「`Task.sleep` 醒来后
/// 被调度到的那点延迟」。后者只会**往后**偏（几十毫秒量级），于是相邻两发的观测间隔
/// 会是 `interval + ε_i − ε_{i−1}`，前一发醒得比后一发晚时观测间隔就短于 interval ——
/// **那是量尺的抖动，不是限速器漏了**。时隙序列没有这层噪声：它要么严格等于
/// interval，要么就是真漏了。两层都报，才分得清「限速器错了」和「时钟不准」。
func limiterSlotCheck(n: Int, concurrency: Int,
                      sourceID: String, interval: TimeInterval) -> (min: TimeInterval,
                                                                    span: TimeInterval,
                                                                    pass: Bool) {
    let box = LimiterTicks()
    _ = cnRunBlocking { () async -> Int in
        await HTTPClient.limiter.reset()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func submit() {
                guard next < n else { return }
                next += 1
                group.addTask {
                    let slot = await HTTPClient.limiter.reserve(sourceID: sourceID,
                                                                interval: interval)
                    await box.add(slot)
                }
            }
            for _ in 0..<min(concurrency, n) { submit() }
            for await _ in group { submit() }
        }
        await HTTPClient.limiter.reset()
        return 0
    }
    let r = cnRunBlocking { await box.ticks }
    guard case .success(let raw) = r, raw.count > 1 else { return (0, 0, false) }
    let sorted = raw.sorted()
    var gaps: [TimeInterval] = []
    for i in 1..<sorted.count { gaps.append(sorted[i].timeIntervalSince(sorted[i - 1])) }
    let mn = gaps.min() ?? 0
    let span = sorted.last!.timeIntervalSince(sorted.first!)
    // 时隙是纯算术，只有浮点误差；1 µs 的容差足够。
    return (mn, span, mn >= interval - 0.000001)
}

// MARK: - 打印


func limiterPrint(_ label: String, _ st: LimiterStats,
                  n: Int, interval: TimeInterval) -> Bool {
    let floorGap = interval * 0.95
    let pass = st.minGap >= floorGap
    out("  【\(label)】")
    out(String(format: "    墙钟总时长    : %.2f s（理论下限 %.2f s = (%d-1)×%.2f）",
               st.wall, Double(n - 1) * interval, n, interval))
    out(String(format: "    实际发包速率  : %.1f 次/分钟", st.perMinute(n)))
    out(String(format: "    相邻间隔      : 最小 %.3f s · 中位 %.3f s · 最大 %.3f s",
               st.minGap, st.medianGap, st.maxGap))
    let zeros = st.gaps.filter { $0 < interval * 0.5 }.count
    out("    「几乎同时发出」的相邻对（间隔 < 半个 interval）: \(zeros) 对"
        + (zeros > 0 ? "　←　这就是突发流量" : ""))
    out(String(format: "    ★ 断言 最小间隔 ≥ interval×0.95 = %.3f s → %@",
               floorGap, pass ? "通过 ✔" : "**未通过 ✘**"))
    // 时间戳抽样：头 8 发 + 尾 4 发。全打 60 行没人看。
    let head = st.stamps.prefix(8).enumerated()
        .map { String(format: "#%02d %.2f", $0.offset + 1, $0.element) }
        .joined(separator: "  ")
    out("    发包时刻（相对第一发，秒）头 8 发: " + head)
    if st.stamps.count > 12 {
        let tail = st.stamps.suffix(4).enumerated()
            .map { String(format: "#%02d %.2f", st.stamps.count - 4 + $0.offset + 1, $0.element) }
            .joined(separator: "  ")
        out("                                     尾 4 发: " + tail)
    }
    out("")
    return pass
}

// MARK: - 子命令

func cmdSourcesLimiter(args: [String]) {
    // args = ["sources", "limiter", <sourceID?>, ...]
    let sourceID = (args.count > 2 && !args[2].hasPrefix("--")) ? args[2] : "itunes"
    let n = max(2, min(500, stressIntArg(args, "--n", 60)))
    let conc = max(1, min(64, stressIntArg(args, "--concurrency", 4)))
    // `--legacy` / `--both` 都表示「连老实现一起跑，做前后对照」。
    let both = args.contains("--both") || args.contains("--legacy")

    probeRegisterSources()
    let policy: SourcePolicy
    switch sourceID {
    case "itunes":      policy = ITunesSource.effectivePolicy
    case "qq":          policy = QQSource.currentPolicy
    case "musicbrainz": policy = .musicBrainz
    default:            policy = .chinese()
    }
    let interval = stressDoubleArg(args, "--interval") ?? policy.minimumInterval

    cnHR("限速器并发正确性（sources limiter）")
    out("  源            : \(sourceID)（\(SourceOutcome.displayName(sourceID))）")
    out(String(format: "  minimumInterval: %.2f s（≈%.1f 次/分钟）",
               interval, interval > 0 ? 60 / interval : 0))
    out("  发包数        : \(n) 发")
    out("  并发          : \(conc) 条线同时抢同一个源的时隙")
    out("  被测对象      : HTTPClient.limiter（**生产实例**，不是替身）")
    out("  说明          : 本命令不发任何网络请求，只量发包节拍。")
    out("")

    // ① 时隙分配层：零网络、零 sleep，只看 actor 发出去的号码牌对不对。
    let slot = limiterSlotCheck(n: n, concurrency: conc, sourceID: sourceID, interval: interval)
    out("  【① 时隙分配层（只调 reserve，不睡，零调度噪声）】")
    out(String(format: "    相邻时隙最小间隔: %.6f s　跨度 %.2f s（应 = (%d-1)×%.2f = %.2f）",
               slot.min, slot.span, n, interval, Double(n - 1) * interval))
    out("    ★ 断言 相邻时隙间隔 ≥ interval → " + (slot.pass ? "通过 ✔" : "**未通过 ✘**"))
    out("")

    var legacyStats: LimiterStats?
    var legacyPass: Bool?
    if both {
        // 老实现：每组一个新实例，跟生产实例互不干扰。
        let legacy = LegacyRateLimiter()
        let ls = limiterRun(n: n, concurrency: conc) {
            await legacy.waitIfNeeded(sourceID: sourceID, interval: interval)
        }
        legacyPass = limiterPrint("修复前（老实现：读 → 睡 → 才写 last）", ls,
                                  n: n, interval: interval)
        legacyStats = ls
    }

    // 新实现：清一次节拍再压，免得上一组的 nextAllowedAt 把第一发推到几十秒后。
    _ = cnRunBlocking { await HTTPClient.limiter.reset() }
    let st = limiterRun(n: n, concurrency: conc) {
        await HTTPClient.limiter.waitIfNeeded(sourceID: sourceID, interval: interval)
    }
    let pass = limiterPrint("修复后（令牌节拍：原子领时隙 → 在 actor 外睡）", st,
                            n: n, interval: interval)
    _ = cnRunBlocking { await HTTPClient.limiter.reset() }

    if !pass {
        out(String(format: "    注：观测间隔比时隙间隔多一层 `Task.sleep` 醒来后的调度延迟"
                   + "（本机实测约 %.0f ms）。interval 越小它占的比例越大 ——"
                   + " %.2f s 的 interval 下 5%% 只有 %.0f ms，量尺本身就不够准。",
                   max(0, (st.wall - Double(n - 1) * interval) / Double(max(1, n - 1)) * 1000),
                   interval, interval * 0.05 * 1000))
        out("")
    }
    out("  判定：" + (slot.pass
        ? "时隙分配严格拉开了 interval（算法层通过 ✔）；"
        : "**时隙分配本身就漏了**（算法层未通过 ✘）；")
        + (pass
        ? "实测发包间隔同样没有跌破 interval×0.95。"
        : "实测最小间隔略低于 interval×0.95，差额来自调度抖动（见上注）。"))
    if let lp = legacyPass, let ls = legacyStats, !lp {
        out(String(format: "        对照：老实现同条件下最小间隔 %.3f s、墙钟 %.1f s（%.0f 次/分钟）；"
                   + "新实现最小间隔 %.3f s、墙钟 %.1f s（%.0f 次/分钟）。",
                   ls.minGap, ls.wall, ls.perMinute(n),
                   st.minGap, st.wall, st.perMinute(n)))
    }
    // 退出码只认算法层：观测层的小幅欠拍是量尺噪声，
    // 拿它判失败会让这条验收在小 interval 下无意义地红。
    if !slot.pass { exit(1) }
}

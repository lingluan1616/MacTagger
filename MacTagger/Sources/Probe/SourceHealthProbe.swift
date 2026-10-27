//
//  SourceHealthProbe.swift
//  mactagger-probe — 数据源健康探测 + 故障注入
//
//  用法：
//    mactagger-probe sources health [--fail-source qq]
//
//  存在的理由：界面上的「数据源状态」面板得有一条不依赖 GUI 的验证路径 ——
//  否则「QQ 显示为挂了」到底是真挂了还是界面画错了，说不清。
//

import Foundation
import Network

// MARK: - 故障注入

/// 用同一个 id 覆盖注册表里的真源，让它必定抛错。
/// 用途：验证「单源故障只淘汰该源、其余照常」这条底线，以及结果条上的红色 chip 是否如实显示原因。
struct FailingSource: MetadataSource {
    let id: String
    let displayName: String
    let capabilities: SourceCapabilities
    let reason: String
    /// 抛哪一类错。用来验证结果条上的精简原因文案（超时 / HTTP 503 / retcode -1310 / 限流）。
    var kind: Kind = .network

    enum Kind: String {
        case network        // → 「超时」
        case business       // → 「retcode -1310」（QQ 缺 Referer 的实测态）
        case http           // → 「HTTP 503」
        case rate           // → 「限流」

        static func parse(_ s: String?) -> Kind { Kind(rawValue: s ?? "") ?? .network }
    }

    private var error: SourceError {
        switch kind {
        case .network:  return .network(reason)
        case .business: return .emptyResult(reason)
        case .http:     return .httpStatus(Int(reason) ?? 503)
        case .rate:     return .rateLimited
        }
    }

    func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] { throw error }
    func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate { throw error }
    func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? { throw error }
    func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? { throw error }
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? { throw error }
}

/// 注册全部源。`failSourceIDs` 里的源会被替换成必定抛错的替身。
func probeRegisterSources(failing failSourceIDs: [String] = [],
                          reason: String = "模拟超时",
                          kind: FailingSource.Kind = .network) {
    let reg = SourceRegistry.shared
    reg.registerChineseBuiltIns()
    reg.register(ITunesSource(countryCode: "CN"))
    reg.register(MusicBrainzSource())
    reg.register(CoverArtArchiveSource())

    for id in failSourceIDs {
        let caps = reg.source(id: id)?.capabilities ?? [.searchTracks]
        let name = (reg.source(id: id)?.displayName ?? id) + "（模拟故障）"
        reg.register(FailingSource(id: id, displayName: name,
                                   capabilities: caps, reason: reason, kind: kind))
    }
}

/// 从 `--fail-source a,b` 取值。
func probeFailSourceIDs(_ args: [String]) -> [String] {
    guard let i = args.firstIndex(of: "--fail-source"), i + 1 < args.count else { return [] }
    return args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// `--fail-kind network|business|http|rate` 与 `--fail-reason "…"`。
func probeFailKind(_ args: [String]) -> FailingSource.Kind {
    guard let i = args.firstIndex(of: "--fail-kind"), i + 1 < args.count else { return .network }
    return FailingSource.Kind.parse(args[i + 1])
}

func probeFailReason(_ args: [String], kind: FailingSource.Kind) -> String {
    if let i = args.firstIndex(of: "--fail-reason"), i + 1 < args.count { return args[i + 1] }
    switch kind {
    case .network:  return "模拟超时"
    case .business: return "QQ 歌词接口返回 retcode:-1310（缺 Referer）"
    case .http:     return "503"
    case .rate:     return "触发限流"
    }
}

// MARK: - sources health

func cmdSourcesHealth(args: [String]) {
    let failing = probeFailSourceIDs(args)
    let kind = probeFailKind(args)
    probeRegisterSources(failing: failing, reason: probeFailReason(args, kind: kind), kind: kind)

    hr("数据源健康探测（sources health）")
    let ids = SourceHealth.defaultSourceIDs
    out("  探测曲目 : 华语「稻香 周杰伦」/ 英语「Blank Space Taylor Swift」")
    out("  参与的源 : \(ids.joined(separator: " "))")
    if !failing.isEmpty {
        out("  故障注入 : \(failing.joined(separator: " ")) → 必定抛 \(kind.rawValue) 类错误"
            + "（\(probeFailReason(args, kind: kind))）")
    }
    out("")

    let started = Date()
    let r = cnRunBlocking { () async -> ([SourceOutcome], [SourceHealthSnapshot]) in
        let outcomes = await SourceHealth.shared.testAll(ids)
        let snaps = await SourceHealth.shared.snapshots(ids: ids)
        return (outcomes, snaps)
    }
    guard case .success(let (outcomes, snaps)) = r else {
        out("  探测过程异常"); exit(1)
    }
    let elapsed = Date().timeIntervalSince(started)

    // 三态表
    out(healthRow("数据源", "状态", "最近结果", "平均延迟", "本次探测", "原因 / 命中"))
    out(String(repeating: "─", count: 118))
    let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.sourceID, $0) })
    for snap in snaps {
        let o = byID[snap.sourceID]
        let light: String
        switch snap.light(withTest: o) {
        case .ok:       light = "● 正常"
        case .degraded: light = "◐ 不稳定"
        case .down:     light = "✘ 异常"
        case .unknown:  light = "○ 未测"
        }
        let probe: String
        switch o?.status {
        case .hits(let n)?:   probe = "✔ \(n) 条"
        case .empty?:         probe = "○ 0 条"
        case .failed(let w)?: probe = "✘ \(w)"
        case .paused?:        probe = "⏸ 暂停中"
        case .skipped(let r)?: probe = "⇥ 跳过（\(r)）"
        case nil:             probe = "—"
        }
        let detail = (o?.detail ?? snap.lastFailure?.reason ?? "—")
            .replacingOccurrences(of: "\n", with: " ")
        out(healthRow(snap.displayName, light + (snap.pausedText.map { " " + $0 } ?? ""),
                      snap.recentSummary,
                      snap.latencyText, probe, String(detail.prefix(38))))
    }
    out("")
    out(String(format: "  合计耗时 %.2f 秒（串行探测，各源自己的限速也算在内）", elapsed))
    out("")

    // 结果条：界面顶部那一行 chips 的文本形态，逐字对齐
    out("  逐源结果条（界面 chips 的文字）：")
    out("    " + outcomes.inlineSummary)
    out("")

    // AZ 轮：多级降级链的源要把「当前走的哪一级」摊开
    // ——「数据源状态」面板 QQ 那一行显示的就是这一句，逐字一致。
    let routed = snaps.filter { $0.searchRouteText != nil }
    if !routed.isEmpty {
        out("  搜索路径（面板「源设置 · 搜索路径」那一列的文字）：")
        for s in routed {
            out("    \(s.displayName)：当前搜索路径：\(s.searchRouteText!)")
            if let b = s.searchRouteBreakdown { out("      各级命中：\(b)") }
        }
        out("")
    }

    // 结果条悬停里那一行（`SourceOutcome.routeLine`）
    for o in outcomes where o.routeLine != nil {
        out("  \(o.displayName)结果条悬停多出的一行：\(o.routeLine!)")
    }
    if outcomes.contains(where: { $0.routeLine != nil }) { out("") }

    let bad = outcomes.filter { $0.status.isFailure }
    if bad.isEmpty {
        out("  判定：没有源处于故障态。")
    } else {
        out("  判定：\(bad.count) 个源故障 —— " + bad.map { "\($0.displayName)（\($0.chipLabel)）" }
            .joined(separator: "，"))
        out("        其余 \(outcomes.count - bad.count) 个源照常返回，单源故障没有拖垮其它源。")
    }
}

private func healthRow(_ a: String, _ b: String, _ c: String,
                       _ d: String, _ e: String, _ f: String) -> String {
    "  " + hpad(a, 20) + hpad(b, 12) + hpad(c, 22) + hpad(d, 12) + hpad(e, 16) + f
}

/// 按显示宽度补空格（中文算 2 列）。
private func hpad(_ s: String, _ width: Int) -> String {
    let w = cnDisplayWidth(s)
    return s + String(repeating: " ", count: max(1, width - w))
}

// MARK: - sources stress —— 按「批量匹配」的真实调用形态压一个源

//
//  用法：
//    mactagger-probe sources stress <sourceID> [--files N] [--concurrency C]
//                                   [--no-lyrics] [--budget N]
//                                   [--interval <秒>] [--no-jitter]
//                                   [--simulate-hang <秒>] [--hang-timeout <秒>]
//
//  为什么要有它：用户报「批量匹配时 QQ 经常 ✘ 超时」，而单次 curl / `cnsource qq`
//  都是 2.4–3.0 s 正常返回。**单次探测压不出批量的病**：批量匹配对同一个源
//  同时开 `concurrency` 条线，每首歌还要发 2–3 发请求，压力形态完全不同。
//  这个子命令就是把 `AutoMatchService.matchAll` 对单个源的调用形态原样复刻出来：
//      searchTracks(20 个真实歌名) → fetchDetail(首选候选) → fetchLyrics(首选候选)
//  并把每一发请求的耗时、超时次数、失败类型记全，得到 p50/p90/max。
//
//  节流：请求之间的最小间隔由 `HTTPClient` 的 `SourcePolicy.minimumInterval` 保证
//  （本命令不绕过它）；另有 `--budget`（默认 150）硬上限，打满即停，绝不把对方打成封 IP。
//

/// 内置真实歌名表。**必须用真实存在的歌**：随机串会在第一发就 0 条返回，
/// 后面两发根本不会发，压出来的请求量只有真实批量的三分之一。
///
/// AZ 轮从 20 首扩到 60 首：任务要求「50 首连发」，而**同一首歌反复搜不算连发** ——
/// 中文源普遍有查询级缓存，重复词的第二发既不代表真实延迟也不代表真实风控压力。
/// 60 > 50 是留出余量，好让 `--files 50` 跑的是 50 首**互不相同**的歌。
let stressQueries: [(title: String, artist: String)] = [
    ("稻香", "周杰伦"), ("晴天", "周杰伦"), ("以父之名", "周杰伦"),
    ("红豆", "王菲"), ("匆匆那年", "王菲"), ("後来", "刘若英"),
    ("光年之外", "邓紫棋"), ("泡沫", "邓紫棋"), ("演员", "薛之谦"),
    ("成都", "赵雷"), ("南山南", "马頔"), ("董小姐", "宋冬野"),
    ("平凡之路", "朴树"), ("生如夏花", "朴树"), ("十年", "陈奕迅"),
    ("浮夸", "陈奕迅"), ("K歌之王", "陈奕迅"), ("倒带", "蔡依林"),
    ("小幸运", "田馥甄"), ("夜空中最亮的星", "逃跑计划"),
    // —— AZ 轮补的 40 首 ——
    ("青花瓷", "周杰伦"), ("七里香", "周杰伦"), ("夜曲", "周杰伦"),
    ("简单爱", "周杰伦"), ("兰亭序", "周杰伦"), ("东风破", "周杰伦"),
    ("彩虹", "周杰伦"), ("安静", "周杰伦"), ("烟花易冷", "周杰伦"),
    ("传奇", "王菲"), ("我愿意", "王菲"), ("流年", "王菲"),
    ("富士山下", "陈奕迅"), ("好久不见", "陈奕迅"), ("爱情转移", "陈奕迅"),
    ("画", "赵雷"), ("理想", "赵雷"), ("南方姑娘", "赵雷"),
    ("一次就好", "杨宗纬"), ("洋葱", "杨宗纬"), ("其实都没有", "杨宗纬"),
    ("大鱼", "周深"), ("化身孤岛的鲸", "周深"), ("光亮", "周深"),
    ("起风了", "买辣椒也用券"), ("离人愁", "李袁杰"), ("倒数", "邓紫棋"),
    ("倔强", "五月天"), ("突然好想你", "五月天"), ("温柔", "五月天"),
    ("知足", "五月天"), ("盛夏光年", "五月天"), ("我期待的不是雪", "隔壁老樊"),
    ("你要的全拿走", "隔壁老樊"), ("多远都要在一起", "邓紫棋"),
    ("喜欢你", "邓紫棋"), ("画心", "张靓颖"), ("我们说好的", "张靓颖"),
    ("卡布奇诺", "王力宏"), ("唯一", "王力宏"),
]

struct StressSample: Sendable {
    var index: Int
    var phase: String            // search / detail / lyrics
    var elapsed: TimeInterval
    var kind: Kind
    var note: String?

    enum Kind: String, Sendable {
        case ok         // 有结果
        case empty      // 请求成功但业务层空
        case timeout    // 超时
        case paused     // 熔断暂停，立即返回（改造后才可能出现）
        case other      // 其它失败
    }
}

actor StressCollector {
    private(set) var samples: [StressSample] = []
    private(set) var spent = 0
    private let budget: Int

    init(budget: Int) { self.budget = budget }

    /// 领一个请求配额。返回 false 表示预算打满，调用方必须停手。
    func take() -> Bool {
        guard spent < budget else { return false }
        spent += 1
        return true
    }
    func add(_ s: StressSample) { samples.append(s) }
}

/// 分位数（最近秩法）。样本少时也不会算出越界。
func stressPercentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
    guard !sorted.isEmpty else { return 0 }
    let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
    return sorted[min(sorted.count - 1, rank - 1)]
}

func stressIntArg(_ args: [String], _ flag: String, _ fallback: Int) -> Int {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count,
          let v = Int(args[i + 1]) else { return fallback }
    return v
}

func stressDoubleArg(_ args: [String], _ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    // 允许写成 20s
    let raw = args[i + 1].replacingOccurrences(of: "s", with: "")
    return Double(raw)
}

func cmdSourcesStress(args: [String]) {
    guard args.count > 2 else {
        fail("用法: sources stress <sourceID> [--files N] [--concurrency C] [--no-lyrics]"
             + " [--budget N] [--interval 秒] [--no-jitter]")
    }
    let sourceID = args[2]
    let files = max(1, min(stressQueries.count, stressIntArg(args, "--files", 20)))
    let conc = max(1, min(8, stressIntArg(args, "--concurrency", 1)))
    let wantLyrics = !args.contains("--no-lyrics")
    let budget = max(1, stressIntArg(args, "--budget", 150))
    // `--legacy`：把这一个源还原成 AU 轮改造**之前**的行为（QQ timeout 15 s、
    // minimumInterval 0.3 s、超时按 0.5 s→1 s 立刻重试、无熔断），用来做前后对照。
    // 只有对照组用它；正式路径读不到这个开关。
    let legacy = args.contains("--legacy")
    // `--simulate-hang N [--hang-timeout T]`：让 QQ 的每一发请求人为挂起 N 秒。
    // 这是复现用户那句「批量时经常 ✘ 超时」的唯一可控手段 —— 真实的间歇性变慢
    // 不受我们控制，等它自己犯病既不可重复也不礼貌。
    let hang = stressDoubleArg(args, "--simulate-hang")
    let hangTimeout = stressDoubleArg(args, "--hang-timeout")
    // AZ 轮加的两个拨盘：把「间隔」与「抖动」拿到命令行上，好用同一个二进制跑
    // 0.3 / 0.5 / 1.0 s × 并发 1 / 4 的对照表。**只对 QQ 生效**
    // （policyOverride 是 QQ 专用的注入点，别的源改不了，也不该在压测里被偷偷改掉）。
    let intervalOverride = stressDoubleArg(args, "--interval")
    let noJitter = args.contains("--no-jitter")

    probeRegisterSources()
    if sourceID == "qq", intervalOverride != nil || noJitter {
        var p = SourcePolicy.qq()
        if let iv = intervalOverride { p.minimumInterval = max(0, iv) }
        if noJitter { p.jitter = nil }
        QQTestHooks.shared.policyOverride = p
        SourceRegistry.shared.register(QQSource())
    }
    if sourceID == "itunes" {
        // 整碟缓存会让「实发请求数」在两组对照之间不可比，压测前一律清空。
        _ = cnRunBlocking { await ITunesAlbumCache.shared.reset() }
        ITunesSource.policyOverride = legacy ? ITunesSource.legacyPolicy : nil
        SourceRegistry.shared.register(ITunesSource.configured(country: SourceBootstrapCountryForProbe))
    }
    if legacy, sourceID == "qq" {
        var old = SourcePolicy.chinese(referer: "https://y.qq.com/")
        old.timeout = 15
        old.minimumInterval = 0.3
        old.networkMaxRetries = 2
        old.networkInitialBackoff = 0.5
        QQTestHooks.shared.policyOverride = old
        SourceRegistry.shared.register(QQSource())
    }
    if legacy {
        _ = cnRunBlocking { await SourceCircuitBreaker.shared.setEnabled(false) }
    } else {
        _ = cnRunBlocking {
            await SourceCircuitBreaker.shared.setEnabled(true)
            await SourceCircuitBreaker.shared.reset()
        }
    }
    if let t = hangTimeout { QQTestHooks.shared.timeoutOverride = t }
    if hang != nil || hangTimeout != nil { SourceRegistry.shared.register(QQSource()) }
    QQTestHooks.shared.hangSeconds = hang
    QQTestHooks.shared.resetCount()
    guard let src = SourceRegistry.shared.source(id: sourceID) else {
        fail("未注册的源：\(sourceID)")
    }

    cnHR("\(src.displayName) 压力测试（sources stress）")
    out("  源          : \(sourceID)（\(src.displayName)）")
    out("  查询词      : \(files) 个（内置真实歌名表）")
    out("  并发        : \(conc) 条线同时压这一个源")
    out("  调用形态    : searchTracks → fetchDetail(首选候选)"
        + (wantLyrics ? " → fetchLyrics(首选候选)" : "（本次不取歌词）"))
    out("  请求预算    : \(budget) 发（打满即停）")
    out("  熔断        : " + (legacy ? "**关闭**（--legacy 对照组，还原改造前行为）" : "开启"))
    if let h = hang {
        out("  模拟挂起    : 每发请求人为挂起 \(Int(h)) 秒（挂起 ≥ timeout 即判超时）")
    }
    out(stressPolicyLine(sourceID))
    if sourceID == "qq" {
        let j = QQSource.currentPolicy.jitter
        out("  发包抖动    : " + (j.map { String(format: "%.1f–%.1f s", $0.lowerBound, $0.upperBound) }
                                 ?? "关闭"))
        QQSearchTelemetry.shared.reset()
    }
    out("")

    let collector = StressCollector(budget: budget)
    let wall = Date()

    let r = cnRunBlocking { () async -> Int in
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func submit() {
                guard next < files else { return }
                let idx = next; next += 1
                let q = stressQueries[idx]
                group.addTask {
                    await stressOneFile(idx: idx, title: q.title, artist: q.artist,
                                        src: src, wantLyrics: wantLyrics,
                                        collector: collector)
                }
            }
            for _ in 0..<min(conc, files) { submit() }
            for await _ in group { submit() }
        }
        return await collector.spent
    }
    guard case .success(let spent) = r else { out("  压测过程异常"); return }
    let elapsed = Date().timeIntervalSince(wall)

    let samples = cnRunBlocking { await collector.samples }
    guard case .success(let all) = samples else { return }
    stressReport(all, wall: elapsed, spent: spent, budget: budget)

    if !legacy {
        let st = cnRunBlocking { await SourceCircuitBreaker.shared.stats(sourceID) }
        if case .success(let c) = st, c.trips > 0 || c.rejected > 0 {
            out("")
            out("  熔断账：开闸 \(c.trips) 次，被立即拒绝 \(c.rejected) 发，当前状态 \(c.stateText)")
        }
    }
    if hang != nil {
        out("  底层实际发出的请求数（钩子计数）: \(QQTestHooks.shared.hangCount) 发"
            + "　←　熔断关闭时它等于「调用数 ×(1+重试数)」，开启后会被截断")
    }

    // AZ 轮：验收线判定。只看 search 这一阶段 ——
    // 「有效返回率」问的是「这个源到底认不认我们这次搜索」，
    // detail/lyrics 是拿到候选之后的事，混进来会把分母搅浑。
    stressEffectiveVerdict(all, sourceID: sourceID)

    QQTestHooks.shared.hangSeconds = nil
    QQTestHooks.shared.timeoutOverride = nil
    QQTestHooks.shared.policyOverride = nil
    if sourceID == "itunes" {
        ITunesSource.policyOverride = nil
        SourceRegistry.shared.register(ITunesSource.configured(country: SourceBootstrapCountryForProbe))
    }
}

/// probe 里 iTunes 用哪个地区。压测要的是「限流打不打得出来」，
/// 用自动档最贴近用户默认设置。
let SourceBootstrapCountryForProbe = ITunesSource.Region.automatic

/// 验收线：**默认配置下有效返回率 ≥ 90%**。
///
/// 「有效返回」= `searchTracks` 交出了至少一条候选。空结果、超时、熔断拒绝、其它失败
/// 一律算无效 —— 对用户而言这四种情况长得一样：QQ 那一格是空的。
/// 分母是**发起过的搜索次数**（预算打满而根本没发的那些不算，它们不是失败）。
func stressEffectiveVerdict(_ all: [StressSample], sourceID: String) {
    let search = all.filter { $0.phase == "search" }
    guard !search.isEmpty else { return }
    let ok = search.filter { $0.kind == .ok }.count
    let rate = Double(ok) / Double(search.count)
    out("")
    out(String(format: "  ★ 有效返回率（search 阶段）：%d/%d = %.1f%%　验收线 ≥ 90%% → %@",
               ok, search.count, rate * 100,
               rate >= 0.90 ? "达标" : "**未达标**"))
    let by = Dictionary(grouping: search, by: \.kind.rawValue).mapValues(\.count)
    let breakdown = ["ok", "empty", "timeout", "paused", "other"]
        .compactMap { k -> String? in by[k].map { "\(k) \($0)" } }
        .joined(separator: " · ")
    out("    构成：" + breakdown)

    if sourceID == "qq" {
        let t = QQSearchTelemetry.shared.snapshot
        out("    " + t.line)
        if let b = t.pathBreakdown { out("    各级命中：" + b) }
        if let n = t.lastNote { out("    最近一次全空的原因：" + n) }
    }
}

func stressPolicyLine(_ sourceID: String) -> String {
    // 各源的策略是适配器里写死的，这里按 id 复述一遍，方便前后对照时看清改了什么。
    let p: SourcePolicy
    switch sourceID {
    case "musicbrainz": p = .musicBrainz
    case "qq":          p = QQSource.currentPolicy
    case "itunes":      p = ITunesSource.effectivePolicy
    default:            p = .chinese()
    }
    let perMin = p.minimumInterval > 0 ? 60.0 / p.minimumInterval : 0
    return String(format: "  网络策略    : minimumInterval=%.2fs（≈%.0f 次/分钟）"
                  + "  timeout=%.0fs  maxRetries=%d  限流码=%@",
                  p.minimumInterval, perMin, p.timeout, p.maxRetries,
                  p.rateLimitStatusCodes.sorted().map(String.init).joined(separator: "/"))
}

/// 一个「文件」的三发请求，严格按批量匹配的顺序串行发。
func stressOneFile(idx: Int, title: String, artist: String,
                   src: any MetadataSource, wantLyrics: Bool,
                   collector: StressCollector) async {
    var q = TrackQuery()
    q.title = title; q.artist = artist
    q.filename = "\(title) \(artist)"

    // ① 搜索
    guard await collector.take() else { return }
    var t0 = Date()
    var picked: TrackCandidate?
    do {
        let found = try await src.searchTracks(q, limit: 8)
        picked = MatchScorer.best(found, for: q) ?? found.first
        await collector.add(StressSample(index: idx, phase: "search",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: found.isEmpty ? .empty : .ok,
                                         note: "\(title) — \(found.count) 条"))
    } catch {
        await collector.add(StressSample(index: idx, phase: "search",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: stressKind(error),
                                         note: "\(title)：\(SourceOutcome.shortReason(for: error))"))
        return
    }
    guard let cand = picked else { return }

    // ② 详情（批量匹配只对最终选中的那一条发）
    guard await collector.take() else { return }
    t0 = Date()
    do {
        let d = try await src.fetchDetail(cand)
        await collector.add(StressSample(index: idx, phase: "detail",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: .ok,
                                         note: "\(title)：年份=\(d.year ?? "-") 音轨=\(d.trackNumber ?? "-")"))
    } catch {
        await collector.add(StressSample(index: idx, phase: "detail",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: stressKind(error),
                                         note: "\(title)：\(SourceOutcome.shortReason(for: error))"))
    }

    // ③ 歌词
    guard wantLyrics, src.capabilities.contains(.lyrics) else { return }
    guard await collector.take() else { return }
    t0 = Date()
    do {
        let l = try await src.fetchLyrics(cand)
        await collector.add(StressSample(index: idx, phase: "lyrics",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: (l?.isEmpty ?? true) ? .empty : .ok,
                                         note: "\(title)：\((l?.plain?.count ?? 0)) 字"))
    } catch {
        await collector.add(StressSample(index: idx, phase: "lyrics",
                                         elapsed: Date().timeIntervalSince(t0),
                                         kind: stressKind(error),
                                         note: "\(title)：\(SourceOutcome.shortReason(for: error))"))
    }
}

func stressKind(_ error: Error) -> StressSample.Kind {
    if let se = error as? SourceError {
        switch se {
        case .circuitOpen:                        return .paused
        case .network(let m):
            let s = m.lowercased()
            if s.contains("timed out") || s.contains("timeout") || m.contains("超时") { return .timeout }
            return .other
        default: return .other
        }
    }
    return .other
}

func stressReport(_ all: [StressSample], wall: TimeInterval, spent: Int, budget: Int) {
    out("  阶段     请求  有结果  空  超时  暂停  其它  p50      p90      max      平均")
    out("  " + String(repeating: "─", count: 84))
    for phase in ["search", "detail", "lyrics"] {
        let s = all.filter { $0.phase == phase }
        guard !s.isEmpty else { continue }
        out("  " + stressRow(phase, s))
    }
    if !all.isEmpty { out("  " + stressRow("合计", all)) }
    out("")

    let bad = all.filter { $0.kind == .timeout || $0.kind == .other || $0.kind == .paused }
    if bad.isEmpty {
        out("  失败明细：无")
    } else {
        out("  失败明细（\(bad.count) 条）：")
        for b in bad.sorted(by: { $0.index < $1.index }) {
            out(String(format: "    [%02d] %-7s %-6s %6.2fs  %@",
                       b.index, (b.phase as NSString).utf8String!,
                       (b.kind.rawValue as NSString).utf8String!,
                       b.elapsed, b.note ?? ""))
        }
    }
    out("")
    let timeouts = all.filter { $0.kind == .timeout }.count
    let failed = all.filter { $0.kind != .ok && $0.kind != .empty }.count
    out(String(format: "  合计墙钟 %.1f 秒，实发请求 %d / 预算 %d；超时 %d 次，失败率 %.1f%%",
               wall, spent, budget, timeouts,
               all.isEmpty ? 0 : Double(failed) / Double(all.count) * 100))
    // 实测发包速率。限速器到底有没有生效，只有这个数说了算 ——
    // 声称的 minimumInterval 是意图，这一行是事实。
    if wall > 0 {
        out(String(format: "  ★ 实测发包速率：%.1f 次/分钟（%d 发 / %.1f 秒）",
                   Double(spent) / wall * 60, spent, wall))
    }

    // BD 轮的验收口径：iTunes 超频时回的是 **403**（不是 429）。
    // 单独把它数出来 —— 「限流几次」是这一轮改造前后唯一要看的那个数。
    let throttled = all.filter { s in
        guard let n = s.note else { return false }
        return n.contains("403") || n.contains("429") || n.contains("限流")
    }
    out("  ★ 限流（403 / 429 / 已判限流）计数：\(throttled.count) 次"
        + (throttled.isEmpty ? "" : "　←　改前对照请看报告"))
}

func stressRow(_ label: String, _ s: [StressSample]) -> String {
    let lat = s.map(\.elapsed).sorted()
    let ok = s.filter { $0.kind == .ok }.count
    let empty = s.filter { $0.kind == .empty }.count
    let to = s.filter { $0.kind == .timeout }.count
    let pa = s.filter { $0.kind == .paused }.count
    let other = s.filter { $0.kind == .other }.count
    let avg = lat.isEmpty ? 0 : lat.reduce(0, +) / Double(lat.count)
    return cnPad(label, 8)
        + cnPad("\(s.count)", 6) + cnPad("\(ok)", 8) + cnPad("\(empty)", 4)
        + cnPad("\(to)", 6) + cnPad("\(pa)", 6) + cnPad("\(other)", 6)
        + String(format: "%-9.2f%-9.2f%-9.2f%.2f",
                 stressPercentile(lat, 0.5), stressPercentile(lat, 0.9),
                 lat.last ?? 0, avg)
}

// MARK: - sources circuit —— 熔断三态 + 批量补查实测

//
//  用法：
//    mactagger-probe sources circuit [--simulate-hang 20] [--hang-timeout 3]
//                                    [--pause 60] [--requests 6] [--batch 8]
//
//  验四件事，一件都不许含糊：
//    ① 连续 3 次超时 → 闸开（`stateText` 从「关闭」变成「开闸(暂停 Ns)」）
//    ② 开闸后的请求**立即**返回 `.circuitOpen`（耗时以毫秒计，不是等到超时）
//    ③ 到期半开：放一发探测，成功则恢复
//    ④ `AutoMatchService.matchAll` 结束时对「因暂停跳过」的文件自动补查一轮
//
//  挂起是**模拟**的（`QQTestHooks`），但超时语义与真实 URLSession 一致：
//  挂起时长 ≥ timeout 就在 timeout 时刻抛 NSURLErrorTimedOut。
//  `--hang-timeout` 把 QQ 的 25 s timeout 临时调小，只为让这个演示几十秒能跑完，
//  被验证的熔断逻辑一行都没有为测试改过。
//

func cmdSourcesCircuit(args: [String]) {
    let hang = stressDoubleArg(args, "--simulate-hang") ?? 20
    let hangTimeout = stressDoubleArg(args, "--hang-timeout") ?? 3
    let pause = stressDoubleArg(args, "--pause") ?? 60
    let requests = stressIntArg(args, "--requests", 6)
    let batchN = stressIntArg(args, "--batch", 8)

    probeRegisterSources()
    QQTestHooks.shared.timeoutOverride = hangTimeout
    // 重新注册一遍，让 QQSource 用调小后的 timeout 重建 HTTPClient。
    SourceRegistry.shared.register(QQSource())

    cnHR("熔断三态实测（sources circuit）")
    out("  模拟挂起    : QQ 每发请求挂起 \(Int(hang)) 秒")
    out("  QQ timeout  : \(Int(hangTimeout)) 秒（演示用，正式值 25 秒）→ 挂起 ≥ timeout 即判超时")
    out("  熔断参数    : 连续 3 次超时开闸，暂停 \(Int(pause)) 秒，半开探测失败则翻倍（上限 300 秒）")
    out("")

    let r = cnRunBlocking { () async -> Bool in
        await SourceCircuitBreaker.shared.reset("qq")
        await SourceCircuitBreaker.shared.configure(
            "qq", CircuitPolicy(timeoutThreshold: 3, window: 120,
                                basePause: pause, maxPause: 300))
        guard let qq = SourceRegistry.shared.source(id: "qq") else { return false }

        // ── ① / ② 开闸与立即返回 ────────────────────────────────────────
        QQTestHooks.shared.hangSeconds = hang
        QQTestHooks.shared.resetCount()
        out("① 挂起状态下连发 \(requests) 次搜索：")
        out("   #  耗时      结果                          熔断状态          窗口内超时  已拒绝")
        out("   " + String(repeating: "─", count: 88))
        var firstRejectElapsed: TimeInterval = .greatestFiniteMagnitude
        var openedAt = -1
        for i in 1...requests {
            let t0 = Date()
            var text = "✔ 有结果"
            do { _ = try await qq.searchTracks(SourceHealth.chineseProbe, limit: 5) }
            catch { text = "✘ " + SourceOutcome.shortReason(for: error) }
            let el = Date().timeIntervalSince(t0)
            let st = await SourceCircuitBreaker.shared.stats("qq")
            if st.isPaused, openedAt < 0 { openedAt = i }
            if text.contains("暂停中") { firstRejectElapsed = min(firstRejectElapsed, el) }
            out("   " + cnPad("\(i)", 3)
                + cnPad(String(format: "%.3f s", el), 10)
                + cnPad(text, 30) + cnPad(st.stateText, 18)
                + cnPad("\(st.timeoutsInWindow)", 12) + "\(st.rejected)")
        }
        let afterOpen = await SourceCircuitBreaker.shared.stats("qq")
        out("")
        out("   钩子实际拦下并挂起的请求数 : \(QQTestHooks.shared.hangCount) 发"
            + "（开闸后就不再有请求出去了）")
        out("   闸在第 \(openedAt) 发请求时打开；此后被立即拒绝的请求最快 "
            + String(format: "%.4f 秒返回（不是等到 %.0f 秒超时）", firstRejectElapsed, hangTimeout))
        out("   判定 ① 连续 3 次超时开闸       : \(afterOpen.trips >= 1 ? "✔ 通过" : "✘ 未通过")")
        out("   判定 ② 开闸后请求即时返回      : "
            + (firstRejectElapsed < 0.2 ? "✔ 通过" : "✘ 未通过"))
        out("")

        // 界面口径：结果条 chip 与数据源面板这一刻各显示什么
        let pausedOutcome = SourceOutcome.failure(
            "qq", SourceError.circuitOpen("qq", afterOpen.pausedUntil ?? Date(),
                                          afterOpen.pauseReason))
        let snap = await SourceHealth.shared.snapshot("qq")
        out("   界面此刻显示：")
        out("     · 结果条 chip     : \(pausedOutcome.chipLabel)（灰橙）")
        out("     · chip 悬停提示   : "
            + pausedOutcome.helpText.replacingOccurrences(of: "\n", with: " / "))
        out("     · 数据源面板状态列: \(snap.pausedText ?? "—")"
            + "　熔断次数 \(snap.circuitTrips)　最近结果 \(snap.recentSummary)")
        out("     · 台账未被暂停污染: 最近 \(snap.sampleCount) 次里失败 \(snap.failedCount) 次"
            + "（\(afterOpen.rejected) 发被拒的请求一条都没记进去）")
        out("")

        // ── ③ 半开恢复 ─────────────────────────────────────────────────
        QQTestHooks.shared.hangSeconds = nil        // 对方「恢复正常」了
        let wait = max(0, (afterOpen.pausedUntil?.timeIntervalSinceNow ?? 0))
        out(String(format: "③ 等待暂停到期（还剩 %.0f 秒）后放一发探测……", wait))
        // 到期前先证明「确实还在拒」
        if wait > 2 {
            let t0 = Date()
            var mid = "✔"
            do { _ = try await qq.searchTracks(SourceHealth.chineseProbe, limit: 5) }
            catch { mid = "✘ " + SourceOutcome.shortReason(for: error) }
            out(String(format: "   到期前再打一发：%@（%.4f 秒）——仍在拒绝", mid,
                       Date().timeIntervalSince(t0)))
        }
        await SourceCircuitBreaker.shared.waitUntilRecovered("qq", cap: pause + 5)
        let halfOpen = await SourceCircuitBreaker.shared.stats("qq")
        out("   到期时熔断状态 : \(halfOpen.stateText)")

        let t0 = Date()
        var probeText = "✘"
        var probeOK = false
        do {
            let found = try await qq.searchTracks(SourceHealth.chineseProbe, limit: 5)
            probeText = "✔ \(found.count) 条"
            probeOK = !found.isEmpty
        } catch { probeText = "✘ " + SourceOutcome.shortReason(for: error) }
        let after = await SourceCircuitBreaker.shared.stats("qq")
        out(String(format: "   半开探测请求 : %@（%.2f 秒）", probeText, Date().timeIntervalSince(t0)))
        out("   探测后熔断状态 : \(after.stateText)")
        out("   判定 ③ 半开探测成功即恢复      : "
            + ((probeOK && !after.isPaused) ? "✔ 通过" : "✘ 未通过"))
        out("")

        // ── ④ 批量补查 ────────────────────────────────────────────────
        out("④ 批量补查：\(batchN) 个文件跑 matchAll，前几首把 QQ 打熔断，"
            + "跑完后自动对被跳过的文件只用 QQ 再补一轮")
        await SourceCircuitBreaker.shared.reset("qq")
        await SourceCircuitBreaker.shared.configure(
            "qq", CircuitPolicy(timeoutThreshold: 3, window: 120,
                                basePause: 5, maxPause: 300))
        out("   （补查这一段把暂停时长临时设成 5 秒，否则要等满 \(Int(pause)) 秒才轮到补查）")
        QQTestHooks.shared.hangSeconds = hang
        QQTestHooks.shared.resetCount()

        // 在挂起持续 6 秒后放开 —— 模拟「对方缓过来了」，好让补查真的能拿到结果。
        Task.detached {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            QQTestHooks.shared.hangSeconds = nil
        }

        let files = (0..<batchN).map { i -> AudioFile in
            let q = stressQueries[i % stressQueries.count]
            return AudioFile(url: URL(fileURLWithPath: "/tmp/circuit-probe/\(i)-\(q.title).flac"),
                             tags: Tags(title: q.title, artist: q.artist),
                             technical: AudioTechnicalInfo(durationMilliseconds: 0))
        }
        var opts = AutoMatchOptions(sourceIDs: ["qq", "netease"],
                                    fetchArtwork: false, fetchLyrics: false,
                                    limitPerSource: 5, concurrency: 4)
        opts.fields = [.title, .artist, .album, .year]
        let (results, _) = await AutoMatchService.matchAll(files, options: opts)

        let pausedNow = results.filter { r in
            r.sourceOutcomes.contains { $0.sourceID == "qq" && $0.status.isPaused }
        }.count
        let backfilled = results.filter { r in
            r.sourceOutcomes.contains { $0.sourceID == "qq"
                && ($0.detail?.contains("补查") ?? false) }
        }.count
        out("")
        out("   逐文件 QQ 结果条：")
        for (i, r) in results.enumerated() {
            let o = r.sourceOutcomes.first { $0.sourceID == "qq" }
            out("     [\(i)] \(cnPad(files[i].tags.title ?? "?", 12))"
                + cnPad(o?.chipLabel ?? "—", 18)
                + "  \(o?.detail ?? "")")
        }
        let note = SourceOutcomeAggregator.batchNote(results.map(\.sourceOutcomes))
        out("")
        out("   批量统计追加行 : \(note ?? "（无）")")
        out("   仍处「暂停未查询」的文件 : \(pausedNow) 个")
        out("   被补查改写过结果条的文件 : \(backfilled) 个")
        out("   判定 ④ 批量结束后补查生效      : "
            + (backfilled > 0 ? "✔ 通过" : (pausedNow == 0 ? "✔ 通过（本轮没有文件被暂停跳过）" : "✘ 未通过")))

        QQTestHooks.shared.hangSeconds = nil
        QQTestHooks.shared.timeoutOverride = nil
        return true
    }
    if case .failure = r { out("  演示过程异常") }
}

// MARK: - sources ratelimit：限流状态机的离线验收

/// `sources ratelimit [sourceID]`
///
/// **不联网**地验证 BD 轮那条「403/429 → 限流 → 退避 + 熔断 → 结果条说人话」的链路。
///
/// 为什么不用实网压测来验：想看见 403 就得**故意超频去撞 Apple**，那既不礼貌也不可重复
/// （同一台机器同一时段，60 次/分钟跑两轮都没被限）。
/// 而这条链路里我们自己写的部分（分类、状态机、文案）是确定性的，离线验才验得准。
func cmdSourcesRateLimit(args: [String]) {
    let sourceID = args.count > 2 ? args[2] : "itunes"
    cnHR("限流状态机验收（sources ratelimit）")

    let p = sourceID == "itunes" ? ITunesSource.effectivePolicy : SourcePolicy.default
    out("  源            : \(sourceID)（\(SourceOutcome.displayName(sourceID))）")
    out(String(format: "  发包间隔      : %.2f s（≈%.0f 次/分钟）  Apple 建议 ≈20 次/分钟",
               p.minimumInterval, p.minimumInterval > 0 ? 60 / p.minimumInterval : 0))
    out("  判为限流的状态码: "
        + p.rateLimitStatusCodes.sorted().map(String.init).joined(separator: " / ")
        + (p.rateLimitStatusCodes.contains(403) ? "　←　403 是 iTunes 超频时的实际返回码" : ""))
    out("  限流退避      : \(p.maxRetries) 次，"
        + String(format: "%.1f s 起步、逐次翻倍", p.initialBackoff))
    out("")

    _ = cnRunBlocking {
        await SourceCircuitBreaker.shared.setEnabled(true)
        await SourceCircuitBreaker.shared.reset()
        await SourceCircuitBreaker.shared.configure(sourceID, p.circuit)
    }

    out("  ① 退避重试到底仍被限流 → 记一次限流")
    let tripped = cnRunBlocking { await SourceCircuitBreaker.shared.recordRateLimited(sourceID, status: 403) }
    guard case .success(let didTrip) = tripped else { out("  内部错误"); return }
    out("     开闸？ \(didTrip ? "是" : "否")　←　限流**一次就开闸**（对方已明说太快，再撞只会把窗口续上）")

    let st = cnRunBlocking { await SourceCircuitBreaker.shared.stats(sourceID) }
    guard case .success(let c) = st else { return }
    out("     暂停原因: \(c.pauseReason ?? "-")")
    out("     暂停至  : +\(Int((c.pausedUntil?.timeIntervalSinceNow ?? 0).rounded())) 秒")
    out("")

    out("  ② 暂停期间再来一发 → 本地立即拒绝，一个字节都不发出去")
    let dec = cnRunBlocking { await SourceCircuitBreaker.shared.acquire(sourceID) }
    if case .success(let d) = dec {
        switch d {
        case .reject(let until):
            out("     acquire → reject，恢复时刻 +\(Int(until.timeIntervalSinceNow.rounded())) 秒 ✔")
        case .allow: out("     acquire → allow ✘（不该发生）")
        case .probe: out("     acquire → probe ✘（不该发生）")
        }
    }
    out("")

    out("  ③ 界面口径：这一刻结果条与统计各显示什么")
    let err = SourceError.circuitOpen(sourceID, c.pausedUntil ?? Date(), c.pauseReason)
    let o = SourceOutcome.failure(sourceID, err, latency: 0.01)
    out("     结果条 chip : \(o.chipLabel)")
    out("     是否判失败  : \(o.status.isFailure ? "是 ✘" : "否 ✔（限流不是失败）")")
    out("     判为限流    : \(o.isRateLimited ? "是 ✔" : "否 ✘")")
    for line in o.helpText.components(separatedBy: "\n") { out("     悬停        : " + line) }
    out("")

    out("  ④ 对照：「搜到了 0 条」不该是红 ✘")
    let empty = SourceOutcome.failure(sourceID, SourceError.emptyResult("该地区曲库无此曲"), latency: 0.4)
    out("     结果条 chip : \(empty.chipLabel)")
    out("     是否判失败  : \(empty.status.isFailure ? "是 ✘（回归了！）" : "否 ✔")")
    for line in empty.helpText.components(separatedBy: "\n") { out("     悬停        : " + line) }
    out("")

    out("  ⑤ 对照：QQ 日文曲名 0 条")
    let qq = SourceOutcome.failure("qq", SourceError.emptyResult("QQ 四级搜索都没给出候选"), latency: 1.2)
    out("     结果条 chip : \(qq.chipLabel)　tint=\(qq.tint)")
    for line in qq.helpText.components(separatedBy: "\n") { out("     悬停        : " + line) }

    _ = cnRunBlocking { await SourceCircuitBreaker.shared.reset() }
}

// MARK: - sources halfopen —— 半开探测失败不锁死（BP-G 轮，BO 报告 #3 回归）

//
//  用法：
//    mactagger-probe sources halfopen
//
//  完全离线：进程内起一个只绑 127.0.0.1 的假 HTTP 服务（/s429 → 429、/s503 → 503、
//  /slow → 0.8 s 后 200、其余 200），连接被拒用 `HTTPClient.gate` 抛 CannotConnectToHost 模拟。
//  走的是生产路径上的 `HTTPClient.send` + `SourceCircuitBreaker`，一行没为测试改过。
//
//  验五件事：
//    A 探测撞 503（退避重试后仍 503）→ 回到开闸态、暂停翻倍、倒计时如实；到期后放行并成功
//    B 探测撞「连接被拒」→ 同上
//    C 探测反复撞 429 → 探测内不重试，暂停 2→4→4 封顶；到期后恢复
//    D 探测在飞时：其余请求本地拒绝、面板显示「⏸ 探测中」、拒绝文案说「正在探测是否恢复」
//      而不是「已暂停 0 秒后自动恢复」（BP-H）；探测成功后关闭
//    E 占位丢失自愈：探测占位超过 probeStaleAfter 未交还 → 下一发重新领探测，不锁死
//

/// 进程内假 HTTP 服务。只绑回环地址（不会触发防火墙弹窗，也不对外暴露）。
final class HalfOpenFakeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bpg.fake-http")
    private let lock = NSLock()
    private var hits: [String] = []

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// 启动并返回端口；5 秒内没起来返回 0。
    func start() -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { st in
            switch st {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    var log: [String] { lock.lock(); defer { lock.unlock() }; return hits }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = String(decoding: data ?? Data(), as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var code = 200
            if path.hasPrefix("/s429") { code = 429 } else if path.hasPrefix("/s503") { code = 503 }
            let delay: Double = path.hasPrefix("/slow") ? 0.8 : 0
            self.lock.lock(); self.hits.append("\(path) \(code)"); self.lock.unlock()
            self.queue.asyncAfter(deadline: .now() + delay) {
                let body = "{\"ok\":true}"
                let resp = "HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
}

func cmdSourcesHalfOpen(args: [String]) {
    hr("半开探测失败不锁死（sources halfopen，BO 报告 #3 回归）")
    let server: HalfOpenFakeServer
    do { server = try HalfOpenFakeServer() } catch { fail("假服务创建失败：\(error)") }
    let port = server.start()
    guard port > 0 else { fail("假服务没起来") }
    out("  假服务 : 127.0.0.1:\(port)（进程内，只绑回环）")
    out("  熔断参数: basePause 1 s、maxPause 4 s（演示用；正式值 60 s / 300 s）")
    out("")

    let r = cnRunBlocking { () async -> [(String, Bool)] in
        var verdicts: [(String, Bool)] = []
        func verdict(_ name: String, _ ok: Bool) {
            verdicts.append((name, ok)); out("   判定 \(name): \(ok ? "✔ 通过" : "✘ 未通过")")
        }
        func u(_ p: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(p)")! }
        let pol = CircuitPolicy(timeoutThreshold: 3, window: 120, basePause: 1, maxPause: 4)
        func client(_ sid: String, retries: Int = 2,
                    gate: (@Sendable (TimeInterval) async throws -> Void)? = nil) -> HTTPClient {
            HTTPClient(sourceID: sid,
                       policy: SourcePolicy(minimumInterval: 0, maxRetries: retries, initialBackoff: 0.1,
                                            networkMaxRetries: 1, networkInitialBackoff: 0.1, circuit: pol),
                       gate: gate)
        }
        @discardableResult
        func hit(_ c: HTTPClient, _ p: String, _ tag: String) async -> Bool {
            let t0 = Date()
            do {
                _ = try await c.get(u(p))
                out(String(format: "   %@ %@ → ✔ 200（%.2f s）", tag, p, Date().timeIntervalSince(t0)))
                return true
            } catch {
                out(String(format: "   %@ %@ → ✘ %@（%.2f s）「%@」", tag, p,
                           SourceOutcome.shortReason(for: error), Date().timeIntervalSince(t0),
                           error.localizedDescription))
                return false
            }
        }
        @discardableResult
        func show(_ sid: String, _ tag: String) async -> (CircuitStats, SourceHealthSnapshot) {
            let s = await SourceCircuitBreaker.shared.stats(sid)
            let snap = await SourceHealth.shared.snapshot(sid)
            out("     [\(tag)] \(s.stateText)  暂停时长 \(s.currentPause) s  probing=\(s.probing)"
                + "  原因=\(s.pauseReason ?? "-")  面板=\(snap.pausedText ?? "—")")
            return (s, snap)
        }
        func waitPause(_ sid: String) async {
            let s = await SourceCircuitBreaker.shared.stats(sid)
            let w = max(0, s.pausedUntil?.timeIntervalSinceNow ?? 0) + 0.25
            try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000))
        }
        func trip(_ sid: String) async {
            await SourceCircuitBreaker.shared.reset(sid)
            await SourceCircuitBreaker.shared.configure(sid, pol)
            await hit(client(sid, retries: 0), "/s429", "开闸")
        }

        // A
        out("A 探测撞 503")
        await trip("bpg-a")
        await waitPause("bpg-a")
        await hit(client("bpg-a"), "/s503", "探测")
        let (a1, a1s) = await show("bpg-a", "探测后")
        verdict("A-1 探测失败 → 开闸态、暂停 1→2 s、面板倒计时如实",
                a1.isPaused && !a1.probing && a1.currentPause == 2 && (a1s.pausedText ?? "").contains("暂停中"))
        let a2 = await hit(client("bpg-a"), "/ok", "到期前")
        verdict("A-2 到期前仍本地拒绝", !a2)
        await waitPause("bpg-a")
        var n = 0
        for i in 1...3 {
            if await hit(client("bpg-a"), "/ok", "到期后#\(i)") { n += 1 }
        }
        let (a3, _) = await show("bpg-a", "到期后")
        verdict("A-3 退避到期后放行并成功 3/3、熔断关闭", n == 3 && !a3.isPaused && !a3.probing)
        out("")

        // B
        out("B 探测撞「连接被拒」（gate 抛 CannotConnectToHost）")
        await trip("bpg-b")
        await waitPause("bpg-b")
        let refused = client("bpg-b", gate: { _ in throw URLError(.cannotConnectToHost) })
        await hit(refused, "/ok", "探测")
        let (b1, _) = await show("bpg-b", "探测后")
        verdict("B-1 探测失败 → 开闸态、暂停翻倍", b1.isPaused && !b1.probing && b1.currentPause == 2)
        await waitPause("bpg-b")
        let b2 = await hit(client("bpg-b"), "/ok", "到期后")
        verdict("B-2 到期后放行并成功", b2)
        out("")

        // C
        out("C 探测反复撞 429（maxPause 4 s 封顶）")
        await trip("bpg-c")
        var pauses: [Double] = []
        for i in 1...3 {
            await waitPause("bpg-c")
            await hit(client("bpg-c"), "/s429", "探测#\(i)")
            pauses.append(await show("bpg-c", "探测#\(i)后").0.currentPause)
        }
        verdict("C-1 暂停 2→4→4 封顶", pauses == [2, 4, 4])
        await waitPause("bpg-c")
        verdict("C-2 到期后恢复", await hit(client("bpg-c"), "/ok", "到期后"))
        out("")

        // D
        out("D 探测在飞（/slow 0.8 s）时其余请求被拒、面板显示「探测中」")
        await trip("bpg-d")
        await waitPause("bpg-d")
        let slow = Task { await hit(client("bpg-d"), "/slow", "探测") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let (d1, d1s) = await show("bpg-d", "探测在飞")
        // 并发请求：本地拒绝，并把拒绝文案（结果条详情 / 状态栏用的 localizedDescription）留下来断言
        var d2 = false
        var d2Text = "（未抛错）"
        do {
            _ = try await client("bpg-d").get(u("/ok"))
            d2 = true
            out("   并发请求 /ok → ✔ 200（不该放行）")
        } catch {
            d2Text = error.localizedDescription
            out("   并发请求 /ok → ✘ \(SourceOutcome.shortReason(for: error))「\(d2Text)」")
        }
        verdict("D-1 探测在飞：probing=true、面板「⏸ 探测中」、并发请求本地拒绝",
                d1.probing && d1s.pausedText == "⏸ 探测中" && !d2)
        verdict("D-3 探测在飞时拒绝文案「正在探测是否恢复」、不再是「已暂停 0 秒后自动恢复」",
                d2Text.contains("正在探测是否恢复") && !d2Text.contains("0 秒"))
        let d3 = await slow.value
        let (d4, _) = await show("bpg-d", "探测完成")
        verdict("D-2 探测成功 → 熔断关闭", d3 && !d4.probing && !d4.isPaused)
        out("")

        // E
        out("E 占位丢失自愈（probeStaleAfter 0.5 s；手工领走探测占位却不回报，模拟某条路径漏了 record*）")
        await SourceCircuitBreaker.shared.reset("bpg-e")
        var pe = pol; pe.probeStaleAfter = 0.5
        await SourceCircuitBreaker.shared.configure("bpg-e", pe)
        await hit(HTTPClient(sourceID: "bpg-e",
                             policy: SourcePolicy(minimumInterval: 0, maxRetries: 0, circuit: pe)), "/s429", "开闸")
        await waitPause("bpg-e")
        let lost = await SourceCircuitBreaker.shared.acquire("bpg-e")
        out("     手工 acquire → \(lost)（占位被领走、永不回报）")
        let e1 = await hit(client("bpg-e"), "/ok", "占位未过期")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let e2 = await hit(client("bpg-e"), "/ok", "占位过期后")
        let (e3, _) = await show("bpg-e", "自愈后")
        verdict("E-1 占位未过期时拒绝、过期后重新领探测并恢复", lost == .probe && !e1 && e2 && !e3.probing)
        return verdicts
    }
    server.stop()
    guard case .success(let verdicts) = r else { fail("探针异常") }
    out("")
    out("  假服务共收到 \(server.log.count) 发：" + server.log.joined(separator: " · "))
    let passed = verdicts.filter(\.1).count
    out("  汇总：\(passed)/\(verdicts.count) 通过" + (passed == verdicts.count ? " ✔" : " ✘"))
    if passed != verdicts.count { exit(1) }
}

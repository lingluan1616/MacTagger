//
//  SourceHealth.swift
//  MacTagger — 数据源健康度台账
//
//  用户的原话是「看不出数据源是否正常」。一次搜索里的逐源结果条（`SourceOutcome`）
//  只回答「这一次怎么样」；要回答「QQ 最近是不是一直在挂」，就得有跨请求的历史。
//
//  设计：
//  1. **每源只留最近 N=20 次**。再多既没用（用户关心的是「现在」）又会无限涨。
//  2. 上报点放在 `HTTPClient.send` 的出口 —— 那是所有源唯一的网络出口，
//     一处接线，全部源自动有数据，适配器一行不用改。
//  3. `testConnection` 用**固定探测曲目**主动打一枪：
//     中文源用「稻香 周杰伦」，国际源用「Blank Space Taylor Swift」；
//     首选曲目搜不到时换另一首再试一次 —— 「两首都搜不到」和「这首恰好没有」
//     是两回事，不做这一步就会把正常的源误判成挂了。
//

import Foundation

// MARK: - 单次记录

public struct SourceHealthEntry: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case ok         // 请求成功（HTTP 2xx）
        case empty      // 成功但业务层空
        case failed     // 失败
    }
    public var at: Date
    public var kind: Kind
    public var latency: TimeInterval
    /// 失败时的精简原因。
    public var reason: String?

    public init(at: Date = Date(), kind: Kind, latency: TimeInterval, reason: String? = nil) {
        self.at = at; self.kind = kind; self.latency = latency; self.reason = reason
    }
}

// MARK: - 一个源的当前健康快照

public struct SourceHealthSnapshot: Sendable, Identifiable, Equatable {
    public var id: String { sourceID }
    public var sourceID: String
    /// 最近 N 次记录，新的在前。
    public var recent: [SourceHealthEntry]
    /// 熔断器把这个源暂停到什么时候。nil = 没被暂停。
    /// **不进 `recent`**：暂停期间根本没发请求，它是「当前状态」而不是「一次请求的结果」。
    public var pausedUntil: Date?
    /// 这个源一共开过几次闸。>0 而 `pausedUntil == nil` 就是「熔断过、已恢复」。
    public var circuitTrips: Int = 0
    /// 半开：暂停已到期、探测那一发正在飞（BP-G 轮）。这段时间里**其余请求仍被本地拒绝**，
    /// 所以对用户而言它仍是「暂停中」—— 只看 `pausedUntil`（已过期）会把它画成「已恢复」。
    public var isProbing: Bool = false

    // MARK: 搜索路径（AZ 轮新增；目前只有 QQ 是多级降级链）

    /// 最近一次走通的搜索路径，如「官方搜索」。单路径的源恒为 nil。
    ///
    /// 为什么它不属于 `recent`：`recent` 记的是**一次 HTTP 请求**的成败，
    /// 而「走的哪一级」是一次**逻辑搜索**（可能是 1～3 次 HTTP）的属性，两者不同粒度。
    public var searchRoute: String?
    /// 最近 N 次逻辑搜索里有多少次拿到了候选，如「有效返回 92%（23/25）」。
    public var searchEffectiveText: String?
    /// 各级各命中几次，如「官方搜索 23 · smartbox 2」。
    public var searchRouteBreakdown: String?

    /// 面板那一格的文字：「官方搜索 · 有效返回 92%（23/25）」。没有路径信息时 nil。
    public var searchRouteText: String? {
        guard let r = searchRoute else { return nil }
        guard let e = searchEffectiveText else { return r }
        return r + " · " + e
    }

    public var isPaused: Bool { (pausedUntil?.timeIntervalSinceNow ?? -1) > 0 }
    /// 「⏸ 暂停中 42s」；半开探测在飞时是「⏸ 探测中」（其余请求此刻仍被拒，不能显示成已恢复）。
    public var pausedText: String? {
        if isProbing { return "⏸ 探测中" }
        guard let u = pausedUntil else { return nil }
        let s = Int(u.timeIntervalSinceNow.rounded(.up))
        return s > 0 ? "⏸ 暂停中 \(s)s" : nil
    }

    public var displayName: String { SourceOutcome.displayName(sourceID) }
    public var sampleCount: Int { recent.count }
    public var okCount: Int { recent.filter { $0.kind == .ok }.count }
    public var emptyCount: Int { recent.filter { $0.kind == .empty }.count }
    public var failedCount: Int { recent.filter { $0.kind == .failed }.count }

    /// 平均延迟（只算成功的那些 —— 失败多半是超时，会把均值拉成噪音）。
    public var averageLatency: TimeInterval? {
        let ok = recent.filter { $0.kind != .failed }
        guard !ok.isEmpty else { return nil }
        return ok.reduce(0) { $0 + $1.latency } / Double(ok.count)
    }

    public var lastFailure: SourceHealthEntry? { recent.first { $0.kind == .failed } }
    public var lastActivity: Date? { recent.first?.at }

    /// 三态灯。**没有样本时是「未知」而不是「正常」** —— 从没请求过就说它好是撒谎。
    public enum Light: String, Sendable { case unknown, ok, degraded, down }

    public var light: Light {
        guard !recent.isEmpty else { return .unknown }
        let rate = Double(failedCount) / Double(recent.count)
        if rate >= 0.5 { return .down }
        if rate > 0 { return .degraded }
        return .ok
    }

    public var lightLabel: String { SourceHealthSnapshot.label(for: light) }

    public static func label(for l: Light) -> String {
        switch l {
        case .unknown:  return "未测"
        case .ok:       return "正常"
        case .degraded: return "不稳定"
        case .down:     return "异常"
        }
    }

    /// 把一次主动探测的结论叠加进来。
    ///
    /// 为什么必须叠：`recent` 里的成败是 `HTTPClient` 记的 **HTTP 层**结果，
    /// 而「HTTP 200 但一条结果都不给」正是中文源被风控、以及某些地区商店整个空掉时的样子
    /// （实测中区 iTunes 就处于这一态：请求全 200，搜什么都是 0 条）。
    /// 只看 HTTP 会把这种源画成绿灯 —— 那恰恰是用户抱怨的「看不出数据源是否正常」。
    public func light(withTest test: SourceOutcome?) -> Light {
        guard let test else { return light }
        switch test.status {
        case .failed: return .down
        case .empty:  return .degraded      // 连固定探测曲都搜不到 = 能连上但没用
        case .hits:   return failedCount > 0 ? .degraded : .ok
        case .paused: return .degraded      // 熔断中：确实有病，但会自动恢复，不画成全红
        case .skipped: return light         // 软截止只发生在批量里，主动探测拿不到这一态
        }
    }

    /// 「最近结果」那一列：`✔ 18 · 空 1 · ✘ 1`
    public var recentSummary: String {
        guard !recent.isEmpty else { return "—" }
        var parts = ["✔ \(okCount)"]
        if emptyCount > 0 { parts.append("空 \(emptyCount)") }
        if failedCount > 0 { parts.append("✘ \(failedCount)") }
        return parts.joined(separator: " · ")
    }

    public var latencyText: String {
        guard let a = averageLatency else { return "—" }
        return String(format: "%.2f s", a)
    }
}

// MARK: - 台账

public actor SourceHealth {

    public static let shared = SourceHealth()

    /// 每源保留的样本数。
    public static let capacity = 20

    private var log: [String: [SourceHealthEntry]] = [:]

    public init() {}

    // MARK: 上报

    public func record(_ sourceID: String, _ entry: SourceHealthEntry) {
        var list = log[sourceID] ?? []
        list.insert(entry, at: 0)
        if list.count > Self.capacity { list.removeLast(list.count - Self.capacity) }
        log[sourceID] = list
    }

    public func record(_ sourceID: String, ok latency: TimeInterval) {
        record(sourceID, SourceHealthEntry(kind: .ok, latency: latency))
    }

    public func record(_ sourceID: String, empty latency: TimeInterval, note: String? = nil) {
        record(sourceID, SourceHealthEntry(kind: .empty, latency: latency, reason: note))
    }

    public func record(_ sourceID: String, failed error: Error, latency: TimeInterval) {
        record(sourceID, SourceHealthEntry(kind: .failed, latency: latency,
                                           reason: SourceOutcome.shortReason(for: error)))
    }

    /// 一次搜索的逐源结果条整批入账。服务层跑完一轮直接把结果条丢进来即可。
    public func record(outcomes: [SourceOutcome]) {
        for o in outcomes {
            switch o.status {
            case .hits:          record(o.sourceID, ok: o.latency)
            case .empty:         record(o.sourceID, empty: o.latency, note: o.detail)
            case .failed(let w): record(o.sourceID, SourceHealthEntry(kind: .failed,
                                                                      latency: o.latency,
                                                                      reason: w))
            case .paused:
                // **一条都不记**。熔断拒绝没有发出任何请求，把它记成失败会双重计数：
                // 真正的那 3 次超时已经在台账里了，再补上 20 条「暂停」只会让
                // 最近 20 次的窗口被暂停填满，把导致熔断的真实原因挤出视野。
                break
            case .skipped:
                // 同样**一条都不记**。请求确实发了出去，但结果我们没等 ——
                // 它既不是成功也不是失败，记进去只会让最近 20 次的窗口失真。
                // 真实的 HTTP 层成败由 `HTTPClient.send` 那一处按自己的节奏补记。
                break
            }
        }
    }

    // MARK: 读取

    public func snapshot(_ sourceID: String) async -> SourceHealthSnapshot {
        let st = await SourceCircuitBreaker.shared.stats(sourceID)
        var snap = SourceHealthSnapshot(sourceID: sourceID,
                                        recent: log[sourceID] ?? [],
                                        pausedUntil: st.pausedUntil,
                                        circuitTrips: st.trips)
        snap.isProbing = st.probing
        // 搜索路径是适配器内部的行为，台账这一层拿不到，只能按源 id 去它自己的遥测里取。
        // 目前只有 QQ 有多级降级链；将来别的源也做成降级链时在这里加一条分支即可。
        if sourceID == "qq" {
            let t = QQSearchTelemetry.shared.snapshot
            if t.attempts > 0 {
                snap.searchRoute = t.pathText
                snap.searchEffectiveText = t.rateText
                snap.searchRouteBreakdown = t.pathBreakdown
            }
        }
        return snap
    }

    /// 全部**可搜索**的源，按推荐优先级排。没有样本的源也要出现在表里（灯是「未测」）。
    public func snapshots(ids: [String]? = nil) async -> [SourceHealthSnapshot] {
        let list = ids ?? SourceHealth.defaultSourceIDs
        var out: [SourceHealthSnapshot] = []
        for id in list { out.append(await snapshot(id)) }
        return out
    }

    public func reset() { log.removeAll() }
    public func reset(_ sourceID: String) { log[sourceID] = nil }

    // MARK: 主动探测

    /// 面板要覆盖的源：注册表里所有能搜索的，按推荐优先级。
    public nonisolated static var defaultSourceIDs: [String] {
        let reg = SourceRegistry.shared
        return reg.recommendedOrder.filter {
            reg.source(id: $0)?.capabilities.contains(.searchTracks) ?? false
        }
    }

    /// 固定探测曲目。选它们的理由：
    /// 一首华语顶流 + 一首英语顶流，任何一个还活着的音乐源都必然收录，
    /// 因此「搜不到」几乎一定是源出了问题，而不是曲库差异。
    public static let chineseProbe = TrackQuery(title: "稻香", artist: "周杰伦",
                                                filename: "稻香 周杰伦")
    public static let englishProbe = TrackQuery(title: "Blank Space", artist: "Taylor Swift",
                                                filename: "Blank Space Taylor Swift")

    /// 该源优先用哪首探测。国际源用英文曲，中文源用华语曲。
    public nonisolated static func primaryProbe(for sourceID: String) -> TrackQuery {
        switch sourceID {
        case "musicbrainz", "coverartarchive", "lastfm": return englishProbe
        default: return chineseProbe
        }
    }

    public nonisolated static func secondaryProbe(for sourceID: String) -> TrackQuery {
        let p = primaryProbe(for: sourceID)
        return p == chineseProbe ? englishProbe : chineseProbe
    }

    /// 打一枪试试这个源还活着没有。结果既返回给调用方，也自动记进台账。
    ///
    /// 两首探测曲**都**搜不到才判 `.empty`：单曲搜不到可能只是曲库差异，
    /// 判成故障会让用户白白去排查网络。
    @discardableResult
    public func testConnection(_ sourceID: String) async -> SourceOutcome {
        guard let src = SourceRegistry.shared.source(id: sourceID) else {
            let o = SourceOutcome(sourceID: sourceID, status: .failed("未注册"),
                                  detail: "该源没有注册到 SourceRegistry")
            record(outcomes: [o])
            return o
        }
        guard src.capabilities.contains(.searchTracks) else {
            let o = SourceOutcome(sourceID: sourceID, status: .failed("不支持搜索"),
                                  detail: "\(src.displayName) 不具备 searchTracks 能力，只作封面/歌词回落")
            return o        // 不入账：这不是故障，别把灯染红
        }

        let started = Date()
        do {
            var found = try await src.searchTracks(SourceHealth.primaryProbe(for: sourceID), limit: 5)
            var used = "首选探测曲"
            if found.isEmpty {
                found = (try? await src.searchTracks(SourceHealth.secondaryProbe(for: sourceID), limit: 5)) ?? []
                used = "备用探测曲"
            }
            let elapsed = Date().timeIntervalSince(started)
            let o = SourceOutcome(sourceID: sourceID,
                                  status: found.isEmpty ? .empty : .hits(found.count),
                                  latency: elapsed,
                                  detail: found.isEmpty
                                      ? "两首探测曲都没有结果（源可能被风控或接口已变更）"
                                      : "\(used)：《\(found[0].title ?? "?")》— \(found[0].artist ?? "?")")
            record(outcomes: [o])
            return o
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            let o = SourceOutcome.failure(sourceID, error, latency: elapsed)
            record(outcomes: [o])
            return o
        }
    }

    /// 全部测一遍。串行跑：并发同时打七个源，各源自己的限速会把耗时算成噪音，
    /// 而这张表的「平均延迟」一列正是要给用户看真实响应速度的。
    public func testAll(_ ids: [String]? = nil) async -> [SourceOutcome] {
        var out: [SourceOutcome] = []
        for id in ids ?? SourceHealth.defaultSourceIDs {
            out.append(await testConnection(id))
        }
        return out
    }
}

// MARK: - 熔断器

//
//  为什么要有它（AU 轮实测结论）：
//  QQ 的接口本身没坏 —— curl 直测 smartbox / musicu / 歌词三个接口全 200，每次 2.4–3.0 s。
//  病在**批量**：一首歌要发 2–3 发请求，批量几十首、文件级并发 4 条线同时压同一个源，
//  对方一旦变慢甚至挂起，我们这边每一发都要死等到 15 s 超时才放弃；
//  更糟的是超时后**立刻按 maxRetries 连发重试**，等于在对方最堵的时候再加两倍流量。
//  结果就是用户看到的那一片「QQ ✘ 超时」。
//
//  三条对策，都在这个 actor 里：
//  1. **超时不再立刻重试**，改指数退避（见 `SourcePolicy.networkBackoff`）。
//  2. **连续超时到阈值就开闸**：暂停 60 s，期间对该源的请求本地立即抛 `.circuitOpen`，
//     一发都不出去 —— 既让对方喘口气，也让用户的批量立刻往下走而不是干等。
//  3. **半开探测**：到期后只放**一发**探测请求，成功就全恢复，失败就再暂停（翻倍，上限 5 分钟）。
//
//  刻意不做的事：不做全局熔断。一个源病了只暂停它自己，其余源照常 —— 这是可插拔源设计的根本。
//

/// 熔断参数。按源可配（`SourceCircuitBreaker.configure`）。
public struct CircuitPolicy: Sendable {
    /// 滑动窗口内累计多少次超时就开闸。
    public var timeoutThreshold: Int
    /// 滑动窗口长度：超过这么久的旧超时不再算数（避免昨天的故障今天还在扣分）。
    public var window: TimeInterval
    /// 首次暂停时长。
    public var basePause: TimeInterval
    /// 暂停时长上限（每失败一次半开探测就翻倍）。
    public var maxPause: TimeInterval
    /// 半开探测占位的**自愈期限**（BP-G 轮）。
    ///
    /// 探测那一发的结论本应由 `HTTPClient.send` 的某条 `record*` 交回；万一哪条路径漏了
    /// （BO 报告 #3 就是这么锁死的：探测撞 503 → 退避重试 → 自己把自己拒了，占位永不交还），
    /// 占位超过这么久仍未交还就视为丢失，下一发请求重新领探测。
    /// 取 240 s：最慢的源 timeout 25 s × (1 + 2 次 5xx 重试 + 2 次网络重试) + 退避，
    /// 合法的探测不可能飞这么久，不会误伤。
    public var probeStaleAfter: TimeInterval
    /// **连续**多少次「HTTP 200 但结果为空」判定为被风控置空，开闸暂停。
    ///
    /// 为什么和超时分开算（AX 轮新增）：这两件事的信号完全不同。
    /// 超时是「对方回不出来」，看的是**滑动窗口内的累计次数**；
    /// 置空是「对方回得很快，但每一发都是空的」——单看一发根本分不清「它没有这首歌」
    /// 与「它在拒绝我」，只有**连续**很多发都空才构成证据，因此中间只要有一次
    /// 拿到结果就必须清零。取 5 是因为：批量里连着 5 首冷门歌全空是可能的（不该误伤），
    /// 而被风控时是**每一发都空**，第 5 发之后就再没有翻盘的可能了。
    /// `0` = 关掉这条规则。
    public var emptyThreshold: Int

    public init(timeoutThreshold: Int = 3,
                window: TimeInterval = 120,
                basePause: TimeInterval = 60,
                maxPause: TimeInterval = 300,
                emptyThreshold: Int = 5,
                probeStaleAfter: TimeInterval = 240) {
        self.timeoutThreshold = timeoutThreshold
        self.window = window
        self.basePause = basePause
        self.maxPause = maxPause
        self.emptyThreshold = emptyThreshold
        self.probeStaleAfter = probeStaleAfter
    }

    public static let `default` = CircuitPolicy()
}

/// 一个源的熔断状态快照，供界面与探针读取。
public struct CircuitStats: Sendable, Equatable {
    public var sourceID: String
    /// 暂停到什么时候。nil = 没被暂停。
    public var pausedUntil: Date?
    /// 一共开过几次闸（整个进程生命周期内）。
    public var trips: Int
    /// 因熔断被**立即拒绝**的请求数。
    public var rejected: Int
    /// 当前窗口内已累计的超时次数。
    public var timeoutsInWindow: Int
    /// 当前暂停时长（翻倍后的值）。
    public var currentPause: TimeInterval
    /// 是否正处在「半开、探测请求在飞」的中间态。
    public var probing: Bool
    /// 当前连续空结果次数（拿到一次非空即清零）。
    public var consecutiveEmpties: Int = 0
    /// 这一次开闸是**为什么**开的：「连续超时」/「疑似被风控置空」。
    /// 没在暂停中时为 nil。结果条的悬停提示直接显示它 ——
    /// 「暂停中」不说原因的话，用户既不知道该等还是该换源，也无从判断是不是自己网络的问题。
    public var pauseReason: String?

    public var isPaused: Bool { (pausedUntil?.timeIntervalSinceNow ?? -1) > 0 }

    /// 三态文字，日志与探针共用：`关闭` / `开闸(暂停 42s)` / `半开(探测中)`
    public var stateText: String {
        if probing { return "半开(探测中)" }
        if let u = pausedUntil, u.timeIntervalSinceNow > 0 {
            return String(format: "开闸(暂停 %.0fs)", u.timeIntervalSinceNow)
        }
        return "关闭"
    }
}

public actor SourceCircuitBreaker {

    public static let shared = SourceCircuitBreaker()

    /// 放行决定。
    public enum Decision: Sendable, Equatable {
        /// 正常放行。
        case allow
        /// 半开探测：这一发是唯一被放出去的请求，成败决定这个源是恢复还是继续暂停。
        case probe
        /// 拒绝，`until` 是恢复时刻。调用方必须**立即**抛 `.circuitOpen`，不许排队等待。
        case reject(until: Date)
    }

    private struct Entry {
        var timeouts: [Date] = []
        var pausedUntil: Date?
        var pause: TimeInterval = 0
        var trips = 0
        var rejected = 0
        var probing = false
        /// 这一次探测占位是什么时候领的（只在 `probing == true` 时有意义）。
        var probeStartedAt: Date?
        /// 本「轮」（由调用方 `beginRound` 划定）里是否开过闸。批量结束后据此决定要不要补查。
        var trippedThisRound = false
        /// 连续拿到空结果的次数。拿到一次非空即清零。
        var emptyStreak = 0
        /// 这次开闸的原因（给结果条的悬停提示看）。
        var pauseReason: String?
    }

    private var entries: [String: Entry] = [:]
    private var policies: [String: CircuitPolicy] = [:]
    /// 全局开关。压力测试的「改造前」对照组要能把它关掉。
    public private(set) var isEnabled = true

    public init() {}

    // MARK: 配置

    public func configure(_ sourceID: String, _ policy: CircuitPolicy) {
        policies[sourceID] = policy
    }

    /// 只在还没配过时登记。`HTTPClient` 每发请求都会调它 ——
    /// 用 `configure` 的话会把探针/调用方显式设过的参数一发一发地盖回默认值。
    public func configureIfAbsent(_ sourceID: String, _ policy: CircuitPolicy) {
        guard policies[sourceID] == nil else { return }
        policies[sourceID] = policy
    }
    public func policy(for sourceID: String) -> CircuitPolicy {
        policies[sourceID] ?? .default
    }
    public func setEnabled(_ on: Bool) { isEnabled = on }

    /// 清空。仅供探针与测试用 —— 生产路径没有任何地方调它。
    public func reset() { entries.removeAll() }
    public func reset(_ sourceID: String) { entries[sourceID] = nil }

    // MARK: 放行判定

    /// **每一发请求都要先过这里。** 必须放在限速等待之前 ——
    /// 放在之后就变成「先排 0.5 s 的队，再告诉你这个源被暂停了」，白等。
    public func acquire(_ sourceID: String) -> Decision {
        guard isEnabled else { return .allow }
        var e = entries[sourceID] ?? Entry()
        defer { entries[sourceID] = e }

        guard let until = e.pausedUntil else { return .allow }

        if Date() < until {
            e.rejected += 1
            return .reject(until: until)
        }
        // 到期了：半开。只放一发探测，其余仍然拒绝（否则一开闸又是一拥而上）。
        let now = Date()
        if e.probing {
            // 自愈（BP-G 轮）：占位远超任何合法探测的耗时仍未交还 = 回报丢了。
            // 不自愈的话这个源会被锁到重启（BO 报告 #3 的病根之一）。
            let p = policy(for: sourceID)
            if let s = e.probeStartedAt, now.timeIntervalSince(s) > p.probeStaleAfter {
                e.probeStartedAt = now
                return .probe
            }
            e.rejected += 1
            return .reject(until: until)
        }
        e.probing = true
        e.probeStartedAt = now
        return .probe
    }

    // MARK: 结果回报

    public func recordSuccess(_ sourceID: String) {
        guard isEnabled else { return }
        var e = entries[sourceID] ?? Entry()
        // 成功即清零：熔断只认「连续」超时，中间成功一次就不该继续累计。
        e.timeouts.removeAll()
        if e.probing || e.pausedUntil != nil {
            e.probing = false
            e.pausedUntil = nil
            e.pause = 0            // 恢复后退避时长归零，下次故障从 basePause 重新起算
            e.pauseReason = nil
        }
        entries[sourceID] = e
    }

    /// 请求被调用方主动取消（软截止到点了，我们不再等它）。
    ///
    /// **只做一件事：把半开探测的占位放掉。** 不计成败、不动暂停时长、不清超时计数 ——
    /// 我们对这一发的结果一无所知，任何结论都是编的。
    /// 但这一句非有不可：`acquire` 返回 `.probe` 时会把 `probing` 置真，
    /// 靠后续的 success/timeout 回报来复位；取消掉的探测两者都不会来，
    /// `probing` 就永远卡在真，之后每一发都被 `acquire` 判 `.reject` —— 源被永久锁死。
    public func recordCancelled(_ sourceID: String) {
        guard isEnabled, var e = entries[sourceID], e.probing else { return }
        e.probing = false
        entries[sourceID] = e
    }

    /// **半开探测失败**（BP-G 轮）：探测那一发撞上 5xx、或连不上主机/握手失败，且在
    /// **探测自己的**重试次数内都没缓过来。回到「开闸」态，暂停时长指数退避
    /// （`basePause` 起、每次翻倍、`maxPause` 封顶），到期后再放一发探测。
    ///
    /// 为什么要单独一条入口：原先这几类错误要么被 `continue` 去重试、回到循环顶端
    /// 再 `acquire` 时被自己的占位拒掉（抛 `.circuitOpen` 逃出 `send`，占位永不交还），
    /// 要么根本不回报熔断器 —— 两条路都让源**永久锁死到重启**，而 `stats()` 因暂停已过期
    /// 报「未暂停」，结果条却一直「已暂停 0 秒后自动恢复」（BO 报告 #3）。
    ///
    /// 超时/连接中断仍走 `recordTimeout`（它自带探测失败分支），限流仍走 `recordRateLimited`；
    /// 拿到 4xx 等「对方活着」的响应仍走 `recordOtherFailure`（判为恢复）。
    /// 返回「是否真的重新开了闸」（不在探测中时什么也不做，返回 false）。
    @discardableResult
    public func recordProbeFailure(_ sourceID: String, reason: String) -> Bool {
        guard isEnabled, var e = entries[sourceID], e.probing else { return false }
        let p = policy(for: sourceID)
        let now = Date()
        e.probing = false
        e.probeStartedAt = nil
        e.pause = min(p.maxPause, max(p.basePause, e.pause * 2))
        e.pausedUntil = now.addingTimeInterval(e.pause)
        e.pauseReason = "半开探测失败（\(reason)）"
        e.trips += 1
        e.trippedThisRound = true
        entries[sourceID] = e
        return true
    }

    // MARK: 空结果（被风控静默置空）

    /// 记一次「HTTP 200 但一条结果都没有」。返回「这一发是否把闸打开了」。
    ///
    /// 判据是**连续**：中间只要有一次拿到结果就清零（见 `recordNonEmpty`）。
    /// 单看一发分不清「它没有这首歌」和「它在拒绝我」，只有连着 N 发全空才构成证据。
    @discardableResult
    public func recordEmptyResult(_ sourceID: String) -> Bool {
        guard isEnabled else { return false }
        let p = policy(for: sourceID)
        guard p.emptyThreshold > 0 else { return false }
        var e = entries[sourceID] ?? Entry()
        defer { entries[sourceID] = e }

        e.emptyStreak += 1
        // 半开探测拿回一个空结果：**判为恢复**，理由同 `recordOtherFailure` ——
        // 拿到了 HTTP 响应就证明对方既没挂起也没拒收连接。空不空由下面的连续计数接管。
        if e.probing { e.probing = false; e.pausedUntil = nil; e.pause = 0; e.pauseReason = nil }
        guard e.emptyStreak >= p.emptyThreshold, e.pausedUntil == nil else { return false }

        e.pause = e.pause > 0 ? min(p.maxPause, e.pause * 2) : p.basePause
        e.pausedUntil = Date().addingTimeInterval(e.pause)
        e.pauseReason = "疑似被风控置空（连续 \(e.emptyStreak) 次 HTTP 200 空结果）"
        e.trips += 1
        e.trippedThisRound = true
        e.emptyStreak = 0
        return true
    }

    /// 记一次「拿到了非空结果」，把连续空结果计数清零。
    public func recordNonEmpty(_ sourceID: String) {
        guard isEnabled, var e = entries[sourceID], e.emptyStreak > 0 else { return }
        e.emptyStreak = 0
        entries[sourceID] = e
    }

    // MARK: 限流

    /// 记一次**被限流**（HTTP 429，iTunes 是 403）。返回「这一发是否把闸打开了」。
    ///
    /// 复用超时那套暂停状态机（`basePause` 起步、每次翻倍、`maxPause` 封顶、半开探测），
    /// 但**独立一条入口**，理由有二：
    /// ① 原因文案不同 —— 用户看到「限流中」才知道该等一会儿而不是去查网络；
    /// ② 判据不同 —— 超时要在滑动窗口里累计到阈值才开闸，
    ///    限流则**一次就够**：对方已经明说「你太快了」，再撞只会把限流窗口一直续上。
    @discardableResult
    public func recordRateLimited(_ sourceID: String, status: Int) -> Bool {
        guard isEnabled else { return false }
        let p = policy(for: sourceID)
        var e = entries[sourceID] ?? Entry()
        defer { entries[sourceID] = e }

        let now = Date()
        // 半开探测又撞上限流：暂停时长翻倍。
        if e.probing { e.probing = false }
        guard e.pausedUntil == nil || e.pausedUntil! <= now else { return false }

        e.pause = e.pause > 0 ? min(p.maxPause, e.pause * 2) : p.basePause
        e.pausedUntil = now.addingTimeInterval(e.pause)
        e.pauseReason = "限流（HTTP \(status)）"
        e.trips += 1
        e.trippedThisRound = true
        e.timeouts.removeAll()
        return true
    }

    /// 记一次超时/连接中断。返回「这一发是否把闸打开了」。
    @discardableResult
    public func recordTimeout(_ sourceID: String) -> Bool {
        guard isEnabled else { return false }
        let p = policy(for: sourceID)
        var e = entries[sourceID] ?? Entry()
        defer { entries[sourceID] = e }

        let now = Date()
        // 半开探测失败：直接再暂停，时长翻倍（上限 maxPause）。
        if e.probing {
            e.probing = false
            e.pause = min(p.maxPause, max(p.basePause, e.pause * 2))
            e.pausedUntil = now.addingTimeInterval(e.pause)
            e.pauseReason = "半开探测再次超时"
            e.trips += 1
            e.trippedThisRound = true
            e.timeouts = [now]
            return true
        }

        e.timeouts.removeAll { now.timeIntervalSince($0) > p.window }
        e.timeouts.append(now)
        guard e.timeouts.count >= p.timeoutThreshold, e.pausedUntil == nil else { return false }

        e.pause = e.pause > 0 ? min(p.maxPause, e.pause * 2) : p.basePause
        e.pausedUntil = now.addingTimeInterval(e.pause)
        e.pauseReason = "连续 \(p.timeoutThreshold) 次超时"
        e.trips += 1
        e.trippedThisRound = true
        e.timeouts.removeAll()
        return true
    }

    /// 非超时类失败（HTTP 4xx/5xx、解析失败、业务码、域名解析失败）。
    ///
    /// **不计入熔断，也不清零超时计数。** 熔断治的只有一种病：对方挂起把我们拖死。
    /// 接口变更/被风控该由结果条如实报出来，暂停它只会让用户以为「过一会儿就好了」。
    ///
    /// 半开探测撞上这类错误时**判为恢复**：拿到了 HTTP 响应（哪怕是 404）就证明对方
    /// 既没挂起也没拒收连接，正是我们要确认的那件事；因为一个 404 就再暂停 60 秒是误伤。
    public func recordOtherFailure(_ sourceID: String) {
        guard isEnabled, var e = entries[sourceID], e.probing else { return }
        e.probing = false
        e.pausedUntil = nil
        e.pause = 0
        e.pauseReason = nil
        e.timeouts.removeAll()
        entries[sourceID] = e
    }

    // MARK: 读取

    public func stats(_ sourceID: String) -> CircuitStats {
        let e = entries[sourceID] ?? Entry()
        let p = policy(for: sourceID)
        let now = Date()
        let live = (e.pausedUntil.map { $0 > now ? $0 : nil } ?? nil)
        return CircuitStats(sourceID: sourceID,
                            pausedUntil: live,
                            trips: e.trips,
                            rejected: e.rejected,
                            timeoutsInWindow: e.timeouts.filter { now.timeIntervalSince($0) <= p.window }.count,
                            currentPause: e.pause,
                            probing: e.probing,
                            consecutiveEmpties: e.emptyStreak,
                            // 半开探测在飞时其余请求仍被拒，结果条要能说清「为什么还不放行」。
                            pauseReason: live != nil ? e.pauseReason
                                : (e.probing ? "半开探测中，结论出来前暂不放行" : nil))
    }

    public func allStats() -> [String: CircuitStats] {
        var out: [String: CircuitStats] = [:]
        for id in entries.keys { out[id] = stats(id) }
        return out
    }

    // MARK: 「一轮」的账（批量结束后的补查靠它）

    /// 批量开始时调一次，把「本轮开过闸」的标记清掉。
    public func beginRound(_ sourceIDs: [String]) {
        for id in sourceIDs {
            entries[id]?.trippedThisRound = false
        }
    }

    /// 本轮开过闸、**且现在已经恢复**（不在暂停中）的源。
    /// 批量结束后只对这些源补查 —— 还在暂停中的源补查也只会再被拒一次。
    public func recoveredAfterRound(_ sourceIDs: [String]) -> [String] {
        let now = Date()
        return sourceIDs.filter { id in
            guard let e = entries[id], e.trippedThisRound else { return false }
            guard let u = e.pausedUntil else { return true }
            return u <= now
        }
    }

    /// 本轮开过闸的源（不论是否已恢复）。
    public func trippedThisRound(_ sourceIDs: [String]) -> [String] {
        sourceIDs.filter { entries[$0]?.trippedThisRound == true }
    }

    /// 等到这个源恢复（最多等 `cap` 秒）。批量结束后的补查用：
    /// 剩几秒就等几秒，比让用户自己盯着表再点一次要体面。等待期间不发任何请求。
    public func waitUntilRecovered(_ sourceID: String, cap: TimeInterval) async {
        guard let u = entries[sourceID]?.pausedUntil else { return }
        let wait = min(cap, u.timeIntervalSinceNow)
        guard wait > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
}

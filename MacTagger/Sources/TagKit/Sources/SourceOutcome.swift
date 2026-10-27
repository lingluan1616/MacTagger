//
//  SourceOutcome.swift
//  MacTagger — 「这一轮里每个数据源到底发生了什么」的统一记账
//
//  为什么要有它：
//  用户看着搜索结果里没有 QQ，无法判断是「QQ 没这首歌」还是「QQ 挂了」。
//  这两件事的处置完全相反 —— 前者该换个源看看，后者该等一会儿再试或去查网络。
//  原先各处只有 `triedSources: [String]` 与 `errors: [(源, 文案)]` 两份残缺记录：
//  前者不区分成败，后者只在失败时才有，**「搜到了 0 条」这一态根本没被记下来**。
//
//  因此把每个源的一次尝试固化成三态 + 耗时：
//      .hits(n)  有 n 条结果        （绿）
//      .empty    请求成功但 0 条     （灰，不是故障）
//      .failed   源本身出问题        （红，附精简原因）
//
//  与既有 `SourceAttempt` 的关系：`SourceAttempt` 是降级链内部的过程记录（多一个
//  `.skipped` 态），本类型是**给界面看的呈现模型**。两者可互转，不重复造轮子。
//

import Foundation

// MARK: - 逐源结果

public struct SourceOutcome: Sendable, Identifiable, Equatable {

    public enum Status: Sendable, Equatable {
        /// 拿到 n 条结果。
        case hits(Int)
        /// 请求成功，但一条都没有。**不是故障**。
        case empty
        /// 源本身出错。附带的字符串是已精简过的原因（「超时」「HTTP 503」「retcode -1310」）。
        case failed(String)
        /// **熔断暂停中**：这个源连续超时开了闸，本轮没有对它发请求，`until` 是自动恢复时刻。
        ///
        /// 为什么不并进 `.failed`：这两件事对用户的含义完全相反 ——
        /// `.failed` 是「问过了，它挂了」；`.paused` 是「上一批已经问出它在挂，这次直接没问」。
        /// 并进去会让批量统计算出「QQ 20/20 失败」这种假账（实际只失败了前 3 次），
        /// 也会让「稍后再跑一次这些文件」这条唯一有用的建议无处可挂。
        case paused(until: Date)
        /// **软截止跳过**：请求发出去了，但这一轮不再等它。
        ///
        /// 为什么不并进 `.failed` 也不并进 `.empty`（AX 轮新增）：
        /// 「等太久所以不等了」是**我们**的决定，不是源的过错 —— 计进失败率会让
        /// 「MusicBrainz 12/12 失败」这种假账刷屏，也会污染熔断计数（熔断治的是
        /// 「对方挂起把我们拖死」，而软截止恰恰已经把「被拖死」这件事解决掉了）；
        /// 并进 `.empty` 又会让用户以为「这个源没有这首歌」，从而去改搜索词，方向全错。
        /// 关联值是给用户看的一句人话：「超过软截止 4 s」/「已有高分候选，提前结束等待」。
        case skipped(reason: String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
        public var isPaused: Bool { if case .paused = self { return true }; return false }
        public var isSkipped: Bool { if case .skipped = self { return true }; return false }
        /// 被软截止跳过的原因。非跳过态为 nil。
        public var skipReason: String? { if case .skipped(let r) = self { return r }; return nil }
        /// 暂停到什么时候。非暂停态为 nil。
        public var pausedUntil: Date? { if case .paused(let u) = self { return u }; return nil }
        public var hitCount: Int { if case .hits(let n) = self { return n }; return 0 }
    }

    public var id: String { sourceID }
    public var sourceID: String
    public var status: Status
    /// 这一次请求花了多久（秒）。含重试与限速等待。
    public var latency: TimeInterval
    /// 退避重试了几次才成功。>0 时 chip 上显示「503×4→通」这类提示。
    public var retries: Int
    /// 完整的原始错误文案，只在悬停提示里出现。
    public var detail: String?

    /// **这一次走的是这个源的哪一条搜索路径**（AZ 轮新增，目前只有 QQ 有多条路径）。
    ///
    /// 为什么要有它：QQ 的搜索是三级降级链（官方搜索 → smartbox → 桌面搜索）。
    /// 用户看到 QQ 那一格是 0 条时，「刚才走到了哪一级、卡在哪一级」决定了他该做什么 ——
    /// 官方搜索被风控要等，smartbox 送错词要改文件名，桌面搜索 2001 谁也没辙（正常，它就那样）。
    /// 不写出来，这三件事在界面上长得一模一样。
    ///
    /// 只有一条路径的源恒为 nil，界面上什么都不显示。
    public var route: String?

    public init(sourceID: String,
                status: Status,
                latency: TimeInterval = 0,
                retries: Int = 0,
                detail: String? = nil,
                route: String? = nil) {
        self.sourceID = sourceID
        self.status = status
        self.latency = latency
        self.retries = retries
        self.detail = detail
        self.route = route
    }

    /// 结果条要显示的路径行。
    ///
    /// `route` 没被显式填时对 QQ 回落到进程内遥测（`QQSearchTelemetry`）——
    /// 结果条是在 QQ 的 `searchTracks` 返回之后立刻造出来的，那一刻遥测里
    /// 「最近一次走通的路径」就是这一条。批量并发下它可能是同批另一个文件的路径，
    /// 所以文案写的是「当前搜索路径」而不是「本次搜索路径」，不把话说满。
    public var routeLine: String? {
        if let route, !route.isEmpty { return "本次搜索路径：" + route }
        guard sourceID == "qq" else { return nil }
        let s = QQSearchTelemetry.shared.snapshot
        return s.attempts > 0 ? s.line : nil
    }

    // MARK: 便捷构造

    public static func hits(_ n: Int, _ sourceID: String, latency: TimeInterval = 0) -> SourceOutcome {
        SourceOutcome(sourceID: sourceID, status: n > 0 ? .hits(n) : .empty, latency: latency)
    }

    /// 由一个错误造结果条。
    ///
    /// **两类错误被特判成非失败**，特判放在这里而不是各调用方，是因为
    /// `gather` / `AlbumMatchService` / `testConnection` 三条路都用这一个构造器 ——
    /// 一处特判，三处都对：
    ///
    /// · `.circuitOpen`（熔断被拒）：它压根没发请求，
    ///   计进失败率会让「QQ 本轮 20/20 失败」这种假账刷屏，也遮住真正的失败原因。
    ///
    /// · `.emptyResult`（HTTP 200 但业务层没有结果）→ **`.empty`（灰 0），不是失败**。
    ///   这是 BD 轮修的那个误报：各源在「搜不到」时抛的都是 `.emptyResult`
    ///   （QQ 三级搜索全空、网易云 `code != 200`、酷狗 `status != 1`…），
    ///   而这里一律映射成红 ✘，于是日文 OST 在 QQ 曲库里本来就没有这件正常事，
    ///   被画成了「QQ 一直失败」。语义上「问过了，它说没有」与「它挂了」相反：
    ///   前者该换个源，后者该等一会儿。判据是 `SourceError` 的**类型**，
    ///   不是文案关键词 —— 各源已经用类型把这件事表达清楚了。
    public static func failure(_ sourceID: String, _ error: Error,
                               latency: TimeInterval = 0) -> SourceOutcome {
        if case .circuitOpen(_, let until, _)? = (error as? SourceError) {
            return SourceOutcome(sourceID: sourceID,
                                 status: .paused(until: until),
                                 latency: latency,
                                 detail: fullReason(for: error))
        }
        if case .emptyResult(let why)? = (error as? SourceError) {
            return SourceOutcome(sourceID: sourceID,
                                 status: .empty,
                                 latency: latency,
                                 detail: why)
        }
        return SourceOutcome(sourceID: sourceID,
                             status: .failed(shortReason(for: error)),
                             latency: latency,
                             detail: fullReason(for: error))
    }

    // MARK: 显示

    /// 源的中文名。注册表里有就用它声明的名字，没注册（或注册表还没初始化）时退回内置表。
    public var displayName: String { SourceOutcome.displayName(sourceID) }

    /// 兜底显示名。注册表查得到时以注册表为准 —— 删掉某个适配器后这里也不会说谎。
    public static func displayName(_ id: String) -> String {
        if let n = SourceRegistry.shared.source(id: id)?.displayName { return n }
        return fallbackNames[id] ?? id
    }

    static let fallbackNames: [String: String] = [
        "itunes": "iTunes Store",
        "netease": "网易云音乐",
        "kugou": "酷狗音乐",
        "qq": "QQ 音乐",
        "kuwo": "酷我音乐",
        "musicbrainz": "MusicBrainz",
        "coverartarchive": "Cover Art Archive",
    ]

    /// chip 上的短名。表格里一行要塞五六个源，「网易云音乐」太长。
    public var shortName: String { SourceOutcome.shortName(sourceID) }

    public static func shortName(_ id: String) -> String {
        switch id {
        case "netease": return "网易云"
        case "kugou":   return "酷狗"
        case "qq":      return "QQ"
        case "kuwo":    return "酷我"
        case "itunes":  return "iTunes"
        case "musicbrainz": return "MusicBrainz"
        case "coverartarchive": return "CAA"
        default:        return displayName(id)
        }
    }

    /// 一枚 chip 的文字：`iTunes 8` / `QQ ✘ 超时` / `酷狗 0` / `MusicBrainz 503×4→通`
    public var chipLabel: String {
        switch status {
        case .hits(let n):
            // 退避重试后才通的，把过程写出来 —— 「这次能用但不稳」是有用信息。
            if retries > 0, let d = detail, let code = SourceOutcome.statusCode(in: d) {
                return "\(shortName) \(code)×\(retries)→通 \(n)"
            }
            if retries > 0 { return "\(shortName) 重试\(retries)→通 \(n)" }
            return "\(shortName) \(n)"
        case .empty:
            return "\(shortName) 0"
        case .failed(let why):
            return "\(shortName) ✘ \(why)"
        case .paused:
            // 「还剩几秒」是这枚 chip 上唯一能让用户做决定的信息（等 12 秒 vs 等 5 分钟），
            // 而「限流」和「超时」的处置完全不同 —— 限流是我们发太快，等一下就好；
            // 超时是对方病了。两者都写出来，chip 也才多两三个字。
            let head = isRateLimited ? "限流中" : "暂停中"
            if let s = pauseRemaining { return "\(shortName) ⏸ \(head)，\(s) 秒后继续" }
            return "\(shortName) ⏸ \(head)"
        case .skipped(let reason):
            // 只写**一个词**的原因分类：chip 一行要塞五六个源，完整原因在悬停里。
            // 但这一个词非写不可 —— 三种跳过要用户做的事完全不同：
            //   ·（排队）我们自己的限速排不上 → 调「每首最多等待」或改用专辑模式；
            //   ·（慢）  这个源真的慢         → 等，或者别勾它；
            //   ·（已够）已有高分候选提前收工 → 什么都不用做，这是好事。
            // BD 轮实测：iTunes 在逐首模式下 20/20 全是「排队」，一个「慢」都没有；
            // 只写「⇥ 跳过」的话用户只会以为 iTunes 挂了。
            return "\(shortName) ⇥ 跳过（\(SourceOutcome.skipKindWord(reason))）"
        }
    }

    /// 「iTunes 2.9 s」——展开行里那条「耗时：…」的单元。
    /// 被软截止跳过的源额外带一句括注，否则用户会以为它只是慢。
    public var latencyLabel: String {
        var s = shortName + " " + String(format: "%.1f s", latency)
        if let r = status.skipReason { s += "（\(r)）" }
        return s
    }

    /// 暂停还剩多少秒（已到期或非暂停态返回 nil）。
    public var pauseRemaining: Int? {
        guard let until = status.pausedUntil else { return nil }
        let s = Int(until.timeIntervalSinceNow.rounded(.up))
        return s > 0 ? s : nil
    }

    /// 这次暂停是**限流**引起的（而不是超时或被风控置空）。
    /// 原因由 `SourceError.circuitOpen` 的第三个关联值一路带过来，落在 `detail` 里。
    public var isRateLimited: Bool {
        guard status.isPaused, let d = detail else { return false }
        return d.contains("限流")
    }

    /// 从跳过原因里提炼**一个词**的分类，给 chip 用。
    /// 判据只看关键词，不做正则 —— 原因串是我们自己生成的，形态可控。
    public static func skipKindWord(_ reason: String) -> String {
        if reason.contains("排队") { return "排队" }
        if reason.contains("提前") || reason.contains("已有高分") { return "已够" }
        return "慢"
    }

    /// 悬停提示：完整原因 + 耗时。
    public var helpText: String {
        var lines: [String] = [displayName]
        switch status {
        case .hits(let n):  lines.append("返回 \(n) 条候选")
        case .empty:
            lines.append("请求成功，但没有搜到结果（不是故障）")
            // 「这个源的曲库里没有这首」是用户最需要听到的那句话 —— 不说，
            // 他会一直以为 QQ 挂了，反复重跑同一批日文 OST。
            if let extra = SourceOutcome.emptyHint(sourceID) { lines.append(extra) }
        case .failed(let w): lines.append("失败：\(w)")
        case .paused(let until):
            let secs = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
            // 熔断的触发条件不止「连续超时」一种（AX 轮加了「连续空结果」），
            // 因此这句话由 `detail` 里的真实原因接管，只在没有 detail 时才用旧文案兜底。
            lines.append(detail?.isEmpty == false
                         ? "已触发熔断，本轮没有对它发请求"
                         : "连续超时已触发熔断，本轮没有对它发请求")
            lines.append(secs > 0 ? "约 \(secs) 秒后自动试探恢复" : "已到恢复时刻，下一次请求会放一发探测")
        case .skipped(let reason):
            lines.append("已跳过：\(reason)")
            if reason.contains("排队") {
                // 这一支**一个字节都没发出去**，说成「请求确实发出去了」是假话。
                lines.append("这是我们自己的限速排不上，不是这个源慢或挂了")
                lines.append("处置：调大自动匹配选项的「每首最多等待」，"
                             + "或改用专辑模式（整碟只搜一次，不受逐首限速拖累）")
            } else {
                lines.append("请求确实发出去了，只是这一轮不再等它 —— 不算失败，也不计熔断")
            }
        }
        if let d = detail, !d.isEmpty, d != statusShortText { lines.append(d) }
        if let r = routeLine { lines.append(r) }
        if retries > 0 { lines.append("退避重试 \(retries) 次") }
        if latency > 0 { lines.append(String(format: "耗时 %.2f 秒", latency)) }
        return lines.joined(separator: "\n")
    }

    private var statusShortText: String {
        if case .failed(let w) = status { return w }
        return ""
    }

    /// 「0 条」的一句人话解释，按源定制。只在悬停提示里出现。
    static func emptyHint(_ id: String) -> String? {
        switch id {
        case "qq":      return "QQ 曲库无此曲（日文 OST、同人碟、独立发行常见）"
        case "netease": return "网易云曲库无此曲，或该版本已下架"
        case "kugou":   return "酷狗曲库无此曲"
        case "kuwo":    return "酷我曲库无此曲"
        case "itunes":  return "该地区的 iTunes Store 没有这首（可在设置里换个地区，或用「自动」按曲名语言选区）"
        default:        return nil
        }
    }

    /// 四态语义：界面据此选颜色（有结果=matched / 0 条=次要 / 失败=failed / 暂停=灰橙）。
    /// 软截止跳过复用「次要」灰：它和「0 条」一样**不是故障**，用户不必为它做任何事。
    public enum Tint: Sendable { case ok, none, bad, paused }
    public var tint: Tint {
        switch status {
        case .hits:    return .ok
        case .empty:   return .none
        case .failed:  return .bad
        case .paused:  return .paused
        case .skipped: return .none
        }
    }

    // MARK: 与 SourceAttempt 互转

    /// 降级链的过程记录 → 呈现模型。`.skipped` 视为「0 条」，并把跳过原因放进 detail。
    public init(attempt: SourceAttempt) {
        self.sourceID = attempt.sourceID
        self.latency = attempt.elapsed
        self.retries = 0
        self.detail = attempt.message
        switch attempt.outcome {
        case .succeeded(let n): self.status = n > 0 ? .hits(n) : .empty
        case .empty:            self.status = .empty
        case .failed:           self.status = .failed(SourceOutcome.shorten(attempt.message ?? "未知错误"))
        case .skipped:          self.status = .empty
        }
    }

    public static func from(_ attempts: [SourceAttempt]) -> [SourceOutcome] {
        attempts.map { SourceOutcome(attempt: $0) }
    }

    // MARK: 原因精简

    /// 完整原因，进悬停提示。
    public static func fullReason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// chip 上那几个字。原则：**一眼能分辨该怎么办** ——
    /// 超时/限流是「等一会儿」，HTTP 4xx/业务码是「这个源的接口变了或被风控了」。
    public static func shortReason(for error: Error) -> String {
        if let se = error as? SourceError {
            switch se {
            case .network(let m):        return networkReason(m)
            case .httpStatus(let c):     return "HTTP \(c)"
            case .decoding:              return "解析失败"
            case .rateLimited:           return "限流"
            case .missingAPIKey:         return "缺 API key"
            case .emptyResult(let m):    return businessReason(m)
            case .unsupported:           return "不支持"
            case .circuitOpen:           return "暂停中"
            }
        }
        return shorten(fullReason(for: error))
    }

    static func networkReason(_ m: String) -> String {
        let s = m.lowercased()
        if s.contains("timed out") || m.contains("超时") || s.contains("timeout") { return "超时" }
        if s.contains("cancel") || m.contains("取消") { return "已取消" }
        if s.contains("offline") || m.contains("未连接") || m.contains("离线") { return "无网络" }
        if s.contains("hostname") || m.contains("找不到服务器") || s.contains("host") { return "域名解析失败" }
        if s.contains("connection") || m.contains("连接") { return "连接中断" }
        if s.contains("ssl") || s.contains("certificate") { return "证书错误" }
        return shorten(m)
    }

    /// HTTP 200 但业务层失败。中文源普遍靠 retcode / code 表达，把那个码提出来最有用：
    /// QQ 缺 Referer 的 `retcode -1310` 是实测最常见的一种静默失败。
    static func businessReason(_ m: String) -> String {
        if let c = businessCode(in: m) { return c }
        if m.contains("静默置空") || m.contains("拦截") { return "被风控" }
        return shorten(m)
    }

    /// 从文案里抠出 `retcode: -1310` / `code=406` / `errcode=20017` 这样的码。
    static func businessCode(in text: String) -> String? {
        for key in ["retcode", "errcode", "ret", "code"] {
            guard let r = text.range(of: key, options: [.caseInsensitive]) else { continue }
            var rest = text[r.upperBound...]
            // 跳过 `=`、`:`、空格、全角冒号
            while let f = rest.first, f == "=" || f == ":" || f == " " || f == "：" {
                rest = rest.dropFirst()
            }
            var num = ""
            if rest.first == "-" { num = "-"; rest = rest.dropFirst() }
            while let f = rest.first, f.isNumber { num.append(f); rest = rest.dropFirst() }
            guard !num.isEmpty, num != "-" else { continue }
            return "\(key.lowercased()) \(num)"
        }
        return nil
    }

    /// HTTP 状态码，用于「503×4→通」。
    static func statusCode(in text: String) -> String? {
        guard let r = text.range(of: "HTTP ") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// 长文案截断。chip 放不下一整句话。
    static func shorten(_ s: String, limit: Int = 12) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「网络错误：xxx」这类前缀去掉，留后半段的实质内容
        for prefix in ["网络错误：", "响应解析失败：", "未获得有效结果：", "服务器返回 "] {
            if t.hasPrefix(prefix) { return shorten(String(t.dropFirst(prefix.count)), limit: limit) }
        }
        guard t.count > limit else { return t }
        return String(t.prefix(limit)) + "…"
    }
}

// MARK: - 一批结果的聚合

public extension Array where Element == SourceOutcome {

    /// 按源 id 排成稳定顺序（推荐优先级在前，其余按字典序）。
    func sortedByPriority() -> [SourceOutcome] {
        let order = SourceRegistry.recommendedPriority
        func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? (order.count + 1) }
        return sorted { a, b in
            let (ra, rb) = (rank(a.sourceID), rank(b.sourceID))
            return ra != rb ? ra < rb : a.sourceID < b.sourceID
        }
    }

    /// 一行摘要：`iTunes 8 · 网易云 5 · QQ ✘ 超时 · 酷狗 0`
    var inlineSummary: String {
        sortedByPriority().map(\.chipLabel).joined(separator: " · ")
    }
}

// MARK: - 批量统计里的「某个源整轮都在挂」

/// 一整批文件跑完后，按源聚合出来的健康度。
/// 只有**失败率 ≥ 50%** 的源才值得单独说一句 —— 偶发一两次失败是常态，不该刷屏。
public struct SourceBatchTally: Sendable {
    public var sourceID: String
    public var total: Int
    public var failed: Int
    public var empty: Int
    /// 因熔断暂停而**根本没有查询**的文件数。不计入 `failed`。
    public var paused: Int = 0
    /// 因软截止而**没等到**的文件数。同样不计入 `failed`。
    public var skipped: Int = 0
    /// 出现次数最多的那个失败原因。
    public var topReason: String?

    public init(sourceID: String, total: Int, failed: Int, empty: Int,
                paused: Int = 0, skipped: Int = 0, topReason: String? = nil) {
        self.sourceID = sourceID; self.total = total; self.failed = failed
        self.empty = empty; self.paused = paused; self.skipped = skipped
        self.topReason = topReason
    }

    /// 失败率的分母**扣掉暂停与软截止跳过的那些**：这两类文件都没拿到该源的答复，
    /// 拿它们当分母会把失败率稀释成假象。
    public var attempted: Int { max(0, total - paused - skipped) }
    public var failureRate: Double { attempted > 0 ? Double(failed) / Double(attempted) : 0 }
    public var displayName: String { SourceOutcome.displayName(sourceID) }

    /// 「本轮 QQ 12/12 失败（retcode -1310），已跳过」
    public var note: String {
        var s = "本轮 \(SourceOutcome.shortName(sourceID)) \(failed)/\(attempted) 失败"
        if let r = topReason { s += "（\(r)）" }
        s += "，已跳过"
        return s
    }

    /// 熔断追加行。用户拿到这句话就知道**该怎么办**：不是「重跑整批」，而是「对这些文件再跑一次」。
    /// 「QQ 音乐本轮 12 首因暂停未查询，可稍后对这些文件再跑一次」
    public var pausedNote: String? {
        guard paused > 0 else { return nil }
        return "\(displayName)本轮 \(paused) 首因暂停未查询，可稍后对这些文件再跑一次"
    }

    /// 软截止追加行。和 `pausedNote` 分开成句，因为**该怎么办**完全不同：
    /// 暂停是「等它恢复再跑一次」，软截止是「这个源太慢，要么调大等待秒数、要么别勾它」。
    public var skippedNote: String? {
        guard skipped > 0 else { return nil }
        return "\(displayName)本轮 \(skipped) 首超过等待上限被跳过（可在自动匹配选项的「网络」区调大「每首最多等待」）"
    }
}

public enum SourceOutcomeAggregator {

    /// 阈值：某个源失败到这个比例才在批量统计后面追加一行。
    public static let noteThreshold: Double = 0.5

    /// 把每个文件的逐源结果条按源聚合。
    public static func tally(_ perFile: [[SourceOutcome]]) -> [SourceBatchTally] {
        var totals: [String: Int] = [:]
        var fails: [String: Int] = [:]
        var empties: [String: Int] = [:]
        var pauses: [String: Int] = [:]
        var skips: [String: Int] = [:]
        var reasons: [String: [String: Int]] = [:]

        for list in perFile {
            for o in list {
                totals[o.sourceID, default: 0] += 1
                switch o.status {
                case .failed(let why):
                    fails[o.sourceID, default: 0] += 1
                    reasons[o.sourceID, default: [:]][why, default: 0] += 1
                case .empty:
                    empties[o.sourceID, default: 0] += 1
                case .paused:
                    pauses[o.sourceID, default: 0] += 1
                case .skipped:
                    skips[o.sourceID, default: 0] += 1
                case .hits:
                    break
                }
            }
        }

        return totals.keys.map { id in
            let top = reasons[id]?.max { $0.value < $1.value }?.key
            return SourceBatchTally(sourceID: id,
                                    total: totals[id] ?? 0,
                                    failed: fails[id] ?? 0,
                                    empty: empties[id] ?? 0,
                                    paused: pauses[id] ?? 0,
                                    skipped: skips[id] ?? 0,
                                    topReason: top)
        }
        .sorted { $0.failureRate > $1.failureRate }
    }

    /// 值得在批量统计后面单独说一句的那些源。
    public static func notableFailures(_ perFile: [[SourceOutcome]]) -> [SourceBatchTally] {
        tally(perFile).filter { $0.failed > 0 && $0.failureRate >= noteThreshold }
    }

    /// 本轮有文件因熔断暂停而没被查询的源。
    public static func pausedSources(_ perFile: [[SourceOutcome]]) -> [SourceBatchTally] {
        tally(perFile).filter { $0.paused > 0 }.sorted { $0.paused > $1.paused }
    }

    /// 本轮有文件因软截止被跳过的源。**只报「过半都被跳过」的**：
    /// 偶尔一两首赶上高分提前结束是设计的正常工作方式，不该刷屏。
    public static func skippedSources(_ perFile: [[SourceOutcome]]) -> [SourceBatchTally] {
        tally(perFile)
            .filter { $0.total > 0 && Double($0.skipped) / Double($0.total) >= noteThreshold }
            .sorted { $0.skipped > $1.skipped }
    }

    /// 批量统计的追加行。没有值得说的源时返回 nil。
    ///
    /// 两类追加行：真失败（「QQ 12/12 失败，已跳过」）与熔断暂停
    /// （「QQ 音乐本轮 12 首因暂停未查询，可稍后对这些文件再跑一次」）。
    /// 后者必须单独成句 —— 它给的是**行动建议**，混进失败率那句话里就没人看得懂了。
    public static func batchNote(_ perFile: [[SourceOutcome]]) -> String? {
        var lines = notableFailures(perFile).map(\.note)
        lines.append(contentsOf: pausedSources(perFile).compactMap(\.pausedNote))
        lines.append(contentsOf: skippedSources(perFile).compactMap(\.skippedNote))
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "；")
    }

    /// 把整批文件的逐源结果条压成**一条**结果条，供复核表顶部那一行 chips 用。
    ///
    /// 压缩规则（顺序即优先级）：
    /// 1. 失败过半 → 判失败，写最常见的那个原因，数字写「12/12 失败」；
    /// 2. 拿到过结果 → 判有结果，数字是整批累计条数；
    /// 3. 其余 → 0 条。
    /// 这样一行就能同时回答「QQ 挂没挂」和「iTunes 一共给了多少条」。
    public static func merge(_ perFile: [[SourceOutcome]]) -> [SourceOutcome] {
        let tallies = tally(perFile)
        var hits: [String: Int] = [:]
        var latencies: [String: [TimeInterval]] = [:]
        var details: [String: String] = [:]
        var pausedUntil: [String: Date] = [:]
        for list in perFile {
            for o in list {
                hits[o.sourceID, default: 0] += o.status.hitCount
                latencies[o.sourceID, default: []].append(o.latency)
                if details[o.sourceID] == nil, let d = o.detail { details[o.sourceID] = d }
                if let u = o.status.pausedUntil {
                    pausedUntil[o.sourceID] = max(pausedUntil[o.sourceID] ?? .distantPast, u)
                }
            }
        }
        return tallies.map { t -> SourceOutcome in
            let ls = latencies[t.sourceID] ?? []
            let avg = ls.isEmpty ? 0 : ls.reduce(0, +) / Double(ls.count)
            let total = hits[t.sourceID] ?? 0
            let status: SourceOutcome.Status
            var detail = details[t.sourceID]
            if t.failed > 0, t.failureRate >= noteThreshold {
                status = .failed(t.topReason ?? "失败")
                detail = "\(t.failed)/\(t.attempted) 次失败" + (t.topReason.map { "（\($0)）" } ?? "")
            } else if total > 0 {
                status = .hits(total)
                var notes: [String] = []
                if t.failed > 0 { notes.append("其中 \(t.failed)/\(t.attempted) 次失败") }
                // 「补查生效」的样子：既有结果、又有过暂停 —— 这一句是它唯一的痕迹。
                if t.paused > 0 { notes.append("另有 \(t.paused) 首因暂停未查询") }
                if t.skipped > 0 { notes.append("另有 \(t.skipped) 首超过等待上限被跳过") }
                if !notes.isEmpty { detail = notes.joined(separator: "，") }
            } else if t.skipped > 0, t.skipped >= t.total - t.paused {
                // 整轮都没等到它：chip 必须说「跳过」而不是「0 条」——
                // 「0 条」会让用户以为这个源没有这些歌，从而去改搜索词，方向全错。
                status = .skipped(reason: "本轮 \(t.skipped)/\(t.total) 首超过等待上限")
                detail = "这个源比「每首最多等待」慢，本轮它的结果一次都没被用上"
            } else if t.paused > 0, let u = pausedUntil[t.sourceID] {
                // 整轮全被熔断挡下：chip 必须说「暂停」而不是「0 条」——
                // 「0 条」会让用户以为 QQ 没有这些歌，从而去改搜索词，方向全错。
                status = .paused(until: u)
                detail = "本轮 \(t.paused)/\(t.total) 首因熔断暂停未查询"
            } else {
                status = .empty
            }
            return SourceOutcome(sourceID: t.sourceID, status: status,
                                 latency: avg, detail: detail)
        }
        .sortedByPriority()
    }
}

//
//  HTTPClient.swift
//  MacTagger — 在线源共用的网络栈
//
//  把 C 报告的实测约束固化进来，避免每个适配器各写一遍：
//  · MusicBrainz 瞬时 503 率约 50% → 指数退避重试
//  · MusicBrainz 官方要求 ≤1 req/s → 按源限速
//  · QQ 歌词缺 Referer 会返回 retcode:-1310 → 按源默认请求头
//  · QQ 搜索被风控静默置空（HTTP 200 但结果为空）→ 调用方必须校验业务层
//

import Foundation

/// 单个源的网络策略。
public struct SourcePolicy: Sendable {
    /// 两次请求之间的最小间隔。MusicBrainz 官方要求 ≥1s。
    public var minimumInterval: TimeInterval
    /// 最大重试次数（仅对可重试的错误：5xx、超时、连接中断）。
    public var maxRetries: Int
    /// 首次退避时长，其后指数增长。
    public var initialBackoff: TimeInterval
    /// 该源所有请求都会带上的头。
    public var defaultHeaders: [String: String]
    public var timeout: TimeInterval
    /// **超时/连接中断专用的重试上限**，与 `maxRetries`（管 429/5xx）分开。
    ///
    /// 为什么要分：503 是对方明确说「这一发我处理不了，换个时间再来」——重试是对的；
    /// 超时是对方**已经收下了请求却回不出来**，多半正卡着，立刻再发只会加重拥塞。
    /// AU 轮实测的 QQ 就是后者：接口没坏，是批量并发把它压慢了，而我们的重试在火上浇油。
    public var networkMaxRetries: Int
    /// 超时重试的首个退避时长，其后翻倍（1s → 2s → 4s）。
    /// 比 `initialBackoff`（0.5s）长一个量级：给对方留出真正缓过来的时间。
    public var networkInitialBackoff: TimeInterval
    /// 该源的熔断参数。
    public var circuit: CircuitPolicy
    /// **发包抖动**：每发请求在限速之后再随机等 `jitter` 秒。nil = 不抖。
    ///
    /// 为什么要有它（AX 轮，只给 QQ 开）：限速器是「每 x 秒放一发」的等间隔节拍，
    /// 文件级并发一高，发出去的请求就成了一串**间隔完全均匀**的脉冲 ——
    /// 那正是风控最容易识别的形状，实测表现为 smartbox 整批静默置空（HTTP 200、0 条）。
    /// 加一点随机抖动把节拍打散，代价是每发多等零点几秒。
    /// 刻意不给其它源开：它们没有出现置空，白白加延迟没有道理。
    public var jitter: ClosedRange<TimeInterval>?

    /// **哪些 HTTP 状态码要按「限流」处置**（退避重试 + 计入熔断），而不是当成普通失败。
    ///
    /// 默认只有 429。iTunes 要多加一个 **403**（BD 轮实测的根因）：
    /// Apple 对 iTunes Search API 的建议是 ≈20 次/分钟，超了之后它**不回 429 而是回 403**，
    /// 于是原先那条 `default:` 分支把它当成「接口权限不对」直接判死 ——
    /// 既不退避、也不熔断，下一首继续用同样的速率去撞，
    /// 用户看到的就是「iTunes 一直失败」。
    public var rateLimitStatusCodes: Set<Int>

    public init(minimumInterval: TimeInterval = 0.3,
                maxRetries: Int = 2,
                initialBackoff: TimeInterval = 0.5,
                defaultHeaders: [String: String] = [:],
                timeout: TimeInterval = 15,
                networkMaxRetries: Int = 2,
                networkInitialBackoff: TimeInterval = 1.0,
                circuit: CircuitPolicy = .default,
                jitter: ClosedRange<TimeInterval>? = nil,
                rateLimitStatusCodes: Set<Int> = [429]) {
        self.rateLimitStatusCodes = rateLimitStatusCodes
        self.jitter = jitter
        self.minimumInterval = minimumInterval
        self.maxRetries = maxRetries
        self.initialBackoff = initialBackoff
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
        self.networkMaxRetries = networkMaxRetries
        self.networkInitialBackoff = networkInitialBackoff
        self.circuit = circuit
    }

    /// 浏览器 UA。中文源实测需要它，缺失会被拦。
    public static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// MusicBrainz 要求的合规 UA：能标识应用并给出联系方式。
    /// 发布前必须换成我们自己的项目页，不可沿用测试值。
    public static let musicBrainzUA = "MacTagger/0.1.0 ( https://github.com/lingluan/mactagger )"

    public static let `default` = SourcePolicy()

    /// MusicBrainz：限速 1 req/s + 4 次退避重试 + 合规 UA。
    public static let musicBrainz = SourcePolicy(
        minimumInterval: 1.1,
        maxRetries: 4,
        initialBackoff: 0.5,
        defaultHeaders: ["User-Agent": musicBrainzUA, "Accept": "application/json"]
    )

    /// 中文源通用：浏览器 UA + 适度限速。
    public static func chinese(referer: String? = nil) -> SourcePolicy {
        var headers = ["User-Agent": browserUA]
        if let referer { headers["Referer"] = referer }
        return SourcePolicy(minimumInterval: 0.3, maxRetries: 2, defaultHeaders: headers)
    }

    /// iTunes 专用（BD 轮）：**把发包速率压到 Apple 的建议值以下**。
    ///
    /// Apple 对 iTunes Search API 的公开建议是 **≈20 次/分钟**。原先这里是 1.0 s
    /// （= 60 次/分钟，正好超三倍），批量匹配几秒内就撞上限流；而限流的表现是 **403**，
    /// 被老代码的 `default:` 分支当成普通 HTTP 失败判死 —— 这就是「iTunes 一直失败」。
    ///
    /// 3.1 s = 19.3 次/分钟，留一点余量给时钟抖动。代价是 100 首要 5 分钟，
    /// 因此 `AlbumMatchService` 那条「按专辑去重、整碟只搜一次」的路更重要了
    /// （见 `ITunesSource.albumKey`）。
    /// · `maxRetries` 3：限流退避 0.6→1.2→2.4 s，覆盖住一个限速窗口的抖动。
    /// · `rateLimitStatusCodes` 加 403：Apple 超频时回的是 403，不是 429。
    public static func itunes() -> SourcePolicy {
        SourcePolicy(minimumInterval: 3.1,
                     maxRetries: 3,
                     initialBackoff: 0.6,
                     defaultHeaders: ["User-Agent": browserUA,
                                      "Accept": "application/json"],
                     timeout: 15,
                     rateLimitStatusCodes: [403, 429])
    }

    /// QQ 专用（AU 轮实测调整，其它源不动）：
    /// · `timeout` 15 → **25 s**：QQ 单次正常响应本就 2.4–3.0 s，批量并发时尾延迟经常越过 15 s，
    ///   那不是「挂了」而是「慢」，15 s 会把大量本来能拿到结果的请求判死。
    /// · `minimumInterval` 0.3 → **0.5 s**：文件级并发 4 条线同时压 QQ 一个源，
    ///   把发包节奏放缓三分之一，尾延迟明显收敛。
    /// · `jitter` 0.2–0.6 s（AX 轮）：见 `SourcePolicy.jitter` 的注释 —— 打散等间隔脉冲，
    ///   试图避开「批量下 smartbox 整批静默置空」。
    public static func qq(referer: String? = "https://y.qq.com/") -> SourcePolicy {
        var p = chinese(referer: referer)
        p.minimumInterval = 0.5
        p.timeout = 25
        p.jitter = 0.2...0.6
        return p
    }
}

// MARK: - 限速器

/// 按源 ID 独立限速。actor 保证并发安全。
///
/// **令牌节拍模型**：actor 里只存一个「本源下一发最早可以开始的时刻」（`nextAllowedAt`），
/// 每个调用者进来先**原子地领走自己的时隙**（`reserve`，全程无 await，
/// actor 的串行性保证两个调用者绝不会领到同一个时隙），领完才到 actor **外面**去睡。
/// 睡多久与限速状态无关，因此并发再高也不会互相踩。
actor RateLimiter {

    /// 本源**下一发**请求最早可以开始的时刻。没有记录 = 现在就能发。
    private var nextAllowedAt: [String: Date] = [:]

    /// 原子领取一个发包时隙，**不睡**。返回值是这一发应当开始的时刻。
    ///
    /// `slot = max(now, nextAllowedAt)`，随即把 `nextAllowedAt` 推到 `slot + interval`。
    /// 空闲久了 `nextAllowedAt` 已经过期，`max` 会把它拉回 `now` —— 不会攒出一堆
    /// 「欠着的」时隙让下一批请求瞬间齐发。
    func reserve(sourceID: String, interval: TimeInterval) -> Date {
        let now = Date()
        guard interval > 0 else { return now }
        let slot = max(now, nextAllowedAt[sourceID] ?? now)
        nextAllowedAt[sourceID] = slot.addingTimeInterval(interval)
        return slot
    }

    /// 原子领时隙，但**只在这个时隙不晚于 `notLaterThan` 时才领**；
    /// 领不到就返回 nil，且**一个时隙都不占用**。
    ///
    /// 为什么需要它（BD 轮实测）：iTunes 是 3.1 s 一发，逐首模式并发 8 条线、
    /// 每首的软截止 4 s —— 于是 20 首里有 19 首的做法是「排进队 → 排到第 20 秒 →
    /// 软截止到点把它取消」。请求确实没发出去，但**时隙已经被它占掉了**：
    /// 一整批 20 个时隙（62 秒的发包预算）全烧在注定要被取消的请求上，
    /// 结果就是实测的 iTunes 0/20。
    /// 先问「排到我这一发是第几秒」、排不上就当场认输，队列才不会越排越长。
    func reserve(sourceID: String, interval: TimeInterval, notLaterThan: Date?) -> Date? {
        let now = Date()
        guard interval > 0 else { return now }
        let slot = max(now, nextAllowedAt[sourceID] ?? now)
        if let limit = notLaterThan, slot > limit { return nil }
        nextAllowedAt[sourceID] = slot.addingTimeInterval(interval)
        return slot
    }

    /// 只看不领：现在来一发要排多久。用于把「排了多久」如实写进跳过原因。
    func queueDelay(sourceID: String) -> TimeInterval {
        max(0, (nextAllowedAt[sourceID] ?? .distantPast).timeIntervalSinceNow)
    }

    /// 清空所有源的节拍。**只给 probe 用**：同一进程里跑前后对照时，
    /// 上一组攒下的 `nextAllowedAt` 会把下一组的第一发推到几十秒之后。
    func reset() { nextAllowedAt.removeAll() }

    /// 睡到某个时隙。抽出来是因为「领时隙」与「睡到时隙」现在有两个调用方
    /// （`waitIfNeeded` 和 `HTTPClient.send` 的带预算那一路），睡法必须一模一样。
    static func sleep(until slot: Date) async {
        let delay = slot.timeIntervalSinceNow
        guard delay > 0 else { return }
        // `Task.sleep(nanoseconds:)` 走的是**默认容差**的定时器，macOS 会做 timer coalescing：
        // 本机实测最多晚醒 0.75 s。晚醒本身不违反限速（只会更慢），但它是**白付的**延迟 ——
        // 60 发就是白等半分钟，而且会把「这一发已经排到第几秒」搅得没法验收。
        // `tolerance: .zero` 把这份容差拿掉；`.continuous` 是不受系统时钟调整影响的单调钟。
        try? await Task.sleep(until: .now.advanced(by: .nanoseconds(Int64(delay * 1_000_000_000))),
                              tolerance: .zero,
                              clock: .continuous)
    }

    /// 排到本源的下一个发包时隙，并等到那一刻。
    ///
    /// **BD 轮修的并发漏洞**：原实现是「算出还差多久 → sleep → 回来才写 `lastRequestAt`」。
    /// `Task.sleep` 会让出 actor，于是文件级并发 8 条线**同时**进来时，
    /// 八个调用读到的是同一个 `last`、算出同一个延迟、睡同一段时间，然后**一起发**——
    /// 限速器实测形同虚设：iTunes 声称 3.1 s 一发，压测里 60 发只用了 11 秒
    /// （≈327 次/分钟，是 Apple 建议值 20 次/分钟的 16 倍）。
    /// 这正是「iTunes 一直失败」的物理原因：我们其实一直在以突发流量撞它。
    ///
    /// 改法是**先领时隙再睡**：时隙由 actor 串行分配，谁也抢不到同一个；
    /// 睡在 actor 外面（本方法 `nonisolated`），睡着的人不占限速器。
    /// 语义就是各 `SourcePolicy` 注释里一直写着的那句「两次请求开始之间隔多久」。
    ///
    /// 验收：`mactagger-probe sources limiter itunes --n 60 --concurrency 4`
    /// 断言相邻发包间隔的**最小值** ≥ `interval × 0.95`。
    nonisolated func waitIfNeeded(sourceID: String, interval: TimeInterval) async {
        guard interval > 0 else { return }
        guard let slot = await reserve(sourceID: sourceID, interval: interval,
                                       notLaterThan: nil) else { return }
        await RateLimiter.sleep(until: slot)
    }
}

// MARK: - 排队预算

/// 「这一发还没发就放弃了」：限速队列已经排到软截止之后，发出去也只会在到点时被取消。
///
/// **这不是失败** —— 一个字节都没发出去，对方没有任何问题。
/// 调用方（`AutoMatchService.fetchOne`）会把它转成 `.skipped`，
/// 并把 `reason` 原样写进结果条，好让用户看见该拧的是哪个旋钮。
public struct RateLimitQueueTooLong: Error, Sendable {
    public let sourceID: String
    /// 现在发的话要排多久。
    public let waitWouldBe: TimeInterval
    /// 本源的发包间隔。
    public let interval: TimeInterval
    /// 调用方还剩多少时间。
    public let remaining: TimeInterval

    /// 结果条上那句人话。刻意把三个数都写出来 ——
    /// 「慢」和「排队」是两回事，用户要能一眼看出这是**我们自己的限速**造成的。
    public var reason: String {
        guard remaining > 0 else {
            // 领时隙的那一刻软截止已经过了。写成「排队 0 s > 剩余 0 s」是句病句，
            // 而且会让人以为不排队也没发 —— 实际是这一发根本没赶上。
            return String(format: "等待上限已到，还要排队 %.1f s（本源 %.1f s 一发）",
                          waitWouldBe, interval)
        }
        return String(format: "限速排队 %.1f s（本源 %.1f s 一发）> 剩余等待 %.1f s",
                      waitWouldBe, interval, remaining)
    }
}

/// 调用方声明「我最多等到什么时候」。
///
/// 用任务本地值而不是给每个适配器加参数：软截止是**调度层**的概念，
/// 十几个适配器没有一个该知道它的存在；而 `HTTPClient` 是所有源唯一的网络出口，
/// 在那里读一次就够。没设值时（歌词、专辑模式、健康探测）行为与从前完全一致。
public enum RateLimitBudget {
    @TaskLocal public static var deadline: Date?
}

// MARK: - 客户端

public struct HTTPClient: Sendable {

    public let sourceID: String
    public let policy: SourcePolicy
    /// **测试注入点**：在真正发起网络 I/O 的那一刻被调用，入参是本源的 timeout。
    ///
    /// 存在的唯一理由是可控地复现「对方收下了请求却迟迟不回」。位置必须**正好在
    /// `session.data(for:)` 之前**：再往前一步（比如放在适配器里）就绕开了限速、
    /// 重试、熔断三段逻辑，验的就不是我们要验的那套代码了。
    /// 闸门抛出的错误会掉进和 URLSession 同一个 `catch`，因此超时判定、退避、
    /// 熔断计数全都按真实路径走。生产路径这个属性恒为 nil。
    public let gate: (@Sendable (TimeInterval) async throws -> Void)?
    /// **全进程唯一**的限速器（按源 ID 分桶）。刻意不是 `private`：
    /// `mactagger-probe sources limiter` 要压的就是生产路径上的这一个实例 ——
    /// 另造一个来测等于测了个替身，测过也不说明生产路径是对的。
    static let limiter = RateLimiter()
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 4 → 8（AX 轮）。**必须跟上文件级并发的上限**，否则是我们自己给自己制造延迟：
        // 实测把并发提到 8 之后，第一波 8 个文件同时打 iTunes，只有 4 条连接可用，
        // 排在后面那 4 个的搜索请求要等前面的封面下载（约 0.5 MB）让出连接 ——
        // 于是「iTunes 4.0 s 超过软截止」成片出现，而 iTunes 真实响应只要 1.2 s。
        // 软截止随后把这个**我们自己造成的**延迟判成「这个源慢」，把它整轮跳过。
        //
        // 提高连接数不会加大对方的压力：发包速率仍由各源的 `minimumInterval`
        // 限速器决定（限的是「两次请求开始之间隔多久」），这里放开的只是
        // 「同时能有几发在飞」——本来就该由并发度决定的那个数。
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    public init(sourceID: String,
                policy: SourcePolicy = .default,
                gate: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.sourceID = sourceID
        self.policy = policy
        self.gate = gate
    }

    // MARK: 请求

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: policy.timeout)
        req.httpMethod = "GET"
        applyHeaders(&req, extra: headers)
        return try await send(req)
    }

    public func post(_ url: URL,
                     body: Data,
                     contentType: String = "application/x-www-form-urlencoded",
                     headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: policy.timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        applyHeaders(&req, extra: headers)
        return try await send(req)
    }

    /// GET 并解析 JSON。
    public func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        let data = try await get(url, headers: headers)
        return try parseJSON(data)
    }

    /// 解析 JSONP：`cb({...})` → 里面的 JSON。QQ 歌词接口即此格式。
    public func parseJSONP(_ data: Data) throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceError.decoding("响应不是有效文本")
        }
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"), open < close else {
            // 没有包裹层，当作裸 JSON
            return try parseJSON(data)
        }
        let inner = String(text[text.index(after: open)..<close])
        guard let innerData = inner.data(using: .utf8) else {
            throw SourceError.decoding("JSONP 内层编码失败")
        }
        return try parseJSON(innerData)
    }

    /// 解析单引号伪 JSON。C 报告实测酷我专辑接口返回此种非法 JSON。
    public func parseLooseJSON(_ data: Data) throws -> Any {
        if let ok = try? parseJSON(data) { return ok }
        guard var text = String(data: data, encoding: .utf8) else {
            throw SourceError.decoding("响应不是有效文本")
        }
        text = text.replacingOccurrences(of: "'", with: "\"")
        guard let fixed = text.data(using: .utf8), let ok = try? parseJSON(fixed) else {
            throw SourceError.decoding("单引号修复后仍不是合法 JSON")
        }
        return ok
    }

    public func parseJSON(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw SourceError.decoding(error.localizedDescription) }
    }

    // MARK: 内部

    private func applyHeaders(_ req: inout URLRequest, extra: [String: String]) {
        for (k, v) in policy.defaultHeaders { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
    }

    /// 「值得退避重试」的底层错误：超时、连接被掐、连不上、握手失败。
    /// 这一类都可能是瞬时的，隔一会儿再试有意义；域名解析失败、离线则不在其中。
    static func isRetryableNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorSecureConnectionFailed:
                return true
            default: return false
            }
        }
        return isHangLike(error)
    }

    /// 「这一发是被我们自己取消的」。URLSession 把取消报成 `NSURLErrorCancelled`，
    /// 结构化并发报成 `CancellationError`，两条路都要认。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// 「对方把我们挂住了」——**只有这一类计入熔断**。
    ///
    /// 为什么要比 `isRetryableNetworkError` 窄：熔断的收益是「不再为这个源白等」。
    /// 连不上主机（`CannotConnectToHost`）是**立刻**失败的，等不等它都不花时间，
    /// 把它计进去只会让一次路由抖动就把源暂停 60 秒，纯属误伤。
    /// 真正会拖死批量的只有两种：请求超时，和连接被对方在中途掐断。
    static func isHangLike(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost
        }
        let s = error.localizedDescription.lowercased()
        return s.contains("timed out") || s.contains("timeout")
            || error.localizedDescription.contains("超时")
    }

    /// 探测失败原因的短文案（进 `pauseReason`，结果条悬停提示里给用户看）。
    static func probeFailureReason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost:    return "连不上主机"
            case NSURLErrorSecureConnectionFailed: return "安全连接失败"
            case NSURLErrorTimedOut:               return "超时"
            case NSURLErrorNetworkConnectionLost:  return "连接中断"
            default: break
            }
        }
        return "网络错误"
    }

    private func send(_ req: URLRequest) async throws -> Data {
        var attempt = 0                      // 429/5xx 的重试计数
        var networkAttempt = 0               // 超时/连接中断的重试计数（与上面分开）
        var backoff = policy.initialBackoff
        var networkBackoff = policy.networkInitialBackoff
        // 健康台账用：这是所有源唯一的网络出口，在这里记一次，全部适配器自动有数据。
        // 只反映 HTTP 层成败；「HTTP 200 但业务层为空」由各源自己判定，
        // 走 SourceHealth.record(outcomes:) 那条路补记。
        let startedAt = Date()
        func report(_ result: Result<Void, Error>) {
            let elapsed = Date().timeIntervalSince(startedAt)
            let sid = sourceID
            let retried = attempt
            Task.detached(priority: .utility) {
                switch result {
                case .success:
                    await SourceHealth.shared.record(
                        sid, SourceHealthEntry(kind: .ok, latency: elapsed,
                                               reason: retried > 0 ? "退避重试 \(retried) 次后成功" : nil))
                case .failure(let e):
                    await SourceHealth.shared.record(sid, failed: e, latency: elapsed)
                }
            }
        }

        // 熔断参数按源注册一次（幂等）。放在这里而不是 init，是因为策略本身就挂在 client 上。
        await SourceCircuitBreaker.shared.configureIfAbsent(sourceID, policy.circuit)

        // ★ 这一次 `send` 是否持有半开探测的占位（BP-G 轮，修 BO 报告 #3「熔断锁死」）。
        //
        // 持有期间的规矩只有两条：
        //   ① 重试**不再回到闸门重新 `acquire`** —— 原先每轮 `while` 顶端都重新领，
        //      探测撞 503/429/连接被拒后 `continue` 回来，被**自己的**占位拒掉，
        //      抛 `.circuitOpen` 逃出 `send`，占位永不交还 → 源锁死到重启；
        //   ② 从 `send` 出去的**每一条路**都必须把结论交回熔断器
        //      （成功 / 探测失败再开闸 / 判恢复 / 取消放占位），一条都不许漏。
        var holdingProbe = false

        while true {
            // ★ 软截止取消（AX 轮）。调用方决定不再等这个源了，就在这里立刻收工：
            // **不记健康台账、不计熔断**——我们对这一发的结果一无所知，任何结论都是编的。
            // 放在循环顶端而不是只在 catch 里判，是因为退避重试那一支会 `try?` 掉
            // `Task.sleep` 的取消错误，不在这里拦一道就会空转到重试次数用完。
            // 但探测占位**必须**放掉（重试途中被取消，占位就在我们手里）。
            if Task.isCancelled {
                if holdingProbe { await SourceCircuitBreaker.shared.recordCancelled(sourceID) }
                throw CancellationError()
            }

            // ★ 熔断闸门。**必须在限速等待之前** ——
            // 放在之后就成了「先排 0.5 s 的队，再告诉你这个源被暂停了」，白等一场。
            // 已持有探测占位的重试不再过闸（见上面 `holdingProbe` 的注释）。
            if !holdingProbe {
                switch await SourceCircuitBreaker.shared.acquire(sourceID) {
                case .reject(let until):
                    // 一发请求都没出去，因此**不记健康台账**（见 SourceHealth.record(outcomes:) 的注释）。
                    // 原因一路带到结果条：「限流中，12 秒后继续」和「连续超时」对用户是两件事。
                    let why = await SourceCircuitBreaker.shared.stats(sourceID).pauseReason
                    throw SourceError.circuitOpen(sourceID, until, why)
                case .probe:
                    holdingProbe = true
                case .allow:
                    break
                }
            }

            // ★ 限速排队（BD 轮）。调用方声明了软截止就走「够不够得上再领时隙」那条路：
            //   排到软截止之后的那一发**根本不领时隙**，直接认输。
            //   不这么做的话，注定要被取消的请求会把发包预算全占光（实测 iTunes 0/20）。
            if let slot = await Self.limiter.reserve(sourceID: sourceID,
                                                     interval: policy.minimumInterval,
                                                     notLaterThan: RateLimitBudget.deadline) {
                await RateLimiter.sleep(until: slot)
            } else {
                let wait = await Self.limiter.queueDelay(sourceID: sourceID)
                // 半开探测的占位必须放掉，否则这个源会被永久锁死在 `.probe` 上
                // ——和软截止取消那一支同一个道理。
                await SourceCircuitBreaker.shared.recordCancelled(sourceID)
                throw RateLimitQueueTooLong(
                    sourceID: sourceID,
                    waitWouldBe: wait,
                    interval: policy.minimumInterval,
                    remaining: RateLimitBudget.deadline?.timeIntervalSinceNow ?? 0)
            }
            // 抖动放在限速**之后**：限速定的是「最快多久一发」，抖动只往后推，
            // 两者叠加仍然不会违反各源的最小间隔。
            if let j = policy.jitter {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: j) * 1_000_000_000))
            }

            do {
                if let gate { try await gate(policy.timeout) }
                let (data, response) = try await Self.session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw SourceError.network("非 HTTP 响应")
                }
                switch http.statusCode {
                case 200...299:
                    await SourceCircuitBreaker.shared.recordSuccess(sourceID)
                    report(.success(()))
                    return data
                case let code where policy.rateLimitStatusCodes.contains(code):
                    // 限流：退避重试；退到底还在限就**开熔断闸**，让后续请求本地立即返回，
                    // 而不是继续拿真实请求去撞墙（撞墙只会把限流窗口一直续上）。
                    // 半开探测撞上限流**不重试**：对方明说还在限，再撞只会续上限流窗口；
                    // 直接交给 `recordRateLimited`（它会把暂停翻倍、重新开闸）。
                    if !holdingProbe, attempt < policy.maxRetries {
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        backoff *= 2
                        continue
                    }
                    await SourceCircuitBreaker.shared.recordRateLimited(sourceID, status: code)
                    // 不在这里 report：下面的 `catch let e as SourceError` 会统一记一次，
                    // 记两次会把限流在健康台账里放大成两倍失败。
                    throw SourceError.rateLimited
                case 500...599:
                    // MusicBrainz 实测瞬时 503 率约 50%，必须退避重试
                    // （持有探测占位时照样重试 —— 仍是同一发逻辑探测，占位不交出去）。
                    if attempt < policy.maxRetries {
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        backoff *= 2
                        continue
                    }
                    // 探测退到底还是 5xx：探测失败 → 回到开闸态、暂停翻倍（BP-G 轮）。
                    if holdingProbe {
                        await SourceCircuitBreaker.shared.recordProbeFailure(
                            sourceID, reason: "HTTP \(http.statusCode)")
                    }
                    throw SourceError.httpStatus(http.statusCode)
                default:
                    throw SourceError.httpStatus(http.statusCode)
                }
            } catch let e as SourceError {
                await SourceCircuitBreaker.shared.recordOtherFailure(sourceID)
                report(.failure(e))
                throw e
            } catch {
                // ★ 被取消（软截止）。同循环顶端那一处：不记账、不计熔断，
                // 但**必须**把半开探测的占位放掉，否则这个源会被永久锁死在 `.probe` 上。
                if Self.isCancellation(error) {
                    await SourceCircuitBreaker.shared.recordCancelled(sourceID)
                    throw CancellationError()
                }
                guard Self.isRetryableNetworkError(error) else {
                    // 域名解析失败、离线、证书错误这些：重试没有意义，也不该拖垮熔断计数。
                    await SourceCircuitBreaker.shared.recordOtherFailure(sourceID)
                    report(.failure(SourceError.network(error.localizedDescription)))
                    throw SourceError.network(error.localizedDescription)
                }

                // ★ 超时/连接中断：先记一笔给熔断器，闸开了就**立刻**放弃重试。
                //   原先这里是「立刻按 maxRetries 连发重试」，对方正卡着时等于三倍流量，
                //   这正是用户看到成片「QQ ✘ 超时」的直接原因。
                //   只有「挂住」类才计熔断；连不上主机之类的快失败照旧只退避重试。
                let tripped = Self.isHangLike(error)
                    ? await SourceCircuitBreaker.shared.recordTimeout(sourceID)
                    : false
                if tripped {
                    // 闸刚被这一发打开：不再重试，但如实抛「超时」——
                    // 这一发确实是超时失败的，报成「暂停中」会把它从失败统计里抹掉。
                    // 后续请求才是 `.circuitOpen`（`acquire` 那一支）。
                    report(.failure(SourceError.network(error.localizedDescription)))
                    throw SourceError.network(error.localizedDescription)
                }
                if networkAttempt < policy.networkMaxRetries {
                    networkAttempt += 1
                    // 指数退避：1s → 2s → 4s。不是「立刻再来一发」。
                    try? await Task.sleep(nanoseconds: UInt64(networkBackoff * 1_000_000_000))
                    networkBackoff *= 2
                    continue
                }
                // 探测退到底仍连不上（连接被拒 / 握手失败）：探测失败 → 回到开闸态、暂停翻倍。
                // 原先这里一句熔断回报都没有，占位永不交还（BO 报告 #3，BP-G 轮修）。
                if holdingProbe {
                    await SourceCircuitBreaker.shared.recordProbeFailure(
                        sourceID, reason: Self.probeFailureReason(error))
                }
                report(.failure(SourceError.network(error.localizedDescription)))
                throw SourceError.network(error.localizedDescription)
            }
        }
    }
}

// MARK: - 取值辅助

/// 从任意 JSON 结构里按路径安全取值，省得每个适配器写一堆 as? 转换。
public struct JSONBox: Sendable {
    public let raw: Any?
    public init(_ raw: Any?) { self.raw = raw }

    public subscript(key: String) -> JSONBox {
        JSONBox((raw as? [String: Any])?[key])
    }
    public subscript(index: Int) -> JSONBox {
        guard let arr = raw as? [Any], index >= 0, index < arr.count else { return JSONBox(nil) }
        return JSONBox(arr[index])
    }

    public var string: String? {
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    public var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
    public var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    public var array: [JSONBox] { (raw as? [Any])?.map(JSONBox.init) ?? [] }
    public var exists: Bool { raw != nil && !(raw is NSNull) }
}

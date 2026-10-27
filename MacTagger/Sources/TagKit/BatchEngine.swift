//
//  BatchEngine.swift
//  MacTagger — 批量处理引擎
//
//  原版所有批量操作（批量写标签、批量提取封面、批量重命名、批量补全…）共用
//  同一套「进度 + 结果统计 + 可取消 + 并发度」框架，结果文案固定为
//
//      成功: {0}, 失败: {1}, 忽略: {2}, 总共: {3}
//
//  本文件就是这套公共框架。`applyEdits` 是阶段 1 用到的第一个具体任务，
//  后续阶段的批量任务只需要提供一个 `(Item) -> BatchOutcome` 闭包，
//  统计/进度/取消/并发全部复用。
//
//  并发度：原版设置里叫「网络搜索线程数」（默认 4）。本地 IO 场景同样默认 4——
//  TagLib 的诊断收集是 thread_local，读写不同文件互不干扰，实测见报告。
//

import Foundation

// MARK: - 进度

public struct BatchProgress: Sendable {
    public var completed: Int
    public var total: Int
    /// 刚刚完成的那个文件的路径（并发下不保证顺序，只用于「正在处理…」提示）。
    public var currentPath: String?
    /// 附加提示行（可移动存储降速暂停 / 恢复等）。为 nil 时界面不占位。
    public var note: String?

    // MARK: 字节口径（用来算 MB/s 与剩余时间）
    //
    // 「完成几个文件」不足以估剩余时间：一首 3 MB 的 mp3 和一首 50 MB 的 flac
    // 都算 1 个，进度条走得一样快，实际耗时差十几倍。所以这里同时按**要落盘的字节**
    // 计量 —— 权重取 `TagService.writeCostDetail(...).totalWrittenBytes`：
    //
    //     搬动的音频字节（整文件重写；开了预留填充就再搬一次）+ 新写进标签区的字节
    //     （封面 + 文本 + 容器包头 + 预留填充，即 `newMetadataBytes`）
    //
    // 早先这里只算**搬动**那一半，于是「6 个 48 KB 的小 FLAC 写一张 1.5 MB 封面」
    // 进度条的 bytesTotal 只有 0.3 MB，而保存确认框那句「写入新数据约 9 MB」算的是
    // 落盘总量 —— 同一次保存两个数字差三十倍，进度条 0.3 MB 早早走满、ETA 归零之后
    // 还在写。两处现在同出一个函数（`WriteCostDetail`），口径永远一致。
    //
    // `bytesTotal == 0` 表示这批既不搬动也不写新数据（例如只剥 ID3v1），
    // 界面就不显示速率（那时耗时由固定开销决定，跟字节没关系）。

    /// 已完成的「落盘字节」（搬动 + 新写入元数据）。
    public var bytesDone: Int64
    /// 本批预计要落盘的总字节。0 = 既没有搬动也没有新数据。
    public var bytesTotal: Int64
    /// 本批开始时刻，用来算速率与剩余时间。
    public var startedAt: Date?

    public init(completed: Int,
                total: Int,
                currentPath: String? = nil,
                note: String? = nil,
                bytesDone: Int64 = 0,
                bytesTotal: Int64 = 0,
                startedAt: Date? = nil) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
        self.note = note
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.startedAt = startedAt
    }

    public var fraction: Double {
        total > 0 ? min(1.0, Double(completed) / Double(total)) : 0
    }

    public var description: String { "\(completed)/\(total)" }

    /// 已耗时（秒）。没有起始时刻时为 0。
    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    /// 实测搬动速率（字节/秒）。样本不足时为 nil。
    public var bytesPerSecond: Double? {
        let e = elapsed
        guard bytesTotal > 0, bytesDone > 0, e > 0.3 else { return nil }
        return Double(bytesDone) / e
    }

    /// `12.4 MB/s`
    public var throughputText: String? {
        guard let bps = bytesPerSecond else { return nil }
        return String(format: "%.1f MB/s", bps / 1_048_576)
    }

    /// 预计剩余秒数。优先按字节推算（更准），退而按「每个文件的平均耗时」推算。
    public var remainingSeconds: Double? {
        let e = elapsed
        guard e > 0.3, completed < total else { return nil }
        if let bps = bytesPerSecond, bytesTotal > bytesDone {
            return Double(bytesTotal - bytesDone) / bps
        }
        guard completed > 0 else { return nil }
        return e / Double(completed) * Double(total - completed)
    }

    /// `剩余约 2 分 10 秒`
    public var etaText: String? {
        guard let r = remainingSeconds, r.isFinite, r >= 1 else { return nil }
        return "剩余约 " + TagService.humanDuration(r)
    }
}

// MARK: - 单项结果

public enum BatchOutcome: Sendable {
    /// 处理成功。
    case succeeded
    /// 无需处理（编辑集为空、字段无变化、格式不支持该操作…）。
    case ignored(String)
    /// 处理失败。
    case failed(TagError)
    /// 任务被取消，该项未开工（不计入成功/失败/忽略任何一栏）。
    case cancelled

    public var isSuccess: Bool { if case .succeeded = self { return true }; return false }
}

// MARK: - 分阶段耗时（BH 轮）

/// 一轮批量作业的时间都花在哪了。
///
/// **为什么要有**：用户实测 105 首（开歌词 + 封面）跑了约 10 分钟，只说「慢」。
/// 「慢」有四种完全不同的病因，对应四种完全不同的处方：
/// 搜索慢 = 源/软截止的事；歌词慢 = 多问了几个源找译文；封面慢 = 下载带宽；
/// 写入慢 = Hi-Res FLAC 首次嵌封面的**整文件重写**，那是物理搬动，改代码救不了。
/// 不分阶段报数，用户下一次在 TF 卡上跑完还是只会说「慢」。
///
/// 匹配那三项是**跨并发累加**的（8 条线同时跑，累加值必然大于墙钟），
/// 它们回答的是「占比」；`wall` 才是墙钟。写入是串/并行写盘，`write` 就是那一段墙钟。
public struct StageTimings: Sendable, Equatable {
    /// 搜索 + 打分（各源 searchTracks / fetchDetail），累加。
    public var search: TimeInterval = 0
    /// 取歌词，累加。含下面的 `translation`。
    public var lyrics: TimeInterval = 0
    /// 其中「为了找译文额外问源」那一轮，累加。
    public var translation: TimeInterval = 0
    /// 封面下载，累加。
    public var artwork: TimeInterval = 0
    /// 补署名（作曲/作词），累加。
    public var credits: TimeInterval = 0
    /// 写盘那一段的墙钟。
    public var write: TimeInterval = 0
    /// 匹配那一段的墙钟。
    public var wall: TimeInterval = 0

    /// 写入阶段**预估会整文件重写**的文件数（写前只读预估，口径同保存确认框）。
    public var rewriteCount: Int = 0
    /// 那些文件预计落盘的总字节（搬动的音频 + 新写入的元数据）。
    public var rewriteBytes: Int64 = 0
    /// 为了找译文额外发起的补查轮数（每首最多 1）。
    public var translationRounds: Int = 0

    public init() {}

    public var isEmpty: Bool {
        search == 0 && lyrics == 0 && artwork == 0 && credits == 0 && write == 0
    }

    /// 「搜索 12.3 s · 歌词 45.6 s（含翻译轮 30.1 s / 18 首）· 封面 8.9 s · 写入 210.0 s
    ///  （整文件重写 20 个，1.2 GB）」—— 复核表底部、完成统计、日志逐字同款。
    public var summaryLine: String {
        var parts: [String] = []
        parts.append(String(format: "搜索 %.1f s", search))
        if lyrics > 0 {
            var t = String(format: "歌词 %.1f s", lyrics)
            if translation > 0 {
                t += String(format: "（含翻译轮 %.1f s / %d 首）", translation, translationRounds)
            }
            parts.append(t)
        }
        if credits > 0 { parts.append(String(format: "署名 %.1f s", credits)) }
        if artwork > 0 { parts.append(String(format: "封面 %.1f s", artwork)) }
        if write > 0 {
            var t = String(format: "写入 %.1f s", write)
            t += rewriteCount > 0
                ? "（整文件重写 \(rewriteCount) 个，\(TagService.humanBytes(rewriteBytes))）"
                : "（无整文件重写）"
            parts.append(t)
        }
        return parts.joined(separator: " · ")
    }

    /// 匹配那一段的「累加 vs 墙钟」一句。累加远大于墙钟 = 并发确实在起作用。
    public var concurrencyLine: String? {
        let sum = search + lyrics + artwork + credits
        guard wall > 0, sum > 0 else { return nil }
        return String(format: "联网累加 %.1f s / 墙钟 %.1f s（并发折算 %.1f×）", sum, wall, sum / wall)
    }
}

// MARK: - 汇总

public struct BatchSummary: Sendable {
    public var succeeded: Int
    public var failed: Int
    public var ignored: Int
    public var total: Int
    public var failures: [(url: URL, error: TagError)]
    /// 被忽略的项与原因。
    public var ignoredItems: [(url: URL, reason: String)]
    /// 部分格式写入成功但拒收了个别字段，这里记下来供界面提示。
    public var rejections: [(url: URL, keys: [String])]
    /// 被取消时为 true，`total` 仍是**计划处理的总数**。
    public var isCancelled: Bool
    /// 耗时（秒）。
    public var elapsed: TimeInterval
    /// 本批顺带做成的「预留填充」（见 `PaddingReserver`）。写入成功且刚发生过整文件重写
    /// 的文件才会有——它们下一次换封面就能原地完成。
    public var reserves: [(url: URL, paddingAfter: Int64, movedBytes: Int64)]
    /// 预留填充失败的项。**不算写入失败**：标签已经写进去了，只是没预留成。
    /// 刻意跳过的（硬链接）不在这里，见 `reserveSkips`。
    public var reserveFailures: [(url: URL, message: String)]
    /// 刻意**跳过**预留的项（BP-H 轮）：目前只有硬链接文件（整文件替换会把链接拆开，
    /// 见 `PaddingReserver.HardLinkSkipped`）。`message` 是原话，详单照列。
    public var reserveSkips: [(url: URL, message: String)] = []

    /// `reserves` 里「预留与重写并成同一次搬动」的个数（走了写前扩填充那条路）。
    public var mergedReserves: Int = 0
    /// 写前扩填充做过、但 TagLib 保存时**仍然**整文件重写了的文件数。
    ///
    /// 这就是预估偏差（渲染出来的元数据比估的小，剩余填充越过 1% 线被收缩）。
    /// 出现这种情况时**不再**补第三次搬动，只计数上报 —— 结果与「不开预留」等价，
    /// 绝不会比旧流程更差。数字长期不为 0 说明估算口径要修。
    public var preExpandMisses: Int = 0
    /// 本批**实测**发生的整段音频搬动次数合计（按「音频起点 / 文件大小动没动」判，不是估的）。
    /// 只在传了 `paddingPolicy` 时统计，否则恒为 0。
    public var audioMoves: Int = 0
    /// 逐文件的实测搬动次数（probe 对照表用）。
    public var moveCounts: [(url: URL, moves: Int)] = []
    /// 分阶段耗时（BH 轮）。谁填谁负责：`applyEdits` 只填写入那一段，
    /// 匹配那几段由 `AutoMatchService.matchAll` / `AlbumMatchService` 填。
    public var stages: StageTimings = StageTimings()

    public init(succeeded: Int = 0,
                failed: Int = 0,
                ignored: Int = 0,
                total: Int = 0,
                failures: [(url: URL, error: TagError)] = [],
                ignoredItems: [(url: URL, reason: String)] = [],
                rejections: [(url: URL, keys: [String])] = [],
                isCancelled: Bool = false,
                elapsed: TimeInterval = 0,
                reserves: [(url: URL, paddingAfter: Int64, movedBytes: Int64)] = [],
                reserveFailures: [(url: URL, message: String)] = []) {
        self.succeeded = succeeded
        self.failed = failed
        self.ignored = ignored
        self.total = total
        self.failures = failures
        self.ignoredItems = ignoredItems
        self.rejections = rejections
        self.isCancelled = isCancelled
        self.elapsed = elapsed
        self.reserves = reserves
        self.reserveFailures = reserveFailures
    }

    /// **原版文案，逐字对齐**：`成功: 3, 失败: 1, 忽略: 0, 总共: 4`
    public var description: String {
        "成功: \(succeeded), 失败: \(failed), 忽略: \(ignored), 总共: \(total)"
    }

    /// 处理完但没到齐（被取消）时，未开工的项数。
    public var unprocessed: Int { max(0, total - succeeded - failed - ignored) }

    public var isAllSucceeded: Bool { failed == 0 && unprocessed == 0 }

    /// 状态栏补充：「预留：成功 N · 跳过 M（硬链接）· 失败 K」（BP-H 轮）。
    ///
    /// - 成功段带填充量与搬动情况：「成功 3（平均填充 45 KB，同一次搬动内完成）」；
    /// - 跳过（硬链接）与失败分开计 —— 跳过是刻意的、链接完好，算成失败会让人以为写坏了；
    /// - 为 0 的段不写（成功段除外，它是这一句的主语）；预留一件事都没发生时返回 nil。
    /// 逐条原话在 `reserveSkips` / `reserveFailures`，详单照列。
    public var reserveNote: String? {
        guard !reserves.isEmpty || preExpandMisses > 0 || !reserveSkips.isEmpty || !reserveFailures.isEmpty
        else { return nil }
        var ok = "成功 \(reserves.count)"
        if !reserves.isEmpty {
            let avg = reserves.reduce(Int64(0)) { $0 + $1.paddingAfter } / Int64(reserves.count)
            var d = [(reserves.count > 1 ? "平均填充 " : "填充 ") + TagService.humanBytes(avg)]
            if mergedReserves == reserves.count {
                d.append("同一次搬动内完成")
            } else if mergedReserves > 0 {
                d.append("其中 \(mergedReserves) 个在同一次搬动内完成")
            }
            ok += "（" + d.joined(separator: "，") + "）"
        }
        var parts = [ok]
        if preExpandMisses > 0 { parts.append("未命中 \(preExpandMisses)（TagLib 仍然重写）") }
        if !reserveSkips.isEmpty { parts.append("跳过 \(reserveSkips.count)（硬链接）") }
        if !reserveFailures.isEmpty { parts.append("失败 \(reserveFailures.count)") }
        return "预留：" + parts.joined(separator: " · ")
    }
}

// MARK: - 预留填充策略

/// 「这次写入要不要顺手把文件头填充补到位」。`nil` 传给 `applyEdits` = 完全不管填充（旧行为）。
///
/// 只在**这次写入本来就要整文件重写**时才做：文件反正要被搬一遍，顺手把填充留够，
/// 换来的是以后每次换封面都原地完成；绝不为了预留而凭空制造一次搬动。
///
/// 落实路径有两条，优先第一条：
/// 1. **写前扩填充**（`PaddingReserver.expandBeforeWrite`）—— 先把 PADDING 扩到
///    「预留量 + 本次新元数据」，随后 TagLib 的保存必然原地。**总共只搬一次**。
/// 2. 合并不了时（换小封面要缩填充、巨图顶到块长上限、文件太小留不下）退回旧的
///    `reserveAfterSaveIfNeeded`：TagLib 先重写，我们再补一次，**两次搬动**。
public struct PaddingPolicy: Sendable {
    /// 总开关。
    public var enabled: Bool
    /// 用户设置的预留意愿（上限）。实际值一律再过一遍 `PaddingReserver.recommendedTarget`
    /// 按文件大小压低——固定 512 KB 对 51 MB 以下的文件会被 TagLib 在下次保存时砸回 4096。
    public var preferredBytes: Int
    /// 补填充之后把文件修改时间恢复成原值（跟随「保留修改时间」偏好）。
    public var preserveModificationDate: Bool
    /// 允许「写前扩填充」把两次搬动并成一次。
    ///
    /// 默认开。关掉就是本轮改动之前的老流程（TagLib 重写 → 事后补填充），
    /// **只给 probe 做 A/B 对照用**，产品路径没有关掉它的理由。
    public var mergeWithWrite: Bool

    public init(enabled: Bool = true,
                preferredBytes: Int = PaddingReserver.defaultReserveBytes,
                preserveModificationDate: Bool = false,
                mergeWithWrite: Bool = true) {
        self.enabled = enabled
        self.preferredBytes = PaddingReserver.safeTarget(preferredBytes)
        self.preserveModificationDate = preserveModificationDate
        self.mergeWithWrite = mergeWithWrite
    }

    public static let disabled = PaddingPolicy(enabled: false)

    /// 这个文件在本次写入里到底会不会被补填充（格式 + 总开关）。
    public func applies(to url: URL) -> Bool {
        enabled && preferredBytes > 0 && PaddingReserver.canReserve(url)
    }
}

// MARK: - 引擎

public enum BatchEngine {

    /// 默认并发度（对应原版设置里的线程数，默认 4）。
    public static let defaultConcurrency = 4

    // MARK: 整文件重写的吞吐估计（预估耗时用）
    //
    // 内置盘与可移动盘差两个数量级，用一个常数去套必然离谱：
    // 内置 APFS + 并发 4 实测 ~2500 MB/s（写页缓存，OS 后台回写），
    // TF 卡 / U 盘串行只有几十 MB/s。所以按卷分两档，各自 EMA 学习。
    // 初值取自性能报告的实测表，**保守打折**——宁可预估偏慢，不要让用户以为很快。

    private static let lock = NSLock()
    private static var throughputInternal:  Double = 900 * 1_048_576
    private static var throughputRemovable: Double = 35 * 1_048_576

    /// 兼容入口：默认给内置盘的数字。
    public static var measuredRewriteThroughput: Double {
        lock.lock(); defer { lock.unlock() }; return throughputInternal
    }

    /// 按这批文件所在的卷取吞吐估计（字节/秒）。
    public static func rewriteThroughput(for urls: [URL]) -> Double {
        lock.lock(); defer { lock.unlock() }
        return VolumeInfo.containsRemovable(urls) ? throughputRemovable : throughputInternal
    }

    /// 用一批的实测结果修正吞吐估计。样本太小（< 32 MB）不参与，避免固定开销污染。
    ///
    /// `bytes` 传的是**落盘字节**（搬动 + 新写入元数据），与 `estimatedWriteCost` 里
    /// 用它做除法的分子同口径 —— 两边必须一致，否则学一次歪一次。
    static func learnRewriteThroughput(urls: [URL], bytes: Int64, seconds: Double) {
        guard bytes >= 32 * 1_048_576, seconds > 0.05 else { return }
        let observed = Double(bytes) / seconds
        let removable = VolumeInfo.containsRemovable(urls)
        lock.lock()
        if removable { throughputRemovable = throughputRemovable * 0.6 + observed * 0.4 }
        else         { throughputInternal  = throughputInternal  * 0.6 + observed * 0.4 }
        lock.unlock()
    }

    /// 可移动 / 外置卷上的并发度：**1**。
    ///
    /// TF / microSD 卡、U 盘的主控缓存很小，并发写入只会让几个写入者互相拖慢
    /// （每个写入者都在争同一块 SLC 缓存 + 同一条 USB/SDIO 通道），串行反而更快。
    public static let removableConcurrency = 1

    // MARK: 自适应暂停总开关

    /// 用户总开关在 UserDefaults 里的键。**缺省（未设置过）视为 true**。
    public static let adaptivePacingDefaultsKey = "MacTagger.adaptiveWritePacing"

    /// 自适应暂停（`WritePacer`）总开关 —— 读写 `MacTagger.adaptiveWritePacing`。
    ///
    /// 这是**唯一入口**：界面菜单的勾选项、probe 的 `--no-pacer` 都改这里。
    /// 关掉之后写入吞吐**照常统计**（供日志诊断），但永远不会 `await` 暂停。
    public static var adaptivePacingEnabled: Bool {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: adaptivePacingDefaultsKey) != nil else { return true }
            return d.bool(forKey: adaptivePacingDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: adaptivePacingDefaultsKey) }
    }

    /// 按这批文件所在的卷推荐并发度。
    ///
    /// - 任一文件在可移动 / 外置 / 网络卷上 → `removableConcurrency`（1）
    /// - 全部在内置本地卷上 → `defaultConcurrency`（4）
    ///
    /// 判定见 `VolumeInfo`；空数组按内置盘处理。
    public static func recommendedConcurrency(for urls: [URL]) -> Int {
        guard !urls.isEmpty else { return defaultConcurrency }
        return VolumeInfo.containsRemovable(urls) ? removableConcurrency : defaultConcurrency
    }

    // MARK: 通用框架

    /// 批量跑任意任务：固定并发度、进度回调、可取消、统一统计。
    ///
    /// - Parameters:
    ///   - items: 待处理项。
    ///   - concurrency: 并发度，<1 会被夹到 1。
    ///   - urlOf: 从 item 取出用于报错/进度显示的 URL。
    ///   - progress: 每完成一项回调一次（并发下顺序不保证，计数保证单调递增）。
    ///   - operation: 实际干活的闭包，返回单项结果。
    /// - Returns: 统计汇总。取消时返回**已完成部分**的统计，`isCancelled == true`。
    ///   - bytesOf: 该项的「字节权重」，用于进度浮层的 MB/s 与剩余时间。
    ///     返回 nil / 全 0 时界面只按件数报进度。
    public static func run<Item: Sendable>(
        _ items: [Item],
        concurrency: Int = defaultConcurrency,
        urlOf: @escaping @Sendable (Item) -> URL,
        bytesOf: (@Sendable (Item) -> Int64)? = nil,
        progress: (@Sendable (BatchProgress) -> Void)?,
        operation: @escaping @Sendable (Item) -> BatchOutcome
    ) async -> BatchSummary {

        let total = items.count
        var summary = BatchSummary(total: total)
        let started = Date()
        guard total > 0 else {
            progress?(BatchProgress(completed: 0, total: 0))
            return summary
        }

        let weights: [Int64] = bytesOf.map { f in items.map(f) } ?? []
        let bytesTotal = weights.reduce(0, +)
        progress?(BatchProgress(completed: 0, total: total,
                                bytesDone: 0, bytesTotal: bytesTotal, startedAt: started))
        let counter = BatchProgressCounter(total: total, bytesTotal: bytesTotal,
                                           startedAt: started, callback: progress)

        // 按下标分发（而不是直接分发元素）：闭包里要按下标取该项的字节权重。
        let results = await ConcurrentWork.orderedMap(Array(items.indices),
                                                      concurrency: concurrency) { i in
            let item = items[i]
            let url = urlOf(item)
            if Task.isCancelled { return BatchOutcome.cancelled }
            let outcome = operation(item)
            counter.advance(url.path, bytes: weights.indices.contains(i) ? weights[i] : 0)
            return outcome
        }

        for (item, outcome) in zip(items, results) {
            let url = urlOf(item)
            switch outcome {
            case .succeeded:
                summary.succeeded += 1
            case .ignored(let reason):
                summary.ignored += 1
                summary.ignoredItems.append((url, reason))
            case .failed(let e):
                summary.failed += 1
                summary.failures.append((url, e))
            case .cancelled, .none:
                summary.isCancelled = true          // 未开工 / 取消导致未派发
            }
        }
        if Task.isCancelled { summary.isCancelled = true }
        summary.elapsed = Date().timeIntervalSince(started)
        return summary
    }

    // MARK: 批量写标签（阶段 1 的具体任务）

    /// 批量套用编辑集。
    ///
    /// 语义：
    /// - `edit.isEmpty`（没有任何字段改动且封面保持）→ **忽略**，不碰文件；
    /// - 写入抛错 → **失败**，错误进 `failures`；
    /// - 写入成功但格式拒收了个别字段 → 仍算**成功**，被拒键进 `rejections`。
    /// - Parameter pacing: 写入节流器配置。`nil` = 自动（只在可移动 / 外置卷上启用），
    ///   传 `.disabled` 可完全关掉，传自定义 `Config` 可调参数（probe 用）。
    /// - Parameter paddingPolicy: 预留填充策略。`nil` = **完全沿用旧行为**（不 inspect、
    ///   不补填充）。传进来时的顺序是：
    ///
    ///     预估 → 该重写且能合并 → `PaddingReserver.expandBeforeWrite`（**唯一一次搬动**）
    ///          → `TagService.write`（命中原地改写）
    ///          → 事后校验；只有「没做写前扩填充、而 TagLib 确实重写过」才走旧的
    ///            `reserveAfterSaveIfNeeded` 兜底（那条路两次搬动）。
    ///
    ///   写前扩填充做过、TagLib 却仍然重写了（预估偏差），只计进 `preExpandMisses`，
    ///   **不再补第三次搬动** —— 结果等价于「没开预留」，绝不会比旧流程更差。
    ///   M4A 之类不支持扩填充的格式静默跳过；预留失败只记进 `summary.reserveFailures`，
    ///   硬链接文件的刻意跳过记进 `summary.reserveSkips`，都**不算写入失败**（标签已经写进去了）。
    public static func applyEdits(_ edits: [(url: URL, edit: TagEdit)],
                                  concurrency: Int = defaultConcurrency,
                                  pacing: WritePacer.Config? = nil,
                                  paddingPolicy: PaddingPolicy? = nil,
                                  progress: (@Sendable (BatchProgress) -> Void)?) async -> BatchSummary {

        let total = edits.count
        var summary = BatchSummary(total: total)
        let started = Date()
        guard total > 0 else {
            progress?(BatchProgress(completed: 0, total: 0))
            return summary
        }

        // 写入前先做一次**只读**代价预估：拿到每个文件「要搬动多少字节」。
        // 这既是进度浮层 MB/s / 剩余时间的权重，也是保存确认框里那句预估的来源。
        // 每个文件只读几百字节的头部，46 个文件的开销在毫秒级。
        //
        // 开了预留填充时权重按**实际搬动次数**算（`WriteCostDetail.moveCount`）：
        // 能合并的文件只搬一次，合并不了的仍是两次。历史上这里无脑算两次，
        // 合并之后再那么算，进度条会在一半的地方走完、ETA 归零之后还在写。
        // 口径与确认框那句「同一次搬动内完成 / 再搬一次」出自同一个函数。
        //
        // 权重取 `totalWrittenBytes`（搬动 + 新写入元数据）而不是只取搬动量：
        // 封面本身是要**真写进磁盘**的字节，小文件配大封面时它才是耗时主项
        // （6 个 48 KB 的 FLAC 写 1.5 MB 封面：搬动约 0.3 MB，新数据约 9 MB）。
        // 只算搬动就会让进度条早早走满、ETA 归零之后还在写，且与确认框数字对不上。
        //
        // 明细整份留着：写入循环里要用它的 `mergesReserve` / `needBytes` / `slackBytes`
        // 决定要不要写前扩填充、扩到多少，省掉每个文件再解析一遍头部。
        let details: [TagService.WriteCostDetail] = edits.map {
            TagService.writeCostDetail(url: $0.url, edit: $0.edit, padding: paddingPolicy)
        }
        let weights: [Int64] = details.map(\.totalWrittenBytes)
        let bytesTotal = weights.reduce(0, +)

        progress?(BatchProgress(completed: 0, total: total,
                                bytesDone: 0, bytesTotal: bytesTotal, startedAt: started))

        let collector = RejectionCollector()
        let reserves = ReserveCollector()
        let counter = BatchProgressCounter(total: total, bytesTotal: bytesTotal,
                                           startedAt: started, callback: progress)
        // 节流器把状态文案挂到进度上报里（note 字段），界面直接显示这一行。
        // 目前会推上来的几种（全部由 WritePacer 生成，这里只做透传）：
        //   · 「存储卡降速，暂停 N 秒等待恢复…（第 k 次）」
        //   · 「已恢复写入」
        //   · 「存储卡持续 X MB/s，已按持续速度写入，不再等待」 ← 暂停被判定无效（等了也白等）
        //   · 「存储卡持续低速，已停止等待，按当前速度继续写入」 ← 累计暂停超出 25% 预算
        // `nil` = 自动（只在可移动/外置卷上开）；显式传入的配置同样受用户总开关约束。
        let config = (pacing ?? WritePacer.Config.automatic(for: edits.map(\.url))).gated()
        let pacer = WritePacer(config: config) { [counter] text in counter.setNote(text) }

        let results = await orderedMapAsync(Array(edits.indices),
                                            concurrency: concurrency) { i -> BatchOutcome in
            let item = edits[i]
            let weight = weights.indices.contains(i) ? weights[i] : 0
            if Task.isCancelled { return .cancelled }
            if item.edit.isEmpty {
                counter.advance(item.url.path)
                return .ignored("编辑集为空，无字段变化")
            }

            // ① 卡在降速区间就先睡一会儿，等主控缓存回血。
            //    暂停期间收到取消会立刻退出等待（Task.sleep 是取消点），
            //    这里再查一次 —— 取消后**不开写下一个文件**。
            await pacer.waitIfThrottled()
            if Task.isCancelled { return .cancelled }

            // ② 写前扩填充：把「TagLib 重写 + 事后补填充」两次搬动并成一次。
            //
            //    只在预估说「本次会因空间不足而整文件重写、而且合并得了」时做
            //    （`WriteCostDetail.mergesReserve`，判据全在 PaddingReserver）。
            //    扩完之后新元数据必然塞得进，紧接着的 TagService.write 就是原地改写。
            //
            //    失败不影响写入：桥接层是「临时文件 → TagLib 复核 → 原子 rename」，
            //    任何一步失败原文件一个字节没动，照常往下写，走旧的事后兜底。
            //
            //    `sizeBefore` 必须在**扩填充之前**取：这一整轮的物理搬动量要完整交给
            //    节流器，否则 TF 卡上最重的那一下（扩填充）在它眼里就消失了。
            let applies = paddingPolicy?.applies(to: item.url) ?? false
            let detail = details.indices.contains(i) ? details[i] : nil
            let sizeBefore = fileSizeInBytes(item.url)
            var preExpanded: ReserveOutcome? = nil
            var preExpandFailure: String? = nil
            // 写前扩填充遇到硬链接的刻意跳过（BP-I）：原话留着，写成功后记进 `reserveSkips`。
            // 文件一个字节没动，照常往下写；⑤ 里也不再走事后兜底（那里会对同一文件再抛一次）。
            var preExpandSkip: String? = nil
            var preElapsed: TimeInterval = 0
            if applies, let policy = paddingPolicy, let d = detail, d.mergesReserve {
                let p0 = DispatchTime.now()
                do {
                    let r = try PaddingReserver.expandBeforeWrite(
                        url: item.url,
                        requiredMetadataBytes: d.estimate.needBytes,
                        slackBytes: d.estimate.slackBytes,
                        target: policy.preferredBytes,
                        preserveModificationDate: policy.preserveModificationDate)
                    if let r, r.changed { preExpanded = r }
                } catch let skip as PaddingReserver.HardLinkSkipped {
                    preExpandSkip = skip.localizedDescription
                } catch {
                    preExpandFailure = error.localizedDescription
                }
                preElapsed = Double(DispatchTime.now().uptimeNanoseconds &- p0.uptimeNanoseconds) / 1_000_000_000
            }

            // ③ 实际写入并计时。
            //    TagService.write 是同步的 C++ 调用，内部**没有任何取消点**：
            //    一旦开写就一定写完，不会把文件写到一半就撒手（不伤卡、不写坏文件）。
            //    开了预留填充时先取一份写前快照（**扩填充之后**的那一刻）——
            //    写完要靠「音频起点/文件大小动没动」判断 TagLib 有没有再搬一次。
            let padBefore: PaddingInfo? = applies ? PaddingReserver.inspect(item.url) : nil
            let t0 = DispatchTime.now()
            let result: BatchOutcome
            do {
                let outcome = try TagService.write(item.edit, to: item.url)
                if !outcome.rejectedKeys.isEmpty {
                    collector.add(item.url, outcome.rejectedKeys)
                }
                result = .succeeded
            } catch let e as TagError {
                result = .failed(e)
            } catch {
                result = .failed(.unknown(error.localizedDescription))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000_000

            // ④ 只有真写成功才采样。写入前后的大小一并交给节流器 ——
            //    大小不变 = 原地改写（按耗时判），大小变了 = 整文件重写（按吞吐判）。
            //    走了写前扩填充时把那一段的耗时与大小变化并进来一起交：这一轮的物理成本
            //    就是「扩填充搬一次 + 原地写」，拆开报会让节流器把最重的一下当成 0。
            if result.isSuccess {
                let sizeAfter = fileSizeInBytes(item.url)
                // 格式（扩展名）决定标签结构，也就决定了固定开销 —— 耗时类按它分桶
                await pacer.record(bytesBefore: sizeBefore,
                                   bytesAfter: sizeAfter,
                                   duration: elapsed + preElapsed,
                                   format: item.url.pathExtension.lowercased())
            }

            // ⑤ 预留填充的收尾。
            //
            //    走过写前扩填充：只做校验。TagLib 若仍然整文件重写了（预估偏差），
            //    **不再补第三次搬动** —— 那样比旧流程还差；只计一笔 miss，
            //    结果等价于「没开预留」。
            //
            //    没走写前扩填充（合并不了 / 扩填充失败 / 收缩重写）：走旧兜底，
            //    「刚刚确实重写过 + 填充不够」才补一次（第二次搬动）。
            //    返回 nil = 本来就不用补，不是失败；抛错 = 没预留成，但标签已经写好了，
            //    所以只记 note，绝不把这条算成写入失败。
            if result.isSuccess, let policy = paddingPolicy, let before = padBefore {
                let after = PaddingReserver.inspect(item.url)
                // 用 didMoveAudio 而不是 didFullRewrite：MP3 保存后尾部会多一个 128 字节的
                // ID3v1，didFullRewrite 会把这 128 字节当成整文件重写，于是每个 MP3 都被
                // 判成「写前扩填充没命中」，白记一笔 miss 还丢掉预留记录。
                let taglibRewrote = PaddingReserver.didMoveAudio(before: before, after: after)
                var moves = (preExpanded != nil ? 1 : 0) + (taglibRewrote ? 1 : 0)
                if let pre = preExpanded {
                    if taglibRewrote {
                        reserves.addMiss(item.url)
                    } else {
                        reserves.add(url: item.url, padding: after.currentPadding,
                                     moved: pre.movedBytes, merged: true)
                    }
                } else if let skip = preExpandSkip {
                    // 硬链接：写前扩填充已判定刻意跳过（链接完好、标签已由 TagLib 原地写入）。
                    // 只记这一条，不再走兜底 —— 兜底里的 `reserve` 会对同一文件再抛一次。
                    reserves.addSkip(item.url, skip)
                } else {
                    do {
                        if let r = try PaddingReserver.reserveAfterSaveIfNeeded(
                            url: item.url,
                            before: before,
                            after: after,
                            target: policy.preferredBytes,
                            preserveModificationDate: policy.preserveModificationDate), r.changed {
                            moves += 1
                            reserves.add(url: item.url, padding: r.paddingAfter,
                                         moved: r.movedBytes, merged: false)
                        }
                    } catch let skip as PaddingReserver.HardLinkSkipped {
                        // 硬链接：刻意跳过（链接完好、标签已由 TagLib 原地写入），不算预留失败。
                        reserves.addSkip(item.url, skip.localizedDescription)
                    } catch {
                        reserves.addFailure(item.url, error.localizedDescription)
                    }
                }
                if let m = preExpandFailure { reserves.addFailure(item.url, "写前扩填充失败：\(m)") }
                reserves.addMoves(item.url, moves)
            }

            counter.advance(item.url.path, bytes: result.isSuccess ? weight : 0)
            return result
        }

        for (item, outcome) in zip(edits, results) {
            switch outcome {
            case .succeeded:
                summary.succeeded += 1
            case .ignored(let reason):
                summary.ignored += 1
                summary.ignoredItems.append((item.url, reason))
            case .failed(let e):
                summary.failed += 1
                summary.failures.append((item.url, e))
            case .cancelled, .none:
                summary.isCancelled = true
            }
        }
        if Task.isCancelled { summary.isCancelled = true }
        summary.elapsed = Date().timeIntervalSince(started)
        summary.rejections = collector.snapshot()
        summary.reserves = reserves.snapshot()
        summary.reserveFailures = reserves.failureSnapshot()
        summary.reserveSkips = reserves.skipSnapshot()
        summary.mergedReserves = reserves.mergedCount()
        summary.preExpandMisses = reserves.missCount()
        summary.moveCounts = reserves.moveSnapshot()
        summary.audioMoves = summary.moveCounts.reduce(0) { $0 + $1.moves }
        // ★ BH 轮：写入这一段的分阶段账。`details` 是上面那次**只读**预估的产物，
        // 不额外读一次盘。N 与字节的口径与保存确认框那句「将整文件重写 N 个文件」完全一致，
        // 于是「预估说要重写 20 个」与「实际写入花了 210 s」能被摆在同一行里对照。
        summary.stages.write = summary.elapsed
        summary.stages.rewriteCount = details.filter(\.rewrites).count
        summary.stages.rewriteBytes = details.filter(\.rewrites)
            .reduce(0) { $0 + $1.totalWrittenBytes }
        // 用这一批的实测结果校准吞吐估计，下次预估更准。
        learnRewriteThroughput(urls: edits.map(\.url), bytes: counter.finishedBytes,
                               seconds: summary.elapsed)
        return summary
    }

    /// 文件字节数；取不到按 0（该样本会被节流器丢弃）。
    static func fileSizeInBytes(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// `ConcurrentWork.orderedMap` 的 async 版本。
    ///
    /// 单独写一份而不是改 `ConcurrentWork`：`applyEdits` 需要在闭包里 `await` 节流器，
    /// 而 `ImportService` 那边的同步版本还有别的调用方在用，不动它更稳。
    static func orderedMapAsync<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        concurrency: Int,
        _ body: @escaping @Sendable (Input) async -> Output
    ) async -> [Output?] {
        if items.isEmpty { return [] }
        let width = max(1, min(concurrency, items.count))
        var results = [Output?](repeating: nil, count: items.count)

        await withTaskGroup(of: (Int, Output?).self) { group in
            var next = 0
            func submit(_ i: Int) {
                let item = items[i]
                group.addTask {
                    if Task.isCancelled { return (i, nil) }
                    return (i, await body(item))
                }
            }
            while next < width { submit(next); next += 1 }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < items.count && !Task.isCancelled {
                    submit(next); next += 1
                }
            }
        }
        return results
    }

    // MARK: 其它批量任务的现成入口（后续阶段直接复用）

    /// 批量清除全部标签容器。
    public static func stripAll(_ urls: [URL],
                                concurrency: Int = defaultConcurrency,
                                progress: (@Sendable (BatchProgress) -> Void)?) async -> BatchSummary {
        // 清除标签是把标签区**变小**，TagLib 会补 PADDING 填满原区间 → 基本都是原地改写，
        // 字节权重多半为 0（界面因此不显示速率，只报件数）。仍然过一遍预估，
        // 免得遇到少数会扩容的格式时剩余时间估歪。
        var strip = TagEdit()
        for f in TagEdit.Field.allCases { strip.remove(f) }
        strip.artworkAction = .removeAll
        return await run(urls,
                         concurrency: concurrency,
                         urlOf: { $0 },
                         bytesOf: { url in
                             let e = TagService.estimatedWriteCost(url: url, edit: strip)
                             return e.fullRewrite ? e.rewriteBytes : 0
                         },
                         progress: progress) { url in
            do { try TagService.stripAllTags(url); return .succeeded }
            catch let e as TagError { return .failed(e) }
            catch { return .failed(.unknown(error.localizedDescription)) }
        }
    }

    /// 批量导出封面到 `directory`，文件名取 `<原文件名>.<ext>`（同名自动加序号）。
    /// 无封面的记为忽略。
    public static func exportArtworks(_ urls: [URL],
                                      to directory: URL,
                                      concurrency: Int = defaultConcurrency,
                                      progress: (@Sendable (BatchProgress) -> Void)?) async -> BatchSummary {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let namer = UniqueNamer()
        return await run(urls, concurrency: concurrency, urlOf: { $0 }, progress: progress) { url in
            do {
                let arts = try TagService.readArtworks(url)
                guard let first = arts.first else { return .ignored("文件内没有封面") }
                let ext = Self.imageExtension(mime: first.mimeType, data: first.data)
                let base = url.deletingPathExtension().lastPathComponent
                let target = namer.reserve(directory: directory, base: base, ext: ext)
                try first.data.write(to: target, options: .atomic)
                return .succeeded
            } catch let e as TagError {
                return .failed(e)
            } catch {
                return .failed(.writeFailed(error.localizedDescription))
            }
        }
    }

    /// 从 MIME 或魔数推断图片扩展名。
    public static func imageExtension(mime: String?, data: Data) -> String {
        if let m = mime?.lowercased() {
            if m.contains("png") { return "png" }
            if m.contains("jpeg") || m.contains("jpg") { return "jpg" }
            if m.contains("gif") { return "gif" }
            if m.contains("bmp") { return "bmp" }
            if m.contains("webp") { return "webp" }
        }
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "bmp" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        return "img"
    }
}

// MARK: - 线程安全小工具

final class BatchProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var bytesDone: Int64 = 0
    private let total: Int
    private let bytesTotal: Int64
    private let startedAt: Date
    private let callback: (@Sendable (BatchProgress) -> Void)?

    init(total: Int,
         bytesTotal: Int64 = 0,
         startedAt: Date = Date(),
         callback: (@Sendable (BatchProgress) -> Void)?) {
        self.total = total
        self.bytesTotal = bytesTotal
        self.startedAt = startedAt
        self.callback = callback
    }

    /// 当前挂着的提示行（降速暂停 / 已恢复），由 `WritePacer` 推过来。
    private var note: String?

    /// 已落盘字节 = 搬动 + 新写入元数据（批量结束后取一次，用来修正吞吐估计）。
    /// 与 `TagService.estimatedWriteCost` 里那句 `moved / bps` 的分子同口径，
    /// 学到的 bps 才能原样喂回预估。
    var finishedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return bytesDone }

    func advance(_ path: String?, bytes: Int64 = 0) {
        lock.lock()
        done += 1; bytesDone += bytes
        let d = done, b = bytesDone, n = note
        lock.unlock()
        callback?(BatchProgress(completed: d, total: total, currentPath: path, note: n,
                                bytesDone: b, bytesTotal: bytesTotal, startedAt: startedAt))
    }

    /// 更新提示行，并**立刻**回调一次进度 —— 暂停期间没有文件完成，
    /// 不主动推一次的话界面看不到「正在等卡回血」。
    func setNote(_ text: String?) {
        lock.lock(); note = text; let d = done, b = bytesDone; lock.unlock()
        callback?(BatchProgress(completed: d, total: total, currentPath: nil, note: text,
                                bytesDone: b, bytesTotal: bytesTotal, startedAt: startedAt))
    }
}

/// 并发写入时收集「顺带补了填充」的结果。失败单独一列——那不算写入失败。
final class ReserveCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(url: URL, paddingAfter: Int64, movedBytes: Int64)] = []
    private var failures: [(url: URL, message: String)] = []
    /// 刻意跳过（硬链接）的项。与 `failures` 分开计。
    private var skips: [(url: URL, message: String)] = []
    /// 其中「预留并进同一次搬动」的个数（写前扩填充那条路）。
    private var merged = 0
    /// 写前扩填充做过、TagLib 却仍然重写了的个数（预估偏差）。
    private var misses = 0
    /// 逐文件实测的整段音频搬动次数。
    private var moves: [(url: URL, moves: Int)] = []

    func add(url: URL, padding: Int64, moved: Int64, merged isMerged: Bool = false) {
        lock.lock()
        items.append((url, padding, moved))
        if isMerged { merged += 1 }
        lock.unlock()
    }

    func addFailure(_ url: URL, _ message: String) {
        lock.lock(); failures.append((url, message)); lock.unlock()
    }

    func addSkip(_ url: URL, _ message: String) {
        lock.lock(); skips.append((url, message)); lock.unlock()
    }

    func addMiss(_ url: URL) {
        lock.lock(); misses += 1; lock.unlock()
    }

    func addMoves(_ url: URL, _ count: Int) {
        lock.lock(); moves.append((url, count)); lock.unlock()
    }

    func snapshot() -> [(url: URL, paddingAfter: Int64, movedBytes: Int64)] {
        lock.lock(); defer { lock.unlock() }; return items
    }

    func failureSnapshot() -> [(url: URL, message: String)] {
        lock.lock(); defer { lock.unlock() }; return failures
    }

    func skipSnapshot() -> [(url: URL, message: String)] {
        lock.lock(); defer { lock.unlock() }; return skips
    }

    func mergedCount() -> Int { lock.lock(); defer { lock.unlock() }; return merged }
    func missCount() -> Int { lock.lock(); defer { lock.unlock() }; return misses }
    func moveSnapshot() -> [(url: URL, moves: Int)] {
        lock.lock(); defer { lock.unlock() }; return moves
    }
}

final class RejectionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(url: URL, keys: [String])] = []

    func add(_ url: URL, _ keys: [String]) {
        lock.lock(); items.append((url, keys)); lock.unlock()
    }

    func snapshot() -> [(url: URL, keys: [String])] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

/// 并发导出时保证目标文件名不撞车。
final class UniqueNamer: @unchecked Sendable {
    private let lock = NSLock()
    private var used = Set<String>()

    func reserve(directory: URL, base: String, ext: String) -> URL {
        lock.lock(); defer { lock.unlock() }
        var name = "\(base).\(ext)"
        var i = 1
        while used.contains(name) || FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path) {
            name = "\(base)-\(i).\(ext)"
            i += 1
        }
        used.insert(name)
        return directory.appendingPathComponent(name)
    }
}

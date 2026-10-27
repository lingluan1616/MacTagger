//
//  WritePacer.swift
//  MacTagger — 写入节流器（自适应暂停）
//
//  为什么需要
//  ---------
//  TF / microSD 卡的主控只有很小一块高速缓存（SLC cache）。持续写入把它写满之后，
//  吞吐会从几十 MB/s 断崖式掉到几 MB/s，而且**闲置几秒就能恢复**。
//  这时候继续硬灌，只会一直待在低速区间；主动停几秒再写反而总耗时更短。
//
//  ⚠︎ 但这条只在「掉速是**热/缓存**造成、停一下能回血」时成立。
//  如果停下来速度没回来，那说明**这就是卡的持续速度**，再等只是白等 ——
//  见下面「暂停有效性判定」。
//
//  两类写入分开判定（关键设计）
//  --------------------------
//  标签写入有两种截然不同的形态，混在一起用同一个口径判定必然误判：
//
//  | 形态 | 判据 | 触发条件 | 实际写入量 |
//  |---|---|---|---|
//  | **原地改写**（写后文件大小不变） | **耗时** | 标签区填充够用 | 只有标签区那几 KB |
//  | **整文件重写**（大小变化 / 首次扩容） | **吞吐** | 填充不够，整文件位移 | ≈ 整个文件 |
//
//  为什么必须分开：原地改写的耗时**与文件大小基本无关**，
//  于是「吞吐 = 字节 / 耗时」≈ 文件大小 × 常数 ——
//  1.4 MB 的 dsf 能算出 2694 MB/s，13 KB 的 ogg 只有 0.5 MB/s，**差 5000 倍**，
//  全是文件大小造成的，跟卡快不快毫无关系。拿这种数当吞吐判降速，纯属噪声。
//  反过来，整文件重写的耗时正比于文件大小，用耗时判也一样是噪声。
//
//  所以：
//  - **原地改写按耗时判**：基线 = 前 N 次原地改写耗时的中位数；
//    EMA 耗时 > 基线 × `latencyRatio`（默认 3.0）且最新样本也慢 → 降速。
//  - **整文件重写按吞吐判**：基线 = 前 N 次吞吐的中位数；
//    EMA 吞吐 < 基线 × `slowdownRatio`（默认 0.35）且最新样本也慢 → 降速。
//  两类各自维护基线与 EMA，**互不污染**；暂停 / 指数退避状态机**共用一套**：
//  任一类判定降速即暂停，某一类连续 `recoveryStreak` 次正常即重置退避。
//
//  「最新样本本身也慢」这条保护是实测加的：只看 EMA 有滞后 ——
//  卡刚回血的那一刻 EMA 还被之前的慢样本拖着，会白白再暂停一次（第一版踩到过，多暂停 16 秒）。
//
//  =========================================================================
//  暂停有效性判定 / 预算 / 基线自适应（2026-09-18 起）
//  =========================================================================
//  **实机反馈**：往 TF 卡批量写入时，「存储卡降速，暂停 N 秒」从 2 秒一路翻到
//  4 → 8 → 16 → 20，越等越久，而且再也回不去。复盘出三条机制在互相喂饭：
//
//  1. 基线取**前 5 次写入的中位数** —— TF 卡前几次写入正好命中 SLC 缓存，最快，
//     基线因此定在**缓存速度**上（实测 80 MB/s 量级）；
//  2. 缓存写满后进入卡的**真实持续速度**（常低于缓存速度的 35%，也就是 `slowdownRatio`），
//     于是**每一个样本**都被判成「降速」；
//  3. 退避只有在「某桶连续 `recoveryStreak` 次正常」时才清零 ——
//     持续整文件重写下永远回不到基线的 35%，于是 2 → 4 → 8 → 16 → 20 一路翻，
//     每 3 个样本就白白等 20 秒。
//
//  本质：**把缓存速度当成了正常速度，在跟物理打架**。
//  暂停的唯一价值是让卡把 SLC 缓存刷回 TLC、换来暂停后的一小段快写；
//  **若暂停后速度没回来，说明这就是卡的持续速度，再等只是白等。**
//
//  三条新机制（都可以通过 `Config` 关掉，默认打开）：
//
//  - **暂停有效性判定**（`effectivenessWindow` / `effectivenessRatio`）
//    每次暂停后，把「暂停后前 K 个样本的均值」与「暂停前 K 个样本的均值」比：
//    - 提升 ≥ 1.5× → 暂停**有效**（卡确实回血了）：允许下一次暂停，
//      但增长从 ×2 改成 **×1.5**（`pauseGrowth`），且封顶从 20 s 降到 **8 s**（`maxPause`）；
//    - 提升 < 1.5× → 暂停**无效**：判定「这就是卡的持续速度」，
//      把该桶基线下调到 `max(暂停后均值, 基线 × 0.5)`（耗时类对称地上调，见
//      `ineffectiveBaselineFloor`）、EMA 取实测均值、退避清零，
//      并进入**冷却期**：接下来至少 `cooldownSeconds`（60 s 写入耗时）
//      或 `cooldownBytes`（256 MB，按吞吐类字节计）内**不再暂停**。
//
//  - **总暂停预算**（`pauseBudgetRatio`，默认 0.25）
//    累计暂停时长 ≤ 累计**写入墙钟**的 25%；超出即**停止暂停**，
//    推一条「存储卡持续低速，已停止等待，按当前速度继续写入」。
//    第 `budgetGracePauses`（默认 1）次暂停**豁免预算** —— 批次刚开始时预算还没攒出来，
//    不豁免的话第一次掉速永远试不了，也就永远拿不到「暂停到底有没有用」这个观测。
//
//  - **基线自适应**（`baselineRecalcEvery` / `baselineConvergeStep`）
//    基线不再只由前 5 次定死：每 `baselineRecalcEvery`（20）个样本收敛一次，
//    向**近期中位数**靠拢，单步最多走到原基线的 `baselineConvergeStep`（70%），
//    **只允许放宽、不允许收紧**（收紧靠 recovery / 重新建基线）。
//    于是「缓存速度霸占基线」最多撑 20 个样本，之后自动向持续速度收敛。
//
//  另外：退避阶梯的清零条件从 `recoveryStreak`（3，仍用于清掉界面提示）
//  分离出 `backoffResetStreak`（10）—— 只有连续 10 次正常写入才认为卡彻底回血、
//  阶梯归零。否则「暂停 → 恰好 3 次正常 → 再掉速」的真·热降速场景里，
//  阶梯每轮都被清成 2 秒，涨不上去也就谈不上退避。
//
//  旧策略（×2 增长、封顶 20 s、无有效性判定 / 无预算 / 无收敛）保留在
//  `Config.adaptiveStrategy = false` 这条路径上，只供 probe 做改前/改后对照。
//
//  默认**只对可移动 / 外置卷启用**（内置 SSD 不存在这个问题，白白暂停是净损失），
//  并受用户总开关 `BatchEngine.adaptivePacingEnabled` 约束。
//
//  线程模型：actor。`BatchEngine` 在写入前 `await waitIfThrottled()`、写入后
//  `await record(bytesBefore:bytesAfter:duration:)`，并发度 >1 时样本会交错，EMA 依然成立。
//

import Foundation

public actor WritePacer {

    // MARK: - 写入形态

    public enum WriteKind: String, Sendable, CaseIterable {
        /// **开销主导**，按**耗时**判定。两种情况归到这里：
        /// - 写后文件大小不变 → 只重写了标签区；
        /// - 大小变了但文件体量小于 `minThroughputBytes` → 传输时间被固定开销淹没，
        ///   算出来的「吞吐」只是文件大小的影子，没有物理意义。
        case inPlace
        /// **传输主导**，按**吞吐**判定：大小变化且体量 ≥ `minThroughputBytes`。
        case fullRewrite

        public var label: String {
            switch self {
            case .inPlace:     return "耗时类"
            case .fullRewrite: return "吞吐类"
            }
        }

        /// 该类判据的单位。
        public var metricUnit: String {
            switch self {
            case .inPlace:     return "ms"
            case .fullRewrite: return "MB/s"
            }
        }

        /// 指标数值越**小**越差（吞吐），还是越**大**越差（耗时）。
        var lowerIsWorse: Bool { self == .fullRewrite }

        /// 把内部指标（秒 / 字节每秒）换成展示用数值。
        public func display(_ metric: Double) -> Double {
            switch self {
            case .inPlace:     return metric * 1000          // 秒 → 毫秒
            case .fullRewrite: return metric / 1_048_576     // B/s → MB/s
            }
        }
    }

    // MARK: - 配置

    public struct Config: Sendable {

        /// 总开关。false 时 `waitIfThrottled()` 立即返回、`record` 只更新统计不判定。
        public var enabled: Bool
        /// 每一类建立基线所需的样本数（各自取中位数）。
        public var baselineSamples: Int
        /// EMA 平滑系数，越大越跟随最新样本。
        public var emaAlpha: Double
        /// **整文件重写**类的降速阈值：EMA 吞吐 < 基线 × 该比例即判降速。
        public var slowdownRatio: Double
        /// **原地改写**类的降速阈值：EMA 耗时 > 基线 × 该比例即判降速。
        public var latencyRatio: Double
        /// 每轮重新采样后，该类至少攒够几个样本才允许判定降速（避免单点抖动误判）。
        public var minSamplesForDecision: Int
        /// 首次暂停时长（秒）。
        public var initialPause: TimeInterval
        /// 暂停时长上限（秒）。**默认 8**（旧策略是 20 —— 等 20 秒还没回血纯属白等）。
        public var maxPause: TimeInterval
        /// 某一类连续多少个正常样本判定「已恢复」，清掉界面上挂着的提示行。
        public var recoveryStreak: Int
        /// 小于该耗时的样本按该值计（防止除零 / 指标算出天文数字）。
        /// 对耗时类同时兼作「下限」：亚毫秒级的差异不参与判定。
        public var minSampleDuration: TimeInterval
        /// **整文件重写按吞吐判的体量门槛**（字节）。
        ///
        /// 一次标签写入的固定开销（打开、解析、写回、关闭）是常数级的。
        /// 文件体量小到这个开销占大头时，「字节 / 耗时」测的就不再是介质的传输能力，
        /// 而只是文件大小本身 —— 实测在内置 SSD 上 13 KB 的 ogg 算出 10 MB/s、
        /// 1.4 MB 的 dsf 算出 2359 MB/s，差 235 倍，**全是固定开销造成的**，
        /// 拿去和 `基线 × 0.35` 比必然误判（实测误暂停 4 次共 30 秒）。
        /// 所以低于该门槛的整文件重写改走**耗时**判定。
        public var minThroughputBytes: Int
        /// **传输主导判据**：只有当本次耗时 ≥ 固定开销 × 该倍数时，
        /// 才认为「传输时间压过了固定开销」，这一笔的吞吐才有物理意义。
        ///
        /// 光靠字节门槛不够 —— 介质快到一定程度（内置 SSD 写页缓存）时，
        /// **再大的文件也是开销主导**：实测 1.4 MB 的 dsf 整文件重写只要 0.35 ms，
        /// 与 0.47 MB 的 wav 的 1.45 ms 相比，吞吐差 7 倍，仍然全是文件大小的影子
        /// （加了字节门槛后仍误暂停 2 次）。
        /// 这条判据会**自动按介质标定**：固定开销取「耗时类基线」，
        /// 没有基线时退而取「已观测到的最小耗时」。
        /// 于是在内置 SSD 上吞吐类几乎不会启用（本来也不需要，节流器在内置盘上是关的），
        /// 在 TF 卡上一次 4 MB 重写要几百毫秒、远超开销，会正常启用。
        public var transferDominanceFactor: Double
        /// **耗时类按文件格式（扩展名小写）分桶**。
        ///
        /// 固定开销是由**标签结构**决定的，不是由文件体积决定的：
        /// wav/aiff 要动 RIFF 块、dsf 的 ID3 在文件尾部、flac 要重排 PADDING……
        /// 实测同格式内很稳定，跨格式能差 5 倍（wav 原地改写 ~1.0–2.5 ms，dsf ~0.4 ms）。
        /// 拿一个全局基线去套所有格式，偏慢格式必然被误判。
        /// 分桶后每个格式各自建基线与 EMA，样本不足 `baselineSamples` 的桶**不参与判定**。
        /// 关掉时所有耗时样本共用一个桶（仅供 probe 做对照）。
        public var bucketByFormat: Bool

        // ---- 以下为 2026-09-18 新增（都有默认值，旧调用点原样编译） ----

        /// **新策略总闸**。false = 回到旧策略（×2 增长、无有效性判定 / 无预算 / 无基线收敛），
        /// 只供 probe 做改前/改后对照（`pacer --scenarios --legacy`）。
        public var adaptiveStrategy: Bool
        /// 暂停时长的增长倍数（新策略 ×1.5；旧策略固定 ×2，不看这个字段）。
        public var pauseGrowth: Double
        /// 暂停有效性判定的样本窗口 K：比较「暂停后前 K 个样本均值」与「暂停前 K 个样本均值」。
        public var effectivenessWindow: Int
        /// 判「暂停有效」所需的提升倍数（默认 1.5×）。低于它即认为**等了也白等**。
        public var effectivenessRatio: Double
        /// 暂停无效时基线放宽的限幅：吞吐类 `max(实测均值, 基线 × 该值)`，
        /// 耗时类对称地 `min(实测均值, 基线 ÷ 该值)`。默认 0.5 = 一次最多放宽一倍。
        public var ineffectiveBaselineFloor: Double
        /// 判定「持续低速」后的冷却期：至少这么多秒的**写入耗时**内不再暂停。
        public var cooldownSeconds: TimeInterval
        /// 冷却期的另一条出口：写满这么多**字节**（只计吞吐类）即解除。两条谁先到算谁。
        public var cooldownBytes: Int
        /// 累计暂停时长 ÷ 累计写入墙钟 的上限。超出即停止暂停。
        public var pauseBudgetRatio: Double
        /// 前几次暂停豁免预算（批次刚开始时预算还没攒出来）。
        public var budgetGracePauses: Int
        /// 每多少个样本做一次基线收敛（只放宽、不收紧）。
        public var baselineRecalcEvery: Int
        /// 单步收敛的限幅：一次最多把基线走到原值的该比例（吞吐类下调、耗时类上调）。
        public var baselineConvergeStep: Double
        /// 连续多少个正常样本才把**退避阶梯**清零（与 `recoveryStreak` 分开，后者只管界面提示）。
        public var backoffResetStreak: Int

        public init(enabled: Bool = true,
                    baselineSamples: Int = 5,
                    emaAlpha: Double = 0.4,
                    slowdownRatio: Double = 0.35,
                    latencyRatio: Double = 3.0,
                    minSamplesForDecision: Int = 3,
                    initialPause: TimeInterval = 2,
                    maxPause: TimeInterval = 8,
                    recoveryStreak: Int = 3,
                    minSampleDuration: TimeInterval = 0.0005,
                    minThroughputBytes: Int = 256 * 1024,
                    transferDominanceFactor: Double = 4.0,
                    bucketByFormat: Bool = true,
                    adaptiveStrategy: Bool = true,
                    pauseGrowth: Double = 1.5,
                    effectivenessWindow: Int = 3,
                    effectivenessRatio: Double = 1.5,
                    ineffectiveBaselineFloor: Double = 0.5,
                    cooldownSeconds: TimeInterval = 60,
                    cooldownBytes: Int = 256 * 1024 * 1024,
                    pauseBudgetRatio: Double = 0.25,
                    budgetGracePauses: Int = 1,
                    baselineRecalcEvery: Int = 20,
                    baselineConvergeStep: Double = 0.7,
                    backoffResetStreak: Int = 10) {
            self.enabled = enabled
            self.baselineSamples = max(1, baselineSamples)
            self.emaAlpha = min(1, max(0.01, emaAlpha))
            self.slowdownRatio = min(1, max(0.01, slowdownRatio))
            self.latencyRatio = max(1.01, latencyRatio)
            self.minSamplesForDecision = max(1, minSamplesForDecision)
            self.initialPause = max(0, initialPause)
            self.maxPause = max(self.initialPause, maxPause)
            self.recoveryStreak = max(1, recoveryStreak)
            self.minSampleDuration = max(0.00001, minSampleDuration)
            self.minThroughputBytes = max(0, minThroughputBytes)
            self.transferDominanceFactor = max(1.0, transferDominanceFactor)
            self.bucketByFormat = bucketByFormat
            self.adaptiveStrategy = adaptiveStrategy
            self.pauseGrowth = max(1.0, pauseGrowth)
            self.effectivenessWindow = max(1, effectivenessWindow)
            self.effectivenessRatio = max(1.0, effectivenessRatio)
            self.ineffectiveBaselineFloor = min(0.99, max(0.01, ineffectiveBaselineFloor))
            self.cooldownSeconds = max(0, cooldownSeconds)
            self.cooldownBytes = max(0, cooldownBytes)
            self.pauseBudgetRatio = min(1, max(0, pauseBudgetRatio))
            self.budgetGracePauses = max(0, budgetGracePauses)
            self.baselineRecalcEvery = max(1, baselineRecalcEvery)
            self.baselineConvergeStep = min(0.99, max(0.1, baselineConvergeStep))
            self.backoffResetStreak = max(1, backoffResetStreak)
        }

        /// 该类判据的阈值：`基线 × 比例`。
        func threshold(for kind: WriteKind, baseline: Double) -> Double {
            baseline * (kind == .inPlace ? latencyRatio : slowdownRatio)
        }

        /// 关掉（内置盘 / 单元测试）。
        public static let disabled = Config(enabled: false)

        /// 默认参数、强制开启（probe 模拟用）。
        public static let always = Config(enabled: true)

        /// **旧策略**（改前对照）：×2 增长、封顶 20 秒、无有效性判定 / 无预算 / 无基线收敛，
        /// 退避阶梯按 `recoveryStreak` 清零。只给 probe 用。
        public static func legacy(initialPause: TimeInterval = 2,
                                  maxPause: TimeInterval = 20) -> Config {
            Config(initialPause: initialPause, maxPause: maxPause, adaptiveStrategy: false)
        }

        /// **默认策略**：这批文件里只要有一个在可移动 / 外置卷上就启用，否则关闭。
        /// 同时受用户总开关 `BatchEngine.adaptivePacingEnabled` 约束。
        public static func automatic(for urls: [URL]) -> Config {
            Config(enabled: BatchEngine.adaptivePacingEnabled && VolumeInfo.containsRemovable(urls))
        }

        /// 套用用户总开关：开关关掉时强制 `enabled = false`。
        /// 关掉后**统计照常记录**（供日志/诊断），只是永远不再 `await` 暂停。
        public func gated() -> Config {
            var c = self
            if !BatchEngine.adaptivePacingEnabled { c.enabled = false }
            return c
        }
    }

    // MARK: - 单类跟踪器

    private struct Tracker {
        let kind: WriteKind
        /// 耗时类的格式桶名（扩展名小写）；吞吐类为 nil。
        var bucket: String?
        var warmup: [Double] = []
        var baseline: Double?
        var ema: Double?
        var last: Double?
        var samplesSinceResume = 0
        var normalStreak = 0
        /// **连续**越阈的样本数。判定降速要求它达到 `minSamplesForDecision`。
        var consecutiveSlow = 0
        var totalSamples = 0
        /// 最近样本（做「暂停前均值」与「近期中位数」用）。跨暂停保留 —— 暂停前的实测速度
        /// 正是有效性判定的分母，`resume()` 清掉它就没得比了。
        var recent: [Double] = []
        /// 距上次基线收敛的样本数。
        var sinceConverge = 0

        /// 指标是否「差」。吞吐类越小越差，耗时类越大越差。
        func isBad(_ v: Double, threshold t: Double) -> Bool {
            kind.lowerIsWorse ? v < t : v > t
        }

        /// 暂停之后重新采样：清 EMA 与本轮计数，**基线与 recent 保留**。
        mutating func resume() {
            ema = nil
            samplesSinceResume = 0
            normalStreak = 0
            consecutiveSlow = 0
        }

        mutating func push(_ v: Double, window: Int) {
            recent.append(v)
            if recent.count > window { recent.removeFirst(recent.count - window) }
        }

        /// 最近 n 个样本的均值（不足就按现有的算）。
        func recentMean(_ n: Int) -> Double? {
            guard !recent.isEmpty else { return nil }
            let s = recent.suffix(n)
            return s.reduce(0, +) / Double(s.count)
        }

        var recentMedian: Double? {
            guard !recent.isEmpty else { return nil }
            let s = recent.sorted()
            let mid = s.count / 2
            return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
        }
    }

    // MARK: - 对外可观测状态（probe / 日志用）

    public struct TrackerStats: Sendable {
        public var kind: WriteKind
        /// 耗时类的格式桶名；吞吐类为 nil。
        public var bucket: String?
        /// 基线（耗时类单位=秒；吞吐类单位=字节/秒），未建立时 nil。
        public var baseline: Double?
        public var ema: Double?
        public var last: Double?
        /// 判定阈值 = 基线 × 对应比例。
        public var threshold: Double?
        public var samplesSinceResume: Int
        public var normalStreak: Int
        /// 连续越阈样本数。
        public var consecutiveSlow: Int
        public var totalSamples: Int
        /// 近期中位数（基线收敛的目标）。
        public var recentMedian: Double?

        /// 展示单位下的数值（ms / MB/s）。
        public var displayBaseline: Double? { baseline.map { kind.display($0) } }
        public var displayEMA: Double? { ema.map { kind.display($0) } }
        public var displayLast: Double? { last.map { kind.display($0) } }
        public var displayThreshold: Double? { threshold.map { kind.display($0) } }
        public var displayRecentMedian: Double? { recentMedian.map { kind.display($0) } }

        public var summary: String {
            func f(_ v: Double?) -> String {
                guard let v, v.isFinite else { return "—" }
                return String(format: "%.2f", v) + kind.metricUnit
            }
            return "\(kind.label)\(bucket.map { "[\($0)]" } ?? ""): 样本=\(totalSamples) 基线=\(f(displayBaseline)) "
                 + "EMA=\(f(displayEMA)) 阈值=\(f(displayThreshold)) 近期中位=\(f(displayRecentMedian)) "
                 + "连续越阈=\(consecutiveSlow) 正常连击=\(normalStreak)"
        }
    }

    /// 一次采样的归属与该跟踪器的最新状态。
    public struct SampleOutcome: Sendable {
        public var kind: WriteKind
        public var bucket: String?
        public var stats: TrackerStats
        /// 这一笔样本刚好完成了一次「暂停有效性判定」时带回结论，否则 nil。
        public var verdict: PauseVerdict?
    }

    /// 一次暂停的事后判定。
    public struct PauseVerdict: Sendable {
        public var kind: WriteKind
        public var bucket: String?
        /// 暂停前 K 个样本均值。
        public var before: Double
        /// 暂停后 K 个样本均值。
        public var after: Double
        /// 提升倍数（>1 = 变好）。
        public var improvement: Double
        /// 是否判定「这次暂停换来了回血」。
        public var effective: Bool
        /// 判无效时把基线放宽到了多少（判有效时 nil）。
        public var newBaseline: Double?

        public var displayBefore: Double { kind.display(before) }
        public var displayAfter: Double { kind.display(after) }
    }

    public struct Stats: Sendable {
        /// 耗时类的各格式桶（键 = 扩展名小写；未分桶时键为 `*`）。
        public var latencyBuckets: [String: TrackerStats]
        public var fullRewrite: TrackerStats
        /// 连续降速次数（决定下次暂停多久）。
        public var consecutiveSlowdowns: Int
        /// 当前是否已判定降速（下一次 `waitIfThrottled()` 会真的睡）。
        public var isThrottled: Bool
        /// 触发降速的是哪一类。
        public var throttleSource: WriteKind?
        /// 触发降速的格式桶（吞吐类为 nil）。
        public var throttleBucket: String?
        /// 下一次若触发暂停会睡多久。
        public var nextPause: TimeInterval
        /// 累计暂停总时长。
        public var totalPaused: TimeInterval
        /// 累计暂停次数。
        public var pauseCount: Int
        /// 是否发生过「暂停期间被取消」。
        public var cancelledDuringPause: Bool
        /// 每次暂停的时长（按发生顺序）。
        public var pauseSeconds: [TimeInterval]
        /// 累计**写入**墙钟（不含暂停）—— 预算与冷却的分母。
        public var writeWallClock: TimeInterval
        /// 累计写入字节（只计吞吐类）。
        public var writtenBytes: Int
        /// 判定「有效」/「无效」的暂停次数。
        public var effectivePauses: Int
        public var ineffectivePauses: Int
        /// 是否已因预算耗尽而**停止暂停**。
        public var budgetStopped: Bool
        /// 是否处在「持续低速」冷却期内。
        public var inCooldown: Bool
        /// 最近一次判定出来的「卡的持续速度」（配 `sustainedKind` 的单位）。
        public var sustainedMetric: Double?
        public var sustainedKind: WriteKind?

        /// 暂停占写入墙钟的比例。
        public var pauseRatio: Double { writeWallClock > 0 ? totalPaused / writeWallClock : 0 }

        /// 耗时类各桶按桶名排序，便于稳定输出。
        public var sortedLatencyBuckets: [TrackerStats] {
            latencyBuckets.keys.sorted().compactMap { latencyBuckets[$0] }
        }
    }

    // MARK: - 暂停有效性评估

    /// 一次暂停挂起的评估：记下触发暂停的那个跟踪器与暂停前均值，
    /// 等它再攒够 K 个样本就结账。
    private struct PendingEval {
        let kind: WriteKind
        let bucket: String?
        let before: Double
        var after: [Double] = []
    }

    // MARK: - 内部状态

    private let config: Config
    private let note: (@Sendable (String?) -> Void)?
    /// 暂停用的睡眠实现。生产为 nil = `Task.sleep`；probe 合成时序时传空实现，
    /// 用**虚拟时钟**跑完 700 秒级的旧策略对照（否则一轮对照要真等十几分钟）。
    private let sleeper: (@Sendable (TimeInterval) async throws -> Void)?

    /// 耗时类：按格式分桶（键 = 扩展名小写；未分桶时统一为 `*`）。
    private var latencyBuckets: [String: Tracker] = [:]
    /// 吞吐类：单一跟踪器，不分桶。
    private var throughputTracker: Tracker

    private var consecutiveSlowdowns = 0
    private var throttled = false
    private var throttleSource: WriteKind?
    /// 触发降速的是哪个格式桶（吞吐类为 nil）。
    private var throttleBucket: String?
    private var totalPaused: TimeInterval = 0
    private var pauseCount = 0
    private var pauseSeconds: [TimeInterval] = []
    private var cancelledDuringPause = false
    /// 已观测到的最小写入耗时 —— 固定开销的上界估计（还没有耗时基线时用它兜底）。
    private var minObservedDuration: TimeInterval?
    /// 当前是否正挂着「已恢复写入 / 不再等待」这类提示，恢复确认后清掉。
    private var showingResumedNote = false

    /// 累计写入墙钟与字节（暂停不计）。预算、冷却都按它们走 ——
    /// 用真实时钟的话，probe 的合成时序（瞬间跑完）永远出不了冷却期。
    private var writeWallClock: TimeInterval = 0
    private var writtenBytes = 0
    private var pendingEval: PendingEval?
    private var effectivePauses = 0
    private var ineffectivePauses = 0
    private var budgetStopped = false
    private var cooldownUntilWall: TimeInterval?
    private var cooldownUntilBytes: Int?
    private var sustainedMetric: Double?
    private var sustainedKind: WriteKind?

    /// `recent` 窗口：既要够做暂停前均值（K），也要够做近期中位数（收敛窗口）。
    private var recentWindow: Int { max(config.effectivenessWindow, config.baselineRecalcEvery) }

    public init(config: Config = .always,
                note: (@Sendable (String?) -> Void)? = nil,
                sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.config = config
        self.note = note
        self.sleeper = sleeper
        self.throughputTracker = Tracker(kind: .fullRewrite, bucket: nil)
    }

    // MARK: - 采样

    /// 记录一次写入。
    ///
    /// - Parameters:
    ///   - bytesBefore: 写入**前**的文件字节数。
    ///   - bytesAfter: 写入**后**的文件字节数。
    ///   - duration: 墙钟耗时。
    ///
    /// 形态判定：`bytesAfter == bytesBefore`（且 > 0）→ 原地改写，按耗时判；
    /// 否则 → 整文件重写，按吞吐判（字节数取写后大小与写前大小的较大者）。
    @discardableResult
    public func record(bytesBefore: Int,
                       bytesAfter: Int,
                       duration: TimeInterval,
                       format: String = "") -> SampleOutcome? {
        let dur = max(duration, config.minSampleDuration)
        let bytes = max(bytesAfter, bytesBefore)
        let isInPlace = bytesBefore > 0 && bytesAfter == bytesBefore

        // 耗时类的桶名：按格式分桶时用扩展名小写，关掉分桶时统一 `*`。
        let bucketKey = config.bucketByFormat
            ? (format.isEmpty ? "?" : format.lowercased())
            : "*"

        // 固定开销估计，三级兜底：
        //   ① 同格式桶的基线（最准 —— 固定开销由标签结构决定，同格式才可比）；
        //   ② 还没有该格式的基线时，取**已有桶里最小的基线**
        //      —— 固定开销是介质的属性，量级跨格式相近，用已知的最便宜的一次写入兜底；
        //   ③ 一个桶都还没建好时才退到常量。
        //
        // ② 是实测补的：新格式的桶一开始没有基线，直接退到常量（微秒级）会让
        // 「传输主导」判据形同虚设，把这个格式的头几笔错分到吞吐类
        // （实测 wav 因此被分到吞吐类，和不分桶时的分类结果不一致，A/B 对照都做不成）。
        let overhead = latencyBuckets[bucketKey]?.baseline
            ?? latencyBuckets.values.compactMap({ $0.baseline }).min()
            ?? config.minSampleDuration
        let transferBound = dur >= overhead * config.transferDominanceFactor

        // 只有「大小变了」+「体量够大」+「传输压过开销」三条同时成立，才按吞吐判。
        let kind: WriteKind = (isInPlace
                               || bytes < config.minThroughputBytes
                               || !transferBound) ? .inPlace : .fullRewrite

        minObservedDuration = min(minObservedDuration ?? dur, dur)      // 仅供诊断

        // 预算 / 冷却的计量：写入耗时照单全收；字节只计吞吐类
        //（原地改写只动标签区那几 KB，拿整个文件大小去凑 256 MB 会让冷却期早早失效）。
        writeWallClock += dur
        if kind == .fullRewrite { writtenBytes += max(0, bytes) }

        let metric: Double
        switch kind {
        case .inPlace:
            metric = dur                                        // 秒，越大越差
        case .fullRewrite:
            guard bytes > 0 else { return nil }
            metric = Double(bytes) / dur                        // 字节/秒，越小越差
        }
        guard metric.isFinite, metric > 0 else { return nil }

        var t: Tracker
        switch kind {
        case .inPlace:
            t = latencyBuckets[bucketKey] ?? Tracker(kind: .inPlace, bucket: bucketKey)
        case .fullRewrite:
            t = throughputTracker
        }

        t.last = metric
        t.samplesSinceResume += 1
        t.totalSamples += 1
        t.push(metric, window: recentWindow)

        // ---- 暂停有效性判定（必须排在阈值判定之前）----
        // 结账会**就地放宽基线**，放宽之后这一笔本身就可能不再算「慢」，
        // 于是不会再顺手触发下一次暂停 —— 这正是「持续低速就别再等」的落点。
        var verdict: PauseVerdict?
        if config.adaptiveStrategy,
           var p = pendingEval,
           p.kind == kind, p.bucket == t.bucket {
            p.after.append(metric)
            if p.after.count >= config.effectivenessWindow {
                verdict = settle(pending: p, tracker: &t)
                pendingEval = nil
            } else {
                pendingEval = p
            }
        }

        // ---- 建立该桶 / 该类的基线 ----
        // 样本不足 baselineSamples 时**不做任何判定**，避免冷启动误判。
        guard let base0 = t.baseline else {
            t.warmup.append(metric)
            if t.warmup.count >= config.baselineSamples {
                let sorted = t.warmup.sorted()
                let mid = sorted.count / 2
                t.baseline = sorted.count % 2 == 1
                    ? sorted[mid]
                    : (sorted[mid - 1] + sorted[mid]) / 2
                t.ema = t.baseline
            }
            store(t, kind: kind, bucket: bucketKey)
            return SampleOutcome(kind: kind, bucket: t.bucket, stats: stats(of: t), verdict: verdict)
        }

        // ---- 基线自适应收敛（每 baselineRecalcEvery 个样本一次，只放宽不收紧）----
        // 前 5 次中位数只是**起点**：TF 卡的前几笔命中 SLC 缓存，天然虚高。
        // 每隔一段就往「近期中位数」走一步（单步限幅 baselineConvergeStep），
        // 缓存速度最多霸占基线 20 个样本。
        t.sinceConverge += 1
        if config.adaptiveStrategy, t.sinceConverge >= config.baselineRecalcEvery {
            t.sinceConverge = 0
            if let med = t.recentMedian {
                let step = config.baselineConvergeStep
                if kind.lowerIsWorse {                     // 吞吐：只下调
                    let target = max(med, base0 * step)
                    if target < base0 { t.baseline = target }
                } else {                                   // 耗时：只上调（同样是放宽）
                    let target = min(med, base0 / step)
                    if target > base0 { t.baseline = target }
                }
            }
        }
        let base = t.baseline ?? base0

        // ---- 正常跟踪 ----
        t.ema = t.ema.map { config.emaAlpha * metric + (1 - config.emaAlpha) * $0 } ?? metric
        let threshold = config.threshold(for: kind, baseline: base)

        // 恢复判定按**单点样本**走（对回血更敏感）。
        // 两条不同量级的「恢复」分开：
        //   · recoveryStreak（3）→ 清掉界面上挂着的提示行；
        //   · backoffResetStreak（10）→ 把退避阶梯清零。
        // 旧策略下两者都用 recoveryStreak（保留对照路径）。
        if t.isBad(metric, threshold: threshold) {
            t.normalStreak = 0
            t.consecutiveSlow += 1
        } else {
            t.consecutiveSlow = 0
            t.normalStreak += 1
            let backoffStreak = config.adaptiveStrategy ? config.backoffResetStreak
                                                        : config.recoveryStreak
            if t.normalStreak >= backoffStreak, consecutiveSlowdowns > 0 {
                consecutiveSlowdowns = 0
            }
            if t.normalStreak >= config.recoveryStreak, showingResumedNote {
                showingResumedNote = false
                note?(nil)
            }
        }

        // 降速判定：几条同时成立才算「卡真的降速了」，缺一不可 ——
        //   ① 该桶**连续** minSamplesForDecision 个样本越阈（持续性，不是一次抖动）；
        //   ② 本轮采样数够（暂停后重新起算，避免刚恢复就又暂停）；
        //   ③ EMA 也越阈（平滑量级确认）；
        //   ④ 不在「持续低速」冷却期内、预算也还没耗尽（新策略）。
        //
        // ① 是实测补上的：只要求「最新样本越阈 + EMA 越阈」时，
        // 掉速刚结束的第一笔（EMA 还带着滞后）仍会误暂停，实测白等 16 秒。
        if config.enabled,
           !(config.adaptiveStrategy && (inCooldown || budgetStopped)),
           t.consecutiveSlow >= config.minSamplesForDecision,
           t.samplesSinceResume >= config.minSamplesForDecision,
           let e = t.ema,
           t.isBad(e, threshold: threshold) {
            throttled = true
            throttleSource = kind
            throttleBucket = t.bucket
        }

        store(t, kind: kind, bucket: bucketKey)
        return SampleOutcome(kind: kind, bucket: t.bucket, stats: stats(of: t), verdict: verdict)
    }

    /// 结账一次暂停：这次等待到底换没换来回血。
    private func settle(pending p: PendingEval, tracker t: inout Tracker) -> PauseVerdict {
        let after = p.after.reduce(0, +) / Double(p.after.count)
        // 提升倍数统一成「>1 = 变好」：吞吐越大越好、耗时越小越好。
        let improvement = p.kind.lowerIsWorse
            ? (p.before > 0 ? after / p.before : 1)
            : (after > 0 ? p.before / after : 1)
        let effective = improvement >= config.effectivenessRatio

        var newBaseline: Double?
        if effective {
            effectivePauses += 1
        } else {
            // 等了也白等 —— 这就是卡的**持续速度**。把基线放宽到实测水平（限幅），
            // 退避清零，进冷却期，界面上换一句「按持续速度写入」。
            ineffectivePauses += 1
            if let b = t.baseline {
                let floor = config.ineffectiveBaselineFloor
                let nb = p.kind.lowerIsWorse ? max(after, b * floor)   // 吞吐：不低于基线的一半
                                             : min(after, b / floor)   // 耗时：不高于基线的两倍
                t.baseline = nb
                newBaseline = nb
            }
            t.ema = after
            t.consecutiveSlow = 0
            t.normalStreak = 0
            consecutiveSlowdowns = 0
            cooldownUntilWall = writeWallClock + config.cooldownSeconds
            cooldownUntilBytes = writtenBytes + config.cooldownBytes
            sustainedMetric = after
            sustainedKind = p.kind
            showingResumedNote = true
            note?(sustainedText(kind: p.kind, metric: after))
        }
        return PauseVerdict(kind: p.kind, bucket: p.bucket, before: p.before, after: after,
                            improvement: improvement, effective: effective,
                            newBaseline: newBaseline)
    }

    private func store(_ t: Tracker, kind: WriteKind, bucket: String) {
        switch kind {
        case .inPlace:     latencyBuckets[bucket] = t
        case .fullRewrite: throughputTracker = t
        }
    }

    /// 「持续低速」冷却期：写入耗时或写入字节任一走够即解除。
    private var inCooldown: Bool {
        guard let w = cooldownUntilWall, let b = cooldownUntilBytes else { return false }
        return writeWallClock < w && writtenBytes < b
    }

    // MARK: - 节流

    /// 写入前调用。已判定降速时在此 `await` 暂停；否则立即返回。
    ///
    /// **取消语义**：暂停等待期间收到取消会**立刻**退出等待（`Task.sleep` 是取消点），
    /// 不睡满、也不上报「已恢复写入」。调用方（`BatchEngine`）在本方法返回后会再查一次
    /// `Task.isCancelled`，因此取消后**不会**再写下一个文件。
    ///
    /// - Returns: `true` = 正常等待结束（或按预算跳过了等待）；`false` = 被取消打断。
    @discardableResult
    public func waitIfThrottled() async -> Bool {
        guard config.enabled, throttled else { return !Task.isCancelled }

        let pause = pauseDuration()

        // ---- 总暂停预算 ----
        // 累计暂停 ≤ 累计写入墙钟 × pauseBudgetRatio。前 budgetGracePauses 次豁免：
        // 批次刚开始时预算还没攒出来，不豁免就永远试不出「暂停到底有没有用」。
        if config.adaptiveStrategy,
           pauseCount >= config.budgetGracePauses,
           totalPaused + pause > writeWallClock * config.pauseBudgetRatio {
            budgetStopped = true
            throttled = false
            throttleSource = nil
            throttleBucket = nil
            pendingEval = nil
            showingResumedNote = true
            note?("存储卡持续低速，已停止等待，按当前速度继续写入")
            return !Task.isCancelled
        }

        consecutiveSlowdowns += 1
        pauseCount += 1

        // 暂停**前**的实测水平：有效性判定的分母。取触发暂停的那个跟踪器。
        if config.adaptiveStrategy,
           let src = throttleSource,
           let tracker = trackerFor(kind: src, bucket: throttleBucket),
           let before = tracker.recentMean(config.effectivenessWindow) {
            pendingEval = PendingEval(kind: src, bucket: throttleBucket, before: before)
        }

        note?("存储卡降速，暂停 \(secondsText(pause)) 秒等待恢复…（第 \(pauseCount) 次）")
        let began = Date()
        do {
            if let sleeper {
                try await sleeper(pause)
            } else {
                try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        } catch {
            // 只有取消会走到这里。记下实际睡了多久，清掉提示后立刻返回。
            let actual = Date().timeIntervalSince(began)
            totalPaused += actual
            pauseSeconds.append(actual)
            cancelledDuringPause = true
            throttled = false
            throttleSource = nil
            throttleBucket = nil
            pendingEval = nil
            note?(nil)
            return false
        }
        // 记**名义**时长：注入 sleeper 的合成时序下真实耗时是 0，
        // 但预算算的是「我们决定等多久」，名义值才是对的。
        totalPaused += pause
        pauseSeconds.append(pause)

        // 暂停后**所有桶与吞吐类都重新采样**（卡是整体回血的），各自基线保留。
        for k in latencyBuckets.keys { latencyBuckets[k]?.resume() }
        throughputTracker.resume()
        throttled = false
        throttleSource = nil
        throttleBucket = nil

        showingResumedNote = true
        note?("已恢复写入")
        return true
    }

    private func trackerFor(kind: WriteKind, bucket: String?) -> Tracker? {
        switch kind {
        case .fullRewrite: return throughputTracker
        case .inPlace:     return bucket.flatMap { latencyBuckets[$0] }
        }
    }

    /// 下一次暂停时长：`initialPause × 增长倍数^连续降速次数`，封顶 `maxPause`。
    /// 新策略 ×1.5（封顶 8 s），旧策略 ×2（封顶 20 s）。
    private func pauseDuration() -> TimeInterval {
        let g = config.adaptiveStrategy ? config.pauseGrowth : 2.0
        let factor = pow(g, Double(consecutiveSlowdowns))
        return min(config.maxPause, config.initialPause * factor)
    }

    // MARK: - 文案

    private func secondsText(_ v: TimeInterval) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func sustainedText(kind: WriteKind, metric: Double) -> String {
        switch kind {
        case .fullRewrite:
            return String(format: "存储卡持续 %.0f MB/s，已按持续速度写入，不再等待",
                          kind.display(metric))
        case .inPlace:
            return String(format: "存储卡每次写入约 %.0f ms，已按当前速度写入，不再等待",
                          kind.display(metric))
        }
    }

    // MARK: - 观测

    public func stats() -> Stats {
        Stats(latencyBuckets: latencyBuckets.mapValues { stats(of: $0) },
              fullRewrite: stats(of: throughputTracker),
              consecutiveSlowdowns: consecutiveSlowdowns,
              isThrottled: throttled,
              throttleSource: throttleSource,
              throttleBucket: throttleBucket,
              nextPause: pauseDuration(),
              totalPaused: totalPaused,
              pauseCount: pauseCount,
              cancelledDuringPause: cancelledDuringPause,
              pauseSeconds: pauseSeconds,
              writeWallClock: writeWallClock,
              writtenBytes: writtenBytes,
              effectivePauses: effectivePauses,
              ineffectivePauses: ineffectivePauses,
              budgetStopped: budgetStopped,
              inCooldown: inCooldown,
              sustainedMetric: sustainedMetric,
              sustainedKind: sustainedKind)
    }

    private func stats(of t: Tracker) -> TrackerStats {
        TrackerStats(kind: t.kind,
                     bucket: t.bucket,
                     baseline: t.baseline,
                     ema: t.ema,
                     last: t.last,
                     threshold: t.baseline.map { config.threshold(for: t.kind, baseline: $0) },
                     samplesSinceResume: t.samplesSinceResume,
                     normalStreak: t.normalStreak,
                     consecutiveSlow: t.consecutiveSlow,
                     totalSamples: t.totalSamples,
                     recentMedian: t.recentMedian)
    }

    public var isEnabled: Bool { config.enabled }
}

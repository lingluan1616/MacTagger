//
//  AutoMatchService.swift
//  MacTagger — 自动匹配标签
//
//  对应原版 FormAutoMatchTags「自动匹配标签」，是阶段 2 的功能落点：
//  把「多源搜索 → 跨源去重 → 打分选优 → 生成差异编辑集」串成界面可直接调用的服务。
//
//  三条设计底线（标签编辑器的数据安全要求）：
//  1. **采纳阈值**：分数不够就标记「忽略」，绝不硬套一个错的候选上去。
//     对应原版「成功 / 失败 / 忽略」三态统计里的「忽略」。
//  2. **字段级白名单**：用户可以只让它补年份和音轨号，不动自己改过的标题。
//  3. **绝不用空值覆盖已有标签**（由 TrackCandidate.asTagEdit 保证）。
//
//  单源故障只淘汰该源，绝不中断整批——这是可插拔源设计的根本目的。
//

import Foundation

// MARK: - 歌词合并设置（BH 轮）

/// 自动匹配写入歌词时，「原词 + 翻译」怎么拼。
///
/// **为什么单开一个结构而不是在自动匹配里另存一套开关**：
/// 用户在「歌词文件选项」里已经选过一次合并格式（批量下载歌词走的就是那一份），
/// 自动匹配再摆一套就会出现「明明勾了翻译，自动匹配写出来还是只有日文原文」——
/// 那正是这一轮要修的病。所以界面层把 `AppSettings.lyricsFile` 的同名两项灌进来，
/// 数据层只认这一个结构，两条路径共用同一份口径（任务书 B1）。
///
/// `separator` / `skipOriginalWhenTranslated` 目前没有界面开关（`LyricsFileOptions`
/// 里也没有），保留字段是为了与 `LyricsService.merge` 的完整签名对齐，
/// 将来加开关时不必再改数据层。
public struct LyricsMergeSettings: Sendable, Equatable {
    /// 关掉 = 只写原词（退化成 BH 轮之前的行为）。
    public var includeTranslation: Bool
    public var mergeFormat: TranslationMergeFormat
    /// `inline` 格式下原词与翻译之间的连接符。
    public var separator: String
    /// 有译文时不保留原词。
    public var skipOriginalWhenTranslated: Bool

    public init(includeTranslation: Bool = true,
                mergeFormat: TranslationMergeFormat = .twoLines,
                separator: String = " ",
                skipOriginalWhenTranslated: Bool = false) {
        self.includeTranslation = includeTranslation
        self.mergeFormat = mergeFormat
        self.separator = separator
        self.skipOriginalWhenTranslated = skipOriginalWhenTranslated
    }

    public static let `default` = LyricsMergeSettings()

    /// 合出「可直接写进 LYRICS 字段 / .lrc 文件」的一份文本。
    /// 没有译文、或关掉了翻译时，**原样退化为原词**（绝不因为合并失败就交白卷）。
    public func merged(_ bundle: LyricsBundle?) -> String? {
        guard let bundle else { return nil }
        guard includeTranslation else { return bundle.plain }
        return LyricsService.merge(plain: bundle.plain,
                                   translated: bundle.translated,
                                   format: mergeFormat,
                                   separator: separator,
                                   skipOriginalWhenTranslated: skipOriginalWhenTranslated)
            ?? bundle.plain
    }

    /// 这一份 bundle 合出来的文本里到底带没带译文。复核表的「歌词（含翻译）」chip 读它。
    public func producesTranslation(_ bundle: LyricsBundle?) -> Bool {
        guard includeTranslation, let bundle else { return false }
        return bundle.hasTranslation
    }
}

// MARK: - 选项

public struct AutoMatchOptions: Sendable {
    /// 参与匹配的源，按优先级排列。空数组表示用注册表里的全部源。
    public var sourceIDs: [String]
    /// 采纳阈值：最佳候选低于此分则判为「忽略」，不写入。
    public var acceptThreshold: Double
    /// 允许写入的字段。nil = 全部字段。
    public var fields: Set<TagEdit.Field>?
    public var fetchArtwork: Bool
    public var artworkSize: Int
    public var fetchLyrics: Bool
    /// 下载到的歌词怎么和译文合并再写入。默认来自「歌词文件选项」，见 `LyricsMergeSettings`。
    /// **BH 轮之前这里什么都没有**：自动匹配只写 `LyricsBundle.plain`，
    /// 用户勾了翻译也永远拿不到译文行。
    public var lyricsMerge: LyricsMergeSettings
    /// 每个源返回的候选上限。
    public var limitPerSource: Int
    /// 文件级并发度。各源自身的限速由 HTTPClient 负责，这里只控文件并行。
    public var concurrency: Int
    /// 在线结果的字形归一策略。默认取进程级设置（App 由「在线结果统一转为」那一项推入）。
    public var chineseVariant: ChineseVariantPolicy

    // MARK: 软截止（AX 轮）
    //
    // 病根：原先每首歌要**等所有源都返回**才打分，于是「每首耗时 = 最慢的那个源」。
    // 实测各源延迟离散得厉害（iTunes 2.9 s / QQ 2.4 s / 酷狗 6.6 s / MusicBrainz 19.7 s），
    // 12 首逐首模式跑了 44 s ≈ 3.7 s/首 —— 快源早就把答案交上来了，全在陪最慢的那个等。
    //
    // 对策：**不等最慢源**。到点就把没回来的源标成 `.skipped`，用已有的候选照常打分。
    // 三条边界：
    // 1. 跳过**不是失败**：不进失败统计、不计熔断（理由见 `SourceOutcome.Status.skipped`）。
    // 2. 请求确实发了出去，只是我们不等了 —— 到点会把在途请求取消掉，把连接还回去。
    // 3. 慢档单列：MusicBrainz 是权威元数据源，值得多等一会儿，但也有上限。

    /// 每个源的软截止（秒）。到点还没返回就不再等它。`<= 0` 关闭软截止（旧行为）。
    public var sourceSoftDeadline: TimeInterval
    /// 「慢但权威」的那些源单独放宽到这个秒数。
    ///
    /// ★ BH 轮：译文补查轮最多问几个源。这一轮是**串行**问的，每多一个源就是实打实
    /// 多等一发；而第三、第四家能补上前两家都没有的译文，实测是极少数。默认 2（网易云 → QQ）。
    public var translationSourceLimit: Int = 2
    public var slowSourceSoftDeadline: TimeInterval
    /// 提前收工的分数门槛：已返回的源里出现 ≥ 这个分的候选就不再等其余源。
    public var earlyAcceptScore: Double
    /// 提前收工至少要有几个源已返回。
    ///
    /// 为什么不是 1：单源的高分是**没有旁证**的高分。iTunes 港区一条繁体《稻香》
    /// 能轻松打到 0.95，但它可能来自某张精选合辑；等第二个源回来才有跨源去重与
    /// 专辑质量的比较基础。2 是「有旁证」与「还快」之间的那个点。
    public var earlyAcceptMinSources: Int
    /// 是否补全作曲/作词（需要额外查歌词源，见 `enrich`）。
    public var fetchCredits: Bool
    /// 署名查询的软截止（秒）。
    public var creditsSoftDeadline: TimeInterval

    /// 走慢档软截止的源。
    public static let slowSourceIDs: Set<String> = ["musicbrainz", "coverartarchive"]

    /// 这个源该等多久。`<= 0` 表示不设软截止。
    public func softDeadline(for sourceID: String) -> TimeInterval {
        guard sourceSoftDeadline > 0 else { return 0 }
        return AutoMatchOptions.slowSourceIDs.contains(sourceID)
            ? max(sourceSoftDeadline, slowSourceSoftDeadline)
            : sourceSoftDeadline
    }

    public init(sourceIDs: [String] = [],
                acceptThreshold: Double = 0.6,
                fields: Set<TagEdit.Field>? = nil,
                fetchArtwork: Bool = false,
                artworkSize: Int = 1200,
                fetchLyrics: Bool = false,
                lyricsMerge: LyricsMergeSettings = .default,
                limitPerSource: Int = 8,
                concurrency: Int = 8,
                chineseVariant: ChineseVariantPolicy = ChineseVariant.onlineDefault,
                sourceSoftDeadline: TimeInterval = 4,
                slowSourceSoftDeadline: TimeInterval = 8,
                earlyAcceptScore: Double = 0.9,
                earlyAcceptMinSources: Int = 2,
                fetchCredits: Bool = true,
                creditsSoftDeadline: TimeInterval = 3) {
        self.sourceIDs = sourceIDs
        self.acceptThreshold = acceptThreshold
        self.fields = fields
        self.fetchArtwork = fetchArtwork
        self.artworkSize = artworkSize
        self.fetchLyrics = fetchLyrics
        self.lyricsMerge = lyricsMerge
        self.limitPerSource = limitPerSource
        self.concurrency = concurrency
        self.chineseVariant = chineseVariant
        self.sourceSoftDeadline = sourceSoftDeadline
        self.slowSourceSoftDeadline = slowSourceSoftDeadline
        self.earlyAcceptScore = earlyAcceptScore
        self.earlyAcceptMinSources = earlyAcceptMinSources
        self.fetchCredits = fetchCredits
        self.creditsSoftDeadline = creditsSoftDeadline
    }

    /// C 报告实测的推荐优先级：P0 四源覆盖约 90% 需求。
    public static let recommended = AutoMatchOptions(
        sourceIDs: ["itunes", "netease", "kugou", "qq"]
    )

    /// **AX 轮之前的行为**，只供压测对照组（`--legacy`）用：
    /// 等所有源、署名照旧回落多源、文件级并发 4。
    /// 不是给用户的选项 —— 界面上没有任何入口能选到它。
    public static var legacy: AutoMatchOptions {
        var o = AutoMatchOptions(sourceIDs: ["itunes", "netease", "kugou", "qq"])
        o.concurrency = 4
        o.sourceSoftDeadline = 0
        o.slowSourceSoftDeadline = 0
        o.earlyAcceptScore = 2          // 永远达不到 → 不会提前收工
        o.creditsSoftDeadline = 0
        return o
    }
}

// MARK: - 结果

public struct AutoMatchResult: Sendable {
    public enum Status: String, Sendable {
        case matched            // 找到且达到阈值
        case ignored            // 有候选但都低于阈值 —— 对应原版「忽略」
        case failed             // 所有源都出错
        case noQuery            // 文件既无标题也无文件名可用
    }

    public var url: URL
    public var status: Status
    public var best: TrackCandidate?
    public var edit: TagEdit?
    public var artwork: Data?
    public var lyrics: LyricsBundle?
    public var triedSources: [String]
    public var candidateCount: Int
    public var errors: [(sourceID: String, message: String)]

    /// **保留下来的候选**，按分降序，`best` 恒为首个。
    ///
    /// 为什么必须留：原先只交出 `best`，复核表里就只有一个答案可看 ——
    /// 用户明知匹配错了也只能整行放弃。专辑模式早就有「换专辑」，逐首模式却什么都没有。
    /// 留住 top N 之后，复核表每行才能给出「换候选 ▾」。
    public var candidates: [TrackCandidate] = []

    /// 逐源结果条：每个源这一轮是「有 n 条 / 0 条 / 挂了」，含耗时。
    /// 与 `errors` 的区别：`errors` 只在失败时才有，**说不出「搜到了 0 条」**，
    /// 而用户看不到 QQ 时最想知道的正是这两者的区别。
    public var sourceOutcomes: [SourceOutcome] = []

    // MARK: 耗时（AX 轮：用户抱怨「慢」，就得让他看得见时间花在哪）

    /// 这一首从进入 `match` 到出结果的总耗时（秒）。
    public var elapsed: TimeInterval = 0
    /// 补署名（作曲/作词）那一步花了多久。0 = 没花时间。
    public var creditsLatency: TimeInterval = 0
    // BH 轮分阶段计时：`elapsed` 只说「这首慢」，下面几项说「慢在哪一段」。
    /// 搜索 + 打分（各源 searchTracks 的耗时**累加**，它们是并发跑的）。
    public var searchLatency: TimeInterval = 0
    /// 封面下载耗时。
    public var artworkLatency: TimeInterval = 0
    /// 取词耗时，**含**下面的 `translationLatency`。
    public var lyricsLatency: TimeInterval = 0
    /// 其中「为了找译文额外问源」那一轮。
    public var translationLatency: TimeInterval = 0
    /// 这一首跑没跑过译文补查轮（0/1）。
    public var translationRounds: Int = 0
    /// 署名是怎么来的：「复用歌词」/「网易云」/「白名单未含，跳过」/「超过软截止」…
    public var creditsNote: String?

    /// 展开行里那一句「耗时：iTunes 2.9 s · 酷狗 6.6 s（超软截止 4 s）· 署名 0 s（复用歌词）」。
    public var timingLine: String {
        var parts = sourceOutcomes.sortedByPriority().map(\.latencyLabel)
        if let n = creditsNote {
            parts.append(String(format: "署名 %.1f s（%@）", creditsLatency, n))
        } else if creditsLatency > 0 {
            parts.append(String(format: "署名 %.1f s", creditsLatency))
        }
        return parts.joined(separator: " · ")
    }

    /// 将要改动的字段摘要，供界面做「写入前预览」。
    public var changedFieldNames: [String] {
        (edit?.changes ?? []).map { $0.field.localizedName }
    }

    // MARK: 按文件选择写入哪些字段
    //
    // ── 为什么这一层也要有 ──
    // 「全部匹配之后，有些文件不想写碟号、有些不想写音轨号」是逐文件的决定：
    // `AutoMatchOptions.fields` 那个白名单是**整轮**的，改不了单个文件。
    // 复核表的勾选状态最终要落到写入组装上，把它记在结果自己身上，
    // 逐首模式与专辑模式就共用同一份口径，probe 也能不经界面直接验。

    /// 本次真会写入的字段。默认 = `edit` 里确有改动的那一整套。
    /// 从中去掉某个字段 = 「这个文件不写它」。
    public var acceptedFields: Set<TagEdit.Field> = []
    /// 匹配到的封面写不写进这个文件。
    public var acceptArtwork: Bool = true
    /// 匹配到的歌词写不写进这个文件。歌词是二段式单独取回来的，
    /// 不在 `edit.changes` 里，所以单独一个开关。
    public var acceptLyrics: Bool = true

    /// 把 `acceptedFields` / `acceptArtwork` 应用到 `edit` 上，得到**真正要写的**那一份。
    ///
    /// 被排除的字段不进 `TagEdit`，因此既不写盘、也不进历史旁存 ——
    /// 「排除」必须是彻底的，留一半就成了「看起来没写、撤销时却冒出来」。
    ///
    /// 封面要特殊照顾一下：候选转 `TagEdit` 时**不带封面**（`asTagEdit` 只管字段），
    /// 封面单独躺在 `artwork` 里，由调用方自己组装。这里替调用方把它排进来，
    /// 好让这一份 edit 真的就是「这个文件将被写入的全部内容」——
    /// 否则「勾了封面却没写」只能靠调用方各自记得，两条路径迟早会分岔。
    public var acceptedEdit: TagEdit? {
        guard let edit else { return nil }
        var out = TagEdit()
        for c in edit.changes where acceptedFields.contains(c.field) {
            out.set(c.field, c.value)
        }
        for r in edit.rawChanges { out.setRaw(r.key, r.values) }
        out.syncID3v1 = edit.syncID3v1
        out.artworkAction = .keep
        if acceptArtwork {
            switch edit.artworkAction {
            case .keep:
                if let data = artwork, !data.isEmpty {
                    out.artworkAction = .replace([Artwork(
                        data: data,
                        mimeType: ArtworkProcessor.mimeType(data),
                        caption: best?.title ?? "Cover",
                        type: .frontCover)])
                }
            case .replace, .removeAll:
                out.artworkAction = edit.artworkAction
            }
        }
        return out
    }

    /// 被用户排除掉的字段（默认全集减去当前勾选）。统计与打印用。
    public var excludedFields: Set<TagEdit.Field> {
        Set((edit?.changes ?? []).map(\.field)).subtracting(acceptedFields)
    }

    /// 默认勾选：本次会改动的字段全集。构造完 `edit` 之后调一次。
    public mutating func resetAcceptedFieldsToAll() {
        acceptedFields = Set((edit?.changes ?? []).map(\.field))
    }
}

// MARK: - 服务

public enum AutoMatchService {

    /// 复核表里每行最多留几条候选。10 条足够覆盖「原版 / Live / 各种合辑」这一串，
    /// 再多只会让「换候选 ▾」的菜单长到没法扫。
    public static let maxKeptCandidates = 10

    // MARK: 逐源取候选（供匹配、手动搜索、健康探测共用）

    /// 并发查各源，返回**未打分的原始候选池**与逐源结果条。
    /// 任一源抛错只记账、不中断 —— 这条底线在拆出这个函数后依然由它一个人守。
    public static func gather(_ query: TrackQuery,
                              options: AutoMatchOptions = .recommended)
        async -> (pool: [TrackCandidate], outcomes: [SourceOutcome]) {

        let sources = resolveSources(options)
        guard !sources.isEmpty, !query.isEmpty else { return ([], []) }

        let started = Date()
        var pooled: [TrackCandidate] = []
        var outcomes: [SourceOutcome] = []
        var returned = Set<String>()
        var earlyStopped = false

        await withTaskGroup(of: SourceGathered.self) { group in
            for src in sources {
                let deadline = options.softDeadline(for: src.id)
                group.addTask { await fetchOne(src, query: query, options: options, deadline: deadline) }
            }

            for await g in group {
                outcomes.append(g.outcome)
                returned.insert(g.outcome.sourceID)
                pooled.append(contentsOf: g.candidates)

                // ★ 提前收工：已经有旁证充分的高分候选了，剩下的源不必再等。
                //
                // 打分是纯本地计算（`MatchScorer.rank` 不发任何请求），拿整池重打一遍
                // 每次也只是几十条候选的字符串比对 —— 比多等一个源便宜好几个数量级。
                guard returned.count < sources.count else { break }
                if shouldStopEarly(pool: pooled, query: query,
                                   sourcesReturned: returned.count, options: options) {
                    earlyStopped = true
                    // cancelAll 会把在途的 URLSession 请求真的取消掉（HTTPClient 认得
                    // `NSURLErrorCancelled`，不记账、不计熔断），把连接立刻还回去。
                    group.cancelAll()
                    break
                }
            }
        }

        // 没等到的那些源：如实记成「跳过」，附上人话原因。
        // **绝不能记成失败或 0 条** —— 前者是假账，后者会让用户以为这个源没有这首歌。
        let elapsed = Date().timeIntervalSince(started)
        var missing: [any MetadataSource] = []
        for src in sources where !returned.contains(src.id) {
            missing.append(src)
            let queued = await limiterQueueDelay(src.id)
            let dl = options.softDeadline(for: src.id)
            let reason: String
            if earlyStopped {
                reason = "已有高分候选，提前结束等待"
            } else if queued > dl {
                reason = String(format: "限速排队 %.0f s > 等待上限 %.0f s", queued, dl)
            } else {
                reason = String(format: "超过软截止 %.0f s", dl)
            }
            outcomes.append(SourceOutcome(sourceID: src.id,
                                          status: .skipped(reason: reason),
                                          latency: elapsed))
        }

        // ★ 救援轮：**一条候选都没拿到**，却还有源被软截止挡在门外。
        //
        // 这一步是整个提速方案的安全阀。软截止的赌注是「快源已经给出答案了，慢源不必再等」；
        // 赌注不成立时（快源全空或全挂），继续「不等」就不是提速而是**把命中变成没命中** ——
        // 那是用户明令不许发生的退化。既然这一首本来就已经要空手而归，
        // 多等一轮不会让任何原本成功的情况变慢，只可能把失败救回成功。只救一轮，不递归。
        if pooled.isEmpty, !missing.isEmpty {
            var rescued: [SourceOutcome] = []
            await withTaskGroup(of: SourceGathered.self) { group in
                for src in missing {
                    group.addTask {
                        // 救援轮不设软截止：它的存在本身就是因为「等不起」的假设已经破产。
                        await fetchOne(src, query: query, options: options, deadline: 0)
                    }
                }
                for await g in group {
                    var o = g.outcome
                    o.detail = (o.detail.map { $0 + "（软截止后救援轮）" }) ?? "软截止后救援轮"
                    rescued.append(o)
                    pooled.append(contentsOf: g.candidates)
                }
            }
            // 救援轮的真实结果替换掉那条「跳过」，否则结果条会说谎。
            for r in rescued {
                if let i = outcomes.firstIndex(where: { $0.sourceID == r.sourceID }) {
                    outcomes[i] = r
                } else {
                    outcomes.append(r)
                }
            }
        }

        // 归一已在各源的子任务里做完（见 `fetchOne`），这里只排个序。
        return (pooled, outcomes.sortedByPriority())
    }

    /// 查一个源，带自己的软截止。到点就返回 `.skipped`，并把在途请求取消掉。
    ///
    /// 为什么用**嵌套**任务组而不是外层一个统一的计时器：各源的软截止不一样
    /// （MusicBrainz 8 s，其余 4 s）。让每个源自己管自己的表，外层就只剩「谁先回来算谁」
    /// 这一件事，不必维护一张「哪个源什么时候到点」的时间表。
    static func fetchOne(_ src: any MetadataSource,
                         query: TrackQuery,
                         options: AutoMatchOptions,
                         deadline: TimeInterval) async -> SourceGathered {

        let started = Date()

        func work() async -> SourceGathered {
            do {
                let found = try await src.searchTracks(query, limit: options.limitPerSource)
                // 空结果计数（AX 轮）：连续 N 次空 → 判为被风控置空并暂停该源。
                // 记在这里而不是 HTTPClient：HTTP 层看到的是 200，「空」是业务层才知道的事。
                if found.isEmpty {
                    await SourceCircuitBreaker.shared.recordEmptyResult(src.id)
                } else {
                    await SourceCircuitBreaker.shared.recordNonEmpty(src.id)
                }
                // ★ 逐首模式的**唯一**简繁归一入口。位置必须在这里 —— 打分之前。
                //
                // 放到打分之后（比如只在写入前转）会踩两个坑：
                // ① 简体查询串对繁体候选的字面相似度天然偏低（"稻香/周杰伦" vs "稻香/周杰倫"），
                //    本该采纳的候选被压到阈值以下判成「忽略」；iTunes 中区空、回退港区之后
                //    整池全是繁体，这个偏差是系统性的，不是个例。
                // ② 跨源去重的判重键是「归一标题+归一艺术家+时长桶」，简繁不统一的话
                //    港区的《稻香》和网易云的《稻香》会被当成两首歌各占一个名额。
                // 从 `gather` 末尾挪到这里是 AX 轮的要求：提前收工要先打分，
                // 打分之前就必须已经归一，否则「提前收工」判的是没归一过的分。
                let converted = found.map { $0.converted(to: options.chineseVariant) }
                return SourceGathered(
                    outcome: SourceOutcome(sourceID: src.id,
                                           status: found.isEmpty ? .empty : .hits(found.count),
                                           latency: Date().timeIntervalSince(started)),
                    candidates: converted,
                    errorMessage: nil)
            } catch let q as RateLimitQueueTooLong {
                // ★ 限速排队排不上（BD 轮）。**一个字节都没发出去**，因此：
                //   不是失败、不计熔断、不进健康台账 —— 记成「跳过」，
                //   但原因要写成真话：是**我们自己的限速**排不上，不是这个源慢或挂了。
                //   实测 iTunes 3.1 s 一发 × 并发 8 × 软截止 4 s ⇒ 20 首里 19 首排不上。
                return SourceGathered(
                    outcome: SourceOutcome(sourceID: src.id,
                                           status: .skipped(reason: q.reason),
                                           latency: Date().timeIntervalSince(started),
                                           detail: q.reason),
                    candidates: [],
                    errorMessage: nil)
            } catch {
                // 业务层空结果（QQ 被风控静默置空就是这一支）同样计进空结果计数。
                if let se = error as? SourceError, case .emptyResult = se {
                    await SourceCircuitBreaker.shared.recordEmptyResult(src.id)
                }
                var outcome = SourceOutcome.failure(src.id, error,
                                                    latency: Date().timeIntervalSince(started))
                // 「暂停中」得说清是**为什么**暂停：连续超时和疑似被风控置空，
                // 用户该做的事完全不同（前者等一会儿，后者换个源或改条件）。
                if outcome.status.isPaused,
                   let why = await SourceCircuitBreaker.shared.stats(src.id).pauseReason {
                    outcome.detail = why
                }
                return SourceGathered(outcome: outcome,
                                      candidates: [],
                                      errorMessage: SourceOutcome.fullReason(for: error))
            }
        }

        guard deadline > 0 else { return await work() }

        // ★ 把软截止**时刻**交给网络层（BD 轮）。`HTTPClient` 拿它决定
        //   「这一发要排到软截止之后了，那就别领时隙了」——
        //   否则注定要被取消的请求照样占着发包预算，把后面本来排得上的挤掉。
        let until = started.addingTimeInterval(deadline)

        return await RateLimitBudget.$deadline.withValue(until) {
            await withTaskGroup(of: SourceGathered?.self) { race in
                race.addTask { await work() }
                race.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    return nil          // nil = 计时器先到
                }
                let first = await race.next() ?? nil
                race.cancelAll()
                if let first { return first }
                // 到点还没回来。分两种写法 —— 用户要做的事完全不同：
                //   · 排队排不上 → 是**我们自己**的限速，该调「每首最多等待」或改用专辑模式；
                //   · 真的慢     → 是这个源慢，等或换源。
                let queued = await Self.limiterQueueDelay(src.id)
                let reason = queued > deadline
                    ? String(format: "限速排队 %.0f s > 等待上限 %.0f s", queued, deadline)
                    : String(format: "超过软截止 %.0f s", deadline)
                return SourceGathered(
                    outcome: SourceOutcome(
                        sourceID: src.id,
                        status: .skipped(reason: reason),
                        latency: Date().timeIntervalSince(started),
                        detail: reason),
                    candidates: [],
                    errorMessage: nil)
            }
        }
    }

    /// 这个源现在排队要多久。只读，不占时隙。
    static func limiterQueueDelay(_ sourceID: String) async -> TimeInterval {
        await HTTPClient.limiter.queueDelay(sourceID: sourceID)
    }

    /// 提前收工的判据：**已返回的源里已经有分够高的候选，且旁证够多**。
    static func shouldStopEarly(pool: [TrackCandidate],
                                query: TrackQuery,
                                sourcesReturned: Int,
                                options: AutoMatchOptions) -> Bool {
        guard options.earlyAcceptScore <= 1.0,
              sourcesReturned >= max(1, options.earlyAcceptMinSources),
              !pool.isEmpty else { return false }
        let top = MatchScorer.rank(pool, for: query).first?.matchScore ?? 0
        return top >= options.earlyAcceptScore
    }

    struct SourceGathered: Sendable {
        var outcome: SourceOutcome
        var candidates: [TrackCandidate]
        var errorMessage: String?
    }

    /// 手动搜索用：给一条查询，直接拿回打分排序、跨源去重后的候选与逐源结果条。
    /// 复核表的「更多 ▾ › 手动搜索…」就是它的唯一调用方。
    public static func searchCandidates(_ query: TrackQuery,
                                        options: AutoMatchOptions = .recommended,
                                        limit: Int = maxKeptCandidates)
        async -> (candidates: [TrackCandidate], outcomes: [SourceOutcome]) {

        let (pool, outcomes) = await gather(query, options: options)
        let ranked = dedupe(MatchScorer.rank(pool, for: query))
        return (Array(ranked.prefix(limit)), outcomes)
    }

    // MARK: 单文件

    public static func match(_ file: AudioFile,
                             options: AutoMatchOptions = .recommended) async -> AutoMatchResult {
        // 耗时统一在这一层记：`matchCore` 有五条 return 分支，每条都补一句既冗余又容易漏。
        let startedAt = Date()
        var r = await matchCore(file, options: options)
        r.elapsed = Date().timeIntervalSince(startedAt)
        return r
    }

    static func matchCore(_ file: AudioFile,
                          options: AutoMatchOptions = .recommended) async -> AutoMatchResult {
        let query = makeQuery(from: file)
        var result = AutoMatchResult(url: file.url,
                                     status: .noQuery,
                                     best: nil, edit: nil,
                                     artwork: nil, lyrics: nil,
                                     triedSources: [],
                                     candidateCount: 0,
                                     errors: [])
        guard !query.isEmpty else { return result }

        let sources = resolveSources(options)
        guard !sources.isEmpty else {
            result.status = .failed
            result.errors.append(("registry", "没有可用的数据源"))
            result.sourceOutcomes = [SourceOutcome(sourceID: "registry",
                                                   status: .failed("无可用源"),
                                                   detail: "没有可用的数据源")]
            return result
        }

        // 并发查各源。任一源抛错只记录、不中断。
        let (pooled, outcomes) = await gather(query, options: options)
        result.sourceOutcomes = outcomes
        result.searchLatency = outcomes.reduce(0) { $0 + $1.latency }
        result.triedSources = outcomes.map(\.sourceID)
        for o in outcomes where o.status.isFailure {
            result.errors.append((o.sourceID, o.detail ?? o.chipLabel))
        }

        result.candidateCount = pooled.count
        guard !pooled.isEmpty else {
            // 全部源都没给出候选：有错误就是 failed，否则是 ignored（搜到了但没结果）
            result.status = result.errors.count == sources.count ? .failed : .ignored
            return result
        }

        // 打分 → 跨源去重 → 取最优。
        // 文件名回落时有两种解释（哪段是标题），各打一次分取更优的——
        // 不额外发请求，只是把同一批候选按两种口径各评一遍。
        let interpretations = queryInterpretations(from: file)
        var bestPool: [TrackCandidate] = []
        var bestTop = -1.0
        for interp in interpretations {
            let r = dedupe(MatchScorer.rank(pooled, for: interp))
            let score = r.first?.matchScore ?? -1
            if score > bestTop { bestTop = score; bestPool = r }
        }
        let deduped = bestPool
        // 无论最终采纳与否，候选都要交出去：低于阈值时用户往往正需要翻一翻第二三名。
        result.candidates = Array(deduped.prefix(maxKeptCandidates))
        guard let top = deduped.first else {
            result.status = .ignored
            return result
        }

        guard top.matchScore >= options.acceptThreshold else {
            result.best = top
            result.status = .ignored          // 分数不够，不写入
            return result
        }

        let enriched = await enrichDetailed(top, options: options)
        result.best = enriched.candidate
        result.edit = enriched.candidate.asTagEdit(fields: options.fields)
        // 默认全勾：结果刚出来时「会改的字段」就是「要写的字段」，
        // 排除是用户在复核表上做的减法。
        result.resetAcceptedFieldsToAll()
        result.artwork = enriched.artwork
        result.lyrics = enriched.lyrics
        result.creditsLatency = enriched.creditsLatency
        result.creditsNote = enriched.creditsNote
        result.artworkLatency = enriched.artworkLatency
        result.lyricsLatency = enriched.lyricsLatency
        result.translationLatency = enriched.translationLatency
        result.translationRounds = enriched.translationRounds
        result.status = .matched
        // 补完详情的那一条要替换掉候选表里的对应项，否则「换候选」换回自己时字段会缩水。
        if !result.candidates.isEmpty { result.candidates[0] = enriched.candidate }

        return result
    }

    // MARK: 候选补全

    /// 把一条候选补成「可以直接写入」的完整形态：补详情 → 封面 → 歌词 → 署名。
    ///
    /// 自动选出的最佳候选与用户手动换的候选走**同一个函数**——
    /// 否则手动换过去的那一条会缺年份、缺封面，看起来像是「换了反而更差」。
    public static func enrich(_ candidate: TrackCandidate,
                              options: AutoMatchOptions = .recommended)
        async -> (candidate: TrackCandidate, artwork: Data?, lyrics: LyricsBundle?) {
        let e = await enrichDetailed(candidate, options: options)
        return (e.candidate, e.artwork, e.lyrics)
    }

    /// 补全的结果 + 「署名那一步花了多久、是怎么来的」。
    /// `enrich` 是它的三元组投影，保持既有调用方一个字都不用改。
    public struct Enriched: Sendable {
        public var candidate: TrackCandidate
        public var artwork: Data?
        public var lyrics: LyricsBundle?
        public var creditsLatency: TimeInterval = 0
        public var creditsNote: String?
        // BH 轮分阶段计时：谁花的时间记在谁头上，好让「慢」有处可查。
        public var artworkLatency: TimeInterval = 0
        /// 取词总耗时，**含**下面的 `translationLatency`。
        public var lyricsLatency: TimeInterval = 0
        /// 其中「为了找译文额外问源」那一轮。
        public var translationLatency: TimeInterval = 0
        /// 这一首有没有跑过译文补查轮（0/1）。
        public var translationRounds: Int = 0
    }

    // MARK: 取词（逐首模式与专辑模式**共用同一处实现**）

    /// 一首歌的取词结果 + 这一步的分阶段计时。
    public struct FetchedLyrics: Sendable {
        /// **未做字形归一**的原始 bundle。调用方各自 `converted(to:)` ——
        /// `enrichDetailed` 在最后统一转，专辑模式在写回 `perFile` 时转，
        /// 放在这里转会让「复用歌词解析署名」那一步拿到已转过的文本（作词→作詞）。
        public var bundle: LyricsBundle?
        /// 取词总耗时，**含** `translationLatency`。
        public var latency: TimeInterval = 0
        /// 其中「为了找译文额外问源」那一轮。
        public var translationLatency: TimeInterval = 0
        /// 这一首跑没跑过译文补查轮（0/1）。
        public var translationRounds: Int = 0

        public init(bundle: LyricsBundle? = nil, latency: TimeInterval = 0,
                    translationLatency: TimeInterval = 0, translationRounds: Int = 0) {
            self.bundle = bundle
            self.latency = latency
            self.translationLatency = translationLatency
            self.translationRounds = translationRounds
        }
    }

    /// 给**一条已经选定的候选**补歌词：胜出源取词 → 值得要翻译时再补查 ≤ `translationSourceLimit` 源。
    ///
    /// ★ BJ 轮新抽出来的方法。在此之前这段逻辑长在 `enrichDetailed` 肚子里，
    /// 而专辑模式**根本不走 `enrich`**（它的候选来自专辑曲目表，不是逐首搜索），
    /// 于是「按文件夹匹配」整条路一句词都取不到 —— 用户报的
    /// 「按文件夹来匹配歌词不会成功，但是逐首的话可以有」就是这么来的。
    /// 两种模式现在调的是同一个函数，不存在「一边修好另一边还漏」。
    ///
    /// - Returns: `options.fetchLyrics == false` 时返回空壳（不发任何请求）。
    public static func fetchLyricsForCandidate(_ candidate: TrackCandidate,
                                               options: AutoMatchOptions = .recommended)
        async -> FetchedLyrics {

        guard options.fetchLyrics else { return FetchedLyrics() }

        let tLyr = Date()
        var lyrics: LyricsBundle?
        var translationLatency: TimeInterval = 0
        var translationRounds = 0

        if let src = SourceRegistry.shared.source(id: candidate.sourceID),
           src.capabilities.contains(.lyrics) {
            lyrics = try? await src.fetchLyrics(candidate)
        }
        // ★ 「有翻译优先」的自动匹配那一半（BD 轮）。
        //
        // 原先只问**胜出源**一家：胜出的是 iTunes / MusicBrainz（都没有歌词能力）
        // 就一句词都没有；胜出的是只给原文的那一家，就永远没有翻译。
        // 用户抱怨的「歌词总是没有翻译」，在自动匹配这条路上就是这么来的。
        //
        // 补查的触发条件收得很紧，免得给华语库平白多打两个源：
        // 只有「这首值得要翻译」（含假名/谚文/英文，见 `LyricsService.wantsTranslation`）
        // **且**手上这份没有译文时才补，且补的是歌词源的推荐顺序、拿到译文即停。
        // 用**已经匹配到的候选**回查，而不是原始文件名 —— 这时曲名/艺术家已经是准的了，
        // 拿它去别的源搜比拿脏文件名去搜命中率高得多。
        //
        // ★ BG 轮：这条补查改走 `LyricsService.resolve`（`bestLyrics` 只是它的壳），
        // 于是自动匹配与「批量下载歌词」「搜索窗」共用**同一套**版本规则 ——
        // 搜索剥版本后缀、marker 打分、不同 Live 场次判不匹配、
        // 本版本无译文时从录音室版移植译文，一处实现（任务书 3d）。
        //
        // 补查触发条件不变：只有「这首值得要翻译」且手上这份没译文时才补。
        // 另外**本版本自己没有译文**时也要进来 —— 移植就发生在这一步里。
        let lyricQuery = TrackQuery(title: candidate.title, artist: candidate.artist,
                                    album: candidate.album, duration: candidate.durationSeconds)
        if lyrics?.hasTranslation != true, LyricsService.wantsTranslation(lyricQuery) {
            // ★ BH 轮：这一轮原先**不封顶也不设时限** —— 四个源串行问到底，
            // 105 首里日文歌多的那些批次，时间基本都花在这儿。两道闸一起上：
            //
            // ① 源数封顶（默认 2：网易云 → QQ）。胜出源若本身有歌词能力就排最前
            //    （它已被标签匹配选中，版本最可能是对的那一份）；没有歌词能力的
            //    iTunes / MusicBrainz 在**进 resolve 之前**就滤掉，否则封顶名额
            //    会被一个根本不出词的源白占一个。
            // ② 软截止，复用 `sourceSoftDeadline`：到点不再开新的源。
            let capable = LyricsService.translationSourceOrder
            var order: [String] = []
            if capable.contains(candidate.sourceID) { order.append(candidate.sourceID) }
            for id in capable where !order.contains(id) { order.append(id) }
            order = Array(order.prefix(max(1, options.translationSourceLimit)))

            let tTrans = Date()
            let r = await LyricsService.resolve(query: lyricQuery,
                                                sourceIDs: order,
                                                stopWhenSatisfied: true,
                                                softDeadline: options.sourceSoftDeadline)
            translationLatency = Date().timeIntervalSince(tTrans)
            translationRounds = 1
            if let b = r.bundle, b.hasTranslation { lyrics = b }
            else if lyrics == nil, let b = r.bundle, !b.isEmpty { lyrics = b }
        }

        return FetchedLyrics(bundle: lyrics,
                             latency: Date().timeIntervalSince(tLyr),
                             translationLatency: translationLatency,
                             translationRounds: translationRounds)
    }

    public static func enrichDetailed(_ candidate: TrackCandidate,
                                      options: AutoMatchOptions = .recommended)
        async -> Enriched {

        // 补详情（搜索结果常缺年份/音轨号）
        var best = candidate
        if let src = SourceRegistry.shared.source(id: best.sourceID),
           let detailed = try? await src.fetchDetail(best) {
            var merged = detailed
            merged.matchScore = best.matchScore   // fetchDetail 不该改分
            best = merged
        }

        // 可选：封面与歌词
        var artwork: Data?
        var lyrics: LyricsBundle?
        var artworkLatency: TimeInterval = 0
        var lyricsLatency: TimeInterval = 0
        var translationLatency: TimeInterval = 0
        var translationRounds = 0
        if options.fetchArtwork, let src = SourceRegistry.shared.source(id: best.sourceID) {
            let tArt = Date()
            defer { artworkLatency = Date().timeIntervalSince(tArt) }
            artwork = try? await src.fetchArtwork(best, preferredSize: options.artworkSize)
            // 本源没有封面时，若有 MBID 可回落 Cover Art Archive
            if artwork == nil, let mbid = best.albumID, best.sourceID == "musicbrainz" {
                artwork = try? await CoverArtArchiveSource()
                    .artwork(releaseMBID: mbid, preferredSize: options.artworkSize)
            }
        }
        if options.fetchLyrics {
            // ★ BJ 轮：这一整段搬进了 `fetchLyricsForCandidate`，专辑模式调的是**同一个**方法。
            // 原先它长在这里，于是「按文件夹匹配」那条路一句词都取不到（见 BJ 报告 §1）。
            let fetched = await fetchLyricsForCandidate(best, options: options)
            lyrics = fetched.bundle
            lyricsLatency = fetched.latency
            translationLatency = fetched.translationLatency
            translationRounds = fetched.translationRounds
        }

        // ★ 作曲 / 作词（AX 轮整段重做 —— 这里原先是**每首多花 5–7 秒**的大头）。
        //
        // 搜索接口几乎都不给署名，但中文平台的歌词开头普遍带「作词 : X」「作曲 : Y」
        // 几行，取一次歌词就能把这两个字段补上。问题出在「取一次」变成了「取好几次」：
        // 旧实现在胜出源没歌词时调 `LyricsService.bestLyrics(["netease","kugou"])`，
        // 而那个函数会把列表里**每一个**源都「搜索 + 取词」两发请求跑完再挑最好的，
        // 不会命中即停；两家都没署名时还要再来一趟 QQ。一首歌因此最多 6 发额外请求。
        //
        // 现在四条一起收：
        // ① 本次已开「下载歌词」且真拿到了词 → 直接从这份词里解析，**一发请求都不发**；
        // ② 否则先问胜出源（它若有歌词能力，这是最相关也最便宜的一发）；
        // ③ 再不行才回落**一个**源（网易云；它没给出署名才轮到酷狗），带 3 s 软截止；
        // ④ 按 (标题, 艺术家) 归一化键做进程内缓存 —— 同一批里同专辑的重复文件、
        //    以及「换候选」反复补全同一首，都只查一次。
        var creditsLatency: TimeInterval = 0
        var creditsNote: String?
        let wantsCredits = options.fields.map {
            $0.contains(.composer) || $0.contains(.lyricist)
        } ?? true

        if !wantsCredits {
            creditsNote = "字段白名单未含作曲/作词，跳过"
        } else if !options.fetchCredits {
            creditsNote = "已关闭「补全作曲/作词」"
        } else if best.composer != nil, best.lyricist != nil {
            creditsNote = "候选自带"
        } else {
            let t0 = Date()
            var credits = LyricsService.credits(from: lyrics?.plain)
            if !credits.isEmpty {
                creditsNote = "复用歌词"
            } else {
                // ② 胜出源自己的歌词（网易云/酷狗/QQ/酷我都有 `.lyrics` 能力）。
                var text: String?
                if let src = SourceRegistry.shared.source(id: best.sourceID),
                   src.capabilities.contains(.lyrics) {
                    text = (try? await src.fetchLyrics(best))??.plain
                    credits = LyricsService.credits(from: text)
                    if !credits.isEmpty { creditsNote = SourceOutcome.shortName(best.sourceID) }
                }
                // ③ 胜出源没有歌词能力（iTunes / MusicBrainz），或它的词里没有署名行。
                if credits.isEmpty {
                    let looked = await LyricsService.lookupCredits(
                        title: best.title, artist: best.artist,
                        album: best.album, duration: best.durationSeconds,
                        softDeadline: options.creditsSoftDeadline)
                    credits = looked.credits
                    creditsNote = looked.note
                }
            }
            creditsLatency = Date().timeIntervalSince(t0)
            if !credits.isEmpty {
                if best.composer == nil { best.composer = credits.composer }
                if best.lyricist == nil { best.lyricist = credits.lyricist }
            } else if creditsNote == nil {
                creditsNote = "未找到署名"
            }
        }

        // ★ 归一入口（同 `gather` 那一处，用的是同一个 `converted(to:)`）。
        //
        // 这里非补一遍不可：`fetchDetail` 是**第二发网络请求**，它返回的字段会整条盖掉
        // 入池时已经转好的那份（iTunes 的 lookup 就是这么工作的），
        // 署名（作曲/作词）与歌词更是这一步才第一次拿到，`gather` 根本没见过它们。
        return Enriched(candidate: best.converted(to: options.chineseVariant),
                        artwork: artwork,
                        lyrics: lyrics?.converted(to: options.chineseVariant),
                        creditsLatency: creditsLatency,
                        creditsNote: creditsNote,
                        artworkLatency: artworkLatency,
                        lyricsLatency: lyricsLatency,
                        translationLatency: translationLatency,
                        translationRounds: translationRounds)
    }

    // MARK: 批量

    public static func matchAll(_ files: [AudioFile],
                                options: AutoMatchOptions = .recommended,
                                progress: (@Sendable (BatchProgress) -> Void)? = nil)
        async -> (results: [AutoMatchResult], summary: BatchSummary) {

        guard !files.isEmpty else {
            return ([], BatchSummary(succeeded: 0, failed: 0, ignored: 0, total: 0, failures: []))
        }

        let concurrency = max(1, min(options.concurrency, 8))
        var results = [AutoMatchResult?](repeating: nil, count: files.count)
        var completed = 0
        // 进度浮层的「平均 x.x 秒/首 · 预计剩余」全靠它：`BatchProgress` 只在
        // 拿得到起始时刻时才算得出 elapsed / ETA，原先这里一直没传，那两个数字恒为空。
        let batchStartedAt = Date()

        // 本轮的熔断账从零起算：`trippedThisRound` 决定收尾时要不要补查。
        let sourceIDs = resolveSources(options).map(\.id)
        await SourceCircuitBreaker.shared.beginRound(sourceIDs)

        await withTaskGroup(of: (Int, AutoMatchResult).self) { group in
            var next = 0
            func submit() {
                guard next < files.count else { return }
                let idx = next; next += 1
                let file = files[idx]
                group.addTask { (idx, await match(file, options: options)) }
            }
            for _ in 0..<min(concurrency, files.count) { submit() }

            for await (idx, r) in group {
                results[idx] = r
                completed += 1
                progress?(BatchProgress(completed: completed,
                                        total: files.count,
                                        currentPath: r.url.path,
                                        startedAt: batchStartedAt))
                submit()
            }
        }

        var final = results.compactMap { $0 }

        // ★ 熔断补查（AU 轮新增）
        //
        // 熔断让批量不必干等，代价是被暂停的那些文件**根本没问过这个源**。
        // 如果就这么收场，用户得自己看懂「12 首因暂停未查询」再手动重跑 —— 那是把
        // 我们省下的那点时间又还回去，还多了一道理解成本。
        // 所以：批量跑完时若该源已经恢复（或马上就恢复），自动对这些文件**只用该源**
        // 再跑一轮，结果并进原结果。只补一轮，不递归 —— 补查再撞熔断就如实留着提示。
        final = await backfillPausedFiles(final, files: files, options: options,
                                          sourceIDs: sourceIDs, progress: progress)

        var succeeded = 0, failed = 0, ignored = 0
        var failures: [(url: URL, error: TagError)] = []
        for r in final {
            switch r.status {
            case .matched: succeeded += 1
            case .ignored, .noQuery: ignored += 1
            case .failed:
                failed += 1
                failures.append((r.url, .writeFailed(r.errors.first?.message ?? "所有数据源均失败")))
            }
        }
        var summary = BatchSummary(succeeded: succeeded, failed: failed,
                                   ignored: ignored, total: final.count,
                                   failures: failures)
        // ★ BH 轮分阶段计时。匹配这几段是**跨并发累加**的（8 条线同时跑，
        // 累加值必然大于墙钟），它们回答的是「占比」；`wall` 才是墙钟。
        // 写入那一段由 `BatchEngine.applyEdits` 自己填，两边合起来才是完整的一张账。
        summary.stages.search = final.reduce(0) { $0 + $1.searchLatency }
        summary.stages.lyrics = final.reduce(0) { $0 + $1.lyricsLatency }
        summary.stages.translation = final.reduce(0) { $0 + $1.translationLatency }
        summary.stages.translationRounds = final.reduce(0) { $0 + $1.translationRounds }
        summary.stages.artwork = final.reduce(0) { $0 + $1.artworkLatency }
        summary.stages.credits = final.reduce(0) { $0 + $1.creditsLatency }
        summary.stages.wall = Date().timeIntervalSince(batchStartedAt)
        summary.elapsed = summary.stages.wall
        return (final, summary)
    }

    // MARK: 熔断补查

    /// 批量收尾时，对「因某个源熔断而没查成」的文件只用该源再跑一轮。
    ///
    /// 三条边界：
    /// 1. **只补已恢复的源**。还在暂停中的等最多 `maxWaitForRecovery` 秒；再不好就留着提示，
    ///    不无限等 —— 用户在等这一批跑完。取 70 秒是为了刚好盖住「首次熔断暂停 60 秒」
    ///    这一档：批量常常十几秒就跑完，等不到 60 秒就等于这条补查永远不会触发。
    ///    翻倍后的 120/240 秒那几档就不等了，让提示行接手。
    /// 2. **只用那一个源**。别的源上一轮已经问过了，重问纯属浪费。
    /// 3. **只补一轮**。补查再撞熔断就如实记在结果条上，不递归。
    static let maxWaitForRecovery: TimeInterval = 70

    static func backfillPausedFiles(_ results: [AutoMatchResult],
                                    files: [AudioFile],
                                    options: AutoMatchOptions,
                                    sourceIDs: [String],
                                    progress: (@Sendable (BatchProgress) -> Void)?)
        async -> [AutoMatchResult] {

        let tripped = await SourceCircuitBreaker.shared.trippedThisRound(sourceIDs)
        guard !tripped.isEmpty else { return results }

        var out = results
        let byURL = Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })

        for sid in tripped {
            let indices = out.indices.filter { i in
                out[i].sourceOutcomes.contains { $0.sourceID == sid && $0.status.isPaused }
            }
            guard !indices.isEmpty else { continue }

            // 还在暂停中就等一小会儿；等不到就放弃这个源的补查（提示已在结果条上）。
            // 等待期间照常报进度：进度条停在 100% 一动不动会被当成卡死。
            let pending = await SourceCircuitBreaker.shared.stats(sid)
            if let until = pending.pausedUntil, until.timeIntervalSinceNow > 0 {
                progress?(BatchProgress(
                    completed: out.count, total: out.count,
                    note: "等待\(SourceOutcome.displayName(sid))熔断恢复（约 "
                        + "\(Int(until.timeIntervalSinceNow.rounded(.up))) 秒），"
                        + "之后自动补查 \(indices.count) 个文件"))
            }
            await SourceCircuitBreaker.shared.waitUntilRecovered(sid, cap: maxWaitForRecovery)
            let stats = await SourceCircuitBreaker.shared.stats(sid)
            guard !stats.isPaused else { continue }

            var retryOptions = options
            retryOptions.sourceIDs = [sid]
            retryOptions.concurrency = 1        // 刚恢复的源，别再一拥而上

            for i in indices {
                guard let file = byURL[out[i].url] else { continue }
                let retry = await match(file, options: retryOptions)
                out[i] = mergeBackfill(out[i], retry: retry, sourceID: sid)
                progress?(BatchProgress(completed: out.count, total: out.count,
                                        currentPath: out[i].url.path,
                                        note: "补查 \(SourceOutcome.displayName(sid))…"))
            }
        }
        return out
    }

    /// 把补查结果并进原结果。
    ///
    /// 合并口径只有一条：**分数说了算**。补查的候选与原结果走的是同一套
    /// `MatchScorer` 打分，因此直接比 `matchScore` 就是公平的；补查赢了才换掉
    /// `best/edit/artwork/lyrics`，输了也要把候选并进「换候选 ▾」的列表里
    /// —— 用户可能正想要那一条。
    static func mergeBackfill(_ original: AutoMatchResult,
                              retry: AutoMatchResult,
                              sourceID: String) -> AutoMatchResult {
        var r = original

        // 结果条：把 `.paused` 那一条换成补查的真实结果。
        if let fresh = retry.sourceOutcomes.first(where: { $0.sourceID == sourceID }) {
            var patched = fresh
            patched.detail = (fresh.detail.map { $0 + "（批量结束后补查）" }) ?? "批量结束后补查"
            if let idx = r.sourceOutcomes.firstIndex(where: { $0.sourceID == sourceID }) {
                r.sourceOutcomes[idx] = patched
            } else {
                r.sourceOutcomes.append(patched)
            }
            r.sourceOutcomes = r.sourceOutcomes.sortedByPriority()
            if patched.status.isFailure {
                r.errors.append((sourceID, patched.detail ?? patched.chipLabel))
            }
        }
        r.candidateCount += retry.candidateCount

        // 候选并表：按分降序、跨源去重，仍然只留 top N。
        let merged = dedupe((r.candidates + retry.candidates)
            .sorted { $0.matchScore > $1.matchScore })
        r.candidates = Array(merged.prefix(maxKeptCandidates))

        let oldScore = original.best?.matchScore ?? -1
        let newScore = retry.best?.matchScore ?? -1
        if retry.status == .matched, newScore > oldScore {
            r.best = retry.best
            r.edit = retry.edit
            r.artwork = retry.artwork ?? original.artwork
            r.lyrics = retry.lyrics ?? original.lyrics
            r.status = .matched
            if let b = r.best, !r.candidates.isEmpty { r.candidates[0] = b }
        } else if original.status != .matched, retry.status == .matched {
            // 原来是 ignored/failed（分数不够或全挂），补查给出了达标的一条。
            r.best = retry.best
            r.edit = retry.edit
            r.artwork = retry.artwork
            r.lyrics = retry.lyrics
            r.status = .matched
        } else if original.status == .failed, retry.status != .failed {
            r.status = retry.status
            if r.best == nil { r.best = retry.best }
        }
        return r
    }

    // MARK: - 内部

    /// 从已有标签构造查询。
    /// **标题优先；没有标题才回落文件名，且文件名只作自由词**——
    /// 文件名含噪声（音轨号、艺术家、格式后缀），当精确曲名匹配会命中 0 条。
    /// 原版界面也区分「标题或文件名 / 文件名」两种搜索条件。
    public static func makeQuery(from file: AudioFile) -> TrackQuery {
        var q = TrackQuery()
        let t = file.tags.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t, !t.isEmpty { q.title = t }
        q.artist = file.tags.artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        q.album = file.tags.album?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if q.title == nil {
            q.filename = file.url.deletingPathExtension().lastPathComponent
        }
        q.duration = file.technical.duration
        return q
    }

    // MARK: 文件名拆解

    /// 从文件名拆出「两段」，对应原版 FormFilenameRel「从文件名中匹配信息更改标签」。
    ///
    /// 为什么必须做：整串文件名直接当曲名去比对，会让标题里literally嵌了
    /// 「歌名-歌手名」的合辑翻唱拿到虚高的相似度。实测 `稻香 - 周杰伦.flac`
    /// 就被一首标题叫《稻香-周杰伦》、艺术家为「阿郎恋曲」的合辑曲以 0.885 分压过原版。
    ///
    /// 处理：剥掉前导音轨号，按常见分隔符切成两段。哪段是标题、哪段是艺术家无法
    /// 单凭字面判断（"Title - Artist" 与 "Artist - Title" 都常见），因此两种解释
    /// 都返回，由调用方各打一次分、取更优的那种。
    public static func splitFilename(_ name: String) -> (a: String, b: String)? {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 剥前导音轨号：「01. 」「01 - 」「01_」「1-」
        if let r = s.range(of: "^\\s*\\d{1,3}\\s*[.\\-_)]\\s*", options: .regularExpression) {
            s = String(s[r.upperBound...])
        }

        // 常见分隔符，按优先级。带空格的更可靠（裸连字符常出现在歌名内部）。
        for sep in [" - ", " – ", " — ", " _ ", "-", "_"] {
            guard let r = s.range(of: sep) else { continue }
            let a = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            // 两侧都得有实质内容，且不能有一侧长得离谱（多半是切错了）
            guard a.count >= 1, b.count >= 1, a.count <= 120, b.count <= 120 else { continue }
            return (a, b)
        }
        return nil
    }

    /// 生成该文件的全部候选查询解释。
    /// 有真标题时只有一种；只有文件名时返回「A是标题」与「B是标题」两种。
    public static func queryInterpretations(from file: AudioFile) -> [TrackQuery] {
        let base = makeQuery(from: file)
        guard base.title == nil, let fname = base.filename,
              let parts = splitFilename(fname) else {
            return [base]
        }
        var first = base
        first.title = parts.a
        first.artist = base.artist ?? parts.b
        first.filename = fname

        var second = base
        second.title = parts.b
        second.artist = base.artist ?? parts.a
        second.filename = fname

        return [first, second]
    }

    static func resolveSources(_ options: AutoMatchOptions) -> [any MetadataSource] {
        let registry = SourceRegistry.shared
        if options.sourceIDs.isEmpty {
            return registry.allSources.filter { $0.capabilities.contains(.searchTracks) }
        }
        return options.sourceIDs.compactMap { registry.source(id: $0) }
            .filter { $0.capabilities.contains(.searchTracks) }
    }

    /// 跨源去重：同一首歌可能被多个源返回。
    /// 判重键 = 归一化标题 + 归一化艺术家 + 时长桶（5 秒一档，容忍各源时长小差异）。
    /// 已按分数降序传入，保留先出现的（即分数最高的）。
    static func dedupe(_ ranked: [TrackCandidate]) -> [TrackCandidate] {
        var seen = Set<String>()
        var out: [TrackCandidate] = []
        for c in ranked {
            let t = MatchScorer.normalize(c.title ?? "")
            let a = MatchScorer.normalize(c.artist ?? "")
            let bucket = c.durationSeconds > 0 ? Int(c.durationSeconds / 5) : -1
            let key = "\(t)|\(a)|\(bucket)"
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

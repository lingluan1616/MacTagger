//
//  AlbumMatchService.swift
//  MacTagger — 按文件夹（专辑模式）自动匹配
//
//  逐首模式解决不了的那个问题：
//  用户的歌只有文件名、没有任何标签。逐首拿「稻香」去搜，原版、Live 版、Remix、
//  翻唱、几十张精选合辑同时命中，而**单曲这一个信号里根本不含区分它们的信息**，
//  于是整柜歌被写成 Live 版和翻唱——这正是他在 Windows 上被坑的原因。
//
//  专辑模式换一个信息源：`周杰伦/魔杰座/01 - 稻香.flac` 里的**文件夹**已经把答案写好了。
//  流程因此整个反过来：
//      文件夹 → 锁定一张专辑 → 把组内文件对到这张专辑的曲目表 → 逐首产出标签
//  「这张专辑对不对」由整组共同证据判定（专辑名、艺术家、**曲目数**、时长序列整体对齐度），
//  比任何单曲的证据都强得多；一旦专辑选对，Live 版和翻唱在曲目表里根本不存在，
//  从源头上就写不进去。
//
//  三条与逐首模式一致的数据安全底线：
//  1. 专辑分不够 → 整组判「忽略」，一个字都不写。
//  2. 对不上曲目表的文件 → 单独判「忽略」，理由写清楚，绝不硬塞一首。
//  3. 字段白名单与「绝不用空值覆盖」由 `TrackCandidate.asTagEdit` 保证，与逐首模式共用。
//

import Foundation

// MARK: - 分组

/// 同一目录下的一批文件 + 从路径推断出的上下文。
public struct FolderGroup: Sendable, Identifiable {
    public var id: URL { directory }
    public var directory: URL
    public var context: FolderContext
    public var files: [AudioFile]

    public init(directory: URL, context: FolderContext, files: [AudioFile]) {
        self.directory = directory; self.context = context; self.files = files
    }

    public var displayName: String { directory.lastPathComponent }
}

// MARK: - 选项

public struct AlbumMatchOptions: Sendable {

    /// **修错库的钥匙**：为 true 时查询只用 `FolderContext`（文件名 + 文件夹），
    /// 完全不看文件现有标签。
    ///
    /// 为什么必须有这个开关：用户的库已经被别的工具写错了——标题写成了 Live 版的名字，
    /// 专辑写成了某张精选合辑。这些错标签一旦参与查询，就会**把匹配再次拉回同一个错答案**，
    /// 越修越错。文件名和文件夹是唯一没被污染过的信息，所以要能一键只信它们。
    public var ignoreExistingTags: Bool
    /// 参与匹配的源。空数组 = 注册表里全部可搜索的源。
    public var sourceIDs: [String]
    /// 专辑候选采纳阈值。最高分低于它就整组判「忽略」，一个字都不写。
    public var acceptThreshold: Double
    /// 单个文件对到某首曲目的最低分。够不着就判「未在专辑曲目表中找到」。
    public var alignAcceptThreshold: Double
    /// 允许写入的字段白名单。nil = 全部。
    public var fields: Set<TagEdit.Field>?
    /// 专辑封面只下载一次，整组共用。
    public var fetchArtwork: Bool
    public var artworkSize: Int
    /// 每个源每次搜索要多少条候选。
    public var limitPerSource: Int
    /// 每组取几首「代表曲」去逐首搜索，用它们的归属专辑投票。
    /// 3 首足够形成共识，再多只是多花请求。
    public var probeTrackCount: Int
    /// 每个源最多深挖几张专辑（`fetchAlbum` 是二段式请求，要控量）。
    public var albumsPerSource: Int
    /// 在线结果的字形归一策略。默认取进程级设置（App 由「在线结果统一转为」那一项推入）。
    public var chineseVariant: ChineseVariantPolicy

    // MARK: 软截止（AX 轮，与逐首模式同一套道理）
    //
    // 专辑模式一个源要打好几枪（专辑名搜索 + N 首代表曲），原先这些枪是**串行**的，
    // 而整组又要等所有源都打完 —— 于是一组的耗时 = Σ(最慢源的每一枪)。
    // 两处一起改：组内那几枪并发发（各源的限速器照旧串行放行，所以不会加压），
    // 外层给每个源一个软截止，到点就不等它。
    //
    // 秒数比逐首模式大：一个源本来就要打 2 枪以上，4 s 会把**所有**源都判超时。

    /// 每个源的软截止（秒）。`<= 0` 关闭。
    public var sourceSoftDeadline: TimeInterval
    /// 「慢但权威」的源（MusicBrainz）单独放宽到这个秒数。
    public var slowSourceSoftDeadline: TimeInterval

    /// 这个源该等多久。`<= 0` 表示不设软截止。
    public func softDeadline(for sourceID: String) -> TimeInterval {
        guard sourceSoftDeadline > 0 else { return 0 }
        return AutoMatchOptions.slowSourceIDs.contains(sourceID)
            ? max(sourceSoftDeadline, slowSourceSoftDeadline)
            : sourceSoftDeadline
    }

    public init(ignoreExistingTags: Bool = false,
                sourceIDs: [String] = [],
                acceptThreshold: Double = 0.6,
                alignAcceptThreshold: Double = 0.5,
                fields: Set<TagEdit.Field>? = nil,
                fetchArtwork: Bool = false,
                artworkSize: Int = 1200,
                limitPerSource: Int = 8,
                probeTrackCount: Int = 3,
                albumsPerSource: Int = 4,
                chineseVariant: ChineseVariantPolicy = ChineseVariant.onlineDefault,
                sourceSoftDeadline: TimeInterval = 8,
                slowSourceSoftDeadline: TimeInterval = 14) {
        self.chineseVariant = chineseVariant
        self.sourceSoftDeadline = sourceSoftDeadline
        self.slowSourceSoftDeadline = slowSourceSoftDeadline
        self.ignoreExistingTags = ignoreExistingTags
        self.sourceIDs = sourceIDs
        self.acceptThreshold = acceptThreshold
        self.alignAcceptThreshold = alignAcceptThreshold
        self.fields = fields
        self.fetchArtwork = fetchArtwork
        self.artworkSize = artworkSize
        self.limitPerSource = limitPerSource
        self.probeTrackCount = probeTrackCount
        self.albumsPerSource = albumsPerSource
    }

    public static let recommended = AlbumMatchOptions(
        sourceIDs: ["itunes", "netease", "qq", "musicbrainz"]
    )

    /// **AX 轮之前的行为**，只供压测对照组用：等所有源、组内那几枪串行。
    public static var legacy: AlbumMatchOptions {
        var o = AlbumMatchOptions(sourceIDs: ["itunes", "netease", "qq", "musicbrainz"])
        o.sourceSoftDeadline = 0
        o.slowSourceSoftDeadline = 0
        o.serialProbes = true
        return o
    }

    /// 组内那几枪串行发（AX 轮之前的行为）。只有压测对照组会把它打开。
    public var serialProbes: Bool = false

    // MARK: 歌词（BJ 轮：专辑模式接上逐首模式那套取词）
    //
    // 专辑模式在此之前**整条不取歌词**：候选来自专辑曲目表，压根不走 `AutoMatchService.enrich`，
    // 而取词逻辑当时长在 `enrich` 肚子里。用户因此看到「按文件夹匹配歌词不会成功，
    // 但逐首可以有（还含翻译）」。现在两边共用 `AutoMatchService.fetchLyricsForCandidate`。

    /// 给每一首已对齐的曲目补歌词。界面由「下载歌词」+「歌词」字段两个开关共同决定。
    public var fetchLyrics: Bool = false
    /// 取词的**曲目级**并发上限（各源自身的限速器照旧串行放行，这里只控并行度）。
    public var concurrency: Int = 4
    /// 译文补查最多问几个源。口径同 `AutoMatchOptions.translationSourceLimit`。
    public var translationSourceLimit: Int = 2

    /// 交给 `AutoMatchService.fetchLyricsForCandidate` 的那份选项。
    /// 只带取词要用到的几项：**不下封面、不补署名**（署名在专辑曲目表里已经有了，
    /// 再补一遍等于每首白发一发请求）。
    var lyricsFetchOptions: AutoMatchOptions {
        var a = AutoMatchOptions(sourceIDs: sourceIDs,
                                 acceptThreshold: acceptThreshold,
                                 fields: fields,
                                 fetchArtwork: false,
                                 artworkSize: artworkSize,
                                 fetchLyrics: true,
                                 limitPerSource: limitPerSource,
                                 concurrency: max(1, concurrency),
                                 chineseVariant: chineseVariant,
                                 sourceSoftDeadline: sourceSoftDeadline,
                                 slowSourceSoftDeadline: slowSourceSoftDeadline,
                                 fetchCredits: false)
        a.translationSourceLimit = translationSourceLimit
        return a
    }
}

// MARK: - 打分明细

public struct ScoreItem: Sendable, Equatable {
    public var name: String
    public var weight: Double
    public var value: Double
    public init(_ name: String, _ weight: Double, _ value: Double) {
        self.name = name; self.weight = weight; self.value = value
    }
    public var display: String { "\(name) \(String(format: "%.2f", value))×\(String(format: "%.2f", weight))" }
}

// MARK: - 专辑候选

public struct AlbumCandidate: Sendable, Identifiable {
    public var id: String { detail.id }
    public var detail: AlbumDetail
    public var score: Double
    /// 有几首「代表曲」把这张专辑认作自己的归属。共识越强越可信。
    public var consensusHits: Int
    public var breakdown: [ScoreItem]
    /// 按本组文件试对齐的结果（打分时顺带算出来，选中后直接复用）。
    public var alignedCount: Int
    public var fileCount: Int
    /// 对齐上的那些文件的平均时长差（秒）。本地时长不可信时为 nil。
    public var meanDurationDelta: Double?
    /// 减分/加分的口语解释，直接显示给用户看。
    public var notes: [String]

    public var alignmentRate: Double {
        fileCount > 0 ? Double(alignedCount) / Double(fileCount) : 0
    }

    public var summary: String {
        detail.summary + " · 对齐 \(alignedCount)/\(fileCount) · 分 " + String(format: "%.3f", score)
    }

    /// 排序谓词。**必须有完整的平局判据**：同一张专辑常常被三四个源同时给出，
    /// 加分叠满后一起顶到 1.000，而 Swift 的 `sort` 不保证稳定 ——
    /// 只按分排会让「选哪张」在两次运行之间随机跳动，其中一张可能少对齐一个文件。
    /// 依次比：分（量化）→ 对齐数 → 代表曲共识 → 源优先级 → 名称 → 曲目表完整度 → id（最终定死）。
    ///
    /// BP-E（BJ 技术债）：BJ 实跑 `米津玄師/Lemon` 第二次运行换了胜者、少对齐一首。两处补丁：
    /// ① **分数先量化**（`MatchScorer.scoreKey`，1e-6）。同一张专辑经不同源、不同加分顺序算出的分
    ///    可能差 1e-16（浮点加法不满足结合律），直接 `!=` 会把「同分」当成「不同分」，
    ///    后面的平局判据一条都用不上 —— 与 AZ 轮 `MatchScorer.rank` 同病同治；
    /// ② 同分同对齐同共识时按**源优先级**（`SourceRegistry.recommendedPriority`，与逐首模式同一张表），
    ///    再按专辑名，最后才是曲目数与 id。全部可复算，与各源返回的先后无关。
    public static func isBetter(_ a: AlbumCandidate, _ b: AlbumCandidate) -> Bool {
        let (ka, kb) = (MatchScorer.scoreKey(a.score), MatchScorer.scoreKey(b.score))
        if ka != kb { return ka > kb }
        if a.alignedCount != b.alignedCount { return a.alignedCount > b.alignedCount }
        if a.consensusHits != b.consensusHits { return a.consensusHits > b.consensusHits }
        let order = SourceRegistry.recommendedPriority
        func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? order.count }
        let (ra, rb) = (rank(a.detail.sourceID), rank(b.detail.sourceID))
        if ra != rb { return ra < rb }
        let (na, nb) = (a.detail.displayTitle, b.detail.displayTitle)
        if na != nb { return na < nb }
        if a.detail.tracks.count != b.detail.tracks.count {
            return a.detail.tracks.count > b.detail.tracks.count
        }
        return a.id < b.id
    }
}

// MARK: - 曲目对齐

public struct TrackAlignment: Sendable {
    public var fileURL: URL
    /// nil = 没对上
    public var track: AlbumTrack?
    public var score: Double
    /// 怎么对上的 / 为什么没对上。
    public var reason: String
}

public struct AlignmentOutcome: Sendable {
    public var pairs: [TrackAlignment]
    public var alignedCount: Int
    /// 对齐上的那些配对的平均分，衡量「这张专辑整体像不像」。
    public var meanPairScore: Double
    public var meanDurationDelta: Double?

    public var fileCount: Int { pairs.count }
    public var rate: Double { fileCount > 0 ? Double(alignedCount) / Double(fileCount) : 0 }
}

// MARK: - 结果

public struct AlbumMatchResult: Sendable, Identifiable {
    public var id: URL { folder }
    public var folder: URL
    public var context: FolderContext
    /// 按分降序的全部专辑候选，界面上「换一张专辑」用它。
    public var albumCandidates: [AlbumCandidate]
    /// 达到阈值的那一张。nil = 整组忽略。
    public var chosen: AlbumCandidate?
    public var alignment: AlignmentOutcome?
    /// 逐文件结果，口径与逐首模式完全一致，写入路径因此可以整个复用。
    public var perFile: [AutoMatchResult]
    public var errors: [(sourceID: String, message: String)]
    /// 逐源结果条：这一组在收集专辑候选时，每个源是「有 n 条 / 0 条 / 挂了」。
    /// 组头的 chips 直接读它 —— 用户因此看得出「网易云没这张专辑」与「网易云挂了」的区别。
    public var sourceOutcomes: [SourceOutcome] = []
    /// 整组被忽略时的原因。
    public var ignoredReason: String?

    public var fileCount: Int { perFile.count }
    public var alignedCount: Int { perFile.filter { $0.status == .matched }.count }
    public var alignmentRate: Double {
        fileCount > 0 ? Double(alignedCount) / Double(fileCount) : 0
    }
}

// MARK: - 服务

public enum AlbumMatchService {

    // MARK: 分组

    /// 按所在目录分组。同目录一组，组内按文件名排序（音轨号顺序）。
    public static func groupByFolder(_ files: [AudioFile]) -> [FolderGroup] {
        var buckets: [URL: [AudioFile]] = [:]
        var order: [URL] = []
        for f in files {
            let dir = f.url.deletingLastPathComponent()
            if buckets[dir] == nil { order.append(dir) }
            buckets[dir, default: []].append(f)
        }
        return order.map { dir in
            let list = (buckets[dir] ?? []).sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            let ctx = FolderContext.infer(directory: dir, fileURLs: list.map(\.url))
            return FolderGroup(directory: dir, context: ctx, files: list)
        }
    }

    /// 这批文件是不是「像专辑目录」——决定界面默认选哪种模式。
    /// 判据：至少有一个目录里放了 ≥2 个文件，且该目录推断得出专辑名。
    public static func looksLikeAlbumLayout(_ files: [AudioFile]) -> Bool {
        let groups = groupByFolder(files)
        guard !groups.isEmpty else { return false }
        return groups.contains { $0.files.count >= 2 && $0.context.isUsable }
    }

    // MARK: 时长可信度

    /// 本地时长可不可信。样本文件、被截断的文件、TagLib 解析错的畸形头都会给出几秒的时长，
    /// 拿这种时长去和专辑曲目表比对，会让**每一张**候选专辑一起被惩罚——
    /// 惩罚没有区分度，却足以把整池压到阈值以下（`MatchScorer` 里踩过同一个坑）。
    /// 因此过半文件的时长不达标就整组当「时长未知」，把这一维摊掉。
    public static func durationsAreCredible(_ files: [AudioFile]) -> Bool {
        guard !files.isEmpty else { return false }
        let ok = files.filter { $0.technical.duration >= MatchScorer.minimumPlausibleQueryDuration }
        return Double(ok.count) / Double(files.count) >= 0.5
    }

    // MARK: - 单组匹配

    public static func match(_ group: FolderGroup,
                             options: AlbumMatchOptions = .recommended) async -> AlbumMatchResult {

        let ctx = effectiveContext(group, options: options)
        var result = AlbumMatchResult(folder: group.directory,
                                      context: ctx,
                                      albumCandidates: [],
                                      chosen: nil,
                                      alignment: nil,
                                      perFile: [],
                                      errors: [],
                                      ignoredReason: nil)

        guard !group.files.isEmpty else {
            result.ignoredReason = "目录里没有可处理的音频文件"
            return result
        }
        guard ctx.isUsable || ctx.artist != nil else {
            result.ignoredReason = "从文件夹名推断不出专辑名，无法用专辑模式"
            result.perFile = group.files.map {
                ignoredResult($0.url, reason: "所在文件夹推断不出专辑名")
            }
            return result
        }

        // ① 收集专辑候选（多源 + 专辑名搜索 + 代表曲投票）
        let harvest = await harvestAlbums(group, context: ctx, options: options)
        result.errors = harvest.errors
        result.sourceOutcomes = harvest.outcomes

        guard !harvest.albums.isEmpty else {
            result.ignoredReason = harvest.errors.isEmpty
                ? "所有来源都没搜到与《\(ctx.album ?? "?")》对应的专辑"
                : "所有来源都失败了"
            result.perFile = group.files.map {
                ignoredResult($0.url, reason: result.ignoredReason ?? "无专辑候选")
            }
            return result
        }

        // ② 逐张打分（顺带算出对齐结果，选中后直接复用）
        let credible = durationsAreCredible(group.files)
        var scored: [AlbumCandidate] = harvest.albums.map { entry in
            scoreAlbum(entry.detail,
                       consensusHits: entry.hits,
                       group: group,
                       context: ctx,
                       durationsCredible: credible,
                       options: options)
        }
        scored.sort(by: AlbumCandidate.isBetter)
        result.albumCandidates = scored

        guard let top = scored.first, top.score >= options.acceptThreshold else {
            let best = scored.first
            result.ignoredReason = best.map {
                "最佳专辑候选《\($0.detail.displayTitle)》只有 "
                + String(format: "%.3f", $0.score)
                + " 分，低于采纳阈值 \(String(format: "%.2f", options.acceptThreshold))，整组未写入"
            } ?? "没有可用的专辑候选"
            result.perFile = group.files.map {
                ignoredResult($0.url, reason: result.ignoredReason ?? "专辑分不够")
            }
            return result
        }

        // ③ 用选中的专辑生成逐文件结果
        let applied = await apply(album: top,
                                  group: group,
                                  context: ctx,
                                  durationsCredible: credible,
                                  options: options)
        result.chosen = top
        result.alignment = applied.alignment
        result.perFile = applied.perFile
        return result
    }

    /// 换一张候选专辑后重算。界面上的「换专辑」下拉直接调它。
    public static func apply(album: AlbumCandidate,
                             group: FolderGroup,
                             context: FolderContext,
                             durationsCredible: Bool? = nil,
                             options: AlbumMatchOptions = .recommended)
        async -> (alignment: AlignmentOutcome, perFile: [AutoMatchResult]) {

        let credible = durationsCredible ?? durationsAreCredible(group.files)
        let alignment = align(group: group, context: context, detail: album.detail,
                              durationsCredible: credible, options: options)

        // 封面整组只下一次
        var artwork: Data?
        if options.fetchArtwork, alignment.alignedCount > 0 {
            artwork = await fetchArtwork(for: album.detail, size: options.artworkSize)
        }

        var perFile: [AutoMatchResult] = []
        for pair in alignment.pairs {
            // 对不上的文件同样要给候选 —— **那正是最需要人工挑一首的时候**。
            let alts = alternatives(for: pair.fileURL, chosen: pair.track, detail: album.detail,
                                    group: group, context: context, options: options)
            guard let track = pair.track else {
                var r = ignoredResult(pair.fileURL, reason: pair.reason)
                r.candidates = alts
                r.candidateCount = album.detail.tracks.count
                perFile.append(r)
                continue
            }
            var cand = album.detail.candidate(for: track)
            cand.matchScore = pair.score
            var r = AutoMatchResult(url: pair.fileURL,
                                    status: .matched,
                                    best: cand,
                                    edit: cand.asTagEdit(fields: options.fields),
                                    artwork: artwork,
                                    lyrics: nil,
                                    triedSources: [album.detail.sourceID],
                                    candidateCount: album.detail.tracks.count,
                                    errors: [])
            // 选中的那首恒为首个，其后是同专辑内最像的几首。
            r.candidates = [cand] + alts
            if r.edit?.changes.isEmpty ?? true { r.edit = nil }
            // 默认全勾（= 本次会改动的字段全集）。复核表上的排除是在这之上做减法，
            // 与逐首模式同一套口径。
            r.resetAcceptedFieldsToAll()
            perFile.append(r)
        }

        // ★ BJ 轮：逐首补歌词。走的是**逐首模式那一个函数**
        // （`AutoMatchService.fetchLyricsForCandidate`：胜出源取词 → 值得要翻译就
        // 再补查 ≤ translationSourceLimit 个源 + 软截止），不是复制一份。
        //
        // 放在这里而不是 `match` 里，是因为「换一张专辑」也走 `apply` ——
        // 换完之后曲目全变了，歌词当然要跟着重取，两条路自动一致。
        if options.fetchLyrics {
            await attachLyrics(&perFile, options: options)
        }
        return (alignment, perFile)
    }

    /// 给已对齐的那几行补歌词。并发上限 = `options.concurrency`，各源限速器照旧生效。
    static func attachLyrics(_ perFile: inout [AutoMatchResult],
                             options: AlbumMatchOptions) async {
        let targets = perFile.indices.filter {
            perFile[$0].status == .matched && perFile[$0].best != nil
        }
        guard !targets.isEmpty else { return }

        let lyricsOptions = options.lyricsFetchOptions
        let concurrency = max(1, min(options.concurrency, 8))
        var fetched: [Int: AutoMatchService.FetchedLyrics] = [:]

        await withTaskGroup(of: (Int, AutoMatchService.FetchedLyrics).self) { group in
            var next = 0
            func submit() {
                guard next < targets.count else { return }
                let idx = targets[next]; next += 1
                guard let cand = perFile[idx].best else { return }
                group.addTask {
                    (idx, await AutoMatchService.fetchLyricsForCandidate(cand, options: lyricsOptions))
                }
            }
            for _ in 0..<min(concurrency, targets.count) { submit() }
            for await (idx, r) in group {
                fetched[idx] = r
                submit()
            }
        }

        for (idx, r) in fetched {
            // 归一入口与 `enrichDetailed` 同一处口径：取回来的原始 bundle 到这里才转字形。
            perFile[idx].lyrics = r.bundle?.converted(to: options.chineseVariant)
            perFile[idx].lyricsLatency = r.latency
            perFile[idx].translationLatency = r.translationLatency
            perFile[idx].translationRounds = r.translationRounds
        }
    }

    // MARK: 批量

    public static func matchAll(_ groups: [FolderGroup],
                                options: AlbumMatchOptions = .recommended,
                                progress: (@Sendable (BatchProgress) -> Void)? = nil)
        async -> (results: [AlbumMatchResult], summary: BatchSummary) {

        var results: [AlbumMatchResult] = []
        let totalFiles = groups.reduce(0) { $0 + $1.files.count }
        var done = 0
        let wallStart = Date()

        // 按文件夹**串行**处理：一组就是一趟完整的「搜专辑 → 拉曲目表」，
        // 请求量本来就比逐首模式小一个数量级，串行既够快又不容易触发各源限流。
        for g in groups {
            if Task.isCancelled { break }
            let r = await match(g, options: options)
            results.append(r)
            done += g.files.count
            progress?(BatchProgress(completed: done, total: totalFiles, currentPath: g.directory.path))
        }

        var succeeded = 0, ignored = 0
        var ignoredItems: [(url: URL, reason: String)] = []
        for r in results {
            for f in r.perFile {
                if f.status == .matched { succeeded += 1 }
                else {
                    ignored += 1
                    ignoredItems.append((f.url, f.errors.first?.message ?? "未对齐"))
                }
            }
        }
        var summary = BatchSummary(succeeded: succeeded, failed: 0, ignored: ignored,
                                   total: totalFiles, failures: [],
                                   ignoredItems: ignoredItems,
                                   isCancelled: Task.isCancelled)
        // ★ BJ 轮分阶段计时。取词那一段是**跨并发累加**的（口径同逐首模式的
        // `BatchSummary.stages`），`wall` 才是墙钟 —— 两个数放在一起才看得出并发在不在起作用。
        var stages = StageTimings()
        for r in results {
            for o in r.sourceOutcomes { stages.search += o.latency }
            for f in r.perFile {
                stages.lyrics += f.lyricsLatency
                stages.translation += f.translationLatency
                stages.translationRounds += f.translationRounds
            }
        }
        stages.wall = Date().timeIntervalSince(wallStart)
        summary.stages = stages
        return (results, summary)
    }

    // MARK: - 上下文补全

    /// 文件夹推断不出专辑名时，若允许看现有标签，就用组内**多数派**的专辑/艺术家补上。
    /// `ignoreExistingTags` 为 true 时这一步整个跳过——那正是它存在的意义。
    public static func effectiveContext(_ group: FolderGroup,
                                        options: AlbumMatchOptions) -> FolderContext {
        var ctx = group.context
        guard !options.ignoreExistingTags else { return ctx }
        if ctx.album == nil {
            ctx.album = majority(group.files.map { $0.tags.album })
        }
        if ctx.artist == nil {
            ctx.artist = majority(group.files.map { $0.tags.albumArtist ?? $0.tags.artist })
        }
        if ctx.year == nil {
            ctx.year = majority(group.files.map { $0.tags.year }).flatMap {
                $0.count >= 4 ? String($0.prefix(4)) : nil
            }
        }
        return ctx
    }

    static func majority(_ values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        for v in values {
            guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            counts[v, default: 0] += 1
        }
        return counts.max { a, b in a.value < b.value }?.key
    }

    /// 这个文件拿什么当查询标题。`ignoreExistingTags` 时只认文件名。
    public static func queryTitle(for file: AudioFile,
                                  context: FolderContext,
                                  options: AlbumMatchOptions) -> String? {
        if !options.ignoreExistingTags {
            let t = file.tags.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t, !t.isEmpty { return t }
        }
        return context.context(for: file.url)?.title
    }

    // MARK: - 收集专辑候选

    struct AlbumEntry {
        var detail: AlbumDetail
        var hits: Int          // 有几首代表曲把它认作归属专辑
    }
    struct Harvest {
        var albums: [AlbumEntry] = []
        var errors: [(sourceID: String, message: String)] = []
        /// 逐源结果条。专辑模式一个源要打好几枪（专辑名搜索 + N 首代表曲），
        /// 合并成一条：命中数取「进了候选池的条数」，任一枪失败即整源判失败。
        var outcomes: [SourceOutcome] = []
    }

    /// 三路取候选，合起来去重：
    ///  A. 用「专辑名 + 艺术家」直接搜专辑（iTunes entity=album / MB release / 其余源按曲目搜）
    ///  B. 取组内前 N 首「代表曲」逐首搜，把它们的归属专辑投票投出来 —— **命中率最高的一路**
    ///  C. A/B 得到的每个 albumID 再走 `fetchAlbum` 拉曲目表
    static func harvestAlbums(_ group: FolderGroup,
                              context ctx: FolderContext,
                              options: AlbumMatchOptions) async -> Harvest {

        var harvest = Harvest()
        let sources = resolveSources(options)
        guard !sources.isEmpty else {
            harvest.errors.append(("registry", "没有可用的数据源"))
            return harvest
        }

        // 代表曲：优先挑推断出标题的文件，均匀取样（首、中、尾），避免全挤在开头
        let titled = group.files.filter { queryTitle(for: $0, context: ctx, options: options) != nil }
        let probes = evenSample(titled, count: max(1, options.probeTrackCount))
        let credible = durationsAreCredible(group.files)

        // (sourceID, albumID) → 命中次数
        var hits: [String: Int] = [:]
        var pool: [String: TrackCandidate] = [:]     // key → 一条能代表该专辑的候选（供 fetchAlbum 用）

        func record(_ c: TrackCandidate, weight: Int) {
            guard let aid = c.albumID, !aid.isEmpty else { return }
            let key = c.sourceID + "\u{1}" + aid
            hits[key, default: 0] += weight
            if pool[key] == nil { pool[key] = c }
        }

        var returnedSources = Set<String>()
        let harvestStarted = Date()

        await withTaskGroup(of: SourceHarvest.self) { gp in
            for src in sources {
                let deadline = options.softDeadline(for: src.id)
                gp.addTask {
                    await harvestOneSource(src, context: ctx, probes: probes,
                                           credible: credible, options: options,
                                           deadline: deadline)
                }
            }
            for await h in gp {
                returnedSources.insert(h.sourceID)
                if let err = h.errorMessage { harvest.errors.append((h.sourceID, err)) }
                harvest.outcomes.append(h.outcome)
                for c in h.byAlbum { record(c, weight: 0) }    // 专辑名搜索只负责把 albumID 放进池子
                for c in h.byTrack { record(c, weight: 1) }    // 代表曲才有投票权
            }
        }
        // 一个源都没回来的情况下 `harvestOneSource` 自己已经交了 `.skipped`；
        // 这里兜的是外层被取消（用户点了取消）时的残缺账。
        let harvestElapsed = Date().timeIntervalSince(harvestStarted)
        for src in sources where !returnedSources.contains(src.id) {
            harvest.outcomes.append(
                SourceOutcome(sourceID: src.id,
                              status: .skipped(reason: "本组未等到该源"),
                              latency: harvestElapsed))
        }
        harvest.outcomes = harvest.outcomes.sortedByPriority()

        guard !pool.isEmpty else { return harvest }

        // C. 每个源里挑票数最高的几个 albumID 深挖曲目表
        var perSource: [String: [(key: String, hit: Int)]] = [:]
        for (key, hit) in hits {
            let sid = String(key.split(separator: "\u{1}").first ?? "")
            perSource[sid, default: []].append((key, hit))
        }
        var picks: [(candidate: TrackCandidate, hits: Int)] = []
        for (_, list) in perSource {
            let ordered = list.sorted { $0.hit > $1.hit }.prefix(options.albumsPerSource)
            for e in ordered {
                guard let c = pool[e.key] else { continue }
                picks.append((c, e.hit))
            }
        }

        var details: [AlbumEntry] = []
        await withTaskGroup(of: (AlbumDetail?, Int, String, String?).self) { gp in
            for p in picks {
                gp.addTask {
                    guard let src = SourceRegistry.shared.source(id: p.candidate.sourceID) else {
                        return (nil, p.hits, p.candidate.sourceID, nil)
                    }
                    do { return (try await src.fetchAlbum(p.candidate), p.hits, src.id, nil) }
                    catch { return (nil, p.hits, src.id, error.localizedDescription) }
                }
            }
            for await (detail, h, sid, err) in gp {
                if let err { harvest.errors.append((sid, err)) }
                guard let detail else { continue }
                // ★ 专辑模式的**唯一**简繁归一入口。整张 `AlbumDetail`（专辑名 + 艺术家 +
                // 整张曲目表）在这里一次转完，位置同样在打分之前 ——
                //
                // 打分要拿曲目表去和本地文件名/标题比对（`align`），曲目表是繁体而查询是简体，
                // 每一首的字面相似度都会掉一截，对齐率跟着掉，整组可能因此被判「忽略」。
                // 而选中之后的对齐结果、逐文件候选（`AlbumDetail.candidate(for:)`）
                // 全部由这份 detail 派生，所以转在这一处就等于把对齐结果一起转了。
                details.append(AlbumEntry(detail: detail.converted(to: options.chineseVariant),
                                          hits: h))
            }
        }
        harvest.albums = details
        return harvest
    }

    /// 一个源在一组里的全部收成。
    struct SourceHarvest: Sendable {
        var sourceID: String
        var byAlbum: [TrackCandidate] = []
        var byTrack: [TrackCandidate] = []
        var errorMessage: String?
        var outcome: SourceOutcome
    }

    /// 对一个源打完「专辑名搜索 + N 首代表曲」这几枪，带软截止。
    ///
    /// 两处提速（AX 轮）：
    /// · **几枪并发发**。原先是 `for f in probes { await … }` 串行，一个 6.6 s 的源
    ///   打三枪就是 20 s。改并发之后深度只剩「一枪」——各源自己的限速器照旧串行放行，
    ///   所以对方看到的发包节奏一点没变，省下的纯粹是我们这边的干等。
    /// · **到点不等**。整组因此不再被最慢的那个源锁住。
    static func harvestOneSource(_ src: any MetadataSource,
                                 context ctx: FolderContext,
                                 probes: [AudioFile],
                                 credible: Bool,
                                 options: AlbumMatchOptions,
                                 deadline: TimeInterval) async -> SourceHarvest {

        let started = Date()

        /// 一首代表曲的一枪。
        func probeOne(_ f: AudioFile) async -> (hits: [TrackCandidate], error: Error?) {
            guard let title = queryTitle(for: f, context: ctx, options: options) else {
                return ([], nil)
            }
            var q = TrackQuery()
            q.title = title
            q.artist = ctx.artist
            q.album = ctx.album
            q.duration = credible ? f.technical.duration : 0
            do {
                let found = try await src.searchTracks(q, limit: options.limitPerSource)
                // 只让「确实像这首歌」的候选参与投票，否则搜索结果里
                // 同歌手的其它歌会把票投给一堆无关专辑
                let filtered = found.filter {
                    guard let ct = $0.title else { return false }
                    return MatchScorer.titleSimilarity(ct, title) >= 0.72
                }
                var out = filtered
                // 有的源搜索结果里**根本不带 albumID**（QQ 的 smartbox 联想接口只给
                // mid/歌名/歌手），不补一次详情就永远进不了专辑候选池。
                // 每首代表曲只补最像的那一条，额外请求上限 = 代表曲数。
                if filtered.allSatisfy({ ($0.albumID ?? "").isEmpty }),
                   let best = filtered.first,
                   let detailed = try? await src.fetchDetail(best),
                   !(detailed.albumID ?? "").isEmpty {
                    out.append(detailed)
                }
                return (out, nil)
            } catch {
                return ([], error)
            }
        }

        func work() async -> SourceHarvest {
            var byAlbum: [TrackCandidate] = []
            var byTrack: [TrackCandidate] = []
            var err: String?
            var firstError: Error?

            // A. 专辑名搜索
            do {
                byAlbum = try await searchAlbumLevel(src, context: ctx, options: options)
            } catch { err = error.localizedDescription; firstError = error }

            // B. 代表曲搜索（并发；`serialProbes` 是压测对照组用的旧行为开关）
            if options.serialProbes {
                for f in probes {
                    let r = await probeOne(f)
                    byTrack.append(contentsOf: r.hits)
                    if err == nil, let e = r.error { err = e.localizedDescription; firstError = e }
                }
            } else {
                var errors: [Error] = []
                await withTaskGroup(of: ([TrackCandidate], Error?).self) { pg in
                    for f in probes { pg.addTask { await probeOne(f) } }
                    for await r in pg {
                        byTrack.append(contentsOf: r.0)
                        if let e = r.1 { errors.append(e) }
                    }
                }
                if err == nil, let e = errors.first { err = e.localizedDescription; firstError = e }
            }

            // 逐源结果条：一枪都没成 → 失败；成了但一条没有 → 0 条。
            let elapsed = Date().timeIntervalSince(started)
            let got = byAlbum.count + byTrack.count
            var outcome: SourceOutcome
            if got == 0, let e = firstError {
                outcome = SourceOutcome.failure(src.id, e, latency: elapsed)
                if outcome.status.isPaused,
                   let why = await SourceCircuitBreaker.shared.stats(src.id).pauseReason {
                    outcome.detail = why
                }
            } else {
                outcome = SourceOutcome(sourceID: src.id,
                                        status: got > 0 ? .hits(got) : .empty,
                                        latency: elapsed,
                                        detail: err)
            }
            return SourceHarvest(sourceID: src.id, byAlbum: byAlbum, byTrack: byTrack,
                                 errorMessage: err, outcome: outcome)
        }

        guard deadline > 0 else { return await work() }

        return await withTaskGroup(of: SourceHarvest?.self) { race in
            race.addTask { await work() }
            race.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await race.next() ?? nil
            race.cancelAll()
            if let first { return first }
            return SourceHarvest(
                sourceID: src.id,
                outcome: SourceOutcome(
                    sourceID: src.id,
                    status: .skipped(reason: String(format: "超过软截止 %.0f s", deadline)),
                    latency: Date().timeIntervalSince(started)))
        }
    }

    /// 专辑名搜索。iTunes 与 MusicBrainz 有专门的专辑端点，比拿专辑名去搜歌准得多；
    /// 其余源退回曲目搜索，靠候选自带的 albumID 把专辑捞出来。
    static func searchAlbumLevel(_ src: any MetadataSource,
                                 context ctx: FolderContext,
                                 options: AlbumMatchOptions) async throws -> [TrackCandidate] {
        guard let album = ctx.album, !album.isEmpty else { return [] }
        var q = TrackQuery()
        q.album = album
        q.artist = ctx.artist
        q.filename = album      // searchTerm = "魔杰座 周杰伦"

        if let it = src as? ITunesSource {
            return try await it.searchAlbums(q, limit: options.limitPerSource)
        }
        if let mb = src as? MusicBrainzSource {
            return try await mb.searchReleases(q, limit: options.limitPerSource)
        }
        return try await src.searchTracks(q, limit: options.limitPerSource)
    }

    static func resolveSources(_ options: AlbumMatchOptions) -> [any MetadataSource] {
        let registry = SourceRegistry.shared
        if options.sourceIDs.isEmpty {
            return registry.allSources.filter { $0.capabilities.contains(.searchTracks) }
        }
        return options.sourceIDs.compactMap { registry.source(id: $0) }
            .filter { $0.capabilities.contains(.searchTracks) }
    }

    /// 均匀取样：首、中、尾各来一点。全挤在开头时，若前几首恰好是冷门曲会白跑。
    static func evenSample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        guard items.count > count else { return items }
        var out: [T] = []
        for i in 0..<count {
            let idx = Int((Double(i) * Double(items.count - 1) / Double(max(1, count - 1))).rounded())
            out.append(items[min(idx, items.count - 1)])
        }
        return out
    }

    // MARK: - 专辑打分

    /// 各维权重。刻意让「曲目数」和「整体对齐度」加起来压过「专辑名」——
    /// 专辑名相似度会把《魔杰座》和一堆叫《魔杰座》的精选/演唱会版本一视同仁，
    /// 真正能把它们分开的是「这张碟有几首」和「这几首跟我文件夹里的对不对得上」。
    public struct AlbumWeights: Sendable {
        public var albumTitle: Double = 0.28
        public var artist: Double = 0.18
        public var trackCount: Double = 0.22
        public var alignment: Double = 0.18
        public var duration: Double = 0.10
        public var year: Double = 0.08
        public init() {}
        public static let `default` = AlbumWeights()
    }

    /// 曲目数完全相等时额外给的加分（在加权平均之后叠加）。
    /// 这是专辑模式里最硬的一个信号：一个文件夹有 11 个文件、一张专辑正好 11 首，
    /// 巧合的概率远低于「专辑名恰好相似」。
    public static let exactTrackCountBonus: Double = 0.10
    /// 代表曲共识加分上限（每首命中 +0.05，最多 +0.15）。
    public static let consensusBonusPerHit: Double = 0.05
    public static let consensusBonusCap: Double = 0.15

    public static func scoreAlbum(_ detail: AlbumDetail,
                                  consensusHits: Int,
                                  group: FolderGroup,
                                  context ctx: FolderContext,
                                  durationsCredible: Bool,
                                  options: AlbumMatchOptions,
                                  weights: AlbumWeights = .default) -> AlbumCandidate {

        var items: [ScoreItem] = []
        var notes: [String] = []

        // ① 专辑名
        if let want = ctx.album, let got = detail.title, !want.isEmpty, !got.isEmpty {
            items.append(ScoreItem("专辑名", weights.albumTitle,
                                   MatchScorer.titleSimilarity(got, want)))
        }

        // ② 艺术家
        if let want = ctx.artist, let got = detail.artist, !want.isEmpty, !got.isEmpty {
            items.append(ScoreItem("艺术家", weights.artist,
                                   MatchScorer.artistSimilarity(got, want)))
        }

        // ③ 曲目数
        let localCount = group.files.count
        let albumCount = detail.effectiveTrackCount
        if albumCount > 0 {
            items.append(ScoreItem("曲目数", weights.trackCount,
                                   trackCountScore(local: localCount, album: albumCount)))
        }

        // ④ 整体对齐度（顺带把每个文件对到哪首也算出来了）
        let alignment = align(group: group, context: ctx, detail: detail,
                              durationsCredible: durationsCredible, options: options)
        if !detail.tracks.isEmpty {
            // 对齐率与配对平均分的乘积：既要「对上的多」，也要「对得准」
            let a = alignment.rate * 0.5 + alignment.meanPairScore * 0.5
            items.append(ScoreItem("对齐度", weights.alignment, a))
        }

        // ⑤ 时长整体差（只在本地时长可信时参与）
        if durationsCredible, let delta = alignment.meanDurationDelta {
            items.append(ScoreItem("时长差", weights.duration, MatchScorer.durationScore(delta)))
        }

        // ⑥ 年份（只在文件夹名里带了年份时参与）
        if let want = MatchScorer.yearValue(ctx.year), let got = MatchScorer.yearValue(detail.year) {
            let gap = abs(got - want)
            let v = gap == 0 ? 1.0 : max(0, 1.0 - Double(gap) * 0.12)
            items.append(ScoreItem("年份", weights.year, v))
        }

        var score = 0.0
        let totalWeight = items.reduce(0) { $0 + $1.weight }
        if totalWeight > 0 {
            score = items.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
        }

        // 加分项
        if albumCount > 0, albumCount == localCount {
            score += exactTrackCountBonus
            notes.append("曲目数与文件数都是 \(localCount)，强吻合")
        }
        if consensusHits > 0 {
            let bonus = min(consensusBonusCap, Double(consensusHits) * consensusBonusPerHit)
            score += bonus
            notes.append("\(consensusHits) 首代表曲把它认作归属专辑")
        }

        // 惩罚项
        if detail.tracks.isEmpty {
            score *= 0.45
            notes.append("该源没给出曲目表，无法逐首对齐（中区 iTunes 的华语专辑普遍如此）")
        }
        if let got = detail.title {
            let folderIsComp = ctx.album.map { MatchScorer.isCompilationAlbumName($0) } ?? false
            if !folderIsComp, MatchScorer.isCompilationAlbumName(got) {
                score *= 0.70
                notes.append("候选是精选/合辑，而文件夹名不是")
            }
            let folderIsLive = ctx.album.map { hasVersionMarker($0) } ?? false
            if !folderIsLive, hasVersionMarker(got) {
                score *= 0.55
                notes.append("候选是 Live/Remix/伴奏版本，而文件夹名不是 —— 正是要避免的那类误匹配")
            }
        }
        if albumCount > 0, albumCount < localCount {
            notes.append("专辑只有 \(albumCount) 首，比文件夹里的 \(localCount) 个文件少")
        }

        return AlbumCandidate(detail: detail,
                              score: min(1.0, max(0.0, score)),
                              consensusHits: consensusHits,
                              breakdown: items,
                              alignedCount: alignment.alignedCount,
                              fileCount: group.files.count,
                              meanDurationDelta: alignment.meanDurationDelta,
                              notes: notes)
    }

    /// 曲目数差 → 分。相等满分，差 1～2 小减，差很多重罚。
    public static func trackCountScore(local: Int, album: Int) -> Double {
        guard local > 0, album > 0 else { return 0.5 }
        let d = abs(local - album)
        switch d {
        case 0:  return 1.0
        case 1:  return 0.72
        case 2:  return 0.52
        case 3:  return 0.32
        default: return max(0, 0.32 - 0.06 * Double(d - 3))
        }
    }

    /// Live / Remix / 伴奏 / 演唱会 这类版本标记。
    public static func hasVersionMarker(_ s: String) -> Bool {
        let n = MatchScorer.normalize(s)
        for kw in versionMarkers where n.contains(kw) { return true }
        return false
    }

    static let versionMarkers: [String] = [
        "live", "remix", "remixed", "acoustic", "karaoke", "instrumental", "unplugged",
        "演唱会", "现场", "伴奏", "翻唱", "混音", "重制", "巡回", "巡演", "音乐会",
    ].map { MatchScorer.normalize($0) }

    // MARK: - 曲目对齐

    /// 把组内文件对到专辑曲目表。**三趟**，理由见每一趟的注释。
    ///
    /// 单个配对的分由三维加权：标题相似度（主）、音轨号是否相等、时长差。
    /// 某一维没法比就摊掉——本地文件常常只有序号没有曲名，或只有曲名没有序号，
    /// 「信息少」不该等于「分低」，否则整组会集体够不着阈值。
    public static func align(group: FolderGroup,
                             context ctx: FolderContext,
                             detail: AlbumDetail,
                             durationsCredible: Bool,
                             options: AlbumMatchOptions) -> AlignmentOutcome {

        let files = group.files
        guard !detail.tracks.isEmpty else {
            return AlignmentOutcome(
                pairs: files.map {
                    TrackAlignment(fileURL: $0.url, track: nil, score: 0,
                                   reason: "该来源没有提供专辑曲目表")
                },
                alignedCount: 0, meanPairScore: 0, meanDurationDelta: nil)
        }

        var assigned = [Int?](repeating: nil, count: files.count)   // file index → track index
        var pairScore = [Double](repeating: 0, count: files.count)
        var reason = [String](repeating: "未在专辑曲目表中找到对应曲目", count: files.count)
        var trackTaken = [Bool](repeating: false, count: detail.tracks.count)

        func fileTitle(_ i: Int) -> String? {
            queryTitle(for: files[i], context: ctx, options: options)
        }
        func fileTrackNo(_ i: Int) -> Int? {
            if !options.ignoreExistingTags, let n = files[i].tags.trackNumber, n > 0 { return n }
            return ctx.context(for: files[i].url)?.trackNumber
        }
        func fileDisc(_ i: Int) -> Int? {
            if !options.ignoreExistingTags, let n = files[i].tags.discNumber, n > 0 { return n }
            return ctx.context(for: files[i].url)?.discNumber ?? ctx.discNumber
        }
        func fileDuration(_ i: Int) -> TimeInterval {
            durationsCredible ? files[i].technical.duration : 0
        }

        /// 一对配对的分。可比的维度才参与，权重按比例摊。
        func score(_ i: Int, _ j: Int) -> Double {
            let t = detail.tracks[j]
            var pairs: [(Double, Double)] = []

            if let ft = fileTitle(i), !ft.isEmpty, !t.title.isEmpty {
                pairs.append((0.62, MatchScorer.titleSimilarity(t.title, ft)))
            }
            if let n = fileTrackNo(i) {
                var v = (n == t.number) ? 1.0 : 0.0
                // 碟号对不上就算音轨号相同也不该给满分（双碟专辑两碟都有第 3 首）
                if v > 0, detail.discCount > 1, let d = fileDisc(i), d != t.disc { v = 0.3 }
                pairs.append((0.24, v))
            }
            let dur = fileDuration(i)
            if dur > 0, t.durationSeconds > 0 {
                pairs.append((0.14, MatchScorer.durationScore(abs(t.durationSeconds - dur))))
            }
            guard !pairs.isEmpty else { return 0 }
            let w = pairs.reduce(0) { $0 + $1.0 }
            return pairs.reduce(0) { $0 + $1.0 * $1.1 } / w
        }

        // 第一趟 —— 音轨号锁定。
        // 文件名里的序号是用户目录里最可靠的结构信息，序号一致且曲名不矛盾时直接定死，
        // 免得贪心阶段被一首「曲名恰好更像」的邻曲抢走位置。
        for i in files.indices {
            guard let n = fileTrackNo(i) else { continue }
            let d = fileDisc(i)
            // 候选必须在**尚未被占**的曲目里挑。
            // 双碟专辑两张碟都有第 n 首，文件自己又常常给不出碟号
            // （散放在一个目录、文件名只写 `07 - …`）——
            // 若像原先那样只取「第一个号码相同的」，第二个文件必然撞上已被占的那一首、
            // 白白放弃这一趟，被推去贪心阶段按曲名硬配，双碟越大越容易错位。
            // 先按碟号精确相符的挑，挑不到再退回同号未占用的任意一首。
            let sameNumber = detail.tracks.indices.filter { j in
                !trackTaken[j] && detail.tracks[j].number == n
            }
            let exactDisc = sameNumber.filter { detail.tracks[$0].disc == d }
            let pool = !exactDisc.isEmpty ? exactDisc
                     : (detail.discCount <= 1 || d == nil ? sameNumber : [])
            guard !pool.isEmpty else { continue }

            let ft = fileTitle(i)
            // 同号多首（只可能出现在多碟）时用曲名挑最像的那一首，没有曲名就取第一首。
            var j = pool[0]
            if let ft, !ft.isEmpty, pool.count > 1 {
                j = pool.max {
                    MatchScorer.titleSimilarity(detail.tracks[$0].title, ft)
                        < MatchScorer.titleSimilarity(detail.tracks[$1].title, ft)
                } ?? pool[0]
            }
            let sim = (ft?.isEmpty ?? true) ? nil
                : MatchScorer.titleSimilarity(detail.tracks[j].title, ft!)
            // 曲名不可比 → 只凭序号也认；曲名可比但明显矛盾 → 交给第二趟重新配
            guard sim == nil || sim! >= 0.45 else { continue }
            assigned[i] = j
            trackTaken[j] = true
            pairScore[i] = score(i, j)
            let where_ = detail.discCount > 1 ? "第 \(detail.tracks[j].disc) 碟第 \(n) 首" : "音轨号 \(n)"
            reason[i] = sim == nil
                ? "文件名音轨号与曲目表的 " + where_ + " 一致（文件名无曲名可比对）"
                : where_ + " 一致且曲名吻合（相似度 " + String(format: "%.2f", sim!) + "）"
        }

        // 第二趟 —— 贪心最优分配。
        // 把剩余的 (文件 × 曲目) 全组合按分降序排一遍，从高到低占位，一对一。
        // 规模上限是 n×m（一张碟通常 ≤ 30 首），排序开销可以忽略；
        // 相比匈牙利算法只在「多处并列」时可能差一点，但结果可解释、可复现，
        // 而且第一趟已经把最可靠的那部分锁死了。
        var combos: [(i: Int, j: Int, s: Double)] = []
        for i in files.indices where assigned[i] == nil {
            for j in detail.tracks.indices where !trackTaken[j] {
                let s = score(i, j)
                if s > 0 { combos.append((i, j, s)) }
            }
        }
        combos.sort { $0.s > $1.s }
        for c in combos {
            guard assigned[c.i] == nil, !trackTaken[c.j] else { continue }
            guard c.s >= options.alignAcceptThreshold else { break }
            assigned[c.i] = c.j
            trackTaken[c.j] = true
            pairScore[c.i] = c.s
            reason[c.i] = "按曲名与时长最优配对（分 " + String(format: "%.2f", c.s) + "）"
        }

        // 第三趟 —— 收尾：没配上的说清楚为什么。
        for i in files.indices where assigned[i] == nil {
            if fileTitle(i) == nil, fileTrackNo(i) == nil {
                reason[i] = "文件名里既无曲名也无音轨号，无从对齐"
            } else if trackTaken.allSatisfy({ $0 }) {
                reason[i] = "专辑曲目表已被组内其它文件占满（文件数多于曲目数）"
            } else {
                reason[i] = "未在专辑曲目表中找到对应曲目（最高配对分低于 "
                    + String(format: "%.2f", options.alignAcceptThreshold) + "）"
            }
        }

        var pairs: [TrackAlignment] = []
        var deltas: [Double] = []
        var scores: [Double] = []
        for i in files.indices {
            let t = assigned[i].map { detail.tracks[$0] }
            pairs.append(TrackAlignment(fileURL: files[i].url, track: t,
                                        score: pairScore[i], reason: reason[i]))
            if t != nil {
                scores.append(pairScore[i])
                let d = fileDuration(i)
                if d > 0, let ts = t?.durationSeconds, ts > 0 { deltas.append(abs(ts - d)) }
            }
        }
        return AlignmentOutcome(
            pairs: pairs,
            alignedCount: scores.count,
            meanPairScore: scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count),
            meanDurationDelta: deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count))
    }

    // MARK: - 同专辑内的备选曲目

    /// 这个文件在**这张专辑内**还能对到哪几首，按像的程度降序。
    ///
    /// 为什么备选只在专辑内找：专辑模式一旦锁定了专辑，剩下的错配几乎全是
    /// 「对到了邻近的另一首」（同碟同名段落、序号错位）。答案就在同一张曲目表里，
    /// 一次网络请求都不用发，切换是瞬时的。要跳出这张专辑另找，
    /// 走复核表行内的「手动搜索…」——那是另一条按需联网的路。
    public static func alternatives(for fileURL: URL,
                                    chosen: AlbumTrack?,
                                    detail: AlbumDetail,
                                    group: FolderGroup,
                                    context ctx: FolderContext,
                                    options: AlbumMatchOptions,
                                    limit: Int = 5) -> [TrackCandidate] {
        guard !detail.tracks.isEmpty else { return [] }
        let file = group.files.first { $0.url == fileURL }
        let title = file.flatMap { queryTitle(for: $0, context: ctx, options: options) }
        let wantNo = ctx.context(for: fileURL)?.trackNumber
        let dur = file.map { $0.technical.duration } ?? 0

        var scored: [(track: AlbumTrack, s: Double)] = []
        for t in detail.tracks {
            if let chosen, t.number == chosen.number, t.disc == chosen.disc { continue }
            var pairs: [(Double, Double)] = []
            if let title, !title.isEmpty, !t.title.isEmpty {
                pairs.append((0.66, MatchScorer.titleSimilarity(t.title, title)))
            }
            if let n = wantNo {
                // 序号越近越可能是「错位一位」的那种误配，排在前面最省事。
                let gap = abs(n - t.number)
                pairs.append((0.20, gap == 0 ? 1.0 : max(0, 1.0 - Double(gap) * 0.25)))
            }
            if dur >= MatchScorer.minimumPlausibleQueryDuration, t.durationSeconds > 0 {
                pairs.append((0.14, MatchScorer.durationScore(abs(t.durationSeconds - dur))))
            }
            let w = pairs.reduce(0) { $0 + $1.0 }
            let v = w > 0 ? pairs.reduce(0) { $0 + $1.0 * $1.1 } / w : 0
            scored.append((t, v))
        }
        // 没有任何可比信息时按曲目表原序给几首，总好过一个都不给。
        scored.sort { a, b in
            a.s != b.s ? a.s > b.s
                : (a.track.disc != b.track.disc ? a.track.disc < b.track.disc
                                                : a.track.number < b.track.number)
        }
        return scored.prefix(limit).map { entry in
            var c = detail.candidate(for: entry.track)
            c.matchScore = entry.s
            return c
        }
    }

    // MARK: - 封面

    /// 整组只下一次。走该源自己的 `fetchArtwork`，拿不到就回落 Cover Art Archive（MB 专用）。
    public static func fetchArtwork(for detail: AlbumDetail, size: Int) async -> Data? {
        guard let src = SourceRegistry.shared.source(id: detail.sourceID) else { return nil }
        var c = TrackCandidate(sourceID: detail.sourceID,
                               nativeID: detail.tracks.first?.nativeID ?? detail.albumID,
                               albumID: detail.albumID)
        c.album = detail.title
        c.artworkURL = detail.artworkURL
        if let data = try? await src.fetchArtwork(c, preferredSize: size), !data.isEmpty {
            return data
        }
        if detail.sourceID == "musicbrainz" {
            return try? await CoverArtArchiveSource()
                .artwork(releaseMBID: detail.albumID, preferredSize: size)
        }
        return nil
    }

    // MARK: - 小工具

    static func ignoredResult(_ url: URL, reason: String) -> AutoMatchResult {
        AutoMatchResult(url: url, status: .ignored, best: nil, edit: nil,
                        artwork: nil, lyrics: nil, triedSources: [],
                        candidateCount: 0, errors: [("album", reason)])
    }
}

//
//  MatchScorer.swift
//  MacTagger — 与数据源无关的候选打分器
//
//  用途：原版「自动匹配标签」会从多个源、每源多条候选里挑一条自动写入。
//  挑错的代价很高（把用户的原版专辑改成再版、把录音室版改成 Live 版），
//  所以打分规则按「可证伪的强信号优先」设计：
//
//    · 标题相似度   权重最高——但同名翻唱、Live 版、Remix 的标题往往完全相同，
//                   只靠标题必然选错，故不能一票定音。
//    · 艺术家相似度 次之——按分隔符切词做集合比对，容忍 "A & B" ↔ "A"。
//    · 时长差       强信号——录音室版与 Live 版通常差 5～30 秒。
//                   ≤3 秒给满分，>15 秒除了本项归零，还对总分乘以惩罚系数。
//    · 专辑匹配     加分项——用户文件常没有专辑标签，故权重最低且可缺省。
//    · 专辑质量     加分项（2026-09-01 新增）——同一首歌往往同时存在于原始专辑与一堆合辑里，
//                   歌曲本身都对，但用户几乎总是想要原始专辑。权重刻意压得很小，
//                   只在标题/艺术家/时长这些主信号打平时充当决胜项，绝不喧宾夺主。
//
//  某一项无法比较时（查询或候选缺该字段），该项权重按比例摊给其余项，
//  避免「信息越少分越低」导致不同文件之间的分数不可比。
//

import Foundation

public enum MatchScorer {

    // MARK: - 权重

    public struct Weights: Sendable {
        public var title: Double
        public var artist: Double
        public var duration: Double
        public var album: Double
        /// 「像不像原始专辑」维度。取 0.12：
        /// 在主信号全部打平（同一首歌的多个发行）时足以拉开约 0.09 的分差决出胜负，
        /// 但即使该项归零也只让总分掉约 0.12，压不过标题/艺术家/时长任何一项。
        public var albumQuality: Double
        /// 「是不是同一份录音」维度（Live / MV / Remix / ver.）。取 0.40：
        /// 仅次于标题，压得过艺术家 —— 同一首歌的两个 Live 在标题与艺术家上完全相同，
        /// 此时唯一能分辨的就是这一维，权重小了就白设。
        /// **只在调用方显式传 `versionQuery` 时参与打分**，否则这一项根本不入池。
        public var version: Double

        public init(title: Double = 0.50, artist: Double = 0.25,
                    duration: Double = 0.15, album: Double = 0.10,
                    albumQuality: Double = 0.12, version: Double = 0.40) {
            self.title = title; self.artist = artist
            self.duration = duration; self.album = album
            self.albumQuality = albumQuality
            self.version = version
        }

        public static let `default` = Weights()
    }

    /// 时长差阈值（秒）。
    public static let exactDurationTolerance: TimeInterval = 3
    public static let looseDurationTolerance: TimeInterval = 8
    public static let durationPenaltyThreshold: TimeInterval = 15
    /// 时长差超过阈值时对总分的乘法惩罚。0.55 意味着「其余项全满也只有 0.55」，
    /// 足以把 Live 版压到录音室版之后，但不至于让它从候选列表里消失。
    public static let durationPenaltyFactor: Double = 0.55
    /// 查询有时长、但候选没给时长时该项的得分。
    /// 取 0.5 而不是摊掉该项：让「已核对时长」的候选稳定压过「无从核对」的候选。
    public static let unverifiedDurationScore: Double = 0.5

    /// 查询时长低于此值时**视为未知**，不参与打分。
    ///
    /// 为什么必须有这道闸（2026-09-01 实测踩到）：
    /// 一个 2 秒的 mp3（测试音、被截断、或 TagLib 把畸形头解析错了）拿去比对，
    /// 会让**每一条**真实候选的时长差都超过 `durationPenaltyThreshold`，
    /// 于是所有候选被同一个 ×0.55 惩罚一视同仁地压下去——
    /// 惩罚不带任何区分度，却足以把整池候选压到 `acceptThreshold` 以下，
    /// 把本该「匹配成功」变成「忽略」。
    ///
    /// 更糟的是它会**把排序倒过来**：搜索阶段干脆不返回时长的源
    /// （QQ smartbox）拿的是 `unverifiedDurationScore`，不吃惩罚，
    /// 于是稳定压过那些**如实报出正确时长**的源（网易云/酷狗/iTunes）。
    /// 实测基线里三首歌全部由 QQ 以 0.917 胜出，正是这个倒置的表现。
    /// 时长不可信时就该当它不存在，而不是拿它去惩罚所有人。
    public static let minimumPlausibleQueryDuration: TimeInterval = 30

    // MARK: - 专辑质量上下文

    /// 「哪个专辑更像原始专辑」这件事**只能相对判断**：
    /// 同一首歌的若干个发行里，年份最早的那个通常就是原版专辑，
    /// 而「2008 年」本身说明不了任何问题（2008 年的歌，原专辑当然是 2008 年）。
    /// 所以年份维度需要整池候选做参照，由 `rank` 统一算好后传进 `score`。
    ///
    /// 单独调 `score` 而不给上下文时，年份项取中性值——不会因为缺上下文而误伤谁。
    public struct AlbumContext: Sendable, Equatable {
        /// 候选池中「与查询确实是同一首歌」的那部分里最早的发行年。
        public var earliestYear: Int?

        public init(earliestYear: Int? = nil) { self.earliestYear = earliestYear }

        public static let none = AlbumContext()

        /// 从候选池提炼上下文。
        ///
        /// 关键：**只统计确实是同一首歌的候选**。搜索结果里混着「七里香」「小城故事」
        /// 这类同歌手的其它歌，它们的年份和本曲的原版年份毫无关系，
        /// 直接取全池最小年会把参照点拉歪。
        ///
        /// 「是不是同一首歌」的门槛取**池内最高标题相似度往下 `titleMargin`**，
        /// 而不是一个绝对值。因为查询串的形态会整体拉低所有候选的相似度：
        /// 手工搜索常把「曲名 歌手」当自由词一起传进来，此时正确候选也只有约 0.76，
        /// 卡死 0.8 会把整池全排除掉、上下文直接失效。
        /// 相对门槛对查询形态免疫，同时照样把「稻香 (Live)」（≈0.63，远低于 1.0）挡在外面。
        public static func make(from candidates: [TrackCandidate],
                                query: TrackQuery,
                                titleMargin: Double = 0.12,
                                absoluteTitleFloor: Double = 0.6,
                                minimumArtistSimilarity: Double = 0.6) -> AlbumContext {
            let queryTitle = firstNonEmpty(query.title, query.filename)

            // 先算每条候选的标题相似度；无从比较时记 1.0（不因缺字段被排除）
            let sims: [Double] = candidates.map { c in
                guard let qt = queryTitle, let ct = c.title, !qt.isEmpty, !ct.isEmpty else { return 1.0 }
                return titleSimilarity(ct, qt)
            }
            guard let bestSim = sims.max() else { return .none }
            let threshold = max(absoluteTitleFloor, bestSim - titleMargin)

            var earliest: Int?
            for (i, c) in candidates.enumerated() {
                guard let y = yearValue(c.year) else { continue }
                guard sims[i] >= threshold else { continue }
                if let qa = query.artist, let ca = c.artist, !qa.isEmpty, !ca.isEmpty {
                    guard artistSimilarity(ca, qa) >= minimumArtistSimilarity else { continue }
                }
                earliest = min(earliest ?? y, y)
            }
            return AlbumContext(earliestYear: earliest)
        }
    }

    // MARK: - 对外接口

    /// 给单个候选打分，返回 0…1。
    ///
    /// `context` 由 `rank` 从整池候选算出。单独调用可不传，此时专辑质量的年份项取中性值。
    public static func score(_ candidate: TrackCandidate,
                             for query: TrackQuery,
                             weights: Weights = .default,
                             context: AlbumContext = .none,
                             versionQuery: VersionInfo? = nil) -> Double {

        var pairs: [(weight: Double, value: Double)] = []

        // 标题：查询无标题时退回文件名（文件名常含艺术家，故用包含式比较兜底）
        //
        // ★ BG 轮：带上 `versionQuery` 时，标题这一维改比**正题**（剥掉版本后缀）。
        // 理由是「Family Song (Live At A20171222)」与「Family Song (Live At B20171225)」
        // 在整串上几乎同分 —— 版本差异全挤在后缀里，标题维度根本分辨不出来，
        // 于是谁赢全看专辑/年份这些弱信号。把版本单拎成一维之后，
        // 标题只负责「是不是同一首歌」，版本负责「是不是同一份录音」，两件事各归各位。
        let queryTitle = firstNonEmpty(versionQuery?.baseTitle, query.title, query.filename)
        if let qt = queryTitle, let ct = candidate.title, !qt.isEmpty, !ct.isEmpty {
            let candTitle = versionQuery == nil
                ? ct : VersionMarker.parse(ct).baseTitle
            pairs.append((weights.title, titleSimilarity(candTitle, qt)))
        }

        if let qa = query.artist, let ca = candidate.artist, !qa.isEmpty, !ca.isEmpty {
            pairs.append((weights.artist, artistSimilarity(ca, qa)))
        }

        // 低于 `minimumPlausibleQueryDuration` 的查询时长不可信，当未知处理（理由见常量注释）
        var penalty = 1.0
        if query.duration >= minimumPlausibleQueryDuration {
            if candidate.durationSeconds > 0 {
                let delta = abs(candidate.durationSeconds - query.duration)
                pairs.append((weights.duration, durationScore(delta)))
                if delta > durationPenaltyThreshold { penalty = durationPenaltyFactor }
            } else {
                // 查询有时长、候选没有 —— 无法核对。
                // 这一项**不能直接摊掉**：否则「查无时长的条目」会和
                // 「时长精确对上的条目」并列满分，实测 MusicBrainz 搜
                // "Blank Space" 时就出现 5 条并列 1.000。
                // 给 unverifiedDurationScore 表示「存疑但不判死」。
                pairs.append((weights.duration, unverifiedDurationScore))
            }
        }

        if let qb = query.album, let cb = candidate.album, !qb.isEmpty, !cb.isEmpty {
            pairs.append((weights.album, titleSimilarity(cb, qb)))
        }

        // 专辑质量：**始终参与**，缺专辑信息时给中性偏低值。
        // 不能像其它项那样「缺就摊掉」——否则「压根没给专辑」的候选（QQ smartbox）
        // 会因为少了一个不满分的项而反超「给了原始专辑」的候选。
        if weights.albumQuality > 0 {
            pairs.append((weights.albumQuality, albumQuality(candidate, context: context)))
        }

        // ★ 版本维度（BG 轮）。**只在调用方显式给了 `versionQuery` 时参与** ——
        // 不给就是今天的行为一个字不差，自动匹配标签那条路完全不受影响。
        // 目前只有歌词那条路（`LyricsService.resolve`）会给。
        if let vq = versionQuery {
            let v = versionSimilarity(candidate.title, query: vq)
            pairs.append((weights.version, v))
            // 可证伪的不匹配（不同 Live 场次）：额外重罚，不让它靠别的维度爬回来。
            if v <= 0.0001 { penalty *= versionMismatchPenalty }
        }

        guard !pairs.isEmpty else { return 0 }
        let totalWeight = pairs.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        let raw = pairs.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
        return clamp01(raw * penalty)
    }

    // MARK: - 排序与确定性平局判据

    //
    //  ★ AZ 轮修的既有问题（AX 报告 §5 遗留第 1 条）
    //
    //  旧实现同分时「保持原顺序」，而**原顺序就是各源返回的先后**：
    //  `gather` 是并发的，哪个源先回来完全看网络。于是跨源打平（实测 iTunes 0.988 =
    //  QQ 0.988）时胜出者在两轮之间随机抖动 —— 同一批文件跑两次，写进去的专辑不一样。
    //  这比「慢」严重得多：用户没法复现、没法信任、也没法判断到底哪一次是对的。
    //
    //  修法：同分时不再看返回顺序，改用四条**可复算**的判据，按优先级依次比：
    //    ① 字段完整度  —— 专辑/年份/音轨号/封面 URL 里有几项非空。多的先。
    //                    理由：分数一样意味着「都对」，那就挑能写进去的东西更多的那条。
    //    ② 来源优先级  —— 按 `sourcePriority` 的次序（默认 = 注册表推荐优先级，
    //                    与 `AutoMatchOptions.sourceIDs` 的默认值逐字相同）。
    //    ③ 专辑更像原版 —— 非合辑先于合辑；再同则专辑名短的先
    //                    （「魔杰座」先于「魔杰座 (Special Edition)」）。
    //    ④ nativeID 字典序 —— 兜底。它没有任何语义，但**保证全序**：
    //                    走到这一步说明前三条全平，此时唯一的要求就是「每次都选同一个」。
    //
    //  为什么分数要先量化（`scoreKey`）：同一条候选在不同调用路径下算出的分可能差 1e-16
    //  （浮点加法不满足结合律），直接用 `!=` 比会把它们当成「不同分」，
    //  于是四条判据一条都用不上，抖动照旧。量化到 1e-6 —— 0…1 的分数里
    //  低于 1e-6 的差别没有任何实际含义，而量化是分数的纯函数，仍然构成合法的全序。
    //

    /// 分数量化粒度。低于此差别一律视为同分，交给确定性判据裁决。
    public static let tieQuantum: Double = 1_000_000

    static func scoreKey(_ v: Double) -> Double { (v * tieQuantum).rounded() }

    /// 「能写进标签的字段有几项」。只数那些**同分时才有意义**的可选字段：
    /// 标题/艺术家已经在打分里比过了，再数一遍是重复计票。
    public static func fieldCompleteness(_ c: TrackCandidate) -> Int {
        var n = 0
        if let v = c.album, !v.isEmpty { n += 1 }
        if let v = c.year, !v.isEmpty { n += 1 }
        if let v = c.trackNumber, !v.isEmpty { n += 1 }
        if c.artworkURL != nil { n += 1 }
        return n
    }

    /// 同分时的确定性比较。返回 true 表示 `a` 应排在 `b` 前面；两者完全等价时返回 nil。
    static func tieBreak(_ a: TrackCandidate, _ b: TrackCandidate,
                         sourcePriority: [String]) -> Bool? {
        // ① 字段完整度
        let (fa, fb) = (fieldCompleteness(a), fieldCompleteness(b))
        if fa != fb { return fa > fb }

        // ② 来源优先级。不在表里的源排在表里所有源之后（而不是并列第一）。
        func rank(_ id: String) -> Int { sourcePriority.firstIndex(of: id) ?? sourcePriority.count }
        let (ra, rb) = (rank(a.sourceID), rank(b.sourceID))
        if ra != rb { return ra < rb }

        // ③ 非合辑优先；再同则专辑名短的优先
        let (ca, cb) = (isCompilation(a), isCompilation(b))
        if ca != cb { return !ca }
        let (la, lb) = (a.album?.count ?? Int.max, b.album?.count ?? Int.max)
        if la != lb { return la < lb }

        // ④ 字典序兜底
        if a.nativeID != b.nativeID { return a.nativeID < b.nativeID }
        return nil
    }

    private static func isCompilation(_ c: TrackCandidate) -> Bool {
        guard let a = c.album, !a.isEmpty else { return false }
        return isCompilationAlbumName(a)
    }

    /// 给所有候选打分并按分降序返回。
    ///
    /// **同分不再看返回顺序**（那是并发下的随机数），走 `tieBreak` 的四条确定性判据。
    /// `sourcePriority` 默认取注册表的推荐优先级；调用方有自己的源次序时传进来即可。
    public static func rank(_ candidates: [TrackCandidate],
                            for query: TrackQuery,
                            weights: Weights = .default,
                            sourcePriority: [String] = SourceRegistry.recommendedPriority,
                            versionQuery: VersionInfo? = nil)
        -> [TrackCandidate] {
        // 年份「谁更早」只有放在整池里才有意义，先算好参照点再逐条打分。
        let context = AlbumContext.make(from: candidates, query: query)
        let scored: [(index: Int, candidate: TrackCandidate)] = candidates.enumerated().map {
            var c = $0.element
            c.matchScore = score(c, for: query, weights: weights,
                                 context: context, versionQuery: versionQuery)
            return ($0.offset, c)
        }
        return scored.sorted { l, r in
            let (ka, kb) = (scoreKey(l.candidate.matchScore), scoreKey(r.candidate.matchScore))
            if ka != kb { return ka > kb }
            if let decided = tieBreak(l.candidate, r.candidate, sourcePriority: sourcePriority) {
                return decided
            }
            // 四条判据全平 = 两条候选在**所有**可比字段上都一样。
            // 此时用入池序号收尾：它是数组下标，永远唯一，保证排序是全序而不是偏序。
            return l.index < r.index
        }.map(\.candidate)
    }

    /// 跨源合并后取最优。低于 `minimumScore` 时返回 nil——宁可不写，也不写错。
    public static func best(_ candidates: [TrackCandidate],
                            for query: TrackQuery,
                            minimumScore: Double = 0.6,
                            weights: Weights = .default,
                            versionQuery: VersionInfo? = nil) -> TrackCandidate? {
        guard let top = rank(candidates, for: query, weights: weights,
                             versionQuery: versionQuery).first else { return nil }
        return top.matchScore >= minimumScore ? top : nil
    }

    // MARK: - 分项打分

    /// 时长差 → 分数。分段线性，拐点见文件头注释。
    public static func durationScore(_ delta: TimeInterval) -> Double {
        let d = abs(delta)
        if d <= exactDurationTolerance { return 1.0 }
        if d <= looseDurationTolerance {
            let t = (d - exactDurationTolerance) / (looseDurationTolerance - exactDurationTolerance)
            return 1.0 - t * 0.4                     // 1.0 → 0.6
        }
        if d <= durationPenaltyThreshold {
            let t = (d - looseDurationTolerance) / (durationPenaltyThreshold - looseDurationTolerance)
            return 0.6 - t * 0.5                     // 0.6 → 0.1
        }
        return 0
    }

    // MARK: - 专辑质量

    /// 完全没有专辑信息时该项的得分。
    /// 略低于「有专辑且没有任何合辑特征」的基线 0.55，
    /// 好让「明确给出了原始专辑」的候选压过「什么都没说」的候选；
    /// 但明显高于合辑（≈0.15），免得没返回专辑名的源被当合辑冤枉。
    public static let unknownAlbumQuality: Double = 0.45
    /// 有专辑名、但没有任何正负特征时的中性基线。
    public static let neutralAlbumQuality: Double = 0.55

    /// 「这张专辑像不像这首歌的原始专辑」，0…1。
    ///
    /// 三个可证伪的信号，全部只做**小幅**加减，合起来最多让总分动约 0.12：
    ///  · 合辑特征（专辑名关键词 / 音轨号很大）→ 减分。合辑里同一首歌完全正确，
    ///    只是用户想要的是原专辑，所以是「更不想要」而不是「错」，减分不能减成 0。
    ///  · 发行年最早 → 加分。同一首歌的多个发行里，最早的通常就是原版。
    ///  · 音轨号小 → 轻微加分；专辑名与曲名相同（单曲/EP）→ 轻微加分。
    public static func albumQuality(_ candidate: TrackCandidate,
                                    context: AlbumContext = .none) -> Double {
        guard let album = candidate.album, !album.isEmpty else { return unknownAlbumQuality }

        var q = neutralAlbumQuality

        // ① 合辑关键词：一票压到低位，但不清零
        if isCompilationAlbumName(album) { q -= 0.40 }

        // ② 音轨号。72 这种数字只可能出现在「精选 80 首」式的大合辑里。
        if let t = trackValue(candidate.trackNumber) {
            if t > 30 { q -= 0.30 }
            else if t > 20 { q -= 0.12 }
            else if t <= 12 { q += 0.06 }
        }

        // ③ 发行年份 —— 相对整池最早年。缺上下文或缺年份时取中性值，不误伤。
        if let y = yearValue(candidate.year), let earliest = context.earliestYear {
            let gap = y - earliest
            q += gap <= 0 ? 0.30 : max(0, 0.30 - 0.03 * Double(gap))
        } else {
            q += 0.14
        }

        // ④ 专辑名 == 曲名：多半是单曲/EP。不一定是原专辑，只给很轻的加分。
        if let t = candidate.title, !t.isEmpty, normalize(t) == normalize(album) { q += 0.05 }

        return clamp01(q)
    }

    /// 合辑/精选集专辑名判定。命中即视为合辑。
    ///
    /// 关键词一律先过 `normalize`（折繁简、去空格标点、转小写）再比对，
    /// 所以「Greatest Hits」「greatest  hits」「精選」「精选」都会归到同一形态。
    /// 刻意**不收**「集」「歌集」这类过宽的字：邓丽君《島國之情歌 第四集》
    /// 是货真价实的原始专辑，收了就会被误判。
    public static func isCompilationAlbumName(_ album: String) -> Bool {
        let n = normalize(album)
        guard !n.isEmpty else { return false }
        for kw in compilationKeywords where n.contains(kw) { return true }
        // 「90年代」「80年代金曲」式的年代合辑。要求前面带数字，
        // 免得把《新的年代》这类正常专辑名误伤。
        if n.range(of: "[0-9]+年代", options: .regularExpression) != nil { return true }
        return false
    }

    /// 已归一化（简体、无空格、小写）的合辑关键词表。
    static let compilationKeywords: [String] = [
        // 中文
        "精选", "精華", "精华", "精粹", "精品", "合辑", "合集", "全集", "选集",
        "大全", "金曲", "珍藏", "典藏", "纪念", "经典", "不朽", "周年", "特集",
        "群星", "串烧", "排行榜", "冠军金曲",
        // 西文（normalize 会去掉空格，故此处也写成无空格形态）
        "greatesthits", "bestof", "verybest", "thebest", "collection",
        "compilation", "anthology", "essential", "ultimate", "variousartists",
    ].map(normalize)

    /// 年份字符串 → 年。容忍 "2008"、"2008-10-15"、"2008/10/15"。越界一律当未知。
    public static func yearValue(_ raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        guard let n = Int(raw.prefix(4)), n > 1900, n < 2200 else { return nil }
        return n
    }

    /// 音轨号字符串 → 号。容忍 "11"、"11/13"、"2/20"。
    public static func trackValue(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let head = raw.split(separator: "/").first.map(String.init) ?? raw
        guard let n = Int(head.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }

    /// 标题/专辑相似度。归一化后算编辑距离，并对包含关系给下限。
    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1.0 }

        var s = editSimilarity(na, nb)

        // 「稻香」vs「稻香 (Live)」：一方完整包含另一方，给 0.86 下限，
        // 但不给满分——真正区分录音室/现场版的活交给时长项。
        if na.contains(nb) || nb.contains(na) {
            let ratio = Double(min(na.count, nb.count)) / Double(max(na.count, nb.count))
            s = max(s, 0.86 * (0.6 + 0.4 * ratio))
        }

        // 去掉括号修饰后再比一次（"Blank Space (Taylor's Version)" ↔ "Blank Space"），
        // 命中则打 0.95 折，保证「完全一致」永远排在「去修饰后一致」前面。
        let ca = normalize(stripQualifiers(a)), cb = normalize(stripQualifiers(b))
        if !ca.isEmpty, !cb.isEmpty, ca != na || cb != nb {
            s = max(s, editSimilarity(ca, cb) * 0.95)
        }
        return clamp01(s)
    }

    /// 艺术家相似度。按 & / 、feat. 等分隔符切词后做双向最优匹配，
    /// 让 "Taylor Swift" 能匹配上 "Taylor Swift & Ed Sheeran"。
    public static func artistSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if !na.isEmpty, na == nb { return 1.0 }

        let ta = artistTokens(a), tb = artistTokens(b)
        if ta.isEmpty || tb.isEmpty { return editSimilarity(na, nb) }

        // 每个查询词在候选词里找最佳配对，取平均
        func directional(_ from: [String], _ to: [String]) -> Double {
            let scores = from.map { f in to.map { editSimilarity(f, $0) }.max() ?? 0 }
            return scores.reduce(0, +) / Double(scores.count)
        }
        let forward = directional(tb, ta)     // 查询 → 候选：查询里的人都在候选里？
        let backward = directional(ta, tb)
        // 偏向 forward：候选多挂了合作艺术家不该重罚
        let combined = forward * 0.75 + backward * 0.25
        return clamp01(max(combined, editSimilarity(na, nb)))
    }

    // MARK: - 归一化

    /// 大小写 / 全半角 / 变音符 / 标点 / 空格 / 繁简全部抹平，只留字母数字与汉字假名。
    public static func normalize(_ s: String) -> String {
        var work = s
        // 繁简统一。实测 MusicBrainz 的华语条目混用两种写法：
        // 同一首「稻香」的艺术家有的记作「周杰伦」有的记作「周杰倫」，
        // 不折叠的话正确候选会因为艺术家项掉分而被没有时长的合辑挤到后面。
        // 统一往**简体**折（Traditional-Simplified）；反方向会把「杰」过度转成「傑」。
        if containsCJK(work) {
            let m = NSMutableString(string: work) as CFMutableString
            if CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false) {
                work = m as String
            }
        }
        let folded = work.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var out = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { out.append(u) }
            // 汉字、假名、谚文：alphanumerics 已覆盖，此处仅防御性保留
        }
        return String(out)
    }

    /// 是否含 CJK。纯 ASCII 串跳过繁简转换，省掉 CFStringTransform 的开销。
    public static func containsCJK(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: continue
            }
        }
        return false
    }

    /// 去掉括号修饰段：(Live) / [Remastered] / 【伴奏】 / （Live版）。
    public static func stripQualifiers(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if "([{（【〈《".contains(ch) { depth += 1; continue }
            if ")]}）】〉》".contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? s : trimmed
    }

    /// 艺术家切词。同时处理西文与中文分隔符，以及 feat./ft./with。
    public static func artistTokens(_ s: String) -> [String] {
        var work = s
        for kw in [" feat.", " feat ", " ft.", " ft ", " featuring ", " with ",
                   " Feat.", " Ft.", " FEAT.", "、", "，", ",", "&", "/", "／", ";", "；", "×"] {
            work = work.replacingOccurrences(of: kw, with: "|")
        }
        return work.split(separator: "|")
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 编辑距离

    /// 归一化编辑距离相似度：1 - levenshtein / max(len)。
    public static func editSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0 }
        let x = Array(a.prefix(200)), y = Array(b.prefix(200))
        let dist = levenshtein(x, y)
        return clamp01(1.0 - Double(dist) / Double(max(x.count, y.count)))
    }

    /// 滚动数组版编辑距离，空间 O(min(n,m))。
    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // 让内层跑短的一边
        let (s, t) = a.count <= b.count ? (a, b) : (b, a)
        var prev = Array(0...s.count)
        var cur = [Int](repeating: 0, count: s.count + 1)
        for i in 1...t.count {
            cur[0] = i
            for j in 1...s.count {
                let cost = (t[i - 1] == s[j - 1]) ? 0 : 1
                cur[j] = min(prev[j] + 1,          // 删
                             cur[j - 1] + 1,       // 插
                             prev[j - 1] + cost)   // 换
            }
            swap(&prev, &cur)
        }
        return prev[s.count]
    }

    // MARK: - 小工具

    private static func clamp01(_ v: Double) -> Double { min(1.0, max(0.0, v)) }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values { if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v } }
        return nil
    }
}

// MARK: - 版本后缀识别（BG 轮）
//
//  为什么要单独有这一层：实测某日文歌手目录里有 4 个《Family Song》的 Live、
//  3 个《うちで踊ろう》的版本、2 个《恋》的现场。它们的**曲名完全相同**，
//  只有括号里的后缀不同。旧的打分把括号整段当「修饰」一折了事
//  （`stripQualifiers` + 0.95 折），于是：
//
//    · 「Family Song (Live At MUSIC STATION SUPER LIVE20171222)」
//      与「Family Song (Live At CDTV SP! Christmas音楽祭20171225)」
//      在标题维度上几乎同分 —— 实测就匹到了**另一场 Live**，
//      用户文件里的 `[ti:]` 至今写着 20171225。
//    · 搜索词原样带着「(Live At …20171222)」送进各源，
//      长后缀把召回打散，有译文的那一条根本没进候选池。
//
//  本层做两件事：
//    ① **搜索**用 `baseTitle`（剥掉版本后缀），召回率回到录音室版的水平；
//    ② **打分**用 marker 集合，同 marker 加分、**不同 Live 场次直接判不匹配**，
//      没有 marker 的录音室版作为次优（它往往是唯一带译文的那一条）。
//
//  刻意**只剥认识的后缀**：`(Dead End)`（日文曲名的英译）、`(在家跳舞吧)`（中文译名）、
//  `(feat. PUNPEE)` 这些不在规则表里的括号段一律原样留在 `baseTitle` 里。
//  宁可少剥一个，也不能把曲名本身剥没了。

/// 一条版本后缀。
public struct VersionMarker: Sendable, Equatable, Hashable {

    public enum Kind: String, Sendable, CaseIterable {
        case live            // (Live) / (Live at …) / -Live- / …现场
        case mv              // (MV版) / (Music Video)
        case remix           // (Remix) / (Potluck Mix) / (混音)
        case instrumental    // (Inst.) / (Off Vocal) / 伴奏 / 纯音乐
        case acoustic        // (Acoustic) / (Unplugged) / 不插电
        case version         // (House ver.) / (TV Size) / (Short Ver.) —— 泛版本
        case cover           // (Cover) / 翻唱
        case demo            // (Demo)
        case remaster        // (Remastered) / 重制版
        case radioEdit       // (Radio Edit) / (Edit)
        case extended        // (Extended Mix) / (Long Ver.)

        /// 中文短名，进复核表与 probe 输出。
        public var label: String {
            switch self {
            case .live:         return "Live"
            case .mv:           return "MV"
            case .remix:        return "Remix"
            case .instrumental: return "伴奏"
            case .acoustic:     return "不插电"
            case .version:      return "版本"
            case .cover:        return "翻唱"
            case .demo:         return "Demo"
            case .remaster:     return "重制"
            case .radioEdit:    return "Edit"
            case .extended:     return "加长"
            }
        }
    }

    public var kind: Kind
    /// 限定词：`House ver.` 的 `house`、`TV Size` 的 `tv`。已归一（小写无空格）。
    public var qualifier: String?
    /// Live 场次名（已去掉 `Live at` 与日期），归一后的形态。
    public var eventName: String?
    /// Live 场次日期。`20171222`（8 位）或 `2017`（4 位年）。
    public var eventDate: String?
    /// 原始片段，仅供展示。
    public var raw: String

    public init(kind: Kind, qualifier: String? = nil,
                eventName: String? = nil, eventDate: String? = nil, raw: String = "") {
        self.kind = kind; self.qualifier = qualifier
        self.eventName = eventName; self.eventDate = eventDate; self.raw = raw
    }

    public var display: String {
        var s = kind.label
        if let q = qualifier, !q.isEmpty { s += ":" + q }
        if let d = eventDate { s += "@" + d }
        else if let e = eventName, !e.isEmpty { s += "@" + String(e.prefix(16)) }
        return s
    }
}

/// 一个曲名拆出来的「正题 + 版本后缀 + 合作艺术家」。
public struct VersionInfo: Sendable, Equatable {
    /// 剥掉已识别后缀之后的正题。剥空了就退回原标题（宁可不剥）。
    public var baseTitle: String
    public var markers: [VersionMarker]
    /// `feat. / ft. / featuring` 段里的艺术家。**不进 `baseTitle`，但保留下来**
    /// —— 搜索词不带它命中率更高，打分时却要用它去补艺术家维度。
    public var featured: [String]
    /// 原标题，供展示与兜底。
    public var original: String

    public init(baseTitle: String, markers: [VersionMarker] = [],
                featured: [String] = [], original: String = "") {
        self.baseTitle = baseTitle; self.markers = markers
        self.featured = featured; self.original = original
    }

    /// 没有任何版本后缀 = 录音室版。
    public var isStudio: Bool { markers.isEmpty }
    public var kinds: Set<VersionMarker.Kind> { Set(markers.map(\.kind)) }

    public var liveMarker: VersionMarker? { markers.first { $0.kind == .live } }
    /// Live 场次日期。没有 Live marker 或该 marker 没带日期时为 nil。
    public var liveDate: String? { liveMarker?.eventDate }
    public var liveEvent: String? { liveMarker?.eventName }

    public var summary: String {
        markers.isEmpty ? "录音室版（无后缀）" : markers.map(\.display).joined(separator: " + ")
    }

    public static func studio(_ title: String) -> VersionInfo {
        VersionInfo(baseTitle: title, markers: [], featured: [], original: title)
    }
}

public extension VersionMarker {

    // MARK: 规则表

    /// 关键词 → 类型。比对前片段会过 `markerKey`（小写、去空格标点、全角转半角）。
    /// 顺序有意义：**先长后短**，`liveversion` 要先于 `live` 命中，
    /// 否则 `(Live Version)` 会先被 `live` 吃掉、`version` 那一维丢失。
    static let keywordTable: [(key: String, kind: Kind)] = [
        // —— 伴奏 / 纯音乐（要最先判：`off vocal ver.` 既含 vocal 又含 ver）——
        ("instrumental", .instrumental), ("offvocal", .instrumental),
        ("karaoke", .instrumental), ("カラオケ", .instrumental),
        ("inst", .instrumental), ("伴奏", .instrumental),
        ("纯音乐", .instrumental), ("純音樂", .instrumental), ("消音", .instrumental),
        // —— 不插电 ——
        ("unplugged", .acoustic), ("acoustic", .acoustic),
        ("アコースティック", .acoustic), ("不插电", .acoustic), ("不插電", .acoustic),
        // —— MV ——
        ("musicvideo", .mv), ("mv版", .mv), ("mv版本", .mv), ("mvver", .mv), ("mv", .mv),
        // —— Live ——
        ("liveversion", .live), ("livever", .live), ("live版", .live), ("live", .live),
        ("ライヴ", .live), ("ライブ", .live),
        ("现场", .live), ("現場", .live), ("实况", .live), ("實況", .live),
        ("演唱会", .live), ("演唱會", .live), ("concert", .live), ("在线演唱会", .live),
        // —— Remix / Mix ——
        ("remix", .remix), ("rmx", .remix), ("リミックス", .remix), ("混音", .remix),
        ("mix", .remix),
        // —— 重制 ——
        ("remastered", .remaster), ("remaster", .remaster),
        ("リマスター", .remaster), ("重制", .remaster), ("重製", .remaster),
        // —— 加长 / 电台剪辑 ——
        ("extended", .extended), ("longversion", .extended), ("longver", .extended),
        ("radioedit", .radioEdit), ("radioversion", .radioEdit),
        // —— 翻唱 / Demo ——
        ("cover", .cover), ("翻唱", .cover), ("demo", .demo),
        // —— 泛版本（最后判）——
        ("version", .version), ("バージョン", .version),
        ("ver.", .version), ("ver_", .version), ("ver", .version),
        ("tvsize", .version), ("tvsizever", .version), ("shortver", .version),
    ]

    /// `feat.` 段的引导词。命中则整段归入 `featured`，不算版本后缀。
    /// 刻意**不收 `with`**：`(With Love)` 是曲名的一部分，收了就会把它剥掉。
    static let featKeywords = ["featuring", "feat.", "feat", "ft.", "ft"]

    // MARK: 解析

    /// 从曲名拆出 `(正题, 版本后缀, 合作艺术家)`。
    ///
    /// 覆盖的写法（全部有本地样本）：
    ///   `Family Song (Live At MUSIC STATION SUPER LIVE20171222)`
    ///   `恋 (Love) (Live At 第67回NHK红白歌合战)`
    ///   `恋 (2023 NHK SONGS现场)` · `光の跡 (2024 FNS歌谣祭现场)`
    ///   `Pop Virus (MV版)` · `読書 (Remix)` · `雨音 (House ver.)` · `KIDS (House ver_)`
    ///   `ギャグ (Inst_)` · `うちで踊ろう (Potluck Mix)` · `くだらないの中に (Live at YELLOW VOYAGE)`
    ///   `【Live】…` · `[Remastered]` · `曲名 -Live-` · `曲名 ～Live～`
    ///   `さらしもの(feat. PUNPEE)` → featured=["punpee"]
    static func parse(_ rawTitle: String?) -> VersionInfo {
        let title = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return VersionInfo(baseTitle: "", original: "") }

        var markers: [VersionMarker] = []
        var featured: [String] = []
        var keep = ""                    // 剥掉已识别段之后剩下的正题

        // ① 括号段。成对扫描，深度 >0 的内容先攒起来，遇到闭括号时整段判定。
        //    `《…》` 与 `「…」` 刻意不算括号 —— 它们在中日曲名里是正文的一部分
        //    （`Lemon (《Unnatural》日剧主题曲)`、`「君は天然色」`）。
        let openers: [Character: Character] = [
            "(": ")", "（": "）", "[": "]", "［": "］",
            "【": "】", "〔": "〕", "〈": "〉", "{": "}", "｛": "｝",
        ]
        var pending = ""
        var closer: Character?
        for ch in title {
            if closer == nil, let c = openers[ch] {
                closer = c; pending = ""; continue
            }
            if let c = closer, ch == c {
                let seg = pending.trimmingCharacters(in: .whitespaces)
                switch classify(seg) {
                case .marker(let m): markers.append(m)
                case .featured(let names): featured.append(contentsOf: names)
                case .keep:
                    // 不认识的段原样留回去（含它的括号），绝不吞字
                    keep += "(" + seg + ")"
                }
                closer = nil; pending = ""; continue
            }
            if closer != nil { pending.append(ch) } else { keep.append(ch) }
        }
        // 括号没闭合：把攒着的内容原样还回去，绝不吞字
        if closer != nil { keep += "(" + pending }

        // ② 破折号 / 波浪号包裹的尾缀：`曲名 -Live-` `曲名 ～Live～` `曲名 -Remix`
        keep = stripDashMarkers(keep, into: &markers)

        // ③ 尾部裸后缀：`曲名 Live` 这类不带任何包裹的写法**不处理** ——
        //    「Live」也可能是曲名的一部分（`Live and Let Die`），风险大于收益。

        var base = keep.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                       .trimmingCharacters(in: .whitespaces)
        // 剥空了（整首歌就叫「(Live)」？）就退回原标题，宁可不剥
        if base.isEmpty { base = title; markers.removeAll(); featured.removeAll() }

        return VersionInfo(baseTitle: base, markers: markers,
                           featured: featured, original: title)
    }

    // MARK: 单段判定

    enum SegmentVerdict {
        case marker(VersionMarker)
        case featured([String])
        case keep
    }

    static func classify(_ segment: String) -> SegmentVerdict {
        let seg = segment.trimmingCharacters(in: .whitespaces)
        guard !seg.isEmpty else { return .keep }
        let key = markerKey(seg)
        guard !key.isEmpty else { return .keep }

        // feat. 段：整段是合作艺术家。判据用**原始片段**上的严格前缀正则，
        // 不用归一键 —— 归一会压掉空格，`Ft Island`（乐队名）就会被当成 `ft. Island`。
        // `_` 是给文件名兜底的：`さらしもの(feat_ PUNPEE)` 是清洗过的写法。
        if seg.range(of: "^(feat|ft|featuring)[._\\s]",
                     options: [.regularExpression, .caseInsensitive]) != nil {
            let names = splitFeatured(seg)
            return names.isEmpty ? .keep : .featured(names)
        }

        // 版本关键词
        for (kw, kind) in keywordTable {
            let k = markerKey(kw)
            guard !k.isEmpty, key.contains(k) else { continue }
            // `mix` 太短，只在整段较短（≤ 24 个归一字符）时才认，
            // 免得把「Remix by 某某长长的一串」之外的正文误伤。
            if k == "mix" || k == "mv" || k == "ver" || k == "inst" {
                guard key.count <= 24 else { continue }
            }
            var m = VersionMarker(kind: kind, raw: seg)
            if kind == .live {
                let (event, date) = liveEventAndDate(seg)
                m.eventName = event; m.eventDate = date
            } else {
                m.qualifier = qualifierBefore(k, in: key)
            }
            return .marker(m)
        }
        return .keep
    }

    /// 版本关键词之前的限定词：`houseverX` → `house`、`tvsize` → nil（整段就是关键词）。
    static func qualifierBefore(_ key: String, in whole: String) -> String? {
        guard let r = whole.range(of: key) else { return nil }
        let head = String(whole[..<r.lowerBound])
        return head.isEmpty ? nil : head
    }

    /// 从 Live 段里抽出「场次名 + 日期」。
    ///
    /// 日期优先认 8 位 `20171222`（各源与用户文件里最常见），
    /// 其次认 `2017.12.22` / `2017-12-22`，最后退回 4 位年 `2017`。
    /// 场次名 = 整段去掉 `live at` 引导词与日期之后的归一残余。
    static func liveEventAndDate(_ segment: String) -> (event: String?, date: String?) {
        let key = markerKey(segment)
        var date: String?

        if let r = key.range(of: "(19|20)[0-9]{6}", options: .regularExpression) {
            let s = String(key[r])
            // 粗校验月份/日，挡掉「20171299」这类乱码
            let mm = Int(s.dropFirst(4).prefix(2)) ?? 0
            let dd = Int(s.suffix(2)) ?? 0
            if (1...12).contains(mm), (1...31).contains(dd) { date = s }
        }
        if date == nil, let r = key.range(of: "(19|20)[0-9]{2}", options: .regularExpression) {
            date = String(key[r])
        }

        var event = key
        for lead in ["liveat", "livein", "live版", "live", "现场", "現場", "实况", "實況"] {
            if let r = event.range(of: lead) {
                event.removeSubrange(r)
            }
        }
        if let d = date, let r = event.range(of: d) { event.removeSubrange(r) }
        event = event.trimmingCharacters(in: .whitespaces)
        return (event.isEmpty ? nil : event, date)
    }

    /// `feat. A, B & C` → ["a", "b", "c"]（归一后的）。
    static func splitFeatured(_ segment: String) -> [String] {
        var work = segment
        for kw in featKeywords {
            for form in [kw, kw.uppercased(), kw.capitalized] {
                if let r = work.range(of: form, options: [.caseInsensitive]) {
                    work = String(work[r.upperBound...]); break
                }
            }
        }
        return MatchScorer.artistTokens(work).filter { !$0.isEmpty }
    }

    /// 破折号 / 波浪号包裹的尾缀。`-Live-` `～Live～` `-Remix-` `- Live`。
    static func stripDashMarkers(_ title: String, into markers: inout [VersionMarker]) -> String {
        var work = title
        let patterns = [
            "\\s*[-‐‑–—－]\\s*([^-‐‑–—－]{1,40})\\s*[-‐‑–—－]\\s*$",   // -Live-
            "\\s*[~～〜]\\s*([^~～〜]{1,40})\\s*[~～〜]\\s*$",           // ～Live～
            "\\s+[-‐‑–—－]\\s*([^-‐‑–—－]{1,40})\\s*$",                 // - Live
        ]
        for p in patterns {
            guard let r = work.range(of: p, options: .regularExpression) else { continue }
            let whole = String(work[r])
            let inner = whole.trimmingCharacters(in: CharacterSet(charactersIn: " -‐‑–—－~～〜"))
            if case .marker(let m) = classify(inner) {
                markers.append(m)
                work = String(work[..<r.lowerBound])
                break
            }
        }
        return work
    }

    // MARK: 归一

    /// 版本后缀专用的归一：小写、全角 ASCII 转半角、去空白与标点。
    /// **假名一个都不折**（不做 `widthInsensitive`，否则半角片假名会被改写），
    /// 汉字做繁→简（`侧` 与 `側` 在各源之间混用）。
    static func markerKey(_ s: String) -> String {
        var work = ""
        work.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFF01...0xFF5E:                                  // 全角 ASCII → 半角
                work.unicodeScalars.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0x3000:                                           // 全角空格
                work.append(" ")
            default:
                work.unicodeScalars.append(u)
            }
        }
        if MatchScorer.containsCJK(work) {
            let m = NSMutableString(string: work) as CFMutableString
            if CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false) {
                work = m as String
            }
        }
        work = work.lowercased()
        var out = String.UnicodeScalarView()
        for u in work.unicodeScalars {
            // 保留 `.` 与 `_`：`ver.` / `ver_` 要靠它们和裸 `ver` 区分
            if CharacterSet.alphanumerics.contains(u) || u == "." || u == "_" {
                out.append(u)
            }
        }
        return String(out)
    }
}

// MARK: - 版本维度打分

public extension MatchScorer {

    /// 两个版本之间的贴合度，0…1。**0 表示可证伪的不匹配**（不同 Live 场次），
    /// 调用方据此额外乘一个重罚系数。
    ///
    /// 判据表（查询版本 → 候选版本）：
    ///
    /// | 查询 | 候选 | 分 | 说明 |
    /// |---|---|---|---|
    /// | 录音室 | 录音室 | 1.00 | |
    /// | 录音室 | 有后缀 | 0.30 | 用户要原版，给了 Live，是错的但不是另一首歌 |
    /// | 有后缀 | 录音室 | `studioFallbackScore` | **次优**：录音室版往往是唯一带译文的那份 |
    /// | Live   | Live（日期相同） | 1.00 | |
    /// | Live   | Live（日期不同） | **0.00** | 另一场，重罚 |
    /// | Live   | Live（场次名差很远） | 0.15 | |
    /// | 同类   | 同类（限定词不同） | 0.55 | `House ver.` vs `Piano ver.` |
    /// | 其余   | —— | Jaccard | 后缀集合重合度 |
    static let studioFallbackScore: Double = 0.55
    /// 版本维度判为「可证伪地不匹配」时，对总分的乘法重罚。
    /// 0.20 比时长的 0.55 狠得多 —— 时长差可能是源的元数据不准，
    /// 而「20171222 场」与「20171225 场」是两份**确定不同**的录音。
    static let versionMismatchPenalty: Double = 0.20

    static func versionSimilarity(_ candidateTitle: String?, query: VersionInfo) -> Double {
        let cand = VersionMarker.parse(candidateTitle)
        return versionSimilarity(cand, query)
    }

    static func versionSimilarity(_ cand: VersionInfo, _ query: VersionInfo) -> Double {
        if query.isStudio && cand.isStudio { return 1.0 }
        if query.isStudio { return 0.30 }
        if cand.isStudio { return studioFallbackScore }

        // 两边都有后缀：先把 Live 场次这条硬判据走完
        if query.kinds.contains(.live), cand.kinds.contains(.live) {
            if let qd = query.liveDate, let cd = cand.liveDate {
                if qd == cd { return 1.0 }
                // 一边只有年、一边有完整日期：年不同 → 不匹配；年相同 → 存疑。
                // 同一年里同一首歌唱过好几场（星野源 2017 年的 Family Song 有 4 场），
                // 所以年相同还要看场次名对不对得上，对不上就压到 0.15。
                let short = min(qd.count, cd.count)
                if String(qd.prefix(short)) != String(cd.prefix(short)) { return 0.0 }
                if let qe = query.liveEvent, let ce = cand.liveEvent, !qe.isEmpty, !ce.isEmpty {
                    return editSimilarity(qe, ce) < 0.5 ? 0.15 : 0.75
                }
                return 0.45
            }
            if let qe = query.liveEvent, let ce = cand.liveEvent, !qe.isEmpty, !ce.isEmpty {
                let s = editSimilarity(qe, ce)
                if s < 0.5 { return 0.15 }
                return 0.6 + 0.4 * s
            }
            // 一边没给场次信息：只知道「都是 Live」
            return 0.80
        }

        let inter = query.kinds.intersection(cand.kinds).count
        let union = query.kinds.union(cand.kinds).count
        guard union > 0 else { return 1.0 }
        var s = Double(inter) / Double(union)
        if inter == 0 { return 0.10 }          // (Remix) 对 (Inst.)：明确不是一份录音

        // 同类但限定词不同：House ver. vs Piano ver.
        let qq = Set(query.markers.compactMap(\.qualifier).filter { !$0.isEmpty })
        let cq = Set(cand.markers.compactMap(\.qualifier).filter { !$0.isEmpty })
        if !qq.isEmpty, !cq.isEmpty, qq.isDisjoint(with: cq) { s = min(s, 0.55) }
        return s
    }
}

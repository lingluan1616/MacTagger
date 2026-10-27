//
//  AppModel+AlbumMatch.swift
//  MacTagger — 专辑模式（按文件夹匹配）的界面状态机
//
//  与逐首模式的关系：**只在「怎么选候选」这一段不同，写入路径完全共用**。
//  匹配完成后照样先出复核清单（`AutoMatchReviewItem`，与逐首模式同一个行模型），
//  用户勾选后走 `performAutoMatchWrite` —— 记历史 → BatchEngine → 完整可撤销。
//  复核窗只是换了一种组织方式：按文件夹分组，组头能整组换一张专辑。
//
//  状态为什么放在单例里：`AppModel` 的存储属性不能在扩展里新增，
//  而任务要求本模式的状态独立成文件、不去动已定型的 AppModel 主体。
//  歌词模块的 `LyricsSettings.shared` 是同一套做法，此处保持一致。
//

import Foundation
import SwiftUI

// MARK: - 匹配方式

enum TagMatchMode: String, CaseIterable, Identifiable {
    /// 原有行为：每个文件各自联网搜索。
    case perTrack = "perTrack"
    /// 新行为：同目录的文件当成一张专辑整体匹配。
    case album    = "album"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .perTrack: return "逐首"
        case .album:    return "按文件夹（专辑模式）"
        }
    }

    var hint: String {
        switch self {
        case .perTrack:
            return "每个文件独立搜索。适合散装单曲；缺点是同名的 Live 版、Remix、翻唱、"
                 + "各种精选合辑会同时命中，单曲本身没有信息能把它们区分开。"
        case .album:
            return "同一个文件夹当作一张专辑整体匹配：先用文件夹名锁定专辑，再把组内文件"
                 + "对到该专辑的曲目表。Live 版和翻唱不在这张专辑的曲目表里，从源头写不进去。"
        }
    }
}

// MARK: - 复核清单模型

/// 复核窗里的一个文件夹组。
struct AlbumMatchGroupReview: Identifiable {
    var id: URL { folder }
    let folder: URL
    let folderName: String
    let context: FolderContext
    /// 全部候选专辑，按分降序。组头的下拉用它。
    var candidates: [AlbumCandidate]
    /// 当前选中的候选 id（`sourceID:albumID`）。nil = 整组未匹配。
    var chosenID: String?
    var items: [AutoMatchReviewItem]
    /// 整组被忽略时的原因。
    var ignoredReason: String?
    /// 正在为「换一张专辑」重算。
    var isReloading: Bool = false
    /// 本组收集专辑候选时的逐源结果条。组头的 chips 读它 ——
    /// 「网易云没这张专辑」和「网易云挂了」必须一眼分得开。
    var sourceOutcomes: [SourceOutcome] = []

    var chosen: AlbumCandidate? {
        guard let chosenID else { return nil }
        return candidates.first { $0.id == chosenID }
    }

    var fileCount: Int { items.count }
    var alignedCount: Int { items.filter { $0.status == .matched }.count }
    /// 真会写的行：逐字段排除干净的不算（见 `AutoMatchReviewItem.writesSomething`）。
    var acceptedCount: Int { items.filter { $0.accepted && $0.writesSomething }.count }
    var writableCount: Int { items.filter { $0.hasSomethingToWrite }.count }
    /// 本组逐字段的勾选统计，专辑卡「本组字段 ▾」菜单用它。
    var fieldTallies: [ReviewFieldTally] { ReviewFieldTally.make(items) }

    /// 组头右侧那一行：《专辑》艺术家 · 年份 · 对齐 n/m
    var headline: String {
        guard let c = chosen else { return ignoredReason ?? "未匹配到专辑" }
        var parts = ["《\(c.detail.displayTitle)》"]
        if let a = c.detail.artist { parts.append(a) }
        if let y = c.detail.year { parts.append(y) }
        parts.append("对齐 \(alignedCount)/\(fileCount)")
        return parts.joined(separator: " · ")
    }

    /// `SourceBootstrap` 是 @MainActor 隔离的，这个只给界面用的显示名跟着标注即可。
    @MainActor var sourceName: String? {
        chosen.map { SourceBootstrap.displayName($0.detail.sourceID) }
    }

    // MARK: 组级 diff（只读）
    //
    // 专辑/专辑艺术家/年份/封面**整组一模一样**，逐行重复一遍纯属噪音，
    // 所以在组头单独摆一行，行里只留每首各不相同的那些字段。

    /// 组内某字段的共同改动。原值不一致时如实说出有几种，不假装整齐。
    func commonChange(_ f: TagEdit.Field) -> (old: String, new: String, count: Int)? {
        let cs = items.compactMap { $0.change(f) }
        guard let first = cs.first else { return nil }
        let olds = Set(cs.map(\.oldValue))
        let news = Set(cs.map(\.newValue))
        let old = olds.count == 1 ? first.oldDisplay : "（\(olds.count) 种原值）"
        let new = news.count == 1 ? first.newDisplay : "（\(news.count) 种新值）"
        return (old, new, cs.count)
    }

    var albumChange: (old: String, new: String, count: Int)? { commonChange(.album) }
    var albumArtistChange: (old: String, new: String, count: Int)? { commonChange(.albumArtist) }
    var yearChange: (old: String, new: String, count: Int)? { commonChange(.year) }

    /// 整组共用的那份封面字节（数据层保证一组只下载一次）。
    /// **不看勾选**：它是专辑卡上那张大图，回答的是「这一组对到了哪张专辑」，
    /// 整组把封面关掉之后这张图仍然是判断专辑对不对的依据。
    var artworkData: Data? { items.first { $0.hasArtwork }?.artwork }
    /// 会被写入封面的文件数。**跟着勾选走** —— 卡上写「写入本组 N 个文件」，
    /// 用户把封面逐个关掉之后这个数不跟着降就是在说谎。
    var artworkFileCount: Int { items.filter { $0.acceptedArtwork != nil }.count }

    /// **只读展示**：组内文件原本就有的那张封面，用于组头「原 → 新」的对比小图。
    /// 与将写入的新封面逐字节相同就返回 nil —— 一模一样的两张图并排摆着只会让人以为改了什么。
    /// （BP-E：字节由 `probeExistingArtworks` 从磁盘读，每个文件夹只有一个文件带着。）
    var originalArtworkData: Data? {
        guard let orig = items.compactMap(\.originalArtwork).first else { return nil }
        if let new = artworkData, new == orig { return nil }
        return orig
    }
    /// 组内原本就带封面的文件数（磁盘真值，BO#8）。
    var originalArtworkFileCount: Int { items.filter { $0.existingArtwork?.hasArtwork == true }.count }

    /// 曲目表碟数。>1 时音轨列必须带碟号。
    var discCount: Int { chosen?.detail.discCount ?? 1 }

    /// 组头第二行的尾巴：整组一致的来源与曲目表规模。
    var trackTableSummary: String? {
        guard let c = chosen else { return nil }
        var s = "曲目表 \(c.detail.tracks.count) 首"
        if c.detail.discCount > 1 { s += " · \(c.detail.discCount) 碟" }
        return s
    }
}

/// 一次专辑模式匹配的完整结果。
struct AlbumMatchReview {
    var groups: [AlbumMatchGroupReview]
    var summary: BatchSummary
    var elapsed: TimeInterval

    var allItems: [AutoMatchReviewItem] { groups.flatMap(\.items) }
    var acceptedItems: [AutoMatchReviewItem] {
        allItems.filter { $0.accepted && $0.writesSomething }
    }
    var acceptedCount: Int { acceptedItems.count }
    var writableCount: Int { allItems.filter { $0.hasSomethingToWrite }.count }
    /// 底部脚注的「共 M 处」。随逐字段勾选实时变。
    var acceptedChangeTotal: Int { acceptedItems.reduce(0) { $0 + $1.acceptedChangeCount } }
    /// 全表逐字段的勾选统计，工具条上那个「全部字段 ▾」菜单用它。
    var fieldTallies: [ReviewFieldTally] { ReviewFieldTally.make(allItems) }
    var fileCount: Int { allItems.count }
    var alignedCount: Int { allItems.filter { $0.status == .matched }.count }
    var matchedGroupCount: Int { groups.filter { $0.chosenID != nil }.count }

    /// 整轮压成一条的逐源结果条（按文件夹聚合，不是按文件）。
    var sourceOutcomes: [SourceOutcome] {
        SourceOutcomeAggregator.merge(groups.map(\.sourceOutcomes))
    }

    /// 「本轮 QQ 3/3 失败（retcode -1310），已跳过」。某源失败率 ≥50% 才有。
    var sourceNote: String? {
        SourceOutcomeAggregator.batchNote(groups.map(\.sourceOutcomes))
    }
}

// MARK: - 状态与选项持久化

@MainActor
final class AlbumMatchStore: ObservableObject {

    static let shared = AlbumMatchStore()

    private enum Key {
        static let mode        = "MacTagger.match.mode"
        static let modeChosen  = "MacTagger.match.modeChosenByUser"
        static let ignoreTags  = "MacTagger.albumMatch.ignoreExistingTags"
        static let alignThresh = "MacTagger.albumMatch.alignThreshold"
    }

    /// 匹配方式。默认逐首；`presentAutoMatch` 会在检测到专辑式目录结构时自动切到专辑模式。
    @Published var mode: TagMatchMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }
    /// **修错库的钥匙**。默认关——大多数人的库标签是对的，
    /// 只有被别的工具写坏过的库才需要「一个字都不信」。
    @Published var ignoreExistingTags: Bool {
        didSet { UserDefaults.standard.set(ignoreExistingTags, forKey: Key.ignoreTags) }
    }
    /// 单文件对到某首曲目的最低分。
    @Published var alignThreshold: Double {
        didSet { UserDefaults.standard.set(alignThreshold, forKey: Key.alignThresh) }
    }

    /// 非 nil 即由复核窗接管显示（`AutoMatchReviewSheet` 会分发过去）。
    @Published var review: AlbumMatchReview?
    @Published var isMatching = false

    /// 换专辑时要重新对齐，得留着原始分组与草稿标签。不参与界面刷新，故不加 @Published。
    var groupsByFolder: [URL: FolderGroup] = [:]
    var drafts: [URL: Tags] = [:]
    /// 本轮读到的「文件里现有的封面」（BO#8）。换专辑整组重建复核行时还要用，所以留着。
    var existingArtworks = ExistingArtworkProbe()
    var lastOptions: AlbumMatchOptions = .recommended

    /// 用户是否亲手选过模式。没选过时，选项窗会按目录结构自动挑一个默认值；
    /// 一旦亲手选过就永远尊重他的选择，不再自作主张改回去。
    private(set) var userChoseMode: Bool

    private init() {
        let d = UserDefaults.standard
        mode = TagMatchMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .perTrack
        userChoseMode = d.bool(forKey: Key.modeChosen)
        ignoreExistingTags = d.object(forKey: Key.ignoreTags) as? Bool ?? false
        alignThreshold = d.object(forKey: Key.alignThresh) as? Double ?? 0.5
    }

    /// 用户在分段控件上亲手选的。
    func chooseMode(_ m: TagMatchMode) {
        userChoseMode = true
        UserDefaults.standard.set(true, forKey: Key.modeChosen)
        mode = m
    }

    /// 选项窗打开时按目录结构挑默认模式：所有选中文件都摆成
    /// 「文件夹 = 专辑」的样子时默认走专辑模式，那正是用户的典型库形态。
    func autoSelectMode(albumLike: Bool) {
        guard !userChoseMode else { return }
        mode = albumLike ? .album : .perTrack
    }

    func reset() {
        review = nil
        groupsByFolder = [:]
        drafts = [:]
        existingArtworks = ExistingArtworkProbe()
    }
}

// MARK: - 状态机

extension AppModel {

    var albumMatch: AlbumMatchStore { AlbumMatchStore.shared }

    /// 交给数据层的专辑模式选项。源、阈值、字段白名单、封面全部沿用自动匹配那套设置，
    /// 只有「忽略现有标签」和对齐阈值是专辑模式独有的。
    var albumMatchOptions: AlbumMatchOptions {
        let s = autoMatchSettings
        var o = AlbumMatchOptions(
            ignoreExistingTags: albumMatch.ignoreExistingTags,
            sourceIDs: s.activeSourceIDs,
            acceptThreshold: s.acceptThreshold,
            alignAcceptThreshold: albumMatch.alignThreshold,
            fields: s.isEveryFieldEnabled ? nil : s.fieldSet,
            fetchArtwork: s.fetchArtwork,
            artworkSize: s.artworkSize,
            limitPerSource: s.limitPerSource)
        // ★ BJ 轮：专辑模式的歌词开关**完全沿用逐首那一套**，没有第二处设置。
        // 两个闸任意一个关着就不取词：
        //  · 「下载歌词」（`fetchLyrics`）—— 用户压根不要词；
        //  · 字段白名单里的「歌词」（`isFieldEnabled(.lyrics)`）—— 要词但这一轮不写它，
        //    那就连请求都不该发（发了也只会被复核表滤掉）。
        o.fetchLyrics = s.fetchLyrics && s.isFieldEnabled(.lyrics)
        o.concurrency = s.concurrency
        return o
    }

    /// 选中的这批文件像不像「按专辑摆好的目录」——决定选项窗默认落在哪个模式。
    var targetsLookLikeAlbums: Bool {
        AlbumMatchService.looksLikeAlbumLayout(autoMatchTargets.map { row -> AudioFile in
            var f = row.file
            f.tags = row.draft
            return f
        })
    }

    // MARK: 开始匹配

    func startAlbumMatch() {
        let rows = autoMatchTargets
        guard !rows.isEmpty else { return }
        let options = albumMatchOptions
        guard !options.sourceIDs.isEmpty else {
            alert = AlertBox(title: "无法开始自动匹配",
                             message: "请至少勾选一个标签来源。", isError: true)
            return
        }
        if refuseWhileBusy() { return }
        // 兜底（BO#16）：还有待读行时后台补读（有进度、可取消），读完再开工。
        if rows.contains(where: { $0.tagsState.isPending }) {
            Task { [weak self] in
                guard let self else { return }
                if await self.materializePendingTagsInBackground(in: rows, title: "专辑匹配前补读标签…") {
                    self.startAlbumMatch()
                }
            }
            return
        }

        // 用工作副本的标签建 AudioFile：用户刚敲进去还没保存的改动也算数。
        // （`ignoreExistingTags` 为真时数据层根本不看这些标签，这里照传不影响。）
        let files: [AudioFile] = rows.map { row in
            var f = row.file
            f.tags = row.draft
            return f
        }
        let drafts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.draft) })
        let groups = AlbumMatchService.groupByFolder(files)

        albumMatch.groupsByFolder = Dictionary(uniqueKeysWithValues: groups.map { ($0.directory, $0) })
        albumMatch.drafts = drafts
        albumMatch.lastOptions = options
        albumMatch.existingArtworks = ExistingArtworkProbe()
        // BO#8：复核表要知道「文件现在有没有封面」。只在这一轮会下封面时才去读。
        let artPlan = options.fetchArtwork
            ? existingArtworkPlan(for: rows) : (known: [URL: ExistingArtworkInfo](), toRead: [URL]())

        autoMatchRunID &+= 1
        let runID = autoMatchRunID

        isBusy = true
        isAutoMatching = true
        albumMatch.isMatching = true
        progressTitle = "按文件夹匹配专辑…"
        progress = BatchProgress(completed: 0, total: files.count)
        statusMessage = "正在按 \(groups.count) 个文件夹联网匹配专辑…"
        cancelHandler = { [weak self] in self?.cancelAlbumMatch() }

        autoMatchTask = Task { [weak self] in
            let started = Date()
            // 与联网匹配并行读现有封面（本地 IO vs 等网络），取消一路传下去。
            async let probed = AppModel.probeExistingArtworks(artPlan.toRead)
            let (results, summary) = await AlbumMatchService.matchAll(groups, options: options) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.autoMatchRunID == runID else { return }
                    self.progress = p
                }
            }
            var existing = await probed
            existing.info.merge(artPlan.known) { disk, _ in disk }
            let elapsed = Date().timeIntervalSince(started)
            let finalExisting = existing
            await MainActor.run {
                guard let self, runID == self.autoMatchRunID else { return }
                self.albumMatch.existingArtworks = finalExisting
                self.finishAlbumMatch(runID: runID, results: results,
                                      summary: summary, elapsed: elapsed)
            }
        }
    }

    func cancelAlbumMatch() {
        guard isAutoMatching else { return }
        autoMatchRunID &+= 1
        autoMatchTask?.cancel()
        autoMatchTask = nil
        isAutoMatching = false
        albumMatch.isMatching = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        statusMessage = "已取消专辑模式匹配"
    }

    private func finishAlbumMatch(runID: Int,
                                  results: [AlbumMatchResult],
                                  summary: BatchSummary,
                                  elapsed: TimeInterval) {
        guard runID == autoMatchRunID else { return }
        isAutoMatching = false
        albumMatch.isMatching = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        autoMatchTask = nil

        var groups: [AlbumMatchGroupReview] = []
        for r in results {
            groups.append(AlbumMatchGroupReview(
                folder: r.folder,
                folderName: r.folder.lastPathComponent,
                context: r.context,
                candidates: r.albumCandidates,
                chosenID: r.chosen?.id,
                items: r.perFile.map { makeAlbumReviewItem(from: $0, detail: r.chosen?.detail) },
                ignoredReason: r.ignoredReason,
                sourceOutcomes: r.sourceOutcomes))
        }
        // 匹配上的组排前面，同状态下按对齐率降序
        groups.sort { a, b in
            let ac = a.chosenID != nil, bc = b.chosenID != nil
            if ac != bc { return ac }
            return a.alignedCount > b.alignedCount
        }

        let review = AlbumMatchReview(groups: groups, summary: summary, elapsed: elapsed)
        albumMatch.review = review

        // ContentView 的复核 sheet 由 `autoMatchReview` 驱动（那份界面代码已定型不动），
        // 这里同时挂上一份**摊平**的清单：sheet 因此能弹出来，
        // 而 `AutoMatchReviewSheet` 看到 albumMatch.review 非 nil 就转交给专辑版复核窗。
        autoMatchReview = AutoMatchReview(items: review.allItems,
                                          summary: summary,
                                          elapsed: elapsed)
        var note = "专辑模式匹配完成 —— \(review.matchedGroupCount)/\(groups.count) 个文件夹锁定了专辑，"
            + "\(review.alignedCount)/\(review.fileCount) 个文件对齐"
        if let sn = review.sourceNote { note += "；" + sn }
        statusMessage = note
    }

    /// 把数据层的逐文件结果转成复核行。字段差异的口径与逐首模式完全一致。
    ///
    /// `detail` 是整组锁定的那张专辑的曲目表。它只用来算**音轨列怎么显示**：
    /// 双碟 OST 两张碟各有第 7 首，写入值都是「7/本碟曲目数」，光看 `TRACKNUMBER`
    /// 两行仍然长得一样，必须带上碟号才成为「1-07/24」「2-07/21」。写入值不受影响。
    private func makeAlbumReviewItem(from r: AutoMatchResult,
                                     detail: AlbumDetail?) -> AutoMatchReviewItem {
        let current = albumMatch.drafts[r.url] ?? Tags()
        var changes: [AutoMatchFieldChange] = []
        for c in r.edit?.changes ?? [] {
            guard let newValue = c.value, !newValue.isEmpty else { continue }
            let old = AppModel.tagValue(c.field, in: current)
            // 等价判定（碟号裸 1 ≡ 1/1）与逐首模式共用，见 AppModel+AutoMatch。
            guard !AppModel.isEquivalentTagValue(c.field, old, newValue) else { continue }
            changes.append(AutoMatchFieldChange(field: c.field, oldValue: old, newValue: newValue))
        }

        // ★ BJ 轮：歌词是二段式单独取回来的（`AutoMatchResult.lyrics`），候选本身不带，
        // 这里并进同一张改动表 —— 与逐首模式 `finishAutoMatch` 里那一段**逐字同款**。
        //
        // 覆盖语义也一并对齐：`old != text` 这把尺子天然覆盖了
        // 「文件里已有一份无译文歌词 → 新结果含译文」—— 合并后的文本必然与旧的纯原文不同，
        // 于是它就是一处改动，照常进复核表、照常可以取消勾选。
        let lyricsAllowed = autoMatchSettings.isFieldEnabled(.lyrics)
        let merge = autoMatchLyricsMerge
        if lyricsAllowed,
           let text = merge.merged(r.lyrics)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let old = AppModel.tagValue(.lyrics, in: current)
            if old != text {
                changes.removeAll { $0.field == .lyrics }
                changes.append(AutoMatchFieldChange(field: .lyrics, oldValue: old, newValue: text))
            }
        }

        let matched = r.status == .matched
        let art = matched ? r.artwork : nil
        let pos = AppModel.trackPosition(of: r.best, in: detail)
        let existing = albumMatch.existingArtworks
        var item = AutoMatchReviewItem(
            url: r.url,
            fileName: r.url.lastPathComponent,
            status: r.status,
            bestTitle: r.best?.title,
            bestArtist: r.best?.artist,
            bestAlbum: r.best?.album,
            sourceID: r.best?.sourceID,
            sourceName: r.best.map { SourceBootstrap.displayName($0.sourceID) },
            score: r.best?.matchScore ?? 0,
            candidateCount: r.candidateCount,
            triedSources: r.triedSources,
            errorText: r.status == .matched ? nil
                : r.errors.map(\.message).joined(separator: "\n").nilIfBlank,
            changes: changes,
            artwork: art,
            // BO#8：原封面按磁盘真值（`current` 是行草稿，封面早被清空，永远是 nil）。
            originalArtwork: existing.previews[r.url],
            existingArtwork: existing.info[r.url],
            artworkWritesTag: ArtworkPolicy.current.writesTag,
            accepted: matched && (!changes.isEmpty || art != nil),
            lyricsHasTranslation: lyricsAllowed && merge.producesTranslation(r.lyrics),
            current: AppModel.displaySnapshot(current),
            trackNumberInDisc: pos.track,
            discNumber: pos.disc,
            discCount: pos.discCount,
            tracksInDisc: pos.tracksInDisc,
            candidates: r.candidates,
            selectedCandidateID: r.best?.id ?? r.candidates.first?.id,
            sourceOutcomes: r.sourceOutcomes)
        // 默认全勾（= 本次会改动的字段全集），与逐首模式同一口径；
        // 封面只在文件里原本没有时默认勾（BO#8）。
        item.resetAcceptedFields()
        return item
    }

    /// 从「对到的那首曲目」还原它在专辑里的位置。
    ///
    /// 数据层给的 `TrackCandidate` 里，音轨号写作「该碟内序号/该碟曲目数」（如 `7/21`）、
    /// 碟号写作 `1/2`（见 `AlbumDetail.candidate(for:)`），取前半段即可；
    /// 本碟曲目数则由曲目表按 `disc` 分组数出来 —— 源不给碟号时全表都是 disc 1，
    /// 结果自然退回单碟形态，与原先显示一致。
    static func trackPosition(of best: TrackCandidate?, in detail: AlbumDetail?)
        -> (track: Int?, disc: Int?, discCount: Int, tracksInDisc: Int) {

        func leadingInt(_ s: String?) -> Int? {
            guard let s else { return nil }
            let head = s.prefix { $0.isNumber }
            return head.isEmpty ? nil : Int(head)
        }
        let track = leadingInt(best?.trackNumber)
        let disc = leadingInt(best?.discNumber)
        guard let detail else {
            return (track, disc, max(1, detail?.discCount ?? 1), 0)
        }
        let perDisc = Dictionary(grouping: detail.tracks, by: \.disc).mapValues(\.count)
        let discCount = max(detail.discCount, perDisc.keys.max() ?? 1)
        let tracksInDisc = perDisc[disc ?? 1] ?? detail.tracks.count
        return (track, disc, max(1, discCount), tracksInDisc)
    }

    // MARK: 换一张专辑

    /// 组头下拉换专辑：重新对齐整组并刷新该组的每一行。
    func changeAlbum(folder: URL, to candidateID: String) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let group = albumMatch.groupsByFolder[folder],
              let candidate = albumMatch.review?.groups[gi].candidates.first(where: { $0.id == candidateID })
        else { return }

        albumMatch.review?.groups[gi].isReloading = true
        let options = albumMatch.lastOptions
        let context = albumMatch.review?.groups[gi].context ?? group.context

        Task { [weak self] in
            let (_, perFile) = await AlbumMatchService.apply(album: candidate,
                                                            group: group,
                                                            context: context,
                                                            options: options)
            await MainActor.run {
                guard let self,
                      let gi = self.albumMatch.review?.groups.firstIndex(where: { $0.folder == folder })
                else { return }
                self.albumMatch.review?.groups[gi].items = perFile.map {
                    self.makeAlbumReviewItem(from: $0, detail: candidate.detail)
                }
                self.albumMatch.review?.groups[gi].chosenID = candidate.id
                self.albumMatch.review?.groups[gi].ignoredReason = nil
                self.albumMatch.review?.groups[gi].isReloading = false
                self.syncFlattenedReview()
                self.statusMessage = "已换成《\(candidate.detail.displayTitle)》，"
                    + "重新对齐 \(perFile.filter { $0.status == .matched }.count)/\(perFile.count) 个文件"
            }
        }
    }

    // MARK: 换候选 / 行内手动搜索（专辑模式）

    /// 换掉**某一行**对到的曲目。候选来自同一张专辑的曲目表（`AlbumMatchService.alternatives`），
    /// 因此切换是**离线瞬时**的 —— 专辑模式的误配几乎全是「对到了邻近的另一首」，
    /// 答案本来就在这张曲目表里，一次请求都不用发。
    /// 要跳出这张专辑另找，用同一行的「手动搜索…」。
    func changeAlbumCandidate(folder: URL, url: URL, to candidateID: UUID) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let ii = albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
        else { return }
        let item = albumMatch.review!.groups[gi].items[ii]
        guard let cand = item.candidates.first(where: { $0.id == candidateID }) else { return }

        let current = albumMatch.drafts[url] ?? Tags()
        let detail = albumMatch.review!.groups[gi].chosen?.detail
        let fields = albumMatch.lastOptions.fields
        // 整组共用的那份封面：换的是曲目不是专辑，封面不该跟着变。
        let cover = albumMatch.review!.groups[gi].artworkData

        let lyricsAllowed = autoMatchSettings.isFieldEnabled(.lyrics)
        let merge = autoMatchLyricsMerge
        let options = albumMatch.lastOptions

        let rebuilt = AppModel.rebuildItem(item, with: cand, current: current,
                                           artwork: item.hasArtwork ? item.artwork : cover,
                                           lyrics: nil, fields: fields, detail: detail,
                                           lyricsAllowed: lyricsAllowed,
                                           merge: merge)
        albumMatch.review?.groups[gi].items[ii] = rebuilt
        syncFlattenedReview()

        // ★ BJ 轮：字段是离线瞬时换的（上面那一句），**歌词换不了** ——
        // 换的是另一首曲目，词当然也是另一首的，只能重新联网取。
        // 于是分两拍：先把字段就地换掉（用户马上看到结果），再补一发取词，
        // 回来时把这一行连歌词一起重算。不这么做的话，换完候选那一行的歌词
        // 要么是**上一首的**（更糟），要么整个消失。
        if options.fetchLyrics, lyricsAllowed {
            albumMatch.review?.groups[gi].items[ii].isReloading = true
            let lyricsOptions = options.lyricsFetchOptions
            let variant = options.chineseVariant
            Task { [weak self] in
                let fetched = await AutoMatchService.fetchLyricsForCandidate(cand,
                                                                            options: lyricsOptions)
                await MainActor.run {
                    guard let self,
                          let gi = self.albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
                          let ii = self.albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
                    else { return }
                    let now = self.albumMatch.review!.groups[gi].items[ii]
                    var updated = AppModel.rebuildItem(now, with: cand, current: current,
                                                       artwork: now.artwork,
                                                       lyrics: fetched.bundle?.converted(to: variant),
                                                       fields: fields, detail: detail,
                                                       lyricsAllowed: lyricsAllowed,
                                                       merge: merge)
                    updated.isReloading = false
                    self.albumMatch.review?.groups[gi].items[ii] = updated
                    self.syncFlattenedReview()
                }
            }
        }

        statusMessage = "已改对到《\(cand.title ?? "?")》"
            + (rebuilt.trackPositionDisplay.map { "（\($0)）" } ?? "") + "，本行已自动勾选"
    }

    /// 专辑模式的行内手动搜索：跳出这张专辑，对这一行单独联网重搜。
    func manualSearchAlbum(folder: URL, url: URL, query: ManualSearchQuery) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let ii = albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url }),
              !query.isEmpty else { return }

        let options = autoMatchSettings.options
        albumMatch.review?.groups[gi].items[ii].isReloading = true
        albumMatch.review?.groups[gi].items[ii].manualQuery = query
        let current = albumMatch.drafts[url] ?? Tags()
        let lyricsAllowed = autoMatchSettings.isFieldEnabled(.lyrics)
        // 专辑模式下手动搜来的这一首同样要合译文（口径与逐首模式共用一处）。
        let merge = autoMatchLyricsMerge

        Task { [weak self] in
            let (found, outcomes) = await AutoMatchService.searchCandidates(query.trackQuery,
                                                                           options: options)
            var e: (candidate: TrackCandidate, artwork: Data?, lyrics: LyricsBundle?)?
            if let first = found.first { e = await AutoMatchService.enrich(first, options: options) }
            await MainActor.run {
                guard let self,
                      let gi = self.albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
                      let ii = self.albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
                else { return }
                self.albumMatch.review?.groups[gi].items[ii].isReloading = false
                self.albumMatch.review?.groups[gi].items[ii].sourceOutcomes = outcomes
                guard let best = found.first, let e else {
                    self.statusMessage = "手动搜索没有结果 —— " + outcomes.inlineSummary
                    self.syncFlattenedReview()
                    return
                }
                var item = self.albumMatch.review!.groups[gi].items[ii]
                var picked = e.candidate
                picked.id = best.id
                picked.matchScore = best.matchScore
                item.candidates = AppModel.mergeCandidates(item.candidates, [picked] + found.dropFirst())
                item.candidateCount = item.candidates.count
                // 手动搜来的曲目不属于这张专辑，音轨位置不能再按专辑曲目表算 → detail 传 nil。
                item = AppModel.rebuildItem(item, with: picked, current: current,
                                            artwork: e.artwork ?? item.artwork,
                                            lyrics: e.lyrics, fields: options.fields,
                                            detail: nil, lyricsAllowed: lyricsAllowed,
                                            merge: merge)
                self.albumMatch.review?.groups[gi].items[ii] = item
                self.syncFlattenedReview()
                self.statusMessage = "已换成《\(picked.title ?? "?")》— \(picked.artist ?? "?")"
                    + "（\(SourceOutcome.displayName(picked.sourceID))），本行已自动勾选"
            }
        }
    }

    // MARK: 勾选

    func setAlbumItemAccepted(folder: URL, url: URL, _ on: Bool) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let ii = albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
        else { return }
        albumMatch.review?.groups[gi].items[ii].accepted = on
        syncFlattenedReview()
    }

    // MARK: 逐字段勾选（按文件选写哪几个字段）
    //
    // 与逐首模式共用 `AutoMatchReviewItem` 上的同一份状态，只是作用域从
    // 「全表 / 展示组」换成了「全表 / 文件夹组」。改完照例 `syncFlattenedReview()`，
    // 让摊平那份清单跟着走 —— 「放弃专辑模式 → 落回逐首复核窗」时排除才不会丢。

    /// 一个文件的一个写入项。
    func setAlbumField(folder: URL, url: URL, _ key: ReviewFieldKey, _ on: Bool) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let ii = albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
        else { return }
        albumMatch.review?.groups[gi].items[ii].setAccepted(key, on)
        syncFlattenedReview()
    }

    /// 点一下 chip：排除 ↔ 恢复。
    func toggleAlbumField(folder: URL, url: URL, _ key: ReviewFieldKey) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }),
              let ii = albumMatch.review?.groups[gi].items.firstIndex(where: { $0.id == url })
        else { return }
        let now = albumMatch.review!.groups[gi].items[ii].isAccepted(key)
        albumMatch.review?.groups[gi].items[ii].setAccepted(key, !now)
        syncFlattenedReview()
    }

    /// 一整组的一个写入项 —— 「这张专辑整组不写碟号」。
    func setAlbumGroupField(folder: URL, _ key: ReviewFieldKey, _ on: Bool) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }) else { return }
        for i in albumMatch.review!.groups[gi].items.indices {
            albumMatch.review!.groups[gi].items[i].setAccepted(key, on)
        }
        syncFlattenedReview()
    }

    /// 整张复核表的一个写入项 —— 「一次性去掉所有音轨号」。
    func setAlbumFieldForAll(_ key: ReviewFieldKey, _ on: Bool) {
        guard albumMatch.review != nil else { return }
        for g in albumMatch.review!.groups.indices {
            for i in albumMatch.review!.groups[g].items.indices {
                albumMatch.review!.groups[g].items[i].setAccepted(key, on)
            }
        }
        syncFlattenedReview()
    }

    func setGroupAccepted(folder: URL, _ on: Bool) {
        guard let gi = albumMatch.review?.groups.firstIndex(where: { $0.folder == folder }) else { return }
        for i in albumMatch.review!.groups[gi].items.indices
        where albumMatch.review!.groups[gi].items[i].hasSomethingToWrite {
            albumMatch.review!.groups[gi].items[i].accepted = on
        }
        syncFlattenedReview()
    }

    func setAllAlbumAccepted(_ on: Bool) {
        guard albumMatch.review != nil else { return }
        for g in albumMatch.review!.groups.indices {
            for i in albumMatch.review!.groups[g].items.indices
            where albumMatch.review!.groups[g].items[i].hasSomethingToWrite {
                albumMatch.review!.groups[g].items[i].accepted = on
            }
        }
        syncFlattenedReview()
    }

    /// 摊平清单跟着组内改动走，保证「放弃 → 落回逐首复核窗」时数据仍然一致。
    private func syncFlattenedReview() {
        guard let r = albumMatch.review else { return }
        autoMatchReview = AutoMatchReview(items: r.allItems, summary: r.summary, elapsed: r.elapsed)
    }

    func discardAlbumMatchReview() {
        albumMatch.reset()
        autoMatchReview = nil
        statusMessage = "已放弃本次专辑模式匹配结果"
    }

    // MARK: 写入

    /// 写入路径与逐首模式**完全共用** —— 记历史 → BatchEngine → 可完整撤销。
    func applyAlbumMatchSelection() {
        guard let review = albumMatch.review else { return }
        let picked = review.acceptedItems
        guard !picked.isEmpty else {
            statusMessage = "没有勾选任何可写入的项"
            return
        }
        // 忙时不开工，复核表也别关（结果留着，等一下再点「应用」）。
        if refuseWhileBusy() { return }
        albumMatch.reset()
        autoMatchReview = nil
        performAutoMatchWrite(picked)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

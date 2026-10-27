//
//  AppModel+AutoMatch.swift
//  MacTagger — 自动匹配标签的界面状态机
//
//  对应原版 FormAutoMatchTags。流程刻意分成两段：
//      联网匹配 → **结果复核** → 写入
//  中间那一段不能省：自动匹配会选错（实测抓到过合辑翻唱以 0.885 压过原版），
//  而标签一旦被改坏就是不可逆的用户数据损失。所以匹配结束只产出一张待办清单，
//  用户逐行复核勾选后才走真正的写入路径（写入前记历史 → 可撤消）。
//

import Foundation
import SwiftUI

// MARK: - 组级字段口径（**纯展示**，写入路径一个字都不看它）
//
// ── 为什么要分级 ──
// 专辑 / 专辑艺术家 / 年份 / 流派 / 封面（单碟时还有碟号）在一组里是**同一个值**：
// 一组 11 首，行内 chips 就把「专辑·专辑艺术家·年份·封面」重复 11 遍，
// 而重复的东西不携带信息 —— 它只会把每首各不相同的那几个字段（标题、音轨号、歌词）淹掉。
//
// 所以这些字段归**专辑卡的组级摘要**说一次，行里不再出现；
// 只有当某一行在这些字段上**与组级值不同**（被换候选换去了别的专辑、原本自带另一张封面），
// 才在那一行单列一枚**橙色** chip。于是判读规则简化成一句：
// **行里出现橙色 = 这一行不随大流，别的行都按专辑卡上写的办。**

/// 一组的组级字段快照。两个复核窗各自从自己的分组模型构造它，再传给每一行。
struct ReviewGroupContext {

    /// 组级新值（只含整组确实会改的字段）。取组内的多数派值。
    var values: [TagEdit.Field: String] = [:]
    /// 组内新值不止一种的字段 → 有几种。组级摘要那一格写作「（2 种新值）」，
    /// 具体是哪一行跑偏，由那一行的橙 chip 指出来。
    var distinctValueCount: [TagEdit.Field: Int] = [:]
    /// 组内**真会被写入**的曲目数。摘要末尾那句「以上应用到本组 N 首」用它 ——
    /// 用可写入数而不是总数：未对齐的那几行一个字段都不会写，把它们算进去就是说谎，
    /// 也会和封面那句「写入本组 4 个文件」当场对不上。
    var trackCount: Int = 0
    /// 多碟专辑。碟号此时**每首可能不同**，退回逐首字段留在行里。
    var isMultiDisc: Bool = false
    /// 组级封面字节。行内封面与它相同就不再重复摆一遍。
    var artwork: Data?

    /// **专辑卡摘要真会印出来的那几个字段**，顺序即摘要里的顺序。
    /// 行内那几枚橙色「≠ 组」chip 也只拿这几个字段去比 —— 卡上没这一格，就没有「组级值」可言。
    var summarized: [TagEdit.Field] = []

    /// **行内 chips 要折掉的字段**。`summarized` 是它的子集。
    ///
    /// 两者只差在「组内一行都不改的那几个」上：不改就压根没有 chip 可丢，
    /// 折掉只是省下一枚说「本次不动」的灰胶囊 —— 而这句话已经由专辑卡整体负责了。
    /// 未匹配组那张灰卡一条摘要都不印，于是两串都是空的，
    /// 那几行的 chips 与改造前一模一样，不会有字段凭空消失。
    var folded: [TagEdit.Field] = []

    /// 专辑级字段的候选池。碟号只在单碟时算专辑级（多碟每首不同，是逐首字段）。
    static let albumLevelPool: [TagEdit.Field] = [.album, .albumArtist, .year, .genre, .disc]

    /// 「以上应用到本组 5 首」。组里一首都写不了就不摆这句。
    var footnote: String? {
        trackCount > 0 ? "以上应用到本组 \(trackCount) 首" : nil
    }

    /// - Parameter summarizes: 这一组会不会画组级 diff 摘要。未匹配组传 false。
    static func make(items: [AutoMatchReviewItem], artwork: Data?,
                     summarizes: Bool = true) -> ReviewGroupContext {
        var ctx = ReviewGroupContext()
        // 逐字段排除之后一个字都不写的行不算数 —— 摘要末尾那句
        // 「以上应用到本组 N 首」得跟着勾选走，否则它会比封面那句「写入本组 4 个文件」多。
        ctx.trackCount = items.filter(\.writesSomething).count
        ctx.artwork = artwork
        // 多碟判定走两条路：专辑模式有曲目表（discCount），逐首模式没有 ——
        // 那就看组内要写的碟号值是不是不止一种，双碟 OST 自然露出「1/2」「2/2」两种。
        let discNews = items.compactMap { $0.change(.disc)?.newValue }
        ctx.isMultiDisc = items.contains { $0.discCount > 1 } || Set(discNews).count > 1

        for f in ReviewGroupContext.albumLevelPool {
            if f == .disc && ctx.isMultiDisc { continue }
            let news = items.compactMap { $0.change(f)?.newValue }
            guard !news.isEmpty else { continue }
            // 组级值取**多数派**：这样「与组不同」的正是少数派那几行，
            // 橙 chip 才指得准 —— 若取第一条，换过候选的那一行反倒会把全组都染橙。
            var tally: [String: Int] = [:]
            for n in news { tally[n, default: 0] += 1 }
            var best = news[0]
            var bestCount = 0
            for n in news where (tally[n] ?? 0) > bestCount {
                best = n
                bestCount = tally[n] ?? 0
            }
            ctx.values[f] = best
            let kinds = Set(news).count
            if kinds > 1 { ctx.distinctValueCount[f] = kinds }
        }

        // 摘要印什么：身份三件（专辑/专辑艺术家/年份）无论改不改都占一格 ——
        // 「整组都不改动」本身就是复核结论；流派与碟号只在真会改时才占格，
        // 免得把 176 pt 的卡片撑爆。
        if summarizes {
            ctx.summarized = [.album, .albumArtist, .year]
            ctx.folded = [.album, .albumArtist, .year, .genre]
            // 碟号：单碟才是专辑级；多碟每首不同，留在行里。
            if !ctx.isMultiDisc { ctx.folded.append(.disc) }
            for f in [TagEdit.Field.genre, .disc]
            where ctx.values[f] != nil && ctx.folded.contains(f) {
                ctx.summarized.append(f)
            }
        }
        return ctx
    }
}

// MARK: - 专辑卡上「封面」那一格与那句提醒（两张复核表共用，BP-E / BO#8）
//
// 原先两边都调 `AlbumCardDiff.artwork(new:old:count:)`，而 `old` 取的是被清空的草稿封面，
// 于是卡上永远是「封面（空）→ 300×300」。这里按磁盘真值说话，而且把**默认不写**说出来 ——
// 已有封面的文件默认不勾封面，卡上不说的话，用户会以为这张新封面整组都会写进去。

enum ReviewArtworkSummary {

    /// 组内「新封面会替换掉音频里现有封面」的那些行（不看勾选）。
    static func replacing(_ items: [AutoMatchReviewItem]) -> [AutoMatchReviewItem] {
        items.filter(\.replacesExistingArtwork)
    }

    /// 现有封面尺寸的概括：「1200×1200」「2 种尺寸」；一张都没读到尺寸时 nil。
    static func existingSizeText(_ items: [AutoMatchReviewItem]) -> String? {
        let sizes = Set(items.compactMap { $0.existingArtwork?.sizeText })
        switch sizes.count {
        case 0:  return nil
        case 1:  return sizes.first
        default: return "\(sizes.count) 种尺寸"
        }
    }

    /// 「将替换现有封面（原 1200×1200）」。组内没有会替换的行时 nil。
    static func replaceText(_ items: [AutoMatchReviewItem]) -> String? {
        let r = replacing(items)
        guard !r.isEmpty else { return nil }
        return "将替换现有封面" + (existingSizeText(r).map { "（原 \($0)）" } ?? "")
    }

    /// 专辑卡上那句橙色提醒。组内没有会替换现有封面的行时 nil。
    static func cardNote(_ items: [AutoMatchReviewItem]) -> String? {
        let r = replacing(items)
        guard let head = replaceText(items) else { return nil }
        let on = r.filter(\.acceptArtwork).count
        if on == 0 {
            return head + " —— 本组 \(r.count) 个文件已有封面，默认保留不写；"
                + "要换请点行内「封面」或用「本组字段 ▾」勾上"
        }
        return head + " —— 已勾选替换 \(on)/\(r.count) 个已有封面的文件"
    }

    /// 专辑卡「封面」那一格：原 → 新（新值后面注明写几个）。整组没有新封面时 nil。
    static func cardDiff(_ items: [AutoMatchReviewItem], newArtwork: Data?) -> AlbumCardDiff? {
        guard let new = newArtwork else { return nil }
        let size = ArtworkProcessor.pixelSize(new)
        let newSize = "\(size.width)×\(size.height)"
        let withArt = items.filter(\.hasArtwork)
        let r = replacing(withArt)
        let unknown = withArt.filter { $0.artworkWritesTag && $0.existingArtwork == nil }.count
        let none = withArt.filter { $0.artworkWritesTag && $0.existingArtwork?.hasArtwork == false }.count
        let folderOnly = withArt.filter { !$0.artworkWritesTag }.count
        let writeCount = withArt.filter { $0.acceptedArtwork != nil }.count

        var old = ""
        if !r.isEmpty { old = "原 " + (existingSizeText(r) ?? "有封面") }
        else if unknown > 0 { old = "原 未知" }
        var newText = newSize
        if writeCount == 0 { newText += " · 不写" }
        else if writeCount < withArt.count { newText += " · 写 \(writeCount)/\(withArt.count)" }

        var help = ["封面：新封面 \(newSize)，本组 \(withArt.count) 个文件可写，勾上的 \(writeCount) 个会写入"]
        if let t = replaceText(withArt) {
            help.append(t + "：\(r.count) 个文件已有封面，默认保留不写，勾上才替换（右下角小图是现在的封面）")
        }
        if unknown > 0 { help.append("\(unknown) 个文件读不出现有封面，为免误换默认不写") }
        if none > 0 { help.append("\(none) 个文件现在没有封面，默认写入") }
        if folderOnly > 0 { help.append("按「封面与写入选项」存为文件夹图片，音频里现有的封面不动") }
        help.append("某一行若要写的不是这张，会在那一行单独亮一枚橙色「封面 ≠ 组」")
        return AlbumCardDiff(label: "封面", old: old, new: newText, help: help.joined(separator: "\n"))
    }
}

// MARK: - 复核清单模型

/// 一个字段的「原值 → 新值」。
struct AutoMatchFieldChange: Identifiable {
    var id: String { field.rawValue }
    let field: TagEdit.Field
    let oldValue: String
    let newValue: String

    var oldDisplay: String { oldValue.isEmpty ? "（空）" : AutoMatchFieldChange.oneLine(oldValue) }
    var newDisplay: String { AutoMatchFieldChange.oneLine(newValue) }

    /// 歌词等多行值在表里只展示首行 + 行数。
    static func oneLine(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return s }
        return String(lines[0]) + " …（共 \(lines.count) 行）"
    }
}

// MARK: - 「写哪几个字段」的钥匙

/// 复核表里一个可勾选的写入项。字段十二个，封面是第十三个 ——
/// 封面不是 `TagEdit.Field`（它走 `artworkAction`），但在用户眼里
/// 「不写这个文件的封面」和「不写这个文件的碟号」是同一种操作，所以统一成一把钥匙。
enum ReviewFieldKey: Hashable, Identifiable {
    case field(TagEdit.Field)
    case artwork

    var id: String {
        switch self {
        case .field(let f): return f.rawValue
        case .artwork:      return "\u{1}ARTWORK"
        }
    }

    var localizedName: String {
        switch self {
        case .field(let f): return f.localizedName
        case .artwork:      return "封面"
        }
    }

    /// 菜单里的排序：按 `TagEdit.Field` 的声明顺序，封面排最后。
    var sortRank: Int {
        switch self {
        case .field(let f): return TagEdit.Field.allCases.firstIndex(of: f) ?? 99
        case .artwork:      return 100
        }
    }
}

// MARK: - 文件里现有的封面（BP-E / BO#8）
//
// 复核表要回答「这一行会不会把文件里原来的封面换掉」。BO 之前取的是 `drafts[url].artworks`，
// 可 `FileRow.init` 为省内存早把封面二进制清空了（FileRow.swift「列表不驻留封面二进制」），
// 于是永远是「文件现在没有封面」：chip 说「本次会写入一张」、专辑卡没有「原 → 新」小图，
// 用户在不知情时把已有的封面替换掉（BO-04：卡上「封面（空）→ 300×300」，同一张图底部的
// 写前预估却说「换上的封面比原来的小」，前后矛盾）。
//
// 现在读**真实状态**：
//  · 行上已读过标签、`artworkCount == 0` → 确知没有，不开文件；
//  · 其余（有封面 / 还是待读行）→ 后台读一次文件里的封面，只留张数、第一张的像素尺寸与字节数
//    （`ArtworkProcessor.pixelSize` 只解析图头，不解码整图），字节随即丢掉；
//    **每个文件夹只留一张完整原图**给专辑卡右下角的「原 → 新」小图（悬停看大图时尺寸/字节才是真的）；
//  · 读不出来（文件被占用 / 卷掉线）→ nil = 未知，按「可能有」处理：默认不写封面。
//
// 默认勾选随之改为：**只有确知文件里原本没有封面时，封面才默认勾上**；已有（或未知）一律默认不勾，
// 复核表上明说「将替换现有封面（原 1200×1200）」，用户要换再点一下。
// 「存为文件夹图片」模式下音频里的封面一个字节不动，谈不上替换，照旧默认勾。

/// 文件里**现在**的封面（磁盘真值，不看草稿）。
struct ExistingArtworkInfo: Equatable, Sendable {
    /// 张数。0 = 文件里没有封面。
    var count: Int
    /// 第一张（优先封面类型）的像素尺寸与字节数。确知没有、或读不出尺寸时为 0。
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var byteCount: Int = 0

    /// 确知没有封面。**别写成 `.none`**：赋给 `ExistingArtworkInfo?` 时 `.none` 会被解析成
    /// `Optional.none`（= 未知），字典里那一项直接被删掉。
    static let noArtwork = ExistingArtworkInfo(count: 0)

    var hasArtwork: Bool { count > 0 }

    /// 「1200×1200」。读不出尺寸时 nil。
    var sizeText: String? {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth)×\(pixelHeight)" : nil
    }

    /// 「将替换现有封面（原 1200×1200）」—— chip、展开区、两张复核表的专辑卡共用这一句。
    var replaceText: String {
        "将替换现有封面" + (sizeText.map { "（原 \($0)）" } ?? "")
    }
}

/// 一轮匹配里读到的「现有封面」。
struct ExistingArtworkProbe: Sendable {
    var info: [URL: ExistingArtworkInfo] = [:]
    /// 每个文件夹第一张完整原图（专辑卡右下角那张小图）。键是提供它的那个文件。
    var previews: [URL: Data] = [:]
}

/// `probeExistingArtworks` 的收集盒：`concurrentPerform` 的回调在任意线程，上锁；
/// `claim` 保证**每个文件夹只留一张**完整原图，内存上限 = 文件夹数 × 一张封面。
final class ExistingArtworkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = Set<URL>()
    private var results: [(url: URL, info: ExistingArtworkInfo?, preview: Data?)] = []

    init(claimed: Set<URL>) { self.claimed = claimed }

    func claim(_ dir: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed.insert(dir).inserted
    }

    func add(_ url: URL, _ info: ExistingArtworkInfo?, _ preview: Data?) {
        lock.lock(); results.append((url, info, preview)); lock.unlock()
    }

    func take() -> (results: [(url: URL, info: ExistingArtworkInfo?, preview: Data?)], claimed: Set<URL>) {
        lock.lock(); defer { results = []; lock.unlock() }
        return (results, claimed)
    }
}

extension AppModel {

    /// 哪些文件要开盘读现有封面：已读过标签且 `artworkCount == 0` 的行确知没有，不开文件。
    func existingArtworkPlan(for rows: [FileRow]) -> (known: [URL: ExistingArtworkInfo], toRead: [URL]) {
        var known: [URL: ExistingArtworkInfo] = [:]
        var toRead: [URL] = []
        for r in rows {
            if r.tagsState.isLoaded && r.artworkCount == 0 {
                known[r.id] = ExistingArtworkInfo.noArtwork
            } else {
                toRead.append(r.id)
            }
        }
        return (known, toRead)
    }

    /// 后台读一批文件的现有封面（BP-E / BO#8）。
    ///
    /// 分块做，每块一个 `Task.detached`（按卷的推荐并发 `concurrentPerform`）；块与块之间看取消 ——
    /// `Task.detached` 不继承取消，整段甩出去就停不下来了。
    nonisolated static func probeExistingArtworks(_ urls: [URL]) async -> ExistingArtworkProbe {
        var out = ExistingArtworkProbe()
        guard !urls.isEmpty else { return out }
        let width = TagReader.recommendedConcurrency(for: urls)
        var claimed = Set<URL>()
        var start = 0
        while start < urls.count {
            if Task.isCancelled { break }
            let slice = Array(urls[start..<min(start + 32, urls.count)])
            start += slice.count
            let box = ExistingArtworkBox(claimed: claimed)
            await Task.detached(priority: .utility) {
                AppModel.readExistingArtworks(slice, concurrency: width, into: box)
            }.value
            let part = box.take()
            claimed = part.claimed
            for r in part.results {
                if let info = r.info { out.info[r.url] = info }
                if let p = r.preview { out.previews[r.url] = p }
            }
        }
        return out
    }

    /// 同步读（在后台线程上调）。只留第一张的尺寸与字节数；本文件夹还没人占位时才留整张原图。
    nonisolated static func readExistingArtworks(_ urls: [URL], concurrency: Int,
                                                 into box: ExistingArtworkBox) {
        let width = min(max(1, concurrency), urls.count)
        DispatchQueue.concurrentPerform(iterations: width) { k in
            for i in stride(from: k, to: urls.count, by: width) {
                let url = urls[i]
                guard let arts = try? TagService.readArtworks(url) else {
                    box.add(url, nil, nil)                       // 读不出来 = 未知
                    continue
                }
                guard let first = arts.first(where: { $0.type == .frontCover }) ?? arts.first else {
                    box.add(url, ExistingArtworkInfo.noArtwork, nil)
                    continue
                }
                let size = ArtworkProcessor.pixelSize(first.data)
                let info = ExistingArtworkInfo(count: arts.count,
                                               pixelWidth: size.width, pixelHeight: size.height,
                                               byteCount: first.data.count)
                let keep = box.claim(url.deletingLastPathComponent())
                box.add(url, info, keep ? first.data : nil)
            }
        }
    }
}

/// 复核清单里的一行。
///
/// 除 `url` / `fileName` 外一律是 `var`：换候选（B2）与行内手动搜索（B3）要就地
/// 重算这一行的匹配结果 —— 标题、来源、分数、字段差异、封面全都会变。
struct AutoMatchReviewItem: Identifiable {
    var id: URL { url }
    let url: URL
    let fileName: String
    var status: AutoMatchResult.Status
    var bestTitle: String?
    var bestArtist: String?
    var bestAlbum: String?
    var sourceID: String?
    var sourceName: String?
    var score: Double
    var candidateCount: Int
    var triedSources: [String]
    var errorText: String?
    var changes: [AutoMatchFieldChange]
    var artwork: Data?
    /// **只读展示**：文件里原本就有的那张封面（完整字节）。写入路径一个字都不看它 ——
    /// 它只服务于复核表的「原 → 新」对比：组头大封面右下角那张 48pt 小图就是它。
    ///
    /// BP-E：原先取 drafts 里的 `Tags.artworks`，而那早被 `FileRow` 清空了，永远是 nil（BO#8）。
    /// 现在由 `probeExistingArtworks` 从磁盘读，**每个文件夹只有一个文件带着它**（省内存）；
    /// 「这个文件有没有封面」一律看 `existingArtwork`，不要看它。
    var originalArtwork: Data?
    /// 文件里现在的封面（磁盘真值）。nil = 不知道（读不出来 / 这一轮没下封面，没去读）。
    var existingArtwork: ExistingArtworkInfo? = nil
    /// 本轮封面会不会**嵌进音频**（封面与写入选项不是「只存文件夹图片」）。
    /// 为 false 时音频里现有的封面不动，谈不上替换。
    var artworkWritesTag: Bool = true
    /// 是否采纳。默认只勾选「已匹配且确有改动」的行。
    var accepted: Bool
    /// 这一行**将要写入的那份歌词**里带没带译文。只喂给复核表的「歌词（含翻译）」chip。
    /// 写入路径不看它 —— 文本早在组装时就已经合并好了。
    var lyricsHasTranslation: Bool = false

    // MARK: 按文件选写哪几个字段
    //
    // ── 用户原话 ──「全部匹配后有些文件不想写碟号、有些不想写音轨号，现在改不了。」
    // 整行勾选是全有全无的，`AutoMatchOptions.fields` 那个白名单又是整轮的 ——
    // 中间这一档「这一个文件的这一个字段」原先没有落脚点，就是它。
    //
    // 语义刻意做成**减法**：默认全勾（= `changes` 的字段全集），用户只做排除。
    // 加法会带来「这一行本来就不改这个字段，勾上是什么意思」的歧义。

    /// 本行真会写入的字段。缺省由 `resetAcceptedFields()` 填成 `changes` 的全集。
    var acceptedFields: Set<TagEdit.Field> = []
    /// 匹配到的封面写不写进这个文件。
    var acceptArtwork: Bool = true

    /// 把勾选重置成「本次会改动的字段全集」，封面按 `defaultAcceptArtwork`。构造完 `changes` 后调一次。
    mutating func resetAcceptedFields() {
        acceptedFields = Set(changes.map(\.field))
        acceptArtwork = defaultAcceptArtwork
    }

    /// 封面默认勾不勾（BP-E / BO#8）：**只在确知文件里原本没有封面时默认写入**。
    /// 已有封面（或还不知道有没有）→ 默认不勾，复核表上说清「将替换现有封面（原 W×H）」，要换再点。
    /// 「只存文件夹图片」模式下音频里的封面不动，照旧默认勾。
    var defaultAcceptArtwork: Bool {
        !artworkWritesTag || existingArtwork?.hasArtwork == false
    }

    /// 这一行的新封面会把**音频里现有的封面**换掉（嵌入模式 + 文件里确有封面）。
    var replacesExistingArtwork: Bool {
        hasArtwork && artworkWritesTag && (existingArtwork?.hasArtwork ?? false)
    }

    /// 换候选 / 手动搜索重算之后，把用户先前的排除**接着用**。
    ///
    /// 不接的话会出现最气人的一幕：用户逐行去掉了碟号，随手换了个候选，
    /// 碟号又自己回来了。接的办法是记住「他排除过什么」而不是「他勾了什么」——
    /// 新候选带来的新字段默认仍然是勾上的。
    mutating func resetAcceptedFields(preservingExclusionsFrom old: AutoMatchReviewItem) {
        let excluded = Set(old.changes.map(\.field)).subtracting(old.acceptedFields)
        acceptedFields = Set(changes.map(\.field)).subtracting(excluded)
        acceptArtwork = old.hasArtwork ? old.acceptArtwork : defaultAcceptArtwork
    }

    func isAccepted(_ key: ReviewFieldKey) -> Bool {
        switch key {
        case .field(let f): return acceptedFields.contains(f)
        case .artwork:      return acceptArtwork
        }
    }

    mutating func setAccepted(_ key: ReviewFieldKey, _ on: Bool) {
        switch key {
        case .field(let f):
            // 只在本行确实会改这个字段时才动它 —— 往集合里塞一个没有改动的字段，
            // 会让「勾中数」凭空变大，而写入路径根本找不到对应的 change。
            guard changes.contains(where: { $0.field == f }) else { return }
            if on { acceptedFields.insert(f) } else { acceptedFields.remove(f) }
        case .artwork:
            guard hasArtwork else { return }
            acceptArtwork = on
        }
    }

    /// 本行**可勾选**的写入项（= 本次真会改动的那些）。菜单与批量开关据此列举。
    var togglableKeys: [ReviewFieldKey] {
        var keys = changes.map { ReviewFieldKey.field($0.field) }
        if hasArtwork { keys.append(.artwork) }
        return keys.sorted { $0.sortRank < $1.sortRank }
    }

    /// 排除掉之后**真会写**的字段改动。写入组装、统计、专辑卡计数全用它。
    var acceptedChanges: [AutoMatchFieldChange] {
        changes.filter { acceptedFields.contains($0.field) }
    }

    /// 会写入的封面（被排除时为 nil）。
    var acceptedArtwork: Data? { acceptArtwork ? artwork : nil }

    /// 勾中之后这一行会改几处。底部脚注「共 M 处」按它累加。
    var acceptedChangeCount: Int {
        acceptedChanges.count + (acceptedArtwork != nil ? 1 : 0)
    }

    /// 勾中之后这一行还有没有东西可写。**整行被逐字段掏空时不该再计入「将修改 N 个文件」**。
    var writesSomething: Bool { acceptedChangeCount > 0 }

    /// 被排除的字段。行内那几枚划线 chip 与组头菜单的三态提示用它。
    var excludedKeys: Set<ReviewFieldKey> {
        var out = Set(changes.map { ReviewFieldKey.field($0.field) }
            .filter { !isAccepted($0) })
        if hasArtwork && !acceptArtwork { out.insert(.artwork) }
        return out
    }

    // MARK: 只读展示补充（不参与写入，写入一律以 `changes` 为准）
    //
    // 复核表要「一眼看全」，就得在同一行里同时摆出原值与新值。
    // `changes` 里只装**确有改动**的字段，没改动的那些字段的当前值无处可取，
    // 于是这里额外留一份当前值快照——它只被界面读取，写入路径一个字都不看它。

    /// 当前值快照，键是字段。取「原 → 新」里那个「原」用。
    var current: [TagEdit.Field: String] = [:]

    /// 对到的曲目在专辑曲目表里的位置（专辑模式才有；逐首模式恒为 nil）。
    var trackNumberInDisc: Int?
    /// 碟号（1 起）。
    var discNumber: Int?
    /// 整张专辑的碟数。>1 时音轨列必须带碟号。
    var discCount: Int = 1
    /// **该碟**的曲目数，不是整张专辑的。
    /// 双碟 OST 两张碟各有自己的第 7 首，写成「7/45」时两行长得一模一样，
    /// 分不清哪首是哪碟的；带上碟号与本碟总数才成为「1-07/24」「2-07/21」。
    var tracksInDisc: Int = 0

    // MARK: 候选与逐源结果（B 组任务）
    //
    // 原先这一行只留得下**一个**答案：数据层给的 `best`。匹配错了，用户能做的只有整行放弃。
    // 专辑模式早有「换专辑」，逐首模式却什么都没有 —— 这里把候选整串留下来，
    // 复核表才给得出「换候选 ▾」。

    /// 按分降序的候选（top 10）。`candidates.first` 是数据层选的那一条。
    var candidates: [TrackCandidate] = []
    /// 当前选中的候选。nil = 用 `candidates.first`（或压根没有候选）。
    var selectedCandidateID: UUID?
    /// 这一行是用户亲手挑的。**手选视为确认，不再受采纳阈值限制** ——
    /// 阈值是给自动决策兜底的，人已经看过了就没有再拦一道的道理。
    var manuallyChosen: Bool = false
    /// 正在为「换候选 / 手动搜索」重算（要补详情、下封面，有网络往返）。
    var isReloading: Bool = false
    /// 这一行匹配时的逐源结果条。展开区里显示，回答「这首为什么没搜到」。
    var sourceOutcomes: [SourceOutcome] = []
    /// 展开区里那句「耗时：iTunes 2.9 s · 酷狗 6.6 s（超软截止 4 s）· 署名 0 s（复用歌词）」。
    /// 用户抱怨「慢」时，第一件要能回答的事就是**时间花在哪个源上**。
    var timingLine: String?
    /// 这一首的总耗时（秒）。
    var elapsed: TimeInterval = 0
    /// 行内手动搜索用过的查询（回显到面板里，免得用户重打一遍）。
    var manualQuery: ManualSearchQuery?

    /// 当前选中的那条候选。
    var selectedCandidate: TrackCandidate? {
        if let id = selectedCandidateID { return candidates.first { $0.id == id } }
        return candidates.first
    }

    /// 「换候选 ▾」菜单里一条的文字：来源 · 标题 — 艺术家 · 专辑 · 年份 · 时长 · 分数
    func candidateLabel(_ c: TrackCandidate) -> String {
        let mark = (c.id == (selectedCandidate?.id)) ? "✓ " : "   "
        var parts: [String] = [SourceOutcome.shortName(c.sourceID)]
        parts.append("\(c.title ?? "未知标题") — \(c.artist ?? "未知艺术家")")
        parts.append(c.album?.isEmpty == false ? c.album! : "—")
        parts.append(c.year?.isEmpty == false ? c.year! : "—")
        parts.append(AutoMatchReviewItem.durationText(c.durationSeconds))
        parts.append(String(format: "%.3f", c.matchScore))
        return mark + parts.joined(separator: " · ")
    }

    static func durationText(_ s: TimeInterval) -> String {
        guard s > 0 else { return "—:—" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var hasArtwork: Bool { artwork != nil }
    /// 本行**能**改几处（不看勾选）。勾选之后真会改几处见 `acceptedChangeCount`。
    var changeCount: Int { changes.count + (hasArtwork ? 1 : 0) }
    /// 本行有没有可写的东西。**看的是全集而不是勾选** —— 整行勾选框的可用性
    /// 归它管：用户把字段一个个去掉时，那个勾选框不该在最后一个被去掉的瞬间
    /// 自己变灰失效，否则他就没法再勾回来了。
    var hasSomethingToWrite: Bool { changeCount > 0 }

    /// 匹配到的曲目描述：《标题》— 艺术家
    var matchDescription: String {
        guard bestTitle != nil || bestArtist != nil else { return "—" }
        return "《\(bestTitle ?? "未知")》— \(bestArtist ?? "未知")"
    }

    /// 将改动的字段摘要。
    var changeSummary: String {
        guard hasSomethingToWrite else {
            return status == .matched ? "标签已是最新" : "—"
        }
        var names = changes.map(\.field.localizedName)
        if hasArtwork { names.append("封面") }
        let shown = names.prefix(4).joined(separator: "、")
        return names.count > 4 ? shown + " 等 \(names.count) 项" : shown
    }

    var statusLabel: String {
        switch status {
        case .matched: return "已匹配"
        case .ignored: return "忽略"
        case .failed:  return "失败"
        case .noQuery: return "无查询条件"
        }
    }

    var statusSymbol: String {
        switch status {
        case .matched: return "checkmark.circle.fill"
        case .ignored: return "circle.dashed"
        case .failed:  return "xmark.octagon.fill"
        case .noQuery: return "questionmark.circle"
        }
    }

    /// 排序权重：已匹配的排最前，失败的沉底。
    var statusRank: Int {
        switch status {
        case .matched: return 0
        case .ignored: return 1
        case .noQuery: return 2
        case .failed:  return 3
        }
    }

    /// 低于阈值被判「忽略」时，把那个够不着的最佳候选也说清楚。
    var ignoredReason: String? {
        guard status == .ignored else { return nil }
        if candidateCount == 0 { return "所有来源都没有搜到候选" }
        if bestTitle != nil { return "最佳候选分数低于采纳阈值，未写入" }
        return "有 \(candidateCount) 条候选，但都低于采纳阈值"
    }

    // MARK: 「原 → 新」取数（只读）

    /// 本次会不会改这个字段。返回 nil 表示不改，界面据此灰显一个「—」。
    func change(_ f: TagEdit.Field) -> AutoMatchFieldChange? {
        changes.first { $0.field == f }
    }

    /// 该字段现在的值。用于不改动时的悬停提示，以及「原」那一格。
    func currentValue(_ f: TagEdit.Field) -> String { current[f] ?? "" }

    /// 音轨位置：单碟 `07/11`，双碟 `1-07/24`。
    ///
    /// 与写入值不是同一件事 —— 写入的是数据层给的 `TRACKNUMBER`（见 `writtenTrack`），
    /// 这里是**给人看的位置**，双碟必须带碟号才区分得开。
    var trackPositionDisplay: String? {
        guard let n = trackNumberInDisc else { return nil }
        let num = n < 100 ? String(format: "%02d", n) : "\(n)"
        let total = tracksInDisc > 0 ? "/\(tracksInDisc)" : ""
        if discCount > 1, let d = discNumber { return "\(d)-" + num + total }
        return num + total
    }

    /// 真正会写进 TRACKNUMBER 的那个字符串（没有改动则 nil）。
    var writtenTrack: String? { change(.track)?.newValue }

    // MARK: 变更 chips（只读展示）
    //
    // 复核表一行摆不下十二个字段的「原 → 新」，但用户要的其实只是
    // 「这一行会动哪几个字段、动的是空位还是我原来的值」——那就是几种颜色的事：
    // **绿 = 从无到有（新增），蓝 = 覆盖已有值（修改），灰 = 本次不动，橙 = 与组级值不同。**
    // 标题在主行、艺术家与音轨在副行已有完整的「原 → 新」，chips 里不再重复。
    //
    // **行内 chips 只留逐首各不相同的字段**（歌词、作曲、注释、多碟时的碟号、
    // 与专辑封面不同的那张封面）。专辑级字段交给专辑卡的组级摘要说一次，见 `ReviewGroupContext`。

    /// 主行/副行已经单独摆过的字段，不进 chips。
    static let chipInlineFields: Set<TagEdit.Field> = [.title, .artist, .track]
    /// 即便本次不改，也照样摆一个灰 chip 的字段 —— 「本次不动它」也是复核结论的一部分。
    /// （范围刻意收窄：十二个字段全灰着列出来只会把真正会改的那几个淹掉。
    /// 有组级口径时，其中的专辑级字段会被滤掉，剩下的才是这一行自己的事。）
    static let chipRestFields: [TagEdit.Field] = [.album, .albumArtist, .year, .disc, .lyrics]

    /// 行尾那一串小标签。
    ///
    /// - Parameters:
    ///   - includeUnchanged: false 时只剩真正会写入的那几个（「只看有改动的字段」开关）。
    ///   - group: 组级口径。传了它，专辑级字段就从行里消失，改由专辑卡说一次；
    ///            本行与组级值不同时才回到行里，且是橙色的。
    /// `@MainActor`：等价判定（碟号裸 1 ≡ 1/1）那把尺子长在 `AppModel` 上，
    /// 复核表要和写入路径用**同一把**，不能在这里另抄一份。调用方全是视图体，本就在主线程。
    @MainActor
    func changeChips(includeUnchanged: Bool = true,
                     group: ReviewGroupContext? = nil) -> [ReviewChangeChip] {
        let albumLevel = Set(group?.folded ?? [])
        var chips: [ReviewChangeChip] = []

        // ① 逐首各不相同的字段的实际改动
        //
        // 这一批 chips **可点击切换**：点一下 = 这个文件不写这个字段（变灰划线），
        // 再点恢复。被排除的照样留在行里（哪怕开了「只看有改动的字段」）——
        // 用户必须看得见自己排除了什么，否则「少写了一个字段」就成了看不见的事故。
        for c in changes
        where !AutoMatchReviewItem.chipInlineFields.contains(c.field) {
            let excluded = !acceptedFields.contains(c.field)
            if albumLevel.contains(c.field) {
                // 专辑级字段平时折给专辑卡说。**唯独被这一行单独排除时要回到行里** ——
                // 「整组都写碟号，就这一首不写」是这一行独有的决定，
                // 折掉它等于让用户再也找不到自己刚划掉的那一枚，也点不回来。
                guard excluded else { continue }
                // 与组级值不同的那种情形归下面的橙 chip 管（它自己带排除态），别画两遍。
                if let g = group, let gv = g.values[c.field],
                   !AppModel.isEquivalentTagValue(c.field, c.newValue, gv) { continue }
                chips.append(ReviewChangeChip(
                    id: c.field.rawValue,
                    label: c.field.localizedName,
                    kind: c.oldValue.isEmpty ? .added : .modified,
                    help: "\(c.field.localizedName)：本组其它文件会写「\(c.newDisplay)」，"
                        + "这一行被单独排除了。\n本行原：\(c.oldDisplay)\n点一下恢复。",
                    key: .field(c.field),
                    excluded: true))
                continue
            }
            // 歌词带译文时把它写在 chip 脸上。用户勾了「翻译」却只看到一枚普通的
            // 「歌词」chip，是没法在**写盘之前**确认这一轮到底有没有合上译文的。
            let label = (c.field == .lyrics && lyricsHasTranslation)
                ? "歌词（含翻译）" : c.field.localizedName
            chips.append(ReviewChangeChip(
                id: c.field.rawValue,
                label: label,
                kind: c.oldValue.isEmpty ? .added : .modified,
                help: "\(label)\n原：\(c.oldDisplay)\n新：\(c.newDisplay)",
                key: .field(c.field),
                excluded: excluded))
        }

        // ② 封面：与组头那张一样就一个字都不说（组级摘要已经说过）
        chips.append(contentsOf: artworkChips(group: group))

        // ③ 专辑级字段上与组不同 —— 唯一会回到行里的专辑级字段，橙色单列
        if let g = group, hasSomethingToWrite {
            for f in g.summarized {
                guard let c = change(f) else { continue }
                if let gv = g.values[f],
                   AppModel.isEquivalentTagValue(f, c.newValue, gv) { continue }
                var groupText = g.values[f].map { "组级：\($0)" } ?? "组级：整组都不改动"
                // 卡上那一格此时写的是「（2 种新值）」，光看卡看不出多数派是哪个值。
                if let kinds = g.distinctValueCount[f] {
                    groupText += "（本组共 \(kinds) 种新值，上面这个是多数）"
                }
                chips.append(ReviewChangeChip(
                    id: "GROUP-" + f.rawValue,
                    label: f.localizedName + " ≠ 组",
                    kind: .groupDiffers,
                    help: "\(f.localizedName)：这一行与专辑卡上写的不是同一个值\n"
                        + groupText + "\n本行原：\(c.oldDisplay)\n本行新：\(c.newDisplay)",
                    // 橙 chip 背后也是一处真改动，一样可以单独排除掉。
                    key: .field(f),
                    excluded: !acceptedFields.contains(f)))
            }
        }

        guard includeUnchanged else { return chips }

        let changed = Set(changes.map(\.field))
        for f in AutoMatchReviewItem.chipRestFields
        where !albumLevel.contains(f) && !changed.contains(f) {
            // 歌词等字段不在展示快照里（`displaySnapshot` 只抄界面用得上的那几列），
            // 当前值无从得知 —— 那就别假称「现在是空的」，只说本次不写。
            let known = current[f]
            let help: String
            if let v = known {
                help = v.isEmpty ? "\(f.localizedName)：现在是空的，本次也不写"
                                 : "\(f.localizedName)：\(v)（本次不改动）"
            } else {
                help = "\(f.localizedName)：本次不写入"
            }
            chips.append(ReviewChangeChip(id: f.rawValue, label: f.localizedName,
                                          kind: .unchanged, help: help))
        }
        if !hasArtwork, group?.artwork == nil {
            chips.append(ReviewChangeChip(id: "ARTWORK", label: "封面", kind: .unchanged,
                                          help: "封面：本次不写入"))
        }
        return chips
    }

    /// 封面 chip 的取舍全在这里：**整组同一张封面就不该在每一行各画一遍**。
    @MainActor
    private func artworkChips(group: ReviewGroupContext?) -> [ReviewChangeChip] {
        // 封面 chip 与字段 chip 一样可点击排除 —— 只有这一行**确实要写封面**时才谈得上。
        let artKey = ReviewFieldKey.artwork
        let artExcluded = !acceptArtwork
        guard let g = group else {
            // 没有组级口径（旧口径 / 单独一行的场合）：照旧摆一枚。
            guard hasArtwork else { return [] }
            return [ReviewChangeChip(
                id: "ARTWORK", label: "封面",
                kind: artworkChipKind,
                help: artworkHelp,
                key: artKey, excluded: artExcluded)]
        }
        if let mine = artwork {
            if let ga = g.artwork {
                // 与组头同一张 → 组级摘要已说过。**除非它被排除了** ——
                // 那就是这一行独有的状态（用户划掉的，或文件里已有封面、默认不替换），
                // 不说出来用户就再也点不回来。
                guard ga != mine || artExcluded else { return [] }
                if ga == mine {
                    let userExcluded = existingArtwork?.hasArtwork == false || !artworkWritesTag
                    return [ReviewChangeChip(
                        id: "ARTWORK", label: "封面", kind: artworkChipKind,
                        help: userExcluded
                            ? "封面：整组同一张，但这一行被单独排除了。点一下恢复。"
                            : artworkHelp,
                        key: artKey, excluded: true)]
                }
                return [ReviewChangeChip(
                    id: "GROUP-ARTWORK", label: "封面 ≠ 组", kind: .groupDiffers,
                    help: "封面：这一行要写的不是专辑卡上那张\n行尾的小缩略图就是它，悬停看大图\n"
                        + artworkHelp,
                    key: artKey, excluded: artExcluded)]
            }
            return [ReviewChangeChip(
                id: "ARTWORK", label: "封面",
                kind: artworkChipKind,
                help: artworkHelp,
                key: artKey, excluded: artExcluded)]
        }
        // 整组都会写封面，唯独这一行不写 —— 这也是一种「与组不同」，得说。
        if g.artwork != nil, hasSomethingToWrite {
            return [ReviewChangeChip(
                id: "GROUP-ARTWORK", label: "封面 ≠ 组", kind: .groupDiffers,
                help: "封面：本组其它文件会写入专辑卡上那张，这一行没有封面可写")]
        }
        return []
    }

    /// 封面 chip 的颜色：确知文件里原本没有 → 绿（新增）；有、或不知道 → 蓝（覆盖）。
    private var artworkChipKind: ReviewChangeKind {
        existingArtwork?.hasArtwork == false || !artworkWritesTag ? .added : .modified
    }

    /// 封面这一项按**真实状态**说的那句话（chip 悬停、展开区共用）。
    var artworkHelp: String {
        guard artworkWritesTag else {
            return "封面：按「封面与写入选项」存为文件夹图片，音频里现有的封面不动"
        }
        switch existingArtwork {
        case .some(let e) where e.hasArtwork:
            return "封面：" + e.replaceText
                + (e.count > 1 ? "（文件里现有 \(e.count) 张，会一并换掉）" : "")
                + (acceptArtwork ? "\n本次会写入。点一下改为保留原封面"
                                 : "\n文件里已有封面，默认保留不写；点一下改为替换")
        case .some:
            return acceptArtwork ? "封面：文件现在没有封面，本次会写入一张"
                                 : "封面：文件现在没有封面；这一行已被排除，点一下恢复"
        case .none:
            return "封面：读不出文件里现有的封面（文件被占用或卷已断开），为免误换默认不写"
                + (acceptArtwork ? "\n本次会写入。点一下改为不写" : "；点一下改为写入")
        }
    }

    /// 展开区「原」那一格：「原 1200×1200」/「原有封面」/ 空 /「未知」。
    var existingArtworkCell: String {
        switch existingArtwork {
        case .some(let e) where e.hasArtwork: return "原 " + (e.sizeText ?? "有封面")
        case .some:                           return ""
        case .none:                           return "未知"
        }
    }

    /// 音轨列的悬停提示：把「显示的位置」与「写入的值」摊开讲清楚。
    var trackHelp: String? {
        guard let pos = trackPositionDisplay else { return nil }
        var s = "曲目位置 " + pos
        if discCount > 1, let d = discNumber {
            s += "（第 \(d) 碟，本碟 \(tracksInDisc) 首；全辑共 \(discCount) 碟）"
        }
        if let w = writtenTrack { s += "\n写入 TRACKNUMBER = " + w }
        return s
    }
}

/// 行内「手动搜索…」的一组输入。默认值由文件名解析而来。
struct ManualSearchQuery: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && artist.trimmingCharacters(in: .whitespaces).isEmpty
            && album.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 交给数据层的查询。空串一律转 nil —— 空字符串会被当成「要求这个字段等于空」。
    var trackQuery: TrackQuery {
        var q = TrackQuery()
        q.title = title.trimmingCharacters(in: .whitespaces).nilIfBlank
        q.artist = artist.trimmingCharacters(in: .whitespaces).nilIfBlank
        q.album = album.trimmingCharacters(in: .whitespaces).nilIfBlank
        q.filename = [q.title, q.artist].compactMap { $0 }.joined(separator: " ")
        return q
    }

    /// 默认值：优先用文件已有标签，没有就拆文件名（和自动匹配的兜底口径一致）。
    static func makeDefault(fileName: String, item: AutoMatchReviewItem) -> ManualSearchQuery {
        var q = ManualSearchQuery()
        q.title = item.currentValue(.title)
        q.artist = item.currentValue(.artist)
        q.album = item.currentValue(.album)
        guard q.title.isEmpty else { return q }
        let stem = (fileName as NSString).deletingPathExtension
        if let parts = AutoMatchService.splitFilename(stem) {
            // 「标题 - 艺术家」与「艺术家 - 标题」都常见，无从单凭字面判断。
            // 已有艺术家时用它反推哪一段是标题，否则按最常见的「标题 - 艺术家」摆。
            if !q.artist.isEmpty,
               MatchScorer.artistSimilarity(parts.a, q.artist) > MatchScorer.artistSimilarity(parts.b, q.artist) {
                q.title = parts.b
            } else {
                q.title = parts.a
                if q.artist.isEmpty { q.artist = parts.b }
            }
        } else {
            q.title = stem
        }
        return q
    }
}

/// 一次自动匹配的完整结果。
struct AutoMatchReview {
    var items: [AutoMatchReviewItem]
    var summary: BatchSummary
    var elapsed: TimeInterval
    /// 换候选 / 手动搜索要重算这一行，得留着**完整**的当前标签（`item.current` 只是展示用的子集）
    /// 与本次用的选项（源、字段白名单、要不要下封面）。
    var drafts: [URL: Tags] = [:]
    var options: AutoMatchOptions = .recommended

    /// 真会被写入的行。**看的是逐字段勾选之后的结果**：
    /// 一行勾着、但字段被逐个划掉干净了，它一个字节都不会写，就不该混进这个数。
    var acceptedItems: [AutoMatchReviewItem] { items.filter { $0.accepted && $0.writesSomething } }
    var acceptedCount: Int { acceptedItems.count }
    var writableCount: Int { items.filter { $0.hasSomethingToWrite }.count }
    /// 底部脚注的「共 M 处」。随逐字段勾选实时变。
    var acceptedChangeTotal: Int { acceptedItems.reduce(0) { $0 + $1.acceptedChangeCount } }
    /// 全表逐字段的勾选统计，工具条上那个「全部字段 ▾」菜单用它。
    var fieldTallies: [ReviewFieldTally] { ReviewFieldTally.make(items) }

    // MARK: 逐源结果条（A1）

    /// 整轮压成一条的逐源结果条，摆在复核表顶部。
    var sourceOutcomes: [SourceOutcome] {
        SourceOutcomeAggregator.merge(items.map(\.sourceOutcomes))
    }

    /// 「本轮 QQ 12/12 失败（retcode -1310），已跳过」。只在某源失败率 ≥50% 时才有。
    var sourceNote: String? {
        SourceOutcomeAggregator.batchNote(items.map(\.sourceOutcomes))
    }

    // MARK: 按匹配到的专辑分组（**纯展示**）

    /// 逐首模式的复核表也按专辑分组。
    ///
    /// 为什么：逐首模式一次几十行，滚起来全是同一张专辑的曲子却看不出它们是一伙的；
    /// 而「这批到底对到了哪张专辑」恰恰是错得最离谱、也最该先被发现的那件事
    /// （抓到 Live 版、抓到精选合辑，都是在专辑这一层就露馅）。
    ///
    /// **只是展示分组**：`indices` 指回 `items` 的原始下标，勾选与写入仍旧一条不动地
    /// 走原来的路径 —— 分组不改变任何一行的语义，只改变它被摆在哪里。
    struct DisplayGroup: Identifiable {
        var id: String
        /// nil = 「未匹配」那一组。
        var album: String?
        var artist: String?
        var year: String?
        var sourceName: String?
        /// 指回 `items` 的下标，顺序即显示顺序。
        var indices: [Int]
        var isUnmatched: Bool
    }

    /// 分组键：专辑 + 专辑艺术家（没有就退回艺术家）。两者都空就归「未匹配」。
    private static func groupKey(_ item: AutoMatchReviewItem) -> (album: String, artist: String)? {
        guard item.status == .matched else { return nil }
        let album = (item.change(.album)?.newValue ?? item.currentValue(.album))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return nil }
        let artist = (item.change(.albumArtist)?.newValue
                      ?? item.change(.artist)?.newValue
                      ?? item.currentValue(.albumArtist).nilIfBlank
                      ?? item.currentValue(.artist))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (album, artist)
    }

    var displayGroups: [DisplayGroup] {
        var order: [String] = []
        var buckets: [String: DisplayGroup] = [:]
        var unmatched: [Int] = []

        for (i, item) in items.enumerated() {
            guard let key = AutoMatchReview.groupKey(item) else {
                unmatched.append(i)
                continue
            }
            let id = key.album + "\u{1}" + key.artist
            if buckets[id] == nil {
                order.append(id)
                buckets[id] = DisplayGroup(
                    id: id,
                    album: key.album,
                    artist: key.artist.isEmpty ? nil : key.artist,
                    year: (item.change(.year)?.newValue ?? item.currentValue(.year)).nilIfBlank,
                    sourceName: item.sourceName,
                    indices: [],
                    isUnmatched: false)
            }
            buckets[id]?.indices.append(i)
        }

        var groups = order.compactMap { buckets[$0] }
        // 多首同专辑的排前面：一次改一整张专辑才是最该先看的那种情形。
        groups.sort { $0.indices.count > $1.indices.count }
        if !unmatched.isEmpty {
            groups.append(DisplayGroup(id: "\u{1}unmatched", album: nil, artist: nil,
                                       year: nil, sourceName: nil,
                                       indices: unmatched, isUnmatched: true))
        }
        return groups
    }
}

// MARK: - 状态机

extension AppModel {

    /// 原版行为：**无选中时对全部文件执行，有选中时只对选中文件执行**。
    /// 列表处于过滤状态时，「全部」指的是当前可见的那些。
    var autoMatchTargets: [FileRow] {
        selection.isEmpty ? displayRows : selectedRows
    }

    var autoMatchScopeLabel: String {
        selection.isEmpty
            ? "全部 \(displayRows.count) 个文件"
            : "选中的 \(selection.count) 个文件"
    }

    // MARK: 入口

    func presentAutoMatch() {
        guard !isBusy else { return }
        guard !autoMatchTargets.isEmpty else {
            statusMessage = "列表为空，请先添加音频文件"
            return
        }
        showAutoMatchOptions = true
    }

    // MARK: 匹配

    func startAutoMatch() {
        // —— 模式分发（专辑模式的唯一接入点）——
        // 专辑模式换的是「怎么选候选」，写入路径仍旧回到本文件的 performAutoMatchWrite，
        // 所以撤销、字段白名单、保留修改日期这些保障一条都不会少。
        if albumMatch.mode == .album {
            startAlbumMatch()
            return
        }

        let rows = autoMatchTargets
        guard !rows.isEmpty else { return }
        let options = autoMatchOptions
        guard !options.sourceIDs.isEmpty else {
            alert = AlertBox(title: "无法开始自动匹配",
                             message: "请至少勾选一个标签来源。", isError: true)
            return
        }
        if refuseWhileBusy() { return }
        // 兜底（BO#16）：正常入口（选项窗）打开时已补读过；别的入口进来还有待读行时，
        // 后台补读（有进度、可取消），读完再开工 —— 不再在主线程上同步整读。
        if rows.contains(where: { $0.tagsState.isPending }) {
            Task { [weak self] in
                guard let self else { return }
                if await self.materializePendingTagsInBackground(in: rows, title: "自动匹配前补读标签…") {
                    self.startAutoMatch()
                }
            }
            return
        }

        // 用工作副本的标签去查询：用户刚敲进去还没保存的标题也算数。
        let files: [AudioFile] = rows.map { row in
            var f = row.file
            f.tags = row.draft
            return f
        }
        let drafts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.draft) })
        // BO#8：复核表要知道「文件现在有没有封面」。只在这一轮会下封面时才去读。
        let artPlan = options.fetchArtwork
            ? existingArtworkPlan(for: rows) : (known: [URL: ExistingArtworkInfo](), toRead: [URL]())

        autoMatchRunID &+= 1
        let runID = autoMatchRunID

        isBusy = true
        isAutoMatching = true
        progressTitle = "自动匹配标签…"
        progress = BatchProgress(completed: 0, total: files.count)
        statusMessage = "正在联网匹配 \(files.count) 个文件…"
        cancelHandler = { [weak self] in self?.cancelAutoMatch() }

        autoMatchTask = Task { [weak self] in
            let started = Date()
            // 读现有封面与联网匹配**并行**：前者是本地 IO，后者几乎全在等网络，
            // 复核表弹出时尺寸早已读好。取消会一路传到这个子任务。
            async let probed = AppModel.probeExistingArtworks(artPlan.toRead)
            let (results, summary) = await AutoMatchService.matchAll(files, options: options) { p in
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
                self?.finishAutoMatch(runID: runID, results: results,
                                      summary: summary, drafts: drafts, elapsed: elapsed,
                                      existing: finalExisting)
            }
        }
    }

    func cancelAutoMatch() {
        guard isAutoMatching else { return }
        autoMatchRunID &+= 1              // 让在途结果作废
        autoMatchTask?.cancel()
        autoMatchTask = nil
        isAutoMatching = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        statusMessage = "已取消自动匹配"
    }

    private func finishAutoMatch(runID: Int,
                                 results: [AutoMatchResult],
                                 summary: BatchSummary,
                                 drafts: [URL: Tags],
                                 elapsed: TimeInterval,
                                 existing: ExistingArtworkProbe = ExistingArtworkProbe()) {
        guard runID == autoMatchRunID else { return }     // 已被取消
        let artworkWritesTag = ArtworkPolicy.current.writesTag
        isAutoMatching = false
        isBusy = false
        progress = nil
        cancelHandler = nil
        autoMatchTask = nil

        let lyricsAllowed = autoMatchSettings.isFieldEnabled(.lyrics)
        let merge = autoMatchLyricsMerge
        var items: [AutoMatchReviewItem] = []

        for r in results {
            let current = drafts[r.url] ?? Tags()
            var changes: [AutoMatchFieldChange] = []

            // 只留下「确实和当前值不同」的字段：数据层不会用空值覆盖，
            // 这里再滤掉「值没变」的，避免复核表被一堆无意义的行淹没。
            for c in r.edit?.changes ?? [] {
                guard let newValue = c.value, !newValue.isEmpty else { continue }
                let old = AppModel.tagValue(c.field, in: current)
                guard !AppModel.isEquivalentTagValue(c.field, old, newValue) else { continue }
                changes.append(AutoMatchFieldChange(field: c.field, oldValue: old, newValue: newValue))
            }

            // 歌词是二段式单独取回来的，候选本身不带，这里并进同一张改动表。
            //
            // ★ BH 轮病根就在这一行。原先取的是 `r.lyrics?.plain` —— **只有原文，
            // 从不合并译文**。用户明明勾了「翻译」，自动匹配写出去的 LYRICS 与 .lrc
            // 却永远是一水儿的日语原文（写入组装那一处同病，见 `applyAutoMatch`）。
            // 现在统一走 `LyricsMergeSettings.merged`，与「批量下载歌词」同一套口径；
            // 没有译文、或用户关掉了翻译时它原样退化成 plain，行为与从前一字不差。
            //
            // 覆盖语义：`old != text` 这把尺子天然覆盖了「旧词无译文、新词有译文」——
            // 合并后的文本必然与旧的纯原文不同，于是它**就是一处改动**，
            // 照常进复核表（看得见 原 → 新）、照常可以取消勾选。
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
            let errText = r.errors.isEmpty ? nil : r.errors
                .map { "\(SourceBootstrap.displayName($0.sourceID))：\($0.message)" }
                .joined(separator: "\n")

            items.append(AutoMatchReviewItem(
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
                errorText: errText,
                changes: changes,
                artwork: art,
                // BO#8：原封面按磁盘真值（`current` 是行草稿，封面早被清空，永远是 nil）。
                originalArtwork: existing.previews[r.url],
                existingArtwork: existing.info[r.url],
                artworkWritesTag: artworkWritesTag,
                accepted: matched && (!changes.isEmpty || art != nil),
                lyricsHasTranslation: lyricsAllowed && merge.producesTranslation(r.lyrics),
                current: AppModel.displaySnapshot(current),
                candidates: r.candidates,
                selectedCandidateID: r.best?.id ?? r.candidates.first?.id,
                sourceOutcomes: r.sourceOutcomes,
                timingLine: r.timingLine,
                elapsed: r.elapsed))
        }

        // 默认全勾：结果刚出来时「会改的字段」就是「要写的字段」。
        // 复核表上的排除是在这之上做减法。封面例外：文件里已有封面的默认不勾（BO#8）。
        for i in items.indices { items[i].resetAcceptedFields() }

        items.sort { a, b in
            a.statusRank != b.statusRank ? a.statusRank < b.statusRank : a.score > b.score
        }

        autoMatchReview = AutoMatchReview(items: items, summary: summary, elapsed: elapsed,
                                          drafts: drafts, options: autoMatchOptions)
        var note = "自动匹配完成 —— " + summary.description
        // 某个源整轮都在挂时单说一句：没有这句，用户只会看到「忽略 12」而不知道为什么。
        if let sn = autoMatchReview?.sourceNote { note += "；" + sn }
        statusMessage = note
    }

    // MARK: - 换候选 / 行内手动搜索（B2 / B3）
    //
    // 两件事共用同一条重算路径：**拿一条候选，就地把这一行整个重算一遍**。
    // 逐首模式与专辑模式也共用它 —— 复核行本来就是同一个模型，
    // 两边各写一套只会让「换完之后字段对不上」这种 bug 各出一次。

    /// 用一条候选重算一行。纯函数，不碰任何状态，好让两种模式都能安心调用。
    ///
    /// - Parameters:
    ///   - current: 该文件**完整**的当前标签（不是 `item.current` 那个展示子集）。
    ///   - detail: 专辑模式下整组锁定的曲目表，只用来算音轨列怎么显示。
    static func rebuildItem(_ item: AutoMatchReviewItem,
                            with candidate: TrackCandidate,
                            current: Tags,
                            artwork: Data?,
                            lyrics: LyricsBundle?,
                            fields: Set<TagEdit.Field>?,
                            detail: AlbumDetail? = nil,
                            lyricsAllowed: Bool,
                            merge: LyricsMergeSettings = .default) -> AutoMatchReviewItem {
        var out = item
        let edit = candidate.asTagEdit(fields: fields)
        var changes: [AutoMatchFieldChange] = []
        for c in edit.changes {
            guard let newValue = c.value, !newValue.isEmpty else { continue }
            let old = AppModel.tagValue(c.field, in: current)
            guard !AppModel.isEquivalentTagValue(c.field, old, newValue) else { continue }
            changes.append(AutoMatchFieldChange(field: c.field, oldValue: old, newValue: newValue))
        }
        // ★ BH 轮：与首轮那处同病同治 —— 原先是 `lyrics?.plain`，「换候选」重算出来的
        // 那一行会把已经合好的译文又打回纯原文。两处共用同一个 `merged`。
        if lyricsAllowed,
           let text = merge.merged(lyrics)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let old = AppModel.tagValue(.lyrics, in: current)
            if old != text {
                changes.removeAll { $0.field == .lyrics }
                changes.append(AutoMatchFieldChange(field: .lyrics, oldValue: old, newValue: text))
            }
        }
        out.lyricsHasTranslation = lyricsAllowed && merge.producesTranslation(lyrics)

        out.changes = changes
        out.artwork = artwork
        // 换候选之后**接着用**用户先前的排除：他刚把碟号划掉，
        // 顺手换个候选就自己长回来，是最难被发现的一种回归。
        out.resetAcceptedFields(preservingExclusionsFrom: item)
        out.bestTitle = candidate.title
        out.bestArtist = candidate.artist
        out.bestAlbum = candidate.album
        out.sourceID = candidate.sourceID
        out.sourceName = SourceBootstrap.displayName(candidate.sourceID)
        out.score = candidate.matchScore
        out.selectedCandidateID = candidate.id
        out.manuallyChosen = true
        // **手选视为确认**：阈值是给自动决策兜底用的，人已经看过并挑了，不该再被它拦下。
        out.status = .matched
        out.errorText = nil
        out.accepted = out.hasSomethingToWrite
        out.isReloading = false

        let pos = AppModel.trackPosition(of: candidate, in: detail)
        out.trackNumberInDisc = pos.track
        out.discNumber = pos.disc
        out.discCount = pos.discCount
        out.tracksInDisc = pos.tracksInDisc
        return out
    }

    /// 把新搜到的候选并进原有候选表：同一条（同源同 nativeID）不重复摆两遍，
    /// 新的排前面 —— 用户刚搜出来的东西理应先看到。
    static func mergeCandidates(_ existing: [TrackCandidate],
                                _ incoming: [TrackCandidate]) -> [TrackCandidate] {
        var seen = Set<String>()
        var out: [TrackCandidate] = []
        for c in incoming + existing {
            let key = c.sourceID + "\u{1}" + c.nativeID
            if seen.insert(key).inserted { out.append(c) }
        }
        return out
    }

    // MARK: 逐首模式

    /// 换候选：就地重算该行的 原→新 diff、字段 chips 与封面，并自动勾选。
    func changeAutoMatchCandidate(url: URL, to candidateID: UUID) {
        guard let review = autoMatchReview,
              let i = review.items.firstIndex(where: { $0.id == url }),
              let cand = review.items[i].candidates.first(where: { $0.id == candidateID })
        else { return }

        let current = review.drafts[url] ?? Tags()
        let options = review.options
        let lyricsAllowed = autoMatchSettings.isFieldEnabled(.lyrics)
        autoMatchReview?.items[i].isReloading = true

        Task { [weak self] in
            // 与自动选出的最佳候选走同一个补全函数：否则手动换过去的那条会缺年份、
            // 缺封面，看起来像是「换了反而更差」。
            let e = await AutoMatchService.enrich(cand, options: options)
            await MainActor.run {
                guard let self,
                      let i = self.autoMatchReview?.items.firstIndex(where: { $0.id == url })
                else { return }
                var item = self.autoMatchReview!.items[i]
                // 补全后的那条要写回候选表，下次换回来才不缩水。
                if let ci = item.candidates.firstIndex(where: { $0.id == candidateID }) {
                    var merged = e.candidate
                    merged.id = candidateID          // 保住菜单里的身份
                    merged.matchScore = cand.matchScore
                    item.candidates[ci] = merged
                }
                let picked = item.candidates.first { $0.id == candidateID } ?? e.candidate
                item = AppModel.rebuildItem(item, with: picked, current: current,
                                            artwork: e.artwork, lyrics: e.lyrics,
                                            fields: options.fields,
                                            lyricsAllowed: lyricsAllowed,
                                            merge: options.lyricsMerge)
                self.autoMatchReview?.items[i] = item
                self.statusMessage = "已换成《\(picked.title ?? "?")》— \(picked.artist ?? "?")"
                    + "（\(SourceOutcome.displayName(picked.sourceID))），本行已自动勾选"
            }
        }
    }

    /// 行内手动搜索：只对这一行重搜，结果并入候选表并选中最佳。
    func manualSearchAutoMatch(url: URL, query: ManualSearchQuery) {
        guard let review = autoMatchReview,
              let i = review.items.firstIndex(where: { $0.id == url }),
              !query.isEmpty else { return }
        let options = review.options
        autoMatchReview?.items[i].isReloading = true
        autoMatchReview?.items[i].manualQuery = query

        Task { [weak self] in
            let (found, outcomes) = await AutoMatchService.searchCandidates(query.trackQuery,
                                                                           options: options)
            await MainActor.run {
                guard let self,
                      let i = self.autoMatchReview?.items.firstIndex(where: { $0.id == url })
                else { return }
                self.autoMatchReview?.items[i].isReloading = false
                self.autoMatchReview?.items[i].sourceOutcomes = outcomes
                guard let best = found.first else {
                    self.statusMessage = "手动搜索没有结果 —— " + outcomes.inlineSummary
                    return
                }
                let merged = AppModel.mergeCandidates(
                    self.autoMatchReview!.items[i].candidates, found)
                self.autoMatchReview?.items[i].candidates = merged
                self.autoMatchReview?.items[i].candidateCount = merged.count
                self.changeAutoMatchCandidate(url: url, to: best.id)
            }
        }
    }

    // MARK: 复核清单的勾选

    func setAutoMatchAccepted(_ id: URL, _ on: Bool) {
        guard let i = autoMatchReview?.items.firstIndex(where: { $0.id == id }) else { return }
        autoMatchReview?.items[i].accepted = on
    }

    // MARK: 逐字段勾选（按文件选写哪几个字段）
    //
    // 三种作用域，一个落点：都在改 `items[i]` 的 `acceptedFields` / `acceptArtwork`。
    // 因此行内 chip、展开区勾选框、两个批量菜单**天然同步** —— 谁改完，其余三处
    // 下一帧就是新样子，不需要任何一处去通知另一处。

    /// 一个文件的一个写入项。
    func setAutoMatchField(_ url: URL, _ key: ReviewFieldKey, _ on: Bool) {
        guard let i = autoMatchReview?.items.firstIndex(where: { $0.id == url }) else { return }
        autoMatchReview?.items[i].setAccepted(key, on)
    }

    /// 点一下 chip：排除 ↔ 恢复。
    func toggleAutoMatchField(_ url: URL, _ key: ReviewFieldKey) {
        guard let i = autoMatchReview?.items.firstIndex(where: { $0.id == url }) else { return }
        let now = autoMatchReview!.items[i].isAccepted(key)
        autoMatchReview?.items[i].setAccepted(key, !now)
    }

    /// 一组（逐首模式按专辑分的展示组）的一个写入项 —— 「整组不写碟号」。
    /// 下标是分组前的原始下标，与勾选走的是同一套。
    func setAutoMatchField(indices: [Int], _ key: ReviewFieldKey, _ on: Bool) {
        guard autoMatchReview != nil else { return }
        for i in indices where autoMatchReview!.items.indices.contains(i) {
            autoMatchReview!.items[i].setAccepted(key, on)
        }
    }

    /// 整张复核表的一个写入项 —— 「一次性去掉所有音轨号」。
    func setAutoMatchFieldForAll(_ key: ReviewFieldKey, _ on: Bool) {
        guard autoMatchReview != nil else { return }
        for i in autoMatchReview!.items.indices {
            autoMatchReview!.items[i].setAccepted(key, on)
        }
    }

    func setAllAutoMatchAccepted(_ on: Bool) {
        guard autoMatchReview != nil else { return }
        for i in autoMatchReview!.items.indices where autoMatchReview!.items[i].hasSomethingToWrite {
            autoMatchReview!.items[i].accepted = on
        }
    }

    /// 「只选已匹配」——把忽略/失败的行取消勾选。
    func selectOnlyMatchedAutoMatch() {
        guard autoMatchReview != nil else { return }
        for i in autoMatchReview!.items.indices {
            let item = autoMatchReview!.items[i]
            autoMatchReview!.items[i].accepted = item.status == .matched && item.hasSomethingToWrite
        }
    }

    func discardAutoMatchReview() {
        autoMatchReview = nil
        statusMessage = "已放弃本次自动匹配结果"
    }

    // MARK: 写入

    func applyAutoMatchSelection() {
        guard let review = autoMatchReview else { return }
        let picked = review.acceptedItems
        guard !picked.isEmpty else {
            statusMessage = "没有勾选任何可写入的项"
            return
        }
        // 忙时（上一批还在回读刷新）不开工，复核表也别关 —— 结果还留着，等一下再点「应用」。
        if refuseWhileBusy() { return }
        autoMatchReview = nil
        performAutoMatchWrite(picked)
    }

    /// 自动匹配 / 专辑写入的组装起点：用户尚未保存的手工改动（`row.pendingEdit`）。
    ///
    /// BP-B 起，检查器里没保存的封面改动会落进行草稿（`stashArtworkEdit`），`pendingEdit`
    /// 里就带着封面动作。原先这里一律 `.keep` —— 用户换好的封面不写，写完回读时草稿又被
    /// 磁盘值覆盖，改动静默消失。现在照「先排入用户的改动，再让匹配结果覆盖」的原则：
    /// 匹配到的封面**勾上了**才覆盖它，否则用户的封面改动照写。
    func autoMatchBaseEdit(_ row: FileRow) -> TagEdit {
        row.pendingEdit
    }

    /// 专辑模式也走这里（`applyAlbumMatchSelection`），
    /// 因此不能是 private —— 两种模式共用同一条「记历史 → 写入 → 可撤销」路径。
    func performAutoMatchWrite(_ items: [AutoMatchReviewItem]) {
        let preserveDate = settings.preserveModificationDate
        var mtimes: [URL: Date] = [:]

        // 封面策略：`.folderFile` 模式下匹配到的封面存成文件夹图片，音频侧回到 .keep。
        // 逐条组装完编辑集后统一过一遍（见 applyArtworkPolicy），记历史依据的是过完之后
        // 的编辑集——音频侧不动封面时不该把旧封面也旁存一份。
        var assembled: [(url: URL, edit: TagEdit)] = []
        for item in items {
            guard let row = row(id: item.url) else { continue }

            // 写前先记历史（撤消依赖此表），记的是磁盘现状而非工作副本。
            // 先排入用户尚未保存的手工改动，再让匹配结果覆盖同名字段——
            // 否则写盘后的重新读取会把用户的活儿吞掉。
            var edit = autoMatchBaseEdit(row)
            // **只排入勾中的字段**：被排除的既不写盘、也不进下面那次历史旁存 ——
            // 「不写」必须是彻底的，留一半就成了「看起来没写、撤销时却冒出来」。
            for c in item.acceptedChanges { edit.set(c.field, c.newValue) }
            if let data = item.acceptedArtwork {
                edit.artworkAction = .replace([Artwork(data: data,
                                                       mimeType: AppModel.imageMIMEType(of: data),
                                                       caption: item.bestTitle ?? "Cover",
                                                       type: .frontCover)])
            }
            guard !edit.isEmpty else { continue }
            assembled.append((row.file.url, edit))
            if preserveDate, let d = row.modifiedAt { mtimes[row.file.url] = d }
        }

        var (finalPayload, folderJobs, policy) = applyArtworkPolicy(assembled)
        // 匹配到的封面可能大到超出容器上限（FLAC 24 bit 块长），先自动压小（AT-04）。
        let artShrunk = fitArtworksToContainerLimits(&finalPayload)

        guard !finalPayload.isEmpty || !folderJobs.isEmpty else {
            statusMessage = "没有需要写入的改动"
            return
        }

        // 写前快照要的「磁盘现状」取自行 —— 这里只查行（主线程状态），真正的磁盘 IO 留到后台。
        // 记历史必须在 edit 组装完成之后：旁存要依据本次实际改动的字段，
        // 才知道除历史表那 6 列外还得备份哪些（专辑艺术家/风格/注释/作曲/歌词/封面）。
        // 走 writeUndoSnapshot 而不是直接调 UndoService：列表行的 file.tags.artworks
        // 是空的（FileRow 为省内存不驻留封面二进制），助手会在本次真会动封面时先从磁盘把
        // 旧封面读回来，否则换完封面撤消，旧封面回不来。
        let snapshots: [(file: AudioFile, edit: TagEdit)] = finalPayload.compactMap { item in
            row(id: item.url).map { (file: $0.file, edit: item.edit) }
        }
        let written = Set(finalPayload.map(\.url))
        let finalMtimes = mtimes.filter { written.contains($0.key) }
        let padding = currentPaddingPolicy
        let history = historyStore
        let sideCar = sideCarStore
        let total = finalPayload.count

        // BO#16：**先置浮层再干活**。原先写前快照（每首读一张旧封面 + 旁存落盘）在主线程上
        // 同步逐条跑，而且排在 `isBusy/progress` 之前 —— 大封面库上彩虹球几十秒，连浮层都没有。
        isBusy = true
        progressTitle = "写入匹配结果…"
        progress = BatchProgress(completed: 0, total: total,
                                 note: "记录撤消数据 0/\(snapshots.count)", startedAt: Date())

        let task = Task { [weak self] in
            // ① 撤消快照：逐条把磁盘部分甩到后台线程，主线程只报进度、看取消。
            var historyFailures = 0
            var recorded = 0
            let startedAt = self?.progress?.startedAt
            for s in snapshots {
                if Task.isCancelled { break }
                let ok = await AppModel.writeUndoSnapshotOffMain(file: s.file, edit: s.edit,
                                                                 history: history, sideCar: sideCar)
                if !ok { historyFailures += 1 }
                recorded += 1
                self?.progress = BatchProgress(completed: 0, total: total,
                                               currentPath: s.file.url.path,
                                               note: "记录撤消数据 \(recorded)/\(snapshots.count)",
                                               startedAt: startedAt)
            }
            // 快照阶段就取消了：一个文件都不写。
            if Task.isCancelled {
                self?.abandonBatchBeforeWrite("写入匹配结果", recordedSnapshots: recorded)
                return
            }

            // ② 真正写入（可取消：没轮到的文件不写，afterBatch 按「磁盘未变」保留原状）。
            let summary = await BatchEngine.applyEdits(finalPayload,
                                                       concurrency: BatchEngine.recommendedConcurrency(for: finalPayload.map(\.url)),
                                                       paddingPolicy: padding) { p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            let folder = summary.isCancelled
                ? FolderArtworkOutcome()
                : (await self?.runFolderArtwork(folderJobs, policy: policy) ?? FolderArtworkOutcome())
            let noteCount = historyFailures
            await MainActor.run {
                guard let self else { return }
                if preserveDate {
                    for (url, date) in finalMtimes {
                        try? FileManager.default.setAttributes([.modificationDate: date],
                                                               ofItemAtPath: url.path)
                    }
                }
                var notes: [String] = []
                if noteCount > 0 { notes.append("\(noteCount) 条历史记录失败") }
                if let n = AppModel.artworkAutoShrinkNote(artShrunk) { notes.append(n) }
                if let side = self.writeSideNote(folder: folder, summary: summary) { notes.append(side) }
                self.afterBatch(summary,
                                reloadURLs: finalPayload.map(\.url),
                                title: "自动匹配标签",
                                extraNote: notes.isEmpty ? nil : "（" + notes.joined(separator: "；") + "）")
                // 匹配结果只有封面 + folderFile 模式 → 音频一个都没写，别报「成功: 0 …」。
                if finalPayload.isEmpty, let s = folder.statusNote { self.statusMessage = s }
                // 匹配到的歌词按「歌词文件选项」再落一份文件。afterBatch 已用重载后的标签
                // 走过一遍，这里补的是「标签容器拒收歌词字段、但用户仍要歌词文件」的情况——
                // 内容一致时 saveLyricsFile 判定为 unchanged，是彻底的空操作，不会重复写。
                // 失败只反映在状态栏计数里，不影响标签写入结果。
                // BI 轮：自动匹配刚拿到译文、而目录里躺着早先写出的**无译文** .lrc 时，
                // 即使没开「覆盖已有文件」也会把它纠正成含译文版（判据在
                // `LyricsService.shouldUpgradeExistingLyricsFile`），升级数目由
                // `saveLyricsFilesIfNeeded` 往状态栏追一句「.lrc 升级为含译文版 N 个」。
                // 这正是用户报的病象：标签里已经有译文了，.lrc 却永远停在旧版。
                var matchedLyrics: [URL: String] = [:]
                for item in finalPayload {
                    if let v = item.edit.changes.first(where: { $0.field == .lyrics })?.value,
                       !v.isEmpty {
                        matchedLyrics[item.url] = v
                    }
                }
                // BL 轮：afterBatch 那一遍已把「歌词文件：已保存 N · 升级为含译文 M · 已存在跳过 K ·
                // 失败 J」写进状态栏；这一遍是补存，只在真多写出/失败时追一句，不重复记账。
                //
                // BP-E（C 组交接）：补存必须等**回读刷新完**再做。`afterBatch` 返回时行还是写前的样子，
                // 歌词文件按「艺术家 - 标题」这类标签命名、而匹配又改了标题/艺术家时，
                // 原先这一遍会按**旧名**再存出一份（多出一个旧名 .lrc）。挂到 `whenBatchRefreshed`
                // 里，命名用的就是刚写进去的新标签。写失败 / 被取消的文件不补存。
                guard !summary.isCancelled else { return }
                let failedURLs = Set(summary.failures.map(\.url))
                let supplementURLs = finalPayload.map(\.url).filter { !failedURLs.contains($0) }
                let texts = matchedLyrics.filter { !failedURLs.contains($0.key) }
                self.whenBatchRefreshed { [weak self] in
                    self?.saveLyricsFilesIfNeeded(supplementURLs, texts: texts, supplement: true)
                }
            }
        }
        cancelHandler = { task.cancel() }
    }

    /// 批量写入在「记录撤消数据」阶段就被取消：一个文件都没写，收起浮层。
    /// 已记下的快照与文件现状一模一样，撤消它们不会改动任何东西。
    func abandonBatchBeforeWrite(_ title: String, recordedSnapshots: Int) {
        isBusy = false
        progress = nil
        cancelHandler = nil
        statusMessage = "已取消\(title)：一个文件都没有写"
            + (recordedSnapshots > 0
               ? "（已记下的 \(recordedSnapshots) 条撤消记录与文件现状相同，撤消它们不会改动任何东西）" : "")
    }

    // MARK: 小工具

    /// 「原值 → 新值」到底算不算一处改动。逐首模式与专辑模式共用这一把尺子。
    ///
    /// 碟号是唯一需要特判的字段：在线源一律写全 `1/1`（见 `AlbumDetail.candidate(for:)`
    /// 的「单碟也写 1/1」），而文件里常年只有一个裸 `1`。两者含义完全相同——单碟专辑的
    /// 第 1 碟——却会让复核表凭空多出一行 `1 → 1/1`、字段 chips 多亮一个「碟号」，
    /// 用户还得为这个「改动」多写一次盘。视为等价：不显示、不计数、也不写。
    ///
    /// 只在**总数为 1** 时才丢掉后半段。`2/2` 与 `2` 不等价——「共 2 碟」是真信息。
    static func isEquivalentTagValue(_ field: TagEdit.Field, _ old: String, _ new: String) -> Bool {
        if old == new { return true }
        guard field == .disc else { return false }
        return normalizedDiscValue(old) == normalizedDiscValue(new)
    }

    /// `01` → `1`；`1/1` → `1`；`1/2` → `1/2`（总数 > 1 时原样保留）。
    static func normalizedDiscValue(_ s: String) -> String {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .split(separator: "/", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = parts.first, let n = Int(head) else { return s }
        let total = parts.count > 1 ? Int(parts[1]) : nil
        guard let total, total > 1 else { return "\(n)" }
        return "\(n)/\(total)"
    }

    /// 取某字段在一份标签里的当前值，用于生成「原值 → 新值」。
    static func tagValue(_ field: TagEdit.Field, in tags: Tags) -> String {
        switch field {
        case .title:       return tags.title ?? ""
        case .artist:      return tags.artist ?? ""
        case .albumArtist: return tags.albumArtist ?? ""
        case .album:       return tags.album ?? ""
        case .year:        return tags.year ?? ""
        case .track:       return tags.trackString ?? ""
        case .disc:        return tags.discString ?? ""
        case .genre:       return tags.genre ?? ""
        case .comment:     return tags.comment ?? ""
        case .composer:    return tags.composer ?? ""
        case .lyricist:    return tags.lyricist ?? ""
        case .lyrics:      return tags.lyrics ?? ""
        }
    }

    /// 复核表要显示「原 → 新」，没改动的字段也得有「原」，
    /// 所以把当前标签里界面会用到的那几列一次性抄一份。**只读**，写入路径不看它。
    static func displaySnapshot(_ tags: Tags) -> [TagEdit.Field: String] {
        var d: [TagEdit.Field: String] = [:]
        for f in [TagEdit.Field.title, .artist, .album, .albumArtist, .year, .track, .disc] {
            d[f] = tagValue(f, in: tags)
        }
        return d
    }

    /// 下载回来的封面只有字节，靠魔数判类型（TagLib 写入需要正确的 MIME）。
    static func imageMIMEType(of data: Data) -> String {
        let b = [UInt8](data.prefix(8))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        return "image/jpeg"
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}


// MARK: - 自动匹配的歌词合并设置（BH 轮）
//
// 「自动匹配」与「批量下载歌词」共用**同一份**设置：用户在歌词文件选项里改的
// 「合并翻译 / 合并格式」，两条路径都该认。原先自动匹配压根没有这一档设置，
// 于是勾了翻译也只写原文 —— 这一段就是把那条线接上。
extension AppModel {

    /// 交给数据层的合并口径。`separator` 与 `skipOriginalWhenTranslated` 目前没有
    /// 独立的界面项，用与 `LyricsFetchOptions` 一致的缺省值。
    var autoMatchLyricsMerge: LyricsMergeSettings {
        LyricsMergeSettings(includeTranslation: settings.lyricsFile.includeTranslation,
                            mergeFormat: settings.lyricsFile.mergeFormat)
    }

    /// `AutoMatchStore.options` 再加上歌词合并口径。
    ///
    /// 为什么不直接写进 `AutoMatchStore`：那个 store 拿不到 `AppSettings`，
    /// 而这份设置的**唯一权威**在 `settings.lyricsFile`。在这里合流，
    /// 两处设置就不会各说各话。
    var autoMatchOptions: AutoMatchOptions {
        var o = autoMatchSettings.options
        o.lyricsMerge = autoMatchLyricsMerge
        return o
    }
}

// MARK: - 复核表底部的写前预估（BH 轮 C3 / C4）
//
// 用户抱怨「105 首跑了 10 分钟」。实测匹配那一段 20 首只要 26 秒（≈1.3 s/首），
// 105 首折算 2.3 分钟 —— 剩下的时间几乎全在**写盘**那一段：
// TF 卡上的大文件首次嵌封面会**整文件重写**，那是物理搬动，改代码救不了。
// 救不了就得**先说清楚**：在按下「应用」之前把量级摆出来，并给出真正管用的那条出路
// （封面改存「文件夹图片」，音频一个字节都不动）。

struct AutoMatchWriteForecast {
    var plan: TagService.WriteCostPlan?
    /// 落点卷是不是可移动 / 外置（TF 卡、U 盘、移动硬盘）。
    var isSlowMedia: Bool = false
    var volumeName: String?

    var rewriteCount: Int { plan?.fullRewriteCount ?? 0 }
    /// 「将整文件重写 N 个文件（搬动约 X GB…），预计 …」
    var warningText: String? { plan?.warningText }
    /// TF 卡提示只在「真要大搬动」且「落点确实是可移动卷」时才出现 ——
    /// 无条件常驻的提示会被当成装饰，真正该看见它的那一次反而看不见。
    var suggestsFolderArtwork: Bool { isSlowMedia && rewriteCount > 0 }
}

extension AppModel {

    /// 复核表底部用的写前预估。**纯只读**：`estimatedWriteCost` 每个文件只读几百字节头部。
    ///
    /// 组装口径与 `performAutoMatchWrite` 保持一致（同样过一遍封面策略），
    /// 否则「预估说要重写 20 个、真写下去却是 0 个」那种事迟早发生。
    func autoMatchWriteForecast(_ items: [AutoMatchReviewItem]) -> AutoMatchWriteForecast {
        var out = AutoMatchWriteForecast()
        var assembled: [(url: URL, edit: TagEdit)] = []
        for item in items {
            guard let row = row(id: item.url) else { continue }
            var edit = autoMatchBaseEdit(row)      // 与 performAutoMatchWrite 同一个起点
            for c in item.acceptedChanges { edit.set(c.field, c.newValue) }
            if let data = item.acceptedArtwork {
                edit.artworkAction = .replace([Artwork(data: data,
                                                       mimeType: AppModel.imageMIMEType(of: data),
                                                       caption: item.bestTitle ?? "Cover",
                                                       type: .frontCover)])
            }
            guard !edit.isEmpty else { continue }
            assembled.append((row.file.url, edit))
        }
        guard !assembled.isEmpty else { return out }
        let (planned, _, _) = applyArtworkPolicy(assembled)
        out.plan = TagService.estimatedWriteCost(planned, padding: currentPaddingPolicy)
        let traits = VolumeInfo.traits(of: assembled[0].url)
        out.isSlowMedia = traits.isSlowMedia
        out.volumeName = traits.name
        return out
    }

    /// 复核表上那个「一键切到文件夹图片」按钮。只改封面落地方式，别的一个字不动。
    func switchToFolderArtworkMode() {
        ArtworkStore.shared.artworkEmbedMode = .folderFile
        statusMessage = "封面已改为「文件夹图片」模式：音频文件一个字节都不会被重写"
    }
}

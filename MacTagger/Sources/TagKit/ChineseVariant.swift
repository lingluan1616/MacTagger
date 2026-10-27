//
//  ChineseVariant.swift
//  MacTagger — 简繁归一（在线结果统一转成用户库的字形）
//
//  为什么要有这一层：
//  用户的库是简体，而**在线源给回来的华语元数据大量是繁体**。
//  最典型的一条链：iTunes `country=CN` 整个商店已经空了（见 ITunesSource 注释），
//  自动回退到港区之后拿回来的就是 `周杰倫 / 國語流行樂 / 鄧麗君`。
//  中文四源同样有繁体条目（港台版专辑、粤语碟）。不归一的话，
//  同一个艺术家在库里会同时存在简繁两种写法，排序、筛选、按艺术家统一标签全部断链。
//
//  两条设计底线：
//  1. **归一必须发生在打分之前**。简体查询串去比繁体候选，`MatchScorer` 的字面相似度
//     会平白低一大截（"稻香/周杰伦" vs "稻香/周杰倫" 差一个字），本来该采纳的候选
//     被压到阈值以下判成「忽略」。所以各服务的归一入口都排在 rank/score 之前。
//  2. **引擎装不上就原样返回**。`MTOpenCC.isAvailable` 为 false 时 `convert` 是恒等函数，
//     整条链照常工作，只是不转字形 —— 绝不因为少了个可选依赖就让匹配功能失效。
//
//  引擎：Homebrew opencc（`brew install opencc`），经 `Sources/TagLibBridge/MTOpenCC.mm` 桥接。
//

import Foundation

// MARK: - 策略

/// 在线结果的字形策略。持久化用 rawValue，别改字符串。
public enum ChineseVariantPolicy: String, CaseIterable, Sendable, Identifiable, Codable {
    /// 不转换，源给什么就是什么。
    case none
    /// 统一转简体（默认）。
    case simplified
    /// 统一转繁体。
    case traditional

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none:        return "不转换"
        case .simplified:  return "简体"
        case .traditional: return "繁体"
        }
    }

    public var menuLabel: String {
        switch self {
        case .none:        return "不转换（源给什么用什么）"
        case .simplified:  return "统一转简体"
        case .traditional: return "统一转繁体"
        }
    }

    /// 恒等策略走快路，调用方不必到处写 `if policy != .none`。
    public var isIdentity: Bool { self == .none }
}

// MARK: - 引擎

/// OpenCC 的 Swift 门面。线程安全（原生层持锁），转换结果带进程内缓存。
public enum ChineseVariant {

    // MARK: 环境

    /// 引擎是否可用。false 时 `convert` 恒等返回。
    public static var isAvailable: Bool { MTOpenCC.isAvailable }

    /// 实际解析到的 OpenCC 配置目录，诊断用。
    public static var configDirectory: String? { MTOpenCC.configDirectory }

    /// 不可用的原因；可用时为 nil。
    public static var unavailableReason: String? { MTOpenCC.unavailableReason }

    /// 一句话环境描述，probe 与设置面板共用。
    public static var environmentSummary: String {
        if isAvailable {
            return "OpenCC 可用（配置目录 \(configDirectory ?? "?")）"
        }
        return "OpenCC 不可用：\(unavailableReason ?? "未知原因")　—— 简繁转换将原样返回"
    }

    // MARK: 全局默认

    /// **在线结果归一的进程级默认策略**。
    ///
    /// 为什么要有它，而不是把策略一路当参数传下去：
    /// `AlbumMatchOptions` / `bestLyrics` 这些入口的构造点散在 `AppModel+AlbumMatch` 等
    /// 本轮不许改的文件里，参数传不进去。这里照搬 `TagService.legacyEncoding` 的既有做法 ——
    /// AppSettings 在 init 与每次切换时把用户选择推给数据层的这一个静态量，
    /// 各选项结构的 `chineseVariant` 默认值取它。probe 用 `--zh` 显式覆盖，
    /// 数据层出厂值是 `.none`（不转），所以离线自检与旧行为完全一致。
    public static var onlineDefault: ChineseVariantPolicy {
        get { defaultLock.lock(); defer { defaultLock.unlock() }; return _onlineDefault }
        set { defaultLock.lock(); _onlineDefault = newValue; defaultLock.unlock() }
    }

    private static let defaultLock = NSLock()
    nonisolated(unsafe) private static var _onlineDefault: ChineseVariantPolicy = .none

    // MARK: 缓存

    /// 缓存上限。艺术家/专辑/流派这几个字段在一个库里高度重复，
    /// 3000 首歌往往只有几百个不同的艺术家名 —— 缓存把 OpenCC 的调用次数砍掉一个数量级。
    /// 超出上限就整体清空（LRU 的簿记成本在这个量级上不划算）。
    private static let cacheLimit = 4000

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// 清空缓存。测试与「重新装载引擎」时用。
    public static func resetCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    // MARK: 转换

    /// 把一段文本转成目标字形。
    ///
    /// 三条快路，顺序不能换：
    /// 1. `.none` / 空串 → 原样返回，一次锁都不用加；
    /// 2. **纯 ASCII → 原样返回**。英文标题占库里很大一部分，让它们白跑一次 OpenCC
    ///    与一次缓存查找纯属浪费；
    /// 3. 命中缓存 → 直接返回。
    public static func convert(_ s: String, to policy: ChineseVariantPolicy) -> String {
        apply(s, policy)
    }

    /// 可选串版本，nil 原样透传。
    public static func convert(_ s: String?, to policy: ChineseVariantPolicy) -> String? {
        guard let s else { return nil }
        return apply(s, policy)
    }

    /// 两个重载共用的实现。**不要**让重载互相调用 —— `String` 可隐式提升成 `String?`，
    /// 编译器会判成 ambiguous（已踩过）。
    private static func apply(_ s: String, _ policy: ChineseVariantPolicy) -> String {
        guard !policy.isIdentity, !s.isEmpty else { return s }
        // 没有一个非 ASCII 标量就不可能含汉字。
        guard s.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return s }

        let key = policy.rawValue + "\u{1}" + s
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let direction: MTChineseDirection = policy == .simplified
            ? .toSimplified
            : .toTraditional
        let out = MTOpenCC.convert(s, direction: direction)

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = out
        lock.unlock()
        return out
    }

    /// 这段文本在该策略下会不会变。批量转换的预览表用它挑出「真的要改」的行。
    public static func changes(_ s: String?, to policy: ChineseVariantPolicy) -> Bool {
        guard let s, !s.isEmpty, !policy.isIdentity else { return false }
        return convert(s, to: policy) != s
    }
}

// MARK: - 值类型扩展

public extension Tags {

    /// **会被简繁转换碰到的文本字段**。年份、音轨号、碟号是数字，注释里常有 URL 与
    /// 播放器写的标记，都不该动字形 —— 但注释确实常被人写成中文说明，所以留在表内，
    /// 由调用方按字段白名单决定要不要转（批量转换面板可以逐字段勾选）。
    static let convertibleFields: [TagEdit.Field] = [
        .title, .artist, .albumArtist, .album, .genre,
        .composer, .lyricist, .comment, .lyrics
    ]

    /// 取某个可转换字段的当前值。
    func value(for field: TagEdit.Field) -> String? {
        switch field {
        case .title:       return title
        case .artist:      return artist
        case .albumArtist: return albumArtist
        case .album:       return album
        case .genre:       return genre
        case .composer:    return composer
        case .lyricist:    return lyricist
        case .comment:     return comment
        case .lyrics:      return lyrics
        case .year:        return year
        case .track:       return trackString
        case .disc:        return discString
        }
    }

    /// 把全部文本字段统一成目标字形。数字字段与封面原样保留。
    func converted(to policy: ChineseVariantPolicy) -> Tags {
        guard !policy.isIdentity else { return self }
        var out = self
        out.title       = ChineseVariant.convert(title, to: policy)
        out.artist      = ChineseVariant.convert(artist, to: policy)
        out.albumArtist = ChineseVariant.convert(albumArtist, to: policy)
        out.album       = ChineseVariant.convert(album, to: policy)
        out.genre       = ChineseVariant.convert(genre, to: policy)
        out.comment     = ChineseVariant.convert(comment, to: policy)
        out.composer    = ChineseVariant.convert(composer, to: policy)
        out.lyricist    = ChineseVariant.convert(lyricist, to: policy)
        out.lyrics      = ChineseVariant.convert(lyrics, to: policy)
        return out
    }
}

public extension TrackCandidate {

    /// 候选的全部文本字段统一字形。
    /// **`sourceID` / `nativeID` / `albumID` / URL 一个都不能动** —— 那些是主键，
    /// 转了之后二段式请求（取详情 / 取封面 / 取歌词）就全找不到东西了。
    func converted(to policy: ChineseVariantPolicy) -> TrackCandidate {
        guard !policy.isIdentity else { return self }
        var out = self
        out.title       = ChineseVariant.convert(title, to: policy)
        out.artist      = ChineseVariant.convert(artist, to: policy)
        out.album       = ChineseVariant.convert(album, to: policy)
        out.albumArtist = ChineseVariant.convert(albumArtist, to: policy)
        out.genre       = ChineseVariant.convert(genre, to: policy)
        out.composer    = ChineseVariant.convert(composer, to: policy)
        out.lyricist    = ChineseVariant.convert(lyricist, to: policy)
        return out
    }
}

public extension AlbumTrack {
    func converted(to policy: ChineseVariantPolicy) -> AlbumTrack {
        guard !policy.isIdentity else { return self }
        var out = self
        out.title  = ChineseVariant.convert(title, to: policy)
        out.artist = ChineseVariant.convert(artist, to: policy)
        return out
    }
}

public extension AlbumDetail {
    /// 专辑名、专辑艺术家、以及**整张曲目表**一起转 —— 只转专辑名不转曲目名的话，
    /// 写进文件的标题仍是繁体，等于没转。
    func converted(to policy: ChineseVariantPolicy) -> AlbumDetail {
        guard !policy.isIdentity else { return self }
        var out = self
        out.title  = ChineseVariant.convert(title, to: policy)
        out.artist = ChineseVariant.convert(artist, to: policy)
        out.tracks = tracks.map { $0.converted(to: policy) }
        return out
    }
}

public extension LyricsBundle {
    /// 原词 / 翻译 / 逐字三段一起转。逐字歌词（KRC / klyric）是带时间戳的结构化文本，
    /// OpenCC 只改汉字、不碰 `[00:12.34]` 这类 ASCII，时间轴不会被破坏。
    func converted(to policy: ChineseVariantPolicy) -> LyricsBundle {
        guard !policy.isIdentity else { return self }
        var out = self
        out.plain      = ChineseVariant.convert(plain, to: policy)
        out.translated = ChineseVariant.convert(translated, to: policy)
        out.wordByWord = ChineseVariant.convert(wordByWord, to: policy)
        return out
    }
}

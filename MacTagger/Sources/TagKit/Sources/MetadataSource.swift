//
//  MetadataSource.swift
//  MacTagger — 在线数据源适配器层的统一契约
//
//  设计原则（来自 C 报告的实测结论）：
//  1. 主程序只依赖本协议，不依赖任何具体源。任一源失效只需删掉一个适配器文件。
//  2. 能力声明式：界面据 `capabilities` 决定某个源出不出现在「歌词来源」等下拉里，
//     避免对不支持逐字歌词的源发无效请求。
//  3. 候选者必须携带源专属 ID —— 所有源的详情/歌词/封面都是二段式请求。
//

import Foundation

// MARK: - 能力声明

public struct SourceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let searchTracks   = SourceCapabilities(rawValue: 1 << 0)
    public static let searchAlbums   = SourceCapabilities(rawValue: 1 << 1)
    public static let artwork        = SourceCapabilities(rawValue: 1 << 2)
    public static let lyrics         = SourceCapabilities(rawValue: 1 << 3)
    /// 翻译歌词（网易云 tlyric / QQ trans）
    public static let translatedLyrics = SourceCapabilities(rawValue: 1 << 4)
    /// 逐字歌词（网易云 klyric / 酷狗 KRC）
    public static let wordByWordLyrics = SourceCapabilities(rawValue: 1 << 5)
    /// 权威元数据：MBID、厂牌、条码
    public static let authoritative  = SourceCapabilities(rawValue: 1 << 6)
    /// 需要用户自备 API key
    public static let requiresAPIKey = SourceCapabilities(rawValue: 1 << 7)
}

// MARK: - 查询与候选

/// 一次匹配查询。字段均可为空，适配器自行决定如何拼查询串。
public struct TrackQuery: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// 无标题时的兜底：文件名（已去扩展名）。对应原版「标题或文件名 / 文件名」搜索条件。
    public var filename: String?
    /// 时长（秒），用于给候选打分。0 表示未知。
    public var duration: TimeInterval

    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                filename: String? = nil, duration: TimeInterval = 0) {
        self.title = title; self.artist = artist; self.album = album
        self.filename = filename; self.duration = duration
    }

    /// 供各源拼接的查询串：优先 "标题 艺术家"，无标题时退回文件名。
    public var searchTerm: String {
        var parts: [String] = []
        if let t = title, !t.isEmpty { parts.append(t) } else if let f = filename, !f.isEmpty { parts.append(f) }
        if let a = artist, !a.isEmpty { parts.append(a) }
        return parts.joined(separator: " ")
    }

    public var isEmpty: Bool { searchTerm.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// 搜索返回的一个候选。必须携带源专属 ID 以便二段式取详情。
public struct TrackCandidate: Identifiable, Sendable, Equatable {
    public var id = UUID()
    /// 来源标识，对应 MetadataSource.id
    public var sourceID: String
    /// 源内主键（网易云 id / QQ songmid / 酷狗 hash / 酷我 rid / iTunes trackId / MB recording MBID）
    public var nativeID: String
    /// 专辑侧主键，取封面常需要（QQ albummid / 酷狗 album_id / MB release MBID）
    public var albumID: String?
    /// 源内**数字**主键。
    ///
    /// 只有 QQ 用得上：取翻译/罗马音的 `music.musichallSong.PlayLyricInfo / GetPlayLyricInfo`
    /// 只认数字 `songID`，不认 `songmid`；而 `nativeID` 装的是 mid（封面、详情都靠它）。
    /// 两个键必须同时带着走，否则拿到候选之后就没法再取带翻译的那份歌词。
    public var numericID: String?

    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: String?
    public var trackNumber: String?
    public var discNumber: String?
    public var genre: String?
    /// 作曲 / 作词。多数搜索接口不给，通常从歌词的署名行提取（见 LyricsService.credits）。
    public var composer: String?
    public var lyricist: String?
    public var durationSeconds: TimeInterval
    public var artworkURL: URL?

    /// 匹配打分（0…1），由 `MatchScorer` 填充，与源无关。
    public var matchScore: Double = 0

    public init(sourceID: String, nativeID: String, albumID: String? = nil) {
        self.sourceID = sourceID; self.nativeID = nativeID; self.albumID = albumID
        self.durationSeconds = 0
    }

    /// 转成可写入的标签改动集。仅包含非空字段——绝不用空值覆盖用户已有的标签。
    public func asTagEdit(fields: Set<TagEdit.Field>? = nil) -> TagEdit {
        var edit = TagEdit()
        func put(_ f: TagEdit.Field, _ v: String?) {
            guard let v, !v.isEmpty else { return }
            if let fields, !fields.contains(f) { return }
            edit.set(f, v)
        }
        put(.title, title); put(.artist, artist); put(.album, album)
        put(.albumArtist, albumArtist); put(.year, year)
        put(.track, trackNumber); put(.disc, discNumber); put(.genre, genre)
        put(.composer, composer); put(.lyricist, lyricist)
        return edit
    }
}

/// 歌词包。原词、翻译、逐字分开存放，由界面决定如何合并
/// （原版有 4 种合并格式，见 B 报告 5.2 节 D 条）。
public struct LyricsBundle: Sendable, Equatable {
    public var plain: String?
    public var translated: String?
    public var wordByWord: String?
    /// 罗马音／音译轨（QQ `roma`、酷狗 `[language:]` 里 `type:0` 的那一段、网易云 `romalrc`）。
    ///
    /// 为什么单开一格而不是塞进 `translated`：日文/韩文曲目上这两轨会**同时存在**，
    /// 合并成一份就必然丢掉一份；而用户要的是「中文翻译行」，罗马音挤掉翻译正是本轮要修的病。
    public var romanized: String?
    public var sourceID: String
    /// 这份翻译是怎么来的。**只有不是本版本自带的译文时才非空**（BG 轮新增）。
    ///
    /// 场景：Live / MV版 / Remix 这些版本在各源普遍只有日文原词、没有中文译文，
    /// 而同一首歌的**录音室版**有译文。`LyricsService` 会把录音室版的译文
    /// 按歌词行对齐「移植」到本版本的时间轴上，此时这里写
    /// 「翻译来自录音室版《…》（源），按歌词行对齐，n/m 行」。
    /// 界面与 probe 拿它给用户一个交代 —— 移植过来的翻译不是本场录音的官方译文，
    /// 不说清楚就是在骗人。
    public var translationSourceNote: String?

    public init(sourceID: String, plain: String? = nil,
                translated: String? = nil, wordByWord: String? = nil,
                romanized: String? = nil,
                translationSourceNote: String? = nil) {
        self.sourceID = sourceID; self.plain = plain
        self.translated = translated; self.wordByWord = wordByWord
        self.romanized = romanized
        self.translationSourceNote = translationSourceNote
    }

    public var isEmpty: Bool {
        plain == nil && translated == nil && wordByWord == nil && romanized == nil
    }

    /// 有没有可用的翻译行。批量歌词的「有翻译优先」全靠它判。
    public var hasTranslation: Bool { translated?.isEmpty == false }
}

// MARK: - 专辑曲目表

/// 专辑里的一首曲目。只保留「对齐本地文件」真正用得上的字段。
public struct AlbumTrack: Sendable, Equatable {
    /// 碟内音轨号，1 起。
    public var number: Int
    /// 碟号，1 起。单碟专辑恒为 1。
    public var disc: Int
    public var title: String
    /// 秒。取不到为 0 —— 对齐时会自动把时长这一维摊掉。
    public var durationSeconds: TimeInterval
    /// 该曲目自己的艺术家（合作曲目与专辑艺术家不同）。
    public var artist: String?
    /// 源内曲目主键，供「换一张专辑后还要取歌词/封面」用。
    public var nativeID: String?

    public init(number: Int, disc: Int = 1, title: String,
                durationSeconds: TimeInterval = 0,
                artist: String? = nil, nativeID: String? = nil) {
        self.number = number; self.disc = disc; self.title = title
        self.durationSeconds = durationSeconds
        self.artist = artist; self.nativeID = nativeID
    }
}

/// 一张专辑的完整曲目表。**专辑模式的核心数据**：
/// 有了它才能把「这个文件夹里的 11 个文件」整体对到「这张专辑的 11 首曲目」上，
/// 而不是让每个文件各自去搜索结果里瞎猜版本。
public struct AlbumDetail: Sendable, Equatable, Identifiable {
    public var id: String { sourceID + ":" + albumID }
    public var sourceID: String
    /// 源内专辑主键（iTunes collectionId / 网易云 album id / QQ albumMid / MB release MBID）。
    public var albumID: String
    public var title: String?
    public var artist: String?
    public var year: String?
    /// 官方声明的曲目总数。与 `tracks.count` 可能不等——
    /// 网易云会因版权下架少给几首，声明值仍是原始曲目数。
    public var trackCount: Int
    public var discCount: Int
    public var tracks: [AlbumTrack]
    public var artworkURL: URL?

    public init(sourceID: String, albumID: String,
                title: String? = nil, artist: String? = nil, year: String? = nil,
                trackCount: Int = 0, discCount: Int = 1,
                tracks: [AlbumTrack] = [], artworkURL: URL? = nil) {
        self.sourceID = sourceID; self.albumID = albumID
        self.title = title; self.artist = artist; self.year = year
        self.trackCount = trackCount; self.discCount = discCount
        self.tracks = tracks; self.artworkURL = artworkURL
    }

    /// 对齐时以实际拿到的曲目条数为准；声明值只在打分时当参考。
    public var effectiveTrackCount: Int { max(trackCount, tracks.count) }

    /// 实际碟数：声明值与曲目表里出现过的最大碟号取大 —— 源少声明碟数时以曲目表为准。
    public var effectiveDiscCount: Int { max(1, discCount, tracks.map(\.disc).max() ?? 1) }

    /// 某张碟上的曲目数。**`trackCount` 是全辑总数（45），不是每碟的**，
    /// 所以多碟时必须按 `disc` 分组现数；单碟直接退回 `effectiveTrackCount`，
    /// 保住「声明 11 首但只拿到 9 首时仍写 n/11」的既有行为。
    public func trackCount(inDisc disc: Int) -> Int {
        guard effectiveDiscCount > 1 else { return effectiveTrackCount }
        let n = tracks.reduce(0) { $1.disc == disc ? $0 + 1 : $0 }
        return n > 0 ? n : effectiveTrackCount
    }

    public var displayTitle: String { title ?? albumID }

    /// 一行摘要：《魔杰座》周杰伦 · 2008 · 11 首
    public var summary: String {
        var parts = ["《\(displayTitle)》"]
        if let a = artist { parts.append(a) }
        if let y = year { parts.append(y) }
        parts.append("\(tracks.count) 首")
        return parts.joined(separator: " · ")
    }

    /// 生成某首曲目的可写候选。专辑级字段（专辑/专辑艺术家/年份/碟号）整组统一，
    /// 曲目级字段（标题/音轨号/艺术家）逐首取——这正是专辑模式相对逐首模式的全部价值。
    public func candidate(for track: AlbumTrack) -> TrackCandidate {
        var c = TrackCandidate(sourceID: sourceID,
                               nativeID: track.nativeID ?? albumID,
                               albumID: albumID)
        c.title = track.title
        c.artist = track.artist ?? artist
        c.album = title
        c.albumArtist = artist
        c.year = year
        // TRACKNUMBER 按标签规范写「该碟内序号/该碟曲目数」，碟别信息一律交给 DISCNUMBER。
        // 双碟专辑第 2 碟第 7 首应写 7/21，写成 7/45（全辑总数）会让播放器
        // 把两张碟当成一张连号的碟排序，也和界面显示的 2-07/21 对不上。
        let total = trackCount(inDisc: track.disc)
        c.trackNumber = total > 0 ? "\(track.number)/\(total)" : "\(track.number)"
        // 单碟也写 1/1：原版「碟号」本就是可编辑字段（B 报告 5.2 节 B 条），写全无害且更明确。
        c.discNumber = "\(track.disc)/\(effectiveDiscCount)"
        c.durationSeconds = track.durationSeconds
        c.artworkURL = artworkURL
        return c
    }
}

// MARK: - 源协议

public protocol MetadataSource: Sendable {
    /// 稳定标识，用于配置持久化。例："netease" / "qq" / "kugou" / "itunes"
    var id: String { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }

    /// 搜索候选。返回空数组表示没搜到，抛错表示源本身出了问题。
    func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate]

    /// 补全候选的详情（音轨号、碟号、年份等搜索结果里常缺的字段）。
    /// 源若无需二段式请求，直接返回入参即可。
    func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate

    /// 取封面字节。不支持则返回 nil。
    func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data?

    /// 取歌词。不支持则返回 nil。
    func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle?

    /// 用候选携带的 `albumID` 拉整张专辑的曲目表。不支持则返回 nil。
    /// 专辑模式（`AlbumMatchService`）唯一依赖的新增能力；逐首模式完全不碰它。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail?
}

/// 默认实现：让只做搜索的源不必写空方法。
public extension MetadataSource {
    func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate { candidate }
    func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? { nil }
    func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? { nil }
    /// 默认不支持整碟拉取。老源一行不改也能继续编译。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? { nil }
}

// MARK: - 错误

public enum SourceError: LocalizedError, Sendable {
    case network(String)
    case httpStatus(Int)
    case decoding(String)
    case rateLimited
    case missingAPIKey(String)
    /// HTTP 200 但业务层为空/失败 —— C 报告实测 QQ 搜索被风控静默置空即属此类，
    /// 只看状态码会把它当成功。
    case emptyResult(String)
    case unsupported
    /// **熔断器开闸**：这个源刚连续超时了好几次，已被暂停到 `until`。
    /// 与其它错误的本质区别：它**一发请求都没发出去**，是本地立即返回的 —— 因此
    /// 既不占用对方的连接，也不该被当成「这次请求失败了」计入健康台账的失败率。
    /// 关联值：源 id + 恢复时刻 + **为什么开的闸**（「连续超时」/「限流（HTTP 429）」/
    /// 「疑似被风控置空」）。原因必须一路带到结果条 —— 「暂停中」不说原因，
    /// 用户既不知道该等还是该换源，也分不清是自己网慢还是被对方限流了。
    case circuitOpen(String, Date, String?)

    public var errorDescription: String? {
        switch self {
        case .network(let m):      return "网络错误：\(m)"
        case .httpStatus(let c):   return "服务器返回 HTTP \(c)"
        case .decoding(let m):     return "响应解析失败：\(m)"
        case .rateLimited:         return "请求过于频繁，已被限流"
        case .missingAPIKey(let s):return "\(s) 需要 API key，请在偏好设置中填写"
        case .emptyResult(let m):  return "未获得有效结果：\(m)"
        case .unsupported:         return "该数据源不支持此操作"
        case .circuitOpen(let id, let until, let why):
            let head = why?.isEmpty == false ? why! : "暂时不稳定"
            // 暂停到期时刻已过却仍被拒 = 半开探测那一发正在飞（`SourceCircuitBreaker.acquire`
            // 只有这一支会带着过期的 `until` 拒绝，对应快照 `isProbing == true`）。
            // 此时没有倒计时可报，「已暂停 0 秒后自动恢复」读着像卡住了（BP-H 轮）。
            let remaining = until.timeIntervalSinceNow
            guard remaining > 0 else {
                return "\(SourceOutcome.displayName(id))\(head)，正在探测是否恢复"
            }
            let secs = Int(remaining.rounded(.up))
            return "\(SourceOutcome.displayName(id))\(head)，已暂停 \(secs) 秒后自动恢复"
        }
    }
}

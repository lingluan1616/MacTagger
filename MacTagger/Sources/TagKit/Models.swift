//
//  Models.swift
//  MacTagger — TagKit 数据模型
//
//  这一层是纯 Swift 值类型，不依赖 AppKit，方便测试与在 CLI 中复用。
//

import Foundation

// MARK: - 封面

/// 封面图类型（对齐 ID3v2 APIC）。
public enum PictureType: Int, CaseIterable, Sendable, Hashable {
    case other = 0
    case fileIcon = 1
    case otherFileIcon = 2
    case frontCover = 3
    case backCover = 4
    case leafletPage = 5
    case media = 6
    case leadArtist = 7
    case artist = 8
    case conductor = 9
    case band = 10
    case composer = 11
    case lyricist = 12
    case recordingLocation = 13
    case duringRecording = 14
    case duringPerformance = 15
    case movieScreenCapture = 16
    case colouredFish = 17
    case illustration = 18
    case bandLogo = 19
    case publisherLogo = 20

    public var localizedName: String {
        switch self {
        case .other: return "其它"
        case .fileIcon: return "文件图标 32x32"
        case .otherFileIcon: return "其它文件图标"
        case .frontCover: return "封面"
        case .backCover: return "封底"
        case .leafletPage: return "内页"
        case .media: return "唱片面"
        case .leadArtist: return "主唱"
        case .artist: return "艺术家"
        case .conductor: return "指挥"
        case .band: return "乐队"
        case .composer: return "作曲"
            case .lyricist: return "作词"
        case .recordingLocation: return "录音地点"
        case .duringRecording: return "录音中"
        case .duringPerformance: return "演出中"
        case .movieScreenCapture: return "影片截图"
        case .colouredFish: return "彩色的鱼"
        case .illustration: return "插画"
        case .bandLogo: return "乐队标志"
        case .publisherLogo: return "发行商标志"
        }
    }
}

/// 一张内嵌封面。
public struct Artwork: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var data: Data
    public var mimeType: String?
    public var caption: String?
    public var type: PictureType
    /// 标签里声明的尺寸（FLAC PICTURE 块会带），未知为 0。
    public var declaredWidth: Int
    public var declaredHeight: Int
    public var declaredColorDepth: Int

    public init(data: Data,
                mimeType: String? = nil,
                caption: String? = nil,
                type: PictureType = .frontCover,
                declaredWidth: Int = 0,
                declaredHeight: Int = 0,
                declaredColorDepth: Int = 0) {
        self.data = data
        self.mimeType = mimeType
        self.caption = caption
        self.type = type
        self.declaredWidth = declaredWidth
        self.declaredHeight = declaredHeight
        self.declaredColorDepth = declaredColorDepth
    }

    public var byteCount: Int { data.count }
}

// MARK: - 标签

/// 一个文件的标签快照。所有字段可为 nil，表示标签中不存在该字段。
public struct Tags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    /// 年份原文，可能是 `2023` 或 `2023-05-01`。
    public var year: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var genre: String?
    public var comment: String?
    public var composer: String?
    public var lyricist: String?
    public var lyrics: String?
    public var artworks: [Artwork]

    /// TagLib PropertyMap 全量原始内容，用于展示未映射到强类型字段的键。
    public var rawProperties: [String: [String]]
    /// 该格式不支持、被 TagLib 拒绝的键。
    public var unsupportedProperties: [String]

    public init(title: String? = nil,
                artist: String? = nil,
                albumArtist: String? = nil,
                album: String? = nil,
                year: String? = nil,
                trackNumber: Int? = nil,
                trackTotal: Int? = nil,
                discNumber: Int? = nil,
                discTotal: Int? = nil,
                genre: String? = nil,
                comment: String? = nil,
                composer: String? = nil,
                lyricist: String? = nil,
                lyrics: String? = nil,
                artworks: [Artwork] = [],
                rawProperties: [String: [String]] = [:],
                unsupportedProperties: [String] = []) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.genre = genre
        self.comment = comment
        self.composer = composer
        self.lyricist = lyricist
        self.lyrics = lyrics
        self.artworks = artworks
        self.rawProperties = rawProperties
        self.unsupportedProperties = unsupportedProperties
    }

    /// `3/12` 形式的音轨串；两者都空时为 nil。
    public var trackString: String? {
        Tags.pairString(trackNumber, trackTotal)
    }

    public var discString: String? {
        Tags.pairString(discNumber, discTotal)
    }

    static func pairString(_ n: Int?, _ total: Int?) -> String? {
        switch (n, total) {
        case let (n?, t?): return "\(n)/\(t)"
        case let (n?, nil): return "\(n)"
        case let (nil, t?): return "0/\(t)"
        default: return nil
        }
    }

    public var isEmpty: Bool {
        title == nil && artist == nil && albumArtist == nil && album == nil
            && year == nil && trackNumber == nil && discNumber == nil
            && genre == nil && comment == nil && composer == nil
            && lyrics == nil && artworks.isEmpty
    }
}

// MARK: - 技术参数

public struct AudioTechnicalInfo: Equatable, Sendable {
    public var durationMilliseconds: Int
    public var bitrateKbps: Int
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var codecName: String
    public var containerName: String
    public var isLossless: Bool
    public var fileSizeBytes: Int64

    public init(durationMilliseconds: Int = 0,
                bitrateKbps: Int = 0,
                sampleRate: Int = 0,
                channels: Int = 0,
                bitsPerSample: Int = 0,
                codecName: String = "",
                containerName: String = "",
                isLossless: Bool = false,
                fileSizeBytes: Int64 = 0) {
        self.durationMilliseconds = durationMilliseconds
        self.bitrateKbps = bitrateKbps
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.codecName = codecName
        self.containerName = containerName
        self.isLossless = isLossless
        self.fileSizeBytes = fileSizeBytes
    }

    public var duration: TimeInterval { Double(durationMilliseconds) / 1000.0 }

    /// `3:45` / `1:02:03`
    public var formattedDuration: String {
        let total = durationMilliseconds / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    public var channelDescription: String {
        switch channels {
        case 0: return "未知"
        case 1: return "单声道"
        case 2: return "立体声"
        default: return "\(channels) 声道"
        }
    }

    public var summary: String {
        var parts: [String] = []
        if !codecName.isEmpty { parts.append(codecName) }
        if bitrateKbps > 0 { parts.append("\(bitrateKbps) kbps") }
        if sampleRate > 0 {
            parts.append(String(format: "%.1f kHz", Double(sampleRate) / 1000.0))
        }
        if bitsPerSample > 0 { parts.append("\(bitsPerSample) bit") }
        parts.append(channelDescription)
        return parts.joined(separator: " · ")
    }
}

// MARK: - 文件

public struct AudioFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var tags: Tags
    public var technical: AudioTechnicalInfo
    /// 文件内实际存在的标签容器，例如 `["ID3v2.4", "ID3v1"]`。
    public var tagContainers: [String]
    public var isReadOnly: Bool
    /// TagLib 读取过程中产生的告警（畸形文件排查用）。
    public var diagnostics: [String]

    public init(url: URL,
                tags: Tags,
                technical: AudioTechnicalInfo,
                tagContainers: [String] = [],
                isReadOnly: Bool = false,
                diagnostics: [String] = []) {
        self.url = url
        self.tags = tags
        self.technical = technical
        self.tagContainers = tagContainers
        self.isReadOnly = isReadOnly
        self.diagnostics = diagnostics
    }

    public var fileName: String { url.lastPathComponent }
    public var fileExtension: String { url.pathExtension.lowercased() }
}

// MARK: - 编辑集

/// 描述一次写入。**只有被显式 set 过的字段才会写回**，其余保持文件原样。
public struct TagEdit: Sendable {

    public enum Field: String, CaseIterable, Sendable {
        case title        = "TITLE"
        case artist       = "ARTIST"
        case albumArtist  = "ALBUMARTIST"
        case album        = "ALBUM"
        case year         = "DATE"
        case track        = "TRACKNUMBER"   // 可写 "3/12"
        case disc         = "DISCNUMBER"    // 可写 "1/2"
        case genre        = "GENRE"
        case comment      = "COMMENT"
        case composer     = "COMPOSER"
        case lyricist     = "LYRICIST"
        case lyrics       = "LYRICS"

        public var localizedName: String {
            switch self {
            case .title: return "标题"
            case .artist: return "艺术家"
            case .albumArtist: return "专辑艺术家"
            case .album: return "专辑"
            case .year: return "年份"
            case .track: return "音轨号"
            case .disc: return "碟号"
            case .genre: return "流派"
            case .comment: return "注释"
            case .composer: return "作曲"
            case .lyricist: return "作词"
            case .lyrics: return "歌词"
            }
        }
    }

    public enum ArtworkAction: Sendable {
        case keep
        case replace([Artwork])
        case removeAll
    }

    /// 有序的字段改动。value 为 nil 表示删除该字段。
    public private(set) var changes: [(field: Field, value: String?)] = []
    /// 非标准键的改动（键会被转成大写）。
    public private(set) var rawChanges: [(key: String, values: [String]?)] = []
    public var artworkAction: ArtworkAction = .keep
    /// 已存在 ID3v1 时是否同步；设为 false 会在保存后剥掉 ID3v1。
    public var syncID3v1: Bool = true

    public init() {}

    public mutating func set(_ field: Field, _ value: String?) {
        changes.removeAll { $0.field == field }
        changes.append((field, value))
    }

    public mutating func remove(_ field: Field) {
        set(field, nil)
    }

    public mutating func setRaw(_ key: String, _ values: [String]?) {
        let upper = key.uppercased()
        rawChanges.removeAll { $0.key == upper }
        rawChanges.append((upper, values))
    }

    public var isEmpty: Bool {
        changes.isEmpty && rawChanges.isEmpty && {
            if case .keep = artworkAction { return true }
            return false
        }()
    }

    /// 便捷构造：把整份 Tags 的核心字段全部排入（用于「整体覆盖」场景）。
    public static func fullOverwrite(with tags: Tags) -> TagEdit {
        var edit = TagEdit()
        edit.set(.title, tags.title)
        edit.set(.artist, tags.artist)
        edit.set(.albumArtist, tags.albumArtist)
        edit.set(.album, tags.album)
        edit.set(.year, tags.year)
        edit.set(.track, tags.trackString)
        edit.set(.disc, tags.discString)
        edit.set(.genre, tags.genre)
        edit.set(.comment, tags.comment)
        edit.set(.composer, tags.composer)
        edit.set(.lyrics, tags.lyrics)
        edit.artworkAction = .replace(tags.artworks)
        return edit
    }

    /// 只把 `new` 与 `old` 有差异的字段排入，天然实现「只写部分字段」。
    ///
    /// 比较范围（BP-C #10）：
    /// - **全部 12 个命名字段**（`Field.allCases`），含作词 `lyricist`。早先漏了它，
    ///   检查器里改作词既不判 dirty、保存也不写（BO 报告 #10）。
    /// - **表外 / raw 字段**：`new.rawProperties` 里、不由命名字段承载的键（见
    ///   `fieldBackedRawKeys`），值与 `old` 不同就排进 `rawChanges`；值为空数组（或全是空串）
    ///   表示删除该键。**只看 `new` 里出现的键**：`new` 里压根没有某个键不当成「删除」——
    ///   待读占位行的草稿是空 `Tags()`（`rawProperties` 为空），若把「缺键」当删除，
    ///   会把文件里 ReplayGain / ISRC 之类用户从没碰过的字段整批抹掉。
    public static func diff(from old: Tags, to new: Tags) -> TagEdit {
        var edit = TagEdit()
        func cmp(_ field: Field, _ a: String?, _ b: String?) {
            let na = (a?.isEmpty ?? true) ? nil : a
            let nb = (b?.isEmpty ?? true) ? nil : b
            if na != nb { edit.set(field, nb) }
        }
        cmp(.title, old.title, new.title)
        cmp(.artist, old.artist, new.artist)
        cmp(.albumArtist, old.albumArtist, new.albumArtist)
        cmp(.album, old.album, new.album)
        cmp(.year, old.year, new.year)
        cmp(.track, old.trackString, new.trackString)
        cmp(.disc, old.discString, new.discString)
        cmp(.genre, old.genre, new.genre)
        cmp(.comment, old.comment, new.comment)
        cmp(.composer, old.composer, new.composer)
        cmp(.lyricist, old.lyricist, new.lyricist)
        cmp(.lyrics, old.lyrics, new.lyrics)

        // 表外字段。`isDirty` / `hasPendingChanges` 会对全表逐行调 diff，这里必须便宜：
        // 草稿是 `file.tags` 的写时复制副本，没人动过 raw 时两边共用同一块存储，
        // 字典 `==` 走存储同一性快路径，整段跳过。键按大写比（PropertyMap 的键本来就是大写）。
        if old.rawProperties != new.rawProperties {
            func norm(_ v: [String]?) -> [String] { (v ?? []).filter { !$0.isEmpty } }
            for key in new.rawProperties.keys.sorted() {
                let upper = key.uppercased()
                guard !fieldBackedRawKeys.contains(upper) else { continue }
                let nv = norm(new.rawProperties[key])
                let ov = norm(old.rawProperties[key] ?? old.rawProperties[upper])
                if nv != ov { edit.setRaw(upper, nv.isEmpty ? nil : nv) }
            }
        }

        if old.artworks.map(\.data) != new.artworks.map(\.data) {
            edit.artworkAction = new.artworks.isEmpty ? .removeAll : .replace(new.artworks)
        }
        return edit
    }

    /// 由命名字段承载的 PropertyMap 键：`diff` 比 raw 时跳过它们，免得同一个键
    /// 既从命名字段写一遍、又从 `rawChanges` 写一遍（两边值不一致时后写的赢，结果不可预期）。
    /// 音轨 / 碟号的「总数」键由 `track` / `disc` 的 `n/t` 串承载，一并跳过。
    public static let fieldBackedRawKeys: Set<String> = Set(Field.allCases.map(\.rawValue))
        .union(["TRACKTOTAL", "TOTALTRACKS", "DISCTOTAL", "TOTALDISCS"])
}

// MARK: - 把编辑集叠到一份标签上

extension Tags {

    /// 把 `edit` 描述的改动叠到这份标签上，返回新标签（**纯内存，不碰磁盘**）。
    ///
    /// 用途：批量收尾异步回读期间用户又改了某一行 —— 回读回来的新标签要把
    /// 「那之后的改动」重新叠上去，而不是把用户刚敲的字覆盖掉。
    /// 与 `TagEdit.diff` 互逆：`old.overlaying(TagEdit.diff(from: old, to: new))` 在
    /// 所比较的字段上等于 `new`。
    public func overlaying(_ edit: TagEdit) -> Tags {
        var t = self
        for change in edit.changes {
            let v = (change.value?.isEmpty ?? true) ? nil : change.value
            switch change.field {
            case .title:       t.title = v
            case .artist:      t.artist = v
            case .albumArtist: t.albumArtist = v
            case .album:       t.album = v
            case .year:        t.year = v
            case .genre:       t.genre = v
            case .comment:     t.comment = v
            case .composer:    t.composer = v
            case .lyricist:
                t.lyricist = v
                // 列表的「作词家」列按 PropertyMap 取值，镜像一份才显示得出来。
                t.rawProperties[TagEdit.Field.lyricist.rawValue] = [v ?? ""]
            case .lyrics:      t.lyrics = v
            case .track:
                let (n, total) = Tags.parsePair(v)
                t.trackNumber = n; t.trackTotal = total
            case .disc:
                let (n, total) = Tags.parsePair(v)
                t.discNumber = n; t.discTotal = total
            }
        }
        for raw in edit.rawChanges {
            if let values = raw.values, !values.isEmpty {
                t.rawProperties[raw.key] = values
            } else {
                t.rawProperties[raw.key] = nil
            }
        }
        switch edit.artworkAction {
        case .keep: break
        case .removeAll: t.artworks = []
        case .replace(let arts): t.artworks = arts
        }
        return t
    }

    /// `3/12` → (3, 12)；`3` → (3, nil)；空 → (nil, nil)。与 App 层 `AppModel.parsePair` 同口径。
    static func parsePair(_ text: String?) -> (Int?, Int?) {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let n = Int(parts.first ?? "")
        let t = parts.count > 1 ? Int(parts[1]) : nil
        return (n, t)
    }
}

// MARK: - 写入结果

public struct WriteOutcome: Sendable {
    /// 全部排定字段都落盘了。
    public var isComplete: Bool
    /// 该格式不支持、没写进去的键。
    public var rejectedKeys: [String]
    public var message: String?

    public init(isComplete: Bool, rejectedKeys: [String] = [], message: String? = nil) {
        self.isComplete = isComplete
        self.rejectedKeys = rejectedKeys
        self.message = message
    }
}

// MARK: - 错误

public enum TagError: LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptedFile(String)
    case notWritable(String)
    case writeFailed(String)
    case nativeException(String)
    case invalidArgument(String)
    case capabilityMissing(String)
    /// 单张封面超出目标容器的硬上限（FLAC 的 METADATA_BLOCK 长度字段只有 24 bit）。
    /// 桥接层在**动文件之前**就拒写，原有封面保持原样。
    /// - `limit` / `actual`：允许的、以及本次要写的**图片数据**字节数。
    case artworkTooLarge(format: String, limit: Int, actual: Int)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let m): return "文件不存在或不可读：\(m)"
        case .unsupportedFormat(let m): return "格式不支持：\(m)"
        case .corruptedFile(let m): return "文件损坏：\(m)"
        case .notWritable(let m): return "文件不可写：\(m)"
        case .writeFailed(let m): return "写入失败：\(m)"
        case .nativeException(let m): return "原生层异常（已兜住，未崩溃）：\(m)"
        case .invalidArgument(let m): return "参数非法：\(m)"
        case .capabilityMissing(let m): return "能力缺失：\(m)"
        case .artworkTooLarge(let format, let limit, let actual):
            let (l, a) = TagError.sizePair(limit, actual)
            return "\(format) 单张封面不能超过 \(l)（当前 \(a)），请先在『调整分辨率 / 压缩』里缩小"
        case .unknown(let m): return m
        }
    }

    /// 刚好落在整 MiB 附近就不带小数（16 MB 比 16.0 MB 好读）。
    private static func mb(_ bytes: Int) -> String {
        let v = Double(bytes) / (1024.0 * 1024.0)
        return abs(v - v.rounded()) < 0.05
            ? String(format: "%.0f MB", v.rounded())
            : String(format: "%.1f MB", v)
    }

    /// 只超出几十字节时两边会印成同一个数（「不能超过 16 MB，当前 16 MB」，看着像 bug）。
    /// 这种紧贴上限的情况改印字节数，用户才知道到底差多少。
    private static func sizePair(_ limit: Int, _ actual: Int) -> (String, String) {
        let l = mb(limit), a = mb(actual)
        guard l == a else { return (l, a) }
        return ("\(limit) 字节", "\(actual) 字节")
    }
}

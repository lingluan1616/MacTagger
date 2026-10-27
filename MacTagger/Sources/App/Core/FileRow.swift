//
//  FileRow.swift
//  MacTagger — 列表行模型、列定义与排序器
//

import Foundation
import SwiftUI

// MARK: - 标签读取状态

/// 一行的标签处在什么阶段。
///
/// 两段式导入的产物：阶段一只枚举出文件名 / 大小 / 修改时间就先上表（`.pending`），
/// 阶段二后台读到标签再换成 `.loaded`。3 万首的目录因此几秒就能看见列表，
/// 而不是等几分钟读完全部标签才显示。
enum TagsState: Equatable {
    /// 还没读标签：只有文件名 / 大小 / 目录 / 修改时间是真的。
    case pending
    /// 标签已读出。
    case loaded
    /// 读取失败（消息给状态点的 tooltip 用）。
    case failed(String)

    var isPending: Bool { self == .pending }

    var isLoaded: Bool { self == .loaded }
}

// MARK: - 行

/// 列表里的一行。`file.tags` 是磁盘上的原样，`draft` 是用户正在改的工作副本。
/// 两者做差即为待写入的编辑集，天然支持「只写改动过的字段」。
struct FileRow: Identifiable, Equatable {

    var id: URL { file.url }
    var file: AudioFile
    var draft: Tags
    /// 封面张数（封面二进制不驻留内存，按需从磁盘读）。
    var artworkCount: Int
    var modifiedAt: Date?
    var fileSize: Int64
    /// 本行是否被批处理标记为失败。
    var lastError: String?
    /// 标签读到哪一步了。见 `TagsState`。
    var tagsState: TagsState

    init(file: AudioFile) {
        var stripped = file
        let count = stripped.tags.artworks.count
        stripped.tags.artworks = []          // 列表不驻留封面二进制
        self.file = stripped
        self.draft = stripped.tags
        self.artworkCount = count
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path)
        self.modifiedAt = attrs?[.modificationDate] as? Date
        self.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? file.technical.fileSizeBytes
        self.tagsState = .loaded
    }

    /// 阶段一的占位行：**一次文件都不打开**。
    ///
    /// 大小与修改时间是目录枚举器顺带取回来的（见 `EnumeratedFile`），
    /// 所以这一行不是空壳 —— 文件名 / 目录 / 大小 / 修改时间四列立刻就是真值。
    init(pending file: EnumeratedFile) {
        self.file = AudioFile(url: file.url,
                              tags: Tags(),
                              technical: AudioTechnicalInfo(fileSizeBytes: file.fileSize))
        self.draft = Tags()
        self.artworkCount = 0
        self.modifiedAt = file.modifiedAt
        self.fileSize = file.fileSize
        self.tagsState = .pending
    }

    var pendingEdit: TagEdit { TagEdit.diff(from: file.tags, to: draft) }
    /// 待读的行永远不算「有改动」：它的 `file.tags` 还不是磁盘上的真值，
    /// 拿它去做差会把「读出来的标签」当成用户的编辑写回去。
    var isDirty: Bool { !tagsState.isPending && !pendingEdit.isEmpty }

    var fileName: String { file.url.lastPathComponent }
    var directory: String { file.url.deletingLastPathComponent().path }

    /// 非标准字段（如作词家）从 PropertyMap 取。
    func raw(_ key: String) -> String? {
        draft.rawProperties[key.uppercased()]?.first
            ?? file.tags.rawProperties[key.uppercased()]?.first
    }

    static func == (a: FileRow, b: FileRow) -> Bool {
        a.file == b.file && a.draft == b.draft && a.artworkCount == b.artworkCount
            && a.modifiedAt == b.modifiedAt && a.lastError == b.lastError
            && a.tagsState == b.tagsState
    }
}

// MARK: - 列

enum ColumnID: String, CaseIterable, Codable, Identifiable, Hashable {
    case filename, title, artist, album, albumArtist, year, track, disc, genre
    case comment, composer, lyricist, hasLyrics, hasPicture
    case duration, bitrate, sampleRate, channels, bitDepth
    case tagFormat, encoding, fileSize, directory, modifiedTime

    var id: String { rawValue }

    /// 这一列的值是否非得读过标签才有。
    ///
    /// 四个例外全部来自目录枚举（文件名 / 大小 / 目录 / 修改时间），
    /// 待读的行在这四列上就是最终值，其余列一律要等第二阶段。
    /// 排序与过滤都靠它区分「真的空」与「还没读」。
    var requiresTags: Bool {
        switch self {
        case .filename, .fileSize, .directory, .modifiedTime: return false
        default: return true
        }
    }
}

// MARK: - 快捷筛选

/// 顶栏搜索框旁那个漏斗菜单里的一条。
///
/// ── 为什么要它 ──
/// 「哪些文件还没有封面」是整理曲库时最常问的一句话，而它在表里的答案散落在
/// 几千行的「封面」列里 —— 用户只能靠点表头排序把它们赶到一头，再手动圈选。
/// 快捷筛选把这句话变成一次点击。
///
/// ── 多选取交集 ──
/// 勾了「无封面」又勾「无歌词」，得到的是**同时**缺这两样的文件，不是并集。
/// 并集会让筛选越勾越宽，与「我要缩小到具体某一批」的意图正好相反。
///
/// ── 待读的行按「未知」处理 ──
/// 两段式导入的 `.pending` 行只有文件名/大小/目录/修改时间是真的，
/// `artworkCount` 恒为 0、`draft` 是空 `Tags()`。要是把它当「无封面」，
/// 刚拖进来的整个目录会在筛选下全部命中，等标签读完又一行行消失 ——
/// 那不是筛选，那是闪烁。所以除 `.pendingTags` 外一律要求 `tagsState.isLoaded`。
enum QuickFilter: String, CaseIterable, Identifiable, Hashable {
    case noArtwork
    case noTitle
    case noAlbum
    case noLyrics
    /// 标签还没读出来的行（含读取失败）。
    case pendingTags

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .noArtwork:   return "无封面"
        case .noTitle:     return "无标题"
        case .noAlbum:     return "无专辑"
        case .noLyrics:    return "无歌词"
        case .pendingTags: return "待读取标签"
        }
    }

    var systemImage: String {
        switch self {
        case .noArtwork:   return "photo.badge.exclamationmark"
        case .noTitle:     return "textformat.abc.dottedunderline"
        case .noAlbum:     return "square.stack.3d.up.slash"
        case .noLyrics:    return "quote.bubble"
        case .pendingTags: return "hourglass"
        }
    }

    var help: String {
        switch self {
        case .noArtwork:   return "只看没有内嵌封面的文件（标签还没读出来的行不算，它们的封面是未知的）"
        case .noTitle:     return "只看标题字段为空的文件"
        case .noAlbum:     return "只看专辑字段为空的文件"
        case .noLyrics:    return "只看没有内嵌歌词的文件"
        case .pendingTags: return "只看标签还没读出来的行（含读取失败），用来盯第二阶段的进度"
        }
    }

    /// 这一行是否命中本条筛选。
    func matches(_ row: FileRow) -> Bool {
        if self == .pendingTags { return !row.tagsState.isLoaded }
        // 标签未知 ≠ 没有。见类型注释。
        guard row.tagsState.isLoaded else { return false }
        func blank(_ s: String?) -> Bool {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch self {
        case .noArtwork:   return row.artworkCount == 0
        case .noTitle:     return blank(row.draft.title)
        case .noAlbum:     return blank(row.draft.album)
        case .noLyrics:    return blank(row.draft.lyrics)
        case .pendingTags: return false
        }
    }
}

/// 单元格的渲染形态。表格按它分派，避免在视图里堆一大摞 `switch column`。
enum ColumnRender {
    /// 文件名列：封面缩略图 + 文件名 + 状态点
    case name
    /// 普通文本，左对齐
    case text
    /// 数字，右对齐 + 等宽数字
    case number
    /// ✓ / —，居中
    case check
}

/// 一列的静态定义。`field` 非空表示这一列可以在列表里内联编辑。
struct ColumnSpec: Identifiable, Hashable {
    let id: ColumnID
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let isNumeric: Bool
    let field: TagEdit.Field?
    /// 作词家这类没有强类型字段的，走 PropertyMap 原始键。
    let rawKey: String?

    init(_ id: ColumnID, _ title: String,
         width: CGFloat = 140, min: CGFloat = 60, max: CGFloat = 600,
         numeric: Bool = false,
         field: TagEdit.Field? = nil,
         rawKey: String? = nil) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = min
        self.maxWidth = max
        self.isNumeric = numeric
        self.field = field
        self.rawKey = rawKey
    }

    var isEditable: Bool { field != nil || rawKey != nil }

    /// 这一列该怎么画。
    var render: ColumnRender {
        switch id {
        case .filename:               return .name
        case .hasLyrics, .hasPicture: return .check
        default:                      return isNumeric ? .number : .text
        }
    }

    /// 单元格内容在列宽里的对齐方式。数字右对齐是表格的基本礼貌（个位数能对齐）。
    var alignment: Alignment {
        switch render {
        case .number: return .trailing
        case .check:  return .center
        default:      return .leading
        }
    }
}

enum ColumnCatalog {

    /// 全部可选列，顺序即「重置」后的默认顺序。文案沿用原版资源用词。
    static let all: [ColumnSpec] = [
        ColumnSpec(.filename,    "文件名",     width: 240, min: 120, field: nil),
        ColumnSpec(.title,       "标题",       width: 180, field: .title),
        ColumnSpec(.artist,      "艺术家",     width: 150, field: .artist),
        ColumnSpec(.album,       "专辑",       width: 170, field: .album),
        ColumnSpec(.albumArtist, "专辑艺术家", width: 150, field: .albumArtist),
        ColumnSpec(.year,        "年份",       width: 62,  min: 48, max: 100, numeric: true, field: .year),
        ColumnSpec(.track,       "音轨号",     width: 66,  min: 48, max: 110, numeric: true, field: .track),
        ColumnSpec(.disc,        "碟号",       width: 60,  min: 44, max: 100, numeric: true, field: .disc),
        ColumnSpec(.genre,       "风格",       width: 110, field: .genre),
        ColumnSpec(.comment,     "注释",       width: 160, field: .comment),
        ColumnSpec(.composer,    "作曲家",     width: 140, field: .composer),
        ColumnSpec(.lyricist,    "作词家",     width: 140, rawKey: "LYRICIST"),
        ColumnSpec(.hasLyrics,   "歌词",       width: 52,  min: 44, max: 70),
        ColumnSpec(.hasPicture,  "封面",       width: 52,  min: 44, max: 70),
        ColumnSpec(.duration,    "持续时间",   width: 78,  min: 60, max: 120, numeric: true),
        ColumnSpec(.bitrate,     "比特率",     width: 84,  min: 60, max: 130, numeric: true),
        ColumnSpec(.sampleRate,  "采样率",     width: 84,  min: 60, max: 130, numeric: true),
        ColumnSpec(.channels,    "声道",       width: 68,  min: 52, max: 110),
        ColumnSpec(.bitDepth,    "位深",       width: 62,  min: 48, max: 100, numeric: true),
        ColumnSpec(.tagFormat,   "标签格式",   width: 130, min: 80),
        ColumnSpec(.encoding,    "编码",       width: 100, min: 70),
        ColumnSpec(.fileSize,    "大小",       width: 84,  min: 60, max: 130, numeric: true),
        ColumnSpec(.directory,   "目录",       width: 260, min: 120, max: 900),
        ColumnSpec(.modifiedTime, "修改时间",  width: 150, min: 110, max: 240)
    ]

    static let byID: [ColumnID: ColumnSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func spec(_ id: ColumnID) -> ColumnSpec { byID[id] ?? all[0] }

    /// 首次启动默认显示的列。
    static let defaultVisible: [ColumnID] = [
        .filename, .title, .artist, .album, .albumArtist,
        .year, .track, .genre, .duration, .bitrate, .tagFormat
    ]
}

// MARK: - 取值

extension FileRow {

    /// 列的显示文本。
    ///
    /// 标签还没读出来的行（待读**或读失败**）只有四列是真的
    /// （文件名 / 大小 / 目录 / 修改时间），其余一律给空串 ——
    /// 不这么挡的话时长列会显示 `0:00`、比特率列显示空，看起来像「这文件是 0 秒的」。
    /// 占位文案由表格视图画（见 `FileTableView`），这里保持数据层诚实：**没有就是没有**。
    func text(for column: ColumnID) -> String {
        if !tagsState.isLoaded && column.requiresTags { return "" }
        switch column {
        case .filename:    return fileName
        case .title:       return draft.title ?? ""
        case .artist:      return draft.artist ?? ""
        case .album:       return draft.album ?? ""
        case .albumArtist: return draft.albumArtist ?? ""
        case .year:        return draft.year ?? ""
        case .track:       return draft.trackString ?? ""
        case .disc:        return draft.discString ?? ""
        case .genre:       return draft.genre ?? ""
        case .comment:     return (draft.comment ?? "").replacingOccurrences(of: "\n", with: " ")
        case .composer:    return draft.composer ?? ""
        case .lyricist:    return raw("LYRICIST") ?? ""
        case .hasLyrics:   return (draft.lyrics?.isEmpty == false) ? "有" : ""
        case .hasPicture:  return artworkCount > 0 ? "\(artworkCount)" : ""
        case .duration:    return file.technical.formattedDuration
        case .bitrate:     return file.technical.bitrateKbps > 0 ? "\(file.technical.bitrateKbps) kbps" : ""
        case .sampleRate:
            let sr = file.technical.sampleRate
            return sr > 0 ? String(format: "%.1f kHz", Double(sr) / 1000.0) : ""
        case .channels:    return file.technical.channels > 0 ? file.technical.channelDescription : ""
        case .bitDepth:    return file.technical.bitsPerSample > 0 ? "\(file.technical.bitsPerSample) bit" : ""
        case .tagFormat:   return file.tagContainers.joined(separator: ", ")
        case .encoding:    return file.technical.codecName
        case .fileSize:    return Formatters.fileSize(fileSize)
        case .directory:   return directory
        case .modifiedTime: return modifiedAt.map(Formatters.dateTime) ?? ""
        }
    }

    /// 内联编辑时写回的文本（与 text(for:) 不同：注释保留换行、封面等列不可编辑）。
    func editableText(for column: ColumnID) -> String {
        let spec = ColumnCatalog.spec(column)
        if let key = spec.rawKey { return raw(key) ?? "" }
        guard let field = spec.field else { return text(for: column) }
        switch field {
        case .title:       return draft.title ?? ""
        case .artist:      return draft.artist ?? ""
        case .albumArtist: return draft.albumArtist ?? ""
        case .album:       return draft.album ?? ""
        case .year:        return draft.year ?? ""
        case .track:       return draft.trackString ?? ""
        case .disc:        return draft.discString ?? ""
        case .genre:       return draft.genre ?? ""
        case .comment:     return draft.comment ?? ""
        case .composer:    return draft.composer ?? ""
        case .lyricist:    return draft.lyricist ?? ""
        case .lyrics:      return draft.lyrics ?? ""
        }
    }

    /// 排序用的比较键。
    fileprivate func sortKey(_ column: ColumnID) -> SortKey {
        switch column {
        case .year:        return .number(Double(draft.year?.prefix(4) ?? "") ?? -1)
        case .track:       return .number(Double(draft.trackNumber ?? -1))
        case .disc:        return .number(Double(draft.discNumber ?? -1))
        case .duration:    return .number(Double(file.technical.durationMilliseconds))
        case .bitrate:     return .number(Double(file.technical.bitrateKbps))
        case .sampleRate:  return .number(Double(file.technical.sampleRate))
        case .channels:    return .number(Double(file.technical.channels))
        case .bitDepth:    return .number(Double(file.technical.bitsPerSample))
        case .fileSize:    return .number(Double(fileSize))
        // 「封面」「歌词」两列排的是**有没有**：升序 0 在前 = 缺的排前面，
        // 正是「先把没封面的挑出来」这句话。封面还顺带按张数分层（0 → 1 → 2…）。
        case .hasPicture:  return .number(Double(artworkCount))
        case .hasLyrics:   return .number((draft.lyrics?.isEmpty == false) ? 1 : 0)
        case .modifiedTime: return .number(modifiedAt?.timeIntervalSince1970 ?? 0)
        default:           return .string(text(for: column))
        }
    }
}

private enum SortKey {
    case string(String)
    case number(Double)

    func compare(_ other: SortKey) -> ComparisonResult {
        switch (self, other) {
        case let (.number(a), .number(b)):
            return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.string(a), .string(b)):
            // 空值永远排在后面，避免一堆空标签霸占表头
            if a.isEmpty && b.isEmpty { return .orderedSame }
            if a.isEmpty { return .orderedDescending }
            if b.isEmpty { return .orderedAscending }
            return a.localizedStandardCompare(b)
        default:
            return .orderedSame
        }
    }
}

// MARK: - 排序器

/// SwiftUI `Table` 的动态列排序器：一个类型覆盖所有列。
///
/// **总序，不是偏序**：`Array.sort` 是内省排序（不稳定），比较器一旦对两行给出
/// `.orderedSame`，它们的先后就随实现细节漂 —— 「封面」这种只有 0/1 两种值的列
/// 上，几千行里只有两个等价类，每次重排（改过滤、读完标签刷表）都会把同一批行
/// 洗成另一种顺序，看起来像列表在自己跳。所以等值时一路降到文件名、再降到完整
/// 路径，让任意两行都有确定的先后 —— 排序因此可复现，等同于稳定。
struct FileSortComparator: SortComparator, Hashable {
    var columnID: ColumnID
    var order: SortOrder = .forward

    func compare(_ lhs: FileRow, _ rhs: FileRow) -> ComparisonResult {
        // 标签还没读出来的行（待读 / 读失败）在「要标签才有值」的列上没有可比的东西。
        // 按空串比会让它们和真正没填这个标签的文件混在一起、还会随升降序在头尾之间跳。
        // 一律沉到末尾（**不随升降序翻转**，与 Finder 处理「正在计算」的行同一个脾气），
        // 彼此之间按文件名排 —— 这就是任务书说的「pending 行按文件名排序」。
        if columnID.requiresTags {
            switch (!lhs.tagsState.isLoaded, !rhs.tagsState.isLoaded) {
            case (true, true):
                return FileSortComparator.tieBreak(lhs, rhs)
            case (true, false):
                return .orderedDescending
            case (false, true):
                return .orderedAscending
            case (false, false):
                break
            }
        }
        let result = lhs.sortKey(columnID).compare(rhs.sortKey(columnID))
        let ordered: ComparisonResult
        switch order {
        case .forward: ordered = result
        case .reverse:
            switch result {
            case .orderedAscending: ordered = .orderedDescending
            case .orderedDescending: ordered = .orderedAscending
            case .orderedSame: ordered = .orderedSame
            }
        }
        guard ordered == .orderedSame else { return ordered }
        // 等值兜底。**不随升降序翻转**：翻转的话「无封面」那一堆会在两个方向上
        // 各洗成一种顺序，用户点两下表头就找不到刚才那一行了。
        return FileSortComparator.tieBreak(lhs, rhs)
    }

    /// 等值兜底：文件名 → 完整路径。两条都相同的只可能是同一行（`id` 就是 URL）。
    private static func tieBreak(_ lhs: FileRow, _ rhs: FileRow) -> ComparisonResult {
        let byName = lhs.fileName.localizedStandardCompare(rhs.fileName)
        guard byName == .orderedSame else { return byName }
        return lhs.file.url.path.localizedStandardCompare(rhs.file.url.path)
    }
}

// MARK: - 格式化

enum Formatters {

    static func fileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func dateTime(_ date: Date) -> String { dateFormatter.string(from: date) }
}

//
//  TagPropagation.swift
//  MacTagger — 「统一 / 补齐标签」的纯逻辑层
//
//  场景（用户原话）：同一个文件夹 / 同一张专辑里，多数文件的专辑名、年份、艺术家、
//  专辑艺术家、风格、封面都一样，偏偏有几首是空的；也常有一两首年份写错成邻近的一年。
//  「从标签取图」（`ArtworkPropagation.swift`）已经解决了封面那一半，这里解决文本那一半，
//  并把封面也一并纳进同一张表，让用户在一个窗口里把整组标签对齐。
//
//  与 `ArtworkPropagation` 同样的定位：**不碰磁盘、不碰 AppKit**，因此可以在 CLI probe 里
//  直接跑（`mactagger-probe propagate <dir>`），也易于单测。唯一的输入就是一批已经读好的
//  `AudioFile`，唯一的输出就是一份 `[(url, TagEdit)]` —— 交给既有的写入路径落盘。
//
//  三条设计约束，都是从真实翻车点倒推出来的：
//
//  1. **只生成真会改动的 edit**。值本来就一样却照写一遍，在 FLAC 上就是一次整文件重写
//     （几十 MB 搬动）。所以每个字段逐文件比一次，相同就不进 payload。
//  2. **数字型字段按语义比，不按字符串比**。`2008` 与 `2008-10-15` 是同一年，
//     碟号裸 `1` 与 `1/1` 是同一张碟 —— 按字符串比会把它们判成「不一致」，
//     于是「覆盖不一致的值」会把 `2008-10-15` 的日期信息白白抹掉。
//  3. **空值不参与「多数值」投票**。一组 11 首里 3 首为空、8 首写着「kun」，
//     多数值必须是「kun」而不是「空」，否则这个功能就反过来把好的抹掉了。
//

import Foundation

// MARK: - 分组

/// 「哪些文件算同一组」。
public enum PropagationGrouping: String, CaseIterable, Sendable, Identifiable {
    /// 按所在文件夹。整理散装音乐库时最常用：一个文件夹通常就是一张碟。
    case folder
    /// 按标签里的专辑（+ 专辑艺术家）。同一张碟散落在多个文件夹时用它。
    case album
    /// 传进来的这一批就是一组（界面上的「当前选中作为一组」）。
    case selection

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .folder:    return "按文件夹"
        case .album:     return "按专辑标签"
        case .selection: return "当前选中作为一组"
        }
    }

    public var hint: String {
        switch self {
        case .folder:    return "同一个文件夹里的文件算一组"
        case .album:     return "专辑 + 专辑艺术家相同的算一组"
        case .selection: return "当前选中的全部文件算一组"
        }
    }
}

/// 一组待统一的文件。
public struct PropagationGroup: Identifiable, Sendable {
    /// 分组键（文件夹路径 / 规范化的专辑键 / 固定串）。
    public var id: String
    /// 下拉里显示的名字。
    public var title: String
    /// 下拉里显示的第二行（路径 / 专辑艺术家）。
    public var subtitle: String
    public var files: [AudioFile]

    public var count: Int { files.count }

    public init(id: String, title: String, subtitle: String, files: [AudioFile]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.files = files
    }

    /// 这一组的封面字节是否已经从磁盘读进来了。
    ///
    /// 列表行（`FileRow`）为省内存把 `tags.artworks` 清空了，只留张数。拿那种 `AudioFile`
    /// 建组，封面一栏会把「没读」误判成「没有封面」，于是给本来有图的文件再写一遍图。
    /// 调用方必须先 `TagService.readAll` 把这一组补全再谈封面 —— 这个标志就是给
    /// 界面做「封面行要不要显示」的判据。
    public var artworksHydrated: Bool {
        files.contains { !$0.tags.artworks.isEmpty }
    }
}

// MARK: - 字段

/// 参与统一的一个字段。文本字段直接复用 `TagEdit.Field`，封面单列一项。
public enum PropagationField: Hashable, Sendable, Identifiable, CaseIterable {
    case tag(TagEdit.Field)
    case artwork

    public static var allCases: [PropagationField] {
        TagEdit.Field.allCases.map { .tag($0) } + [.artwork]
    }

    public var id: String {
        switch self {
        case .tag(let f): return f.rawValue
        case .artwork:    return "__ARTWORK__"
        }
    }

    public var localizedName: String {
        switch self {
        case .tag(let f): return f.localizedName
        case .artwork:    return "封面"
        }
    }

    /// 是不是「整组通常一致」的字段。
    ///
    /// 标题 / 音轨号 / 歌词逐首各不相同，把它们统一掉等于毁数据，所以默认不勾、
    /// 也不参与「自动勾选有空缺或不一致的字段」。仍然列在表里（用户偶尔真要统一注释），
    /// 只是要自己动手勾。
    public var isGroupLevel: Bool {
        switch self {
        case .artwork: return true
        case .tag(let f):
            switch f {
            case .album, .albumArtist, .artist, .year, .genre, .disc, .composer, .comment:
                return true
            case .title, .track, .lyricist, .lyrics:
                return false
            }
        }
    }

    /// 界面上的排列次序：用户最常统一的排前面。
    ///
    /// 前六项（专辑 / 专辑艺术家 / 艺术家 / 年份 / 流派 / 封面）正是用户描述的那一组
    /// 「整张碟一样、偏偏有几首是空的」字段，一屏之内不用滚动就能全部看到。
    public static let displayOrder: [PropagationField] = [
        .tag(.album), .tag(.albumArtist), .tag(.artist), .tag(.year),
        .tag(.genre), .artwork,
        .tag(.disc), .tag(.composer), .tag(.comment),
        .tag(.lyricist), .tag(.track), .tag(.title), .tag(.lyrics),
    ]
}

// MARK: - 值分布

/// 某个字段在组内的一个取值。
public struct FieldValueBucket: Identifiable, Sendable {
    /// 归一化键（数字型字段按语义归一，见 `TagPropagation.normalizedKey`）。
    public var id: String
    /// 展示与写入用的原样值。同一个桶里出现多种原样写法时取**出现最多**的那一种。
    public var display: String
    public var count: Int
    /// 随便挑一个持有该值的文件，界面上用来说明「比如 03.flac」。
    public var exampleFile: URL
    public var urls: [URL]
    /// 仅封面桶有：这一桶对应的封面本体（写入时直接用它）。
    public var artwork: Artwork?

    public init(id: String, display: String, count: Int,
                exampleFile: URL, urls: [URL], artwork: Artwork? = nil) {
        self.id = id
        self.display = display
        self.count = count
        self.exampleFile = exampleFile
        self.urls = urls
        self.artwork = artwork
    }
}

/// 一个字段在一组文件里的全貌。
public struct FieldSurvey: Identifiable, Sendable {
    public var field: PropagationField
    /// **非空**取值的分布，按「出现次数降序 → 值升序」排好，直接喂给下拉。
    public var buckets: [FieldValueBucket]
    /// 该字段为空的文件数。
    public var emptyCount: Int
    /// 参与统计的文件总数。
    public var totalCount: Int

    public var id: String { field.id }

    /// 出现次数最多的那个非空值。并列时取排序后的第一个（可复现）。
    public var majority: FieldValueBucket? { buckets.first }

    /// 非空值只有一种（有空缺也算一致 —— 一致说的是「写着的都一样」）。
    public var isConsistent: Bool { buckets.count <= 1 }

    /// 全组都写着同一个值、一个空的都没有 —— 这一行不需要动。
    public var isUniform: Bool { emptyCount == 0 && buckets.count == 1 }

    /// 全组都是空的 —— 组内没有值可借，只能手输。
    public var isAllEmpty: Bool { buckets.isEmpty }

    /// 一致性标记文案。
    public var statusText: String {
        if isAllEmpty { return "全为空" }
        if isUniform { return "已一致" }
        if emptyCount > 0 && !isConsistent { return "\(emptyCount) 个空 · \(buckets.count) 种值" }
        if emptyCount > 0 { return "\(emptyCount) 个空" }
        return "\(buckets.count) 种值"
    }

    /// 该字段这一组值得不值得默认勾上：是整组级字段，且确实有空缺或不一致。
    public var suggestsPropagation: Bool {
        guard field.isGroupLevel, !isAllEmpty else { return false }
        return emptyCount > 0 || !isConsistent
    }

    public init(field: PropagationField, buckets: [FieldValueBucket],
                emptyCount: Int, totalCount: Int) {
        self.field = field
        self.buckets = buckets
        self.emptyCount = emptyCount
        self.totalCount = totalCount
    }
}

// MARK: - 模式与计划

/// 写入范围。
public enum PropagationMode: String, CaseIterable, Sendable, Identifiable {
    /// 只写那些该字段为空的文件（默认）。已经写着别的值的一律不动。
    case fillEmptyOnly
    /// 连「写着别的值」的一起纠正，把整组对齐到选定值。
    case overwriteMismatch

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .fillEmptyOnly:     return "只填空的"
        case .overwriteMismatch: return "覆盖不一致的值"
        }
    }

    public var hint: String {
        switch self {
        case .fillEmptyOnly:
            return "只补该字段为空的文件；已经写着别的值的保持原样"
        case .overwriteMismatch:
            return "把整组对齐到选定值，写着别的值的一并纠正"
        }
    }
}

/// 预览表里的一行改动。
public struct PropagationChange: Identifiable, Sendable {
    public var id: String { url.path + "\u{1}" + field.id }
    public var url: URL
    public var field: PropagationField
    /// 原值（空为 ""）。封面行是「1.4 MB · 1000×1000」这种描述。
    public var oldValue: String
    public var newValue: String
    /// 原来就是空的（补齐）还是原来写着别的（纠正）。界面上用不同的点色。
    public var wasEmpty: Bool

    public var fileName: String { url.lastPathComponent }

    public init(url: URL, field: PropagationField,
                oldValue: String, newValue: String, wasEmpty: Bool) {
        self.url = url
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.wasEmpty = wasEmpty
    }
}

/// 一次统一操作的完整计划。
public struct PropagationPlan: Sendable {
    /// 交给写入路径的编辑集。**每一条都真会改动文件**，值相同的已经剔掉。
    public var edits: [(url: URL, edit: TagEdit)]
    /// 预览表数据，按文件名 → 字段次序排好。
    public var changes: [PropagationChange]

    public var isEmpty: Bool { edits.isEmpty }
    public var fileCount: Int { edits.count }
    public var changeCount: Int { changes.count }

    public var summary: String {
        isEmpty ? "0 个文件需要修改"
                : "将修改 \(fileCount) 个文件，共 \(changeCount) 处"
    }

    public init(edits: [(url: URL, edit: TagEdit)] = [], changes: [PropagationChange] = []) {
        self.edits = edits
        self.changes = changes
    }

    // MARK: 生成

    /// 按选定值生成计划。
    ///
    /// - Parameters:
    ///   - group: 目标组。封面参与时必须是**已补全封面字节**的组（见 `artworksHydrated`）。
    ///   - choices: 勾选的文本字段 → 选定值。没进这个字典的字段一概不动。
    ///   - mode: 只填空 / 覆盖不一致。
    ///   - artwork: 勾选封面时的选定封面；nil = 不动封面。
    public static func plan(group: PropagationGroup,
                            choices: [TagEdit.Field: String],
                            mode: PropagationMode,
                            artwork: Artwork? = nil) -> PropagationPlan {

        // 字段的写入次序固定成 displayOrder，预览表与实际写入才对得上。
        let orderedFields: [TagEdit.Field] = PropagationField.displayOrder.compactMap {
            if case .tag(let f) = $0, choices[f] != nil { return f }
            return nil
        }
        let chosenHash = artwork.map { TagPropagation.artworkHash($0.data) }

        var edits: [(url: URL, edit: TagEdit)] = []
        var changes: [PropagationChange] = []

        for file in group.files.sorted(by: { fileNameLess($0.url, $1.url) }) {
            var edit = TagEdit()
            var touched = false

            for field in orderedFields {
                guard let chosen = choices[field] else { continue }
                let chosenTrimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chosenTrimmed.isEmpty else { continue }   // 选定值为空 = 不写（删字段另有入口）

                let current = TagPropagation.value(of: field, in: file.tags) ?? ""
                let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                let isEmpty = currentTrimmed.isEmpty

                switch mode {
                case .fillEmptyOnly:
                    guard isEmpty else { continue }
                case .overwriteMismatch:
                    // 归一化相等就不写：`2008-10-15` 对 `2008`、裸 `1` 对 `1/1` 都算已经对齐，
                    // 白写一遍在 FLAC 上就是一次整文件重写。
                    let a = TagPropagation.normalizedKey(field, currentTrimmed)
                    let b = TagPropagation.normalizedKey(field, chosenTrimmed)
                    guard isEmpty || a != b else { continue }
                }

                edit.set(field, chosenTrimmed)
                touched = true
                changes.append(PropagationChange(url: file.url,
                                                 field: .tag(field),
                                                 oldValue: currentTrimmed,
                                                 newValue: chosenTrimmed,
                                                 wasEmpty: isEmpty))
            }

            if let artwork, let chosenHash {
                let currentArts = file.tags.artworks
                let currentHash = currentArts.first.map { TagPropagation.artworkHash($0.data) }
                let needs: Bool
                switch mode {
                case .fillEmptyOnly:     needs = currentArts.isEmpty
                case .overwriteMismatch: needs = currentHash != chosenHash
                }
                if needs {
                    edit.artworkAction = .replace([artwork])
                    touched = true
                    changes.append(PropagationChange(url: file.url,
                                                     field: .artwork,
                                                     oldValue: currentArts.isEmpty
                                                        ? "" : TagPropagation.artworkLabel(currentArts[0]),
                                                     newValue: TagPropagation.artworkLabel(artwork),
                                                     wasEmpty: currentArts.isEmpty))
                }
            }

            if touched { edits.append((file.url, edit)) }
        }

        return PropagationPlan(edits: edits, changes: changes)
    }

    /// 只要编辑集的版本（任务书里的签名）。
    public static func make(group: PropagationGroup,
                            choices: [TagEdit.Field: String],
                            mode: PropagationMode,
                            artwork: Artwork? = nil) -> [(url: URL, edit: TagEdit)] {
        plan(group: group, choices: choices, mode: mode, artwork: artwork).edits
    }

    private static func fileNameLess(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }
}

// MARK: - 算法

public enum TagPropagation {

    // MARK: 分组

    /// 把文件分成若干组。空组不返回；组内按文件名排序，组之间按标题排序。
    public static func groupFiles(_ files: [AudioFile],
                                  by grouping: PropagationGrouping) -> [PropagationGroup] {
        guard !files.isEmpty else { return [] }

        switch grouping {
        case .selection:
            return [PropagationGroup(id: "__selection__",
                                     title: "当前选中",
                                     subtitle: "\(files.count) 个文件",
                                     files: sortedByName(files))]

        case .folder:
            var buckets: [String: [AudioFile]] = [:]
            for f in files {
                buckets[f.url.deletingLastPathComponent().path, default: []].append(f)
            }
            return buckets.map { key, group in
                let dir = URL(fileURLWithPath: key)
                return PropagationGroup(id: key,
                                        title: dir.lastPathComponent.isEmpty ? key : dir.lastPathComponent,
                                        subtitle: key,
                                        files: sortedByName(group))
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        case .album:
            var buckets: [String: [AudioFile]] = [:]
            for f in files { buckets[albumKey(f), default: []].append(f) }
            return buckets.map { key, group in
                let first = group[0]
                let album = (first.tags.album ?? "").trimmingCharacters(in: .whitespaces)
                let aa = (first.tags.albumArtist ?? "").trimmingCharacters(in: .whitespaces)
                let ar = (first.tags.artist ?? "").trimmingCharacters(in: .whitespaces)
                let by = aa.isEmpty ? ar : aa
                return PropagationGroup(id: key,
                                        title: album.isEmpty ? "（无专辑名）" : album,
                                        subtitle: by.isEmpty ? "\(group.count) 个文件" : by,
                                        files: sortedByName(group))
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// 专辑分组键：专辑 + 专辑艺术家（专辑艺术家为空时退到艺术家）。
    /// 与 `ArtworkPropagation` 同一套规范化，两个功能对「同一张碟」的判断保持一致。
    static func albumKey(_ f: AudioFile) -> String {
        let album = ArtworkPropagation.normalize(f.tags.album)
        var by = ArtworkPropagation.normalize(f.tags.albumArtist)
        if by.isEmpty { by = ArtworkPropagation.normalize(f.tags.artist) }
        return album + "\u{1}" + by
    }

    static func sortedByName(_ files: [AudioFile]) -> [AudioFile] {
        files.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: 取值与归一化

    /// 从 `Tags` 里按 `TagEdit.Field` 取值。音轨 / 碟号取 `3/12` 这种成对串。
    public static func value(of field: TagEdit.Field, in tags: Tags) -> String? {
        switch field {
        case .title:       return tags.title
        case .artist:      return tags.artist
        case .albumArtist: return tags.albumArtist
        case .album:       return tags.album
        case .year:        return tags.year
        case .track:       return tags.trackString
        case .disc:        return tags.discString
        case .genre:       return tags.genre
        case .comment:     return tags.comment
        case .composer:    return tags.composer
        case .lyricist:    return tags.lyricist
        case .lyrics:      return tags.lyrics
        }
    }

    /// 归并 / 比较用的键。
    ///
    /// - 年份：取开头的四位年 —— `2008` 与 `2008-10-15` 是同一年，
    ///   按字符串比会判成两种值，于是「覆盖不一致」会把日期抹成光秃秃的年份。
    /// - 音轨 / 碟号：`n/total` 里 total 缺失或等于 n 都算「没有额外信息」，
    ///   所以裸 `1` ≡ `1/1`、`2` ≡ `2/2`；`1/2` 与 `1` 仍是两种值（一个知道共两张碟）。
    /// - 其余字段：按原样（只去首尾空白）。大小写不同就是不同的值 —— 表里如实列出来，
    ///   由用户挑要统一到哪一种，别替他做主。
    public static func normalizedKey(_ field: TagEdit.Field, _ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        switch field {
        case .year:
            return yearOf(s) ?? s
        case .track, .disc:
            let (n, t) = pairOf(s)
            guard let n else { return s }
            if let t, t != n { return "\(n)/\(t)" }
            return "\(n)"
        default:
            return s
        }
    }

    /// `2008-10-15` / `2008.10` / `2008` → `2008`。取不到四位年时返回 nil。
    public static func yearOf(_ s: String) -> String? {
        var digits = ""
        for ch in s {
            if ch.isNumber {
                digits.append(ch)
                if digits.count == 4 { return digits }
            } else if !digits.isEmpty {
                return nil          // 出现 `20-08` 这种断开的数字就别猜了
            }
        }
        return nil
    }

    /// `3/12` → (3, 12)；`3` → (3, nil)；`0/12` → (0, 12)。
    public static func pairOf(_ s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let n = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "")
        let t = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (n, t)
    }

    // MARK: 封面指纹

    /// 封面归并用的字节指纹（FNV-1a 64 位 + 长度）。
    ///
    /// 不用加密哈希：这里只要「同一张图归到同一桶」，长度已经把绝大多数不同图分开了，
    /// FNV-1a 再把剩下的分开。纯 Swift、无依赖，probe 与 App 同一份结果。
    public static func artworkHash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { raw in
            for byte in raw {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01B3
            }
        }
        return String(format: "%llx-%d", h, data.count)
    }

    /// 封面在表里的一行说明：`1.4 MB · 1000×1000 · image/jpeg`。
    /// 尺寸只用标签里声明的（FLAC PICTURE 块会带），**不解码图片** —— 这一层不碰 ImageIO。
    public static func artworkLabel(_ art: Artwork) -> String {
        var parts = [TagService.humanBytes(Int64(art.byteCount))]
        if art.declaredWidth > 0 && art.declaredHeight > 0 {
            parts.append("\(art.declaredWidth)×\(art.declaredHeight)")
        }
        if let m = art.mimeType, !m.isEmpty { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    // MARK: 值分布统计

    /// 对一组文件的某个文本字段做值分布统计。
    public static func survey(_ field: TagEdit.Field, in files: [AudioFile]) -> FieldSurvey {
        // key → (原样写法 → 次数, 全部 url)
        var order: [String] = []
        var variants: [String: [String: Int]] = [:]
        var urls: [String: [URL]] = [:]
        var emptyCount = 0

        for f in files {
            let raw = (value(of: field, in: f.tags) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { emptyCount += 1; continue }
            let key = normalizedKey(field, raw)
            if variants[key] == nil { order.append(key); variants[key] = [:]; urls[key] = [] }
            variants[key]?[raw, default: 0] += 1
            urls[key]?.append(f.url)
        }

        let buckets: [FieldValueBucket] = order.compactMap { key in
            guard let vs = variants[key], let us = urls[key], let first = us.first else { return nil }
            let count = us.count
            // 同一个键下有多种原样写法（`2008` 与 `2008-10-15`）时，取出现最多的那一种；
            // 并列时取字典序小的，保证结果可复现。
            let display = vs.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.first?.key ?? key
            return FieldValueBucket(id: key, display: display, count: count,
                                    exampleFile: first, urls: us)
        }.sorted {
            $0.count != $1.count ? $0.count > $1.count
                                 : $0.display.localizedStandardCompare($1.display) == .orderedAscending
        }

        return FieldSurvey(field: .tag(field), buckets: buckets,
                           emptyCount: emptyCount, totalCount: files.count)
    }

    /// 封面的值分布：按字节指纹归并，每一桶带上封面本体供界面画缩略图。
    ///
    /// 只看**第一张**封面（多数文件也只有一张；有多张时第一张就是写入时会被换掉的那张）。
    public static func artworkSurvey(in files: [AudioFile]) -> FieldSurvey {
        var order: [String] = []
        var arts: [String: Artwork] = [:]
        var urls: [String: [URL]] = [:]
        var emptyCount = 0

        for f in files {
            let picked = f.tags.artworks.first { $0.type == .frontCover } ?? f.tags.artworks.first
            guard let art = picked else { emptyCount += 1; continue }
            let key = artworkHash(art.data)
            if arts[key] == nil { order.append(key); arts[key] = art; urls[key] = [] }
            urls[key]?.append(f.url)
        }

        let buckets: [FieldValueBucket] = order.compactMap { key in
            guard let art = arts[key], let us = urls[key], let first = us.first else { return nil }
            return FieldValueBucket(id: key, display: artworkLabel(art), count: us.count,
                                    exampleFile: first, urls: us, artwork: art)
        }.sorted {
            // 次数相同就让**字节大的**排前面：同一张碟里往往是高清那张更值得当基准。
            $0.count != $1.count ? $0.count > $1.count
                                 : (($0.artwork?.byteCount ?? 0) > ($1.artwork?.byteCount ?? 0))
        }

        return FieldSurvey(field: .artwork, buckets: buckets,
                           emptyCount: emptyCount, totalCount: files.count)
    }

    /// 一组文件的全字段值分布，按 `PropagationField.displayOrder` 排好。
    ///
    /// - Parameter includeArtwork: 组内封面字节没读进来时传 false，封面行就不会出现
    ///   （否则会把「没读」误报成「全为空」，见 `PropagationGroup.artworksHydrated`）。
    public static func surveyAll(_ group: PropagationGroup,
                                 includeArtwork: Bool = true) -> [FieldSurvey] {
        PropagationField.displayOrder.compactMap { field in
            switch field {
            case .tag(let f):
                return survey(f, in: group.files)
            case .artwork:
                guard includeArtwork else { return nil }
                return artworkSurvey(in: group.files)
            }
        }
    }

    /// 「用组内多数值填空字段」的默认选择：整组级字段里，凡是有多数值的都选上。
    /// 检查器上那个一键按钮用它，生成的计划仍然要过预览确认，不静默写。
    public static func majorityChoices(_ surveys: [FieldSurvey]) -> (choices: [TagEdit.Field: String],
                                                                    artwork: Artwork?) {
        var choices: [TagEdit.Field: String] = [:]
        var artwork: Artwork?
        for s in surveys where s.field.isGroupLevel {
            guard let m = s.majority else { continue }
            switch s.field {
            case .tag(let f): choices[f] = m.display
            case .artwork:    artwork = m.artwork
            }
        }
        return (choices, artwork)
    }
}

//
//  FolderContext.swift
//  MacTagger — 从文件路径推断专辑上下文
//
//  为什么需要它（用户的真实痛点）：
//  一整柜只有文件名、没有任何标签的歌，逐首拿去联网搜「稻香」，
//  会同时命中原版、Live 版、Remix 版、翻唱、各种精选合辑——
//  单曲搜索没有任何信号能区分它们，于是大批文件被写成 Live/翻唱版本。
//
//  但文件夹本身就藏着最强的那个信号：`周杰伦/魔杰座/01 - 稻香.flac`
//  已经把「专辑 = 魔杰座、艺术家 = 周杰伦、这是第 11 首」全说清楚了。
//  本文件把这条信息从路径里刨出来，`AlbumMatchService` 再拿它去锁定整张专辑。
//
//  设计原则：
//  1. **只做可证伪的剥离**。年份、`[FLAC]`、`CD1` 这类装饰有明确形态，剥掉是安全的；
//     形态不明的一律原样保留——宁可多带噪声，也不敢把专辑名剪短。
//  2. **剥离绝不允许把名字剪空**。Taylor Swift 的《1989》整个专辑名就是一个年份，
//     按「剥年份」的规则会剪成空串，所以每条规则都带「剪空就撤销」的兜底。
//  3. 纯字符串处理、不碰磁盘、不联网，`probeCases` 里带 12 条内置用例可随时自检。
//

import Foundation

// MARK: - 单个文件的推断结果

public struct FileNameContext: Sendable, Equatable {
    public var url: URL
    /// 文件名前导的音轨号（`01 - 稻香` → 1）。四位数一律不认，那多半是年份。
    public var trackNumber: Int?
    /// `1-01 Hello` 这种「碟-轨」写法里的碟号。
    public var discNumber: Int?
    /// 去掉序号、艺术家前后缀、格式装饰之后的曲名。
    public var title: String?
    /// 文件名里自带的艺术家（`周杰伦 - 稻香` → 周杰伦）。
    public var artist: String?
    /// 未经任何处理的文件名主干（去扩展名）。
    public var stem: String

    public init(url: URL, trackNumber: Int? = nil, discNumber: Int? = nil,
                title: String? = nil, artist: String? = nil, stem: String = "") {
        self.url = url; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.title = title; self.artist = artist; self.stem = stem
    }
}

// MARK: - 文件夹级上下文

public struct FolderContext: Sendable, Equatable {

    /// 艺术家是从哪儿推出来的，界面上要说清楚，免得用户以为是联网猜的。
    public enum ArtistOrigin: String, Sendable {
        case parentFolder    = "上级文件夹"
        case folderNameSplit = "文件夹名拆分"
        case filenamePrefix  = "文件名公共前缀"
        case none            = "未推断出"
    }

    /// 这些文件所在的目录。
    public var directory: URL
    /// 承载专辑名的那个目录（`…/魔杰座/CD1` 时指向 `魔杰座`）。
    public var albumDirectory: URL
    /// 专辑目录的原始名字，未做任何剥离。
    public var rawFolderName: String
    /// 剥离年份/装饰/碟号/前导序号之后的专辑名。
    public var album: String?
    public var artist: String?
    public var artistOrigin: ArtistOrigin
    /// 文件夹名里带的发行年（`魔杰座 (2008)` → 2008）。
    public var year: String?
    /// `CD1` 目录或 `… CD1` 后缀给出的碟号。
    public var discNumber: Int?
    /// 目录内每个文件的推断结果，顺序与传入一致。
    public var files: [FileNameContext]

    public init(directory: URL,
                albumDirectory: URL,
                rawFolderName: String,
                album: String? = nil,
                artist: String? = nil,
                artistOrigin: ArtistOrigin = .none,
                year: String? = nil,
                discNumber: Int? = nil,
                files: [FileNameContext] = []) {
        self.directory = directory
        self.albumDirectory = albumDirectory
        self.rawFolderName = rawFolderName
        self.album = album
        self.artist = artist
        self.artistOrigin = artistOrigin
        self.year = year
        self.discNumber = discNumber
        self.files = files
    }

    /// 有专辑名才谈得上「按文件夹匹配」。
    public var isUsable: Bool { !(album ?? "").isEmpty }

    public var summary: String {
        var parts: [String] = []
        parts.append("专辑=" + (album ?? "—"))
        parts.append("艺术家=" + (artist ?? "—"))
        if let y = year { parts.append("年=\(y)") }
        if let d = discNumber { parts.append("碟=\(d)") }
        return parts.joined(separator: " ")
    }

    public func context(for url: URL) -> FileNameContext? {
        files.first { $0.url == url }
    }

    // MARK: - 推断入口

    /// 从一组同目录文件推断上下文。
    /// `fileURLs` 必须同属一个目录（`AlbumMatchService.groupByFolder` 保证这点）。
    public static func infer(directory: URL, fileURLs: [URL]) -> FolderContext {
        let dirName = directory.lastPathComponent
        let parent = directory.deletingLastPathComponent()

        // ① 目录本身就是 `CD1` / `Disc 2` 时，专辑名在上一层。
        var albumDir = directory
        var discFromFolder: Int?
        if let d = discFolderNumber(dirName), !parent.path.isEmpty, parent.path != "/" {
            discFromFolder = d
            albumDir = parent
        }

        // ② 剥离专辑目录名上的装饰
        let rawAlbumName = albumDir.lastPathComponent
        var cleaned = clean(folderName: rawAlbumName)
        if discFromFolder == nil { discFromFolder = cleaned.disc }

        // ③ `周杰伦 - 魔杰座` 这类「艺术家 - 专辑」目录名
        var artist: String?
        var origin: ArtistOrigin = .none
        if let split = splitArtistAlbum(cleaned.name) {
            artist = split.artist
            cleaned.name = split.album
            origin = .folderNameSplit
        }

        // ④ 祖父目录名当艺术家。通用目录名（Music/下载/新建文件夹…）不算数。
        if artist == nil {
            let grand = albumDir.deletingLastPathComponent()
            let gName = grand.lastPathComponent
            if !gName.isEmpty, gName != "/", !isGenericFolderName(gName),
               grand.path != "/", grand.path != albumDir.path {
                let g = clean(folderName: gName)
                if !g.name.isEmpty { artist = g.name; origin = .parentFolder }
            }
        }

        // ⑤ 逐文件解析（先不套艺术家，拿到公共前缀后再定稿）
        let stems = fileURLs.map { $0.deletingPathExtension().lastPathComponent }
        let prefixArtist = commonArtistPrefix(stems)
        if artist == nil, let p = prefixArtist { artist = p; origin = .filenamePrefix }

        let files = fileURLs.map { url -> FileNameContext in
            parseFileName(url, knownArtist: artist, prefixArtist: prefixArtist)
        }

        return FolderContext(directory: directory,
                             albumDirectory: albumDir,
                             rawFolderName: rawAlbumName,
                             album: cleaned.name.isEmpty ? nil : cleaned.name,
                             artist: artist,
                             artistOrigin: artist == nil ? .none : origin,
                             year: cleaned.year,
                             discNumber: discFromFolder,
                             files: files)
    }

    // MARK: - 文件夹名剥离

    public struct CleanedFolderName: Sendable, Equatable {
        public var name: String
        public var year: String?
        public var disc: Int?
    }

    /// 剥离顺序刻意固定：括号装饰 → 碟号后缀 → 年份 → 前导序号。
    /// 每一步都带「剪空就撤销」的兜底（见文件头第 2 条原则）。
    public static func clean(folderName raw: String) -> CleanedFolderName {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var year: String?
        var disc: Int?

        // ① 括号段：只剥「已知装饰」与「纯年份」，其余原样留着
        //    （`(Live)`、`(香港之戀)` 属于专辑身份的一部分，剥掉就认不出了）
        s = stripDecoratedBrackets(s, year: &year)

        // ② 碟号后缀：`魔杰座 CD1` / `魔杰座 Disc 2` / `魔杰座-CD2`
        if let m = firstMatch("^(.*?)[\\s\\-_.]*(?:cd|disc|disk|碟)[\\s\\-_.]*([0-9]{1,2})$",
                             in: s, caseInsensitive: true),
           let head = m[1], let n = m[2].flatMap({ Int($0) }), n > 0,
           !head.trimmingCharacters(in: separatorSet).isEmpty {
            disc = n
            s = head.trimmingCharacters(in: separatorSet)
        }

        // ③ 裸年份：前导 `2008 - X`、后缀 `X 2008`、或独立成段。
        //    整名就是年份时（Taylor Swift《1989》）**不剥**。
        if year == nil {
            let stripped = stripBareYear(s, into: &year)
            s = stripped
        }

        // ④ 前导序号：`01. 魔杰座` / `1 - 魔杰座`。四位数不认（那是年份）。
        if let m = firstMatch("^([0-9]{1,3})\\s*[.)\\-_、]\\s*(.+)$", in: s),
           let numStr = m[1], let rest = m[2],
           numStr.count <= 3, Int(numStr) != nil,
           !rest.trimmingCharacters(in: separatorSet).isEmpty {
            s = rest.trimmingCharacters(in: separatorSet)
        }

        s = s.trimmingCharacters(in: separatorSet)
        return CleanedFolderName(name: s, year: year, disc: disc)
    }

    /// 括号段处理。命中年份则记下年份；命中装饰词则整段丢弃；其余保留。
    static func stripDecoratedBrackets(_ raw: String, year: inout String?) -> String {
        var out = ""
        var buffer = ""
        var depth = 0
        var openChar: Character = "("
        for ch in raw {
            if depth == 0, "([{（【〔".contains(ch) {
                depth = 1; openChar = ch; buffer = ""; continue
            }
            if depth > 0, ")]}）】〕".contains(ch) {
                depth = 0
                let inner = buffer.trimmingCharacters(in: .whitespaces)
                if let y = yearToken(inner) {
                    year = year ?? y                       // `(2008)` → 年份，整段丢弃
                } else if isDecorationToken(inner) {
                    // `[FLAC]` / `[320K]` / `(Deluxe)` → 丢弃
                } else {
                    out += String(openChar) + buffer + String(ch)   // 原样还回去
                }
                buffer = ""
                continue
            }
            if depth > 0 { buffer.append(ch) } else { out.append(ch) }
        }
        if depth > 0 { out += String(openChar) + buffer }   // 括号没闭合，还原
        let trimmed = out.trimmingCharacters(in: separatorSet)
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// 裸年份剥离。只认「独立成词」的 19xx/20xx，且剥完不能为空。
    static func stripBareYear(_ s: String, into year: inout String?) -> String {
        // 前导：`2008 - 魔杰座` / `2008.魔杰座`
        if let m = firstMatch("^((?:19|20)[0-9]{2})\\s*[.)\\-_、]\\s*(.+)$", in: s),
           let y = m[1], let rest = m[2],
           !rest.trimmingCharacters(in: separatorSet).isEmpty {
            year = y
            return rest.trimmingCharacters(in: separatorSet)
        }
        // 后缀：`魔杰座 2008` / `魔杰座-2008`
        if let m = firstMatch("^(.+?)[\\s.\\-_]+((?:19|20)[0-9]{2})$", in: s),
           let head = m[1], let y = m[2],
           !head.trimmingCharacters(in: separatorSet).isEmpty {
            year = y
            return head.trimmingCharacters(in: separatorSet)
        }
        return s
    }

    /// `[FLAC]` `[320K]` `(Deluxe)` 这类与专辑身份无关的装饰词。
    static func isDecorationToken(_ raw: String) -> Bool {
        let n = raw.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return true }
        let lower = n.lowercased()
        for kw in decorationKeywords where lower == kw { return true }
        for kw in decorationContains where lower.contains(kw) { return true }
        // `320K` `320kbps` `24bit` `96khz` `24bit-96khz` `16-44.1`
        if lower.range(of: "^[0-9]{2,4}\\s*(k|kbps|bit|khz|hz)", options: .regularExpression) != nil { return true }
        if lower.range(of: "^[0-9]{1,2}\\s*bit", options: .regularExpression) != nil { return true }
        return false
    }

    static let decorationKeywords: [String] = [
        "flac", "ape", "wav", "wv", "mp3", "aac", "m4a", "alac", "dsd", "dsf", "dff",
        "sacd", "hdcd", "cd", "hi-res", "hires", "hq", "lossless", "无损", "母带",
        "deluxe", "deluxe edition", "special edition", "expanded edition",
        "bonus", "bonus track", "bonus tracks", "disc", "disk", "分轨", "整轨",
        "cue", "log", "scans", "封面", "自扫", "百度云", "网盘",
    ]
    static let decorationContains: [String] = [
        "kbps", "bit/", "khz", "24bit", "16bit", "分轨", "无损音乐",
    ]

    /// `CD1` / `Disc 2` / `碟一` 这类**整个目录名就是碟号**的情况。
    public static func discFolderNumber(_ name: String) -> Int? {
        let s = name.trimmingCharacters(in: .whitespaces)
        if let m = firstMatch("^(?:cd|disc|disk|dvd|碟|光碟)[\\s\\-_.]*([0-9]{1,2})$",
                             in: s, caseInsensitive: true),
           let n = m[1].flatMap({ Int($0) }), n > 0, n < 100 {
            return n
        }
        return nil
    }

    /// 目录名里的 `艺术家 - 专辑`。两边都得像样，否则不拆——
    /// 专辑名自己带连字符（`Mmm... - EP`）时拆错的代价比不拆大。
    public static func splitArtistAlbum(_ name: String) -> (artist: String, album: String)? {
        for sep in [" - ", " – ", " — ", " _ ", "－"] {
            guard let r = name.range(of: sep) else { continue }
            let a = String(name[..<r.lowerBound]).trimmingCharacters(in: separatorSet)
            let b = String(name[r.upperBound...]).trimmingCharacters(in: separatorSet)
            guard a.count >= 1, b.count >= 1, a.count <= 40, b.count <= 80 else { continue }
            // 右侧只剩年份/装饰的，说明本来就不是「艺术家 - 专辑」
            guard yearToken(b) == nil, !isDecorationToken(b) else { continue }
            return (a, b)
        }
        return nil
    }

    /// 通用目录名——出现在祖父层时不能当艺术家。
    public static func isGenericFolderName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return genericFolderNames.contains(n)
    }

    static let genericFolderNames: Set<String> = [
        "music", "musics", "mymusic", "my music", "itunes", "itunes media", "media",
        "songs", "song", "album", "albums", "audio", "downloads", "download",
        "desktop", "documents", "library", "volumes", "users", "temp", "tmp",
        "new folder", "untitled folder", "unsorted",
        "音乐", "我的音乐", "歌曲", "专辑", "唱片", "下载", "桌面", "文档",
        "新建文件夹", "待整理", "未分类", "音乐库",
    ]

    // MARK: - 文件名解析

    /// 解析单个文件名。`prefixArtist` 是整组共有的前缀艺术家，用来把它从曲名里剪掉。
    public static func parseFileName(_ url: URL,
                                     knownArtist: String?,
                                     prefixArtist: String?) -> FileNameContext {
        let stem = url.deletingPathExtension().lastPathComponent
        var ctx = FileNameContext(url: url, stem: stem)
        var s = stem.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① `1-01 Hello`：碟-轨。要求第二段后面确实跟着分隔符或空格，
        //    否则 `01-稻香` 会被误读成「碟 0 轨 1」。
        if let m = firstMatch("^([0-9]{1,2})[\\-_.]([0-9]{1,3})(?:[\\s.)\\-_、]+)(.+)$", in: s),
           let d = m[1].flatMap({ Int($0) }), let t = m[2].flatMap({ Int($0) }),
           let rest = m[3], d > 0, d < 50, t > 0, t < 200,
           !rest.trimmingCharacters(in: separatorSet).isEmpty {
            ctx.discNumber = d
            ctx.trackNumber = t
            s = rest
        } else if let m = firstMatch("^(?:track|曲目)[\\s._-]*([0-9]{1,3})\\b[\\s.)\\-_、]*(.*)$",
                                     in: s, caseInsensitive: true),
                  let t = m[1].flatMap({ Int($0) }), t > 0, t < 200 {
            ctx.trackNumber = t
            s = m[2] ?? ""
        } else if let m = firstMatch("^([0-9]{1,3})\\s*[.)\\-_、]\\s*(.+)$", in: s),
                  let t = m[1].flatMap({ Int($0) }), let rest = m[2],
                  t > 0, t < 200,
                  !rest.trimmingCharacters(in: separatorSet).isEmpty {
            ctx.trackNumber = t
            s = rest
        } else if let m = firstMatch("^([0-9]{1,3})\\s+(.+)$", in: s),
                  let t = m[1].flatMap({ Int($0) }), let rest = m[2],
                  t > 0, t < 200,
                  !rest.trimmingCharacters(in: separatorSet).isEmpty {
            ctx.trackNumber = t
            s = rest
        }

        s = s.trimmingCharacters(in: separatorSet)

        // ② 艺术家前缀 / 后缀
        var fileArtist: String?
        if let p = prefixArtist, let stripped = stripArtistAffix(s, artist: p) {
            fileArtist = p
            s = stripped
        } else if let known = knownArtist, let stripped = stripArtistAffix(s, artist: known) {
            fileArtist = known
            s = stripped
        } else if let split = splitArtistAlbum(s) {
            // `周杰伦 - 稻香`：整组没有共同前缀时，单文件也能拆
            // 哪边是艺术家无法单凭字面判断，交给调用方；这里记下左段供参考。
            fileArtist = split.artist
            s = split.album
        }

        // ③ 格式装饰
        var throwaway: String?
        s = stripDecoratedBrackets(s, year: &throwaway)
        s = s.trimmingCharacters(in: separatorSet)

        ctx.title = s.isEmpty ? nil : s
        ctx.artist = fileArtist
        return ctx
    }

    /// 剪掉 `艺术家 - ` 前缀或 ` - 艺术家` 后缀。剪空则不剪。
    static func stripArtistAffix(_ s: String, artist: String) -> String? {
        let na = MatchScorer.normalize(artist)
        guard !na.isEmpty else { return nil }
        for sep in [" - ", " – ", " — ", "-", "_", " _ ", "－"] {
            if let r = s.range(of: sep) {
                let head = String(s[..<r.lowerBound]).trimmingCharacters(in: separatorSet)
                let tail = String(s[r.upperBound...]).trimmingCharacters(in: separatorSet)
                if MatchScorer.normalize(head) == na, !tail.isEmpty { return tail }
                if MatchScorer.normalize(tail) == na, !head.isEmpty { return head }
            }
        }
        return nil
    }

    /// 整组文件名的公共艺术家前缀。要求 ≥2 个文件、前缀以分隔符收尾。
    public static func commonArtistPrefix(_ stems: [String]) -> String? {
        guard stems.count >= 2 else { return nil }
        // 先剥掉各自的前导序号，否则 `01 - ` `02 - ` 的差异会让公共前缀恒为空
        let bodies = stems.map { stem -> String in
            var s = stem
            if let r = s.range(of: "^\\s*[0-9]{1,3}\\s*[.)\\-_、]?\\s*", options: .regularExpression) {
                let rest = String(s[r.upperBound...])
                if !rest.trimmingCharacters(in: separatorSet).isEmpty { s = rest }
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        guard let first = bodies.first else { return nil }
        var prefix = ""
        outer: for (i, ch) in first.enumerated() {
            for b in bodies.dropFirst() {
                let idx = b.index(b.startIndex, offsetBy: i, limitedBy: b.endIndex)
                guard let idx, idx < b.endIndex, b[idx] == ch else { break outer }
            }
            prefix.append(ch)
        }
        guard prefix.count >= 2 else { return nil }
        // 前缀必须停在分隔符上，否则 `稻香`/`稻草人` 会给出「稻」这种碎片
        for sep in [" - ", " – ", " — ", " _ ", "_", "-"] {
            guard let r = prefix.range(of: sep, options: .backwards) else { continue }
            let a = String(prefix[..<r.lowerBound]).trimmingCharacters(in: separatorSet)
            guard a.count >= 1, a.count <= 40 else { continue }
            return a
        }
        return nil
    }

    // MARK: - 小工具

    static let separatorSet = CharacterSet(charactersIn: " \t-_.·、–—－")

    /// 整串就是一个 19xx/20xx 年份时返回它。
    public static func yearToken(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 4, let n = Int(t), n >= 1900, n <= 2199 else { return nil }
        return t
    }

    /// 取第一处匹配的各捕获组（index 0 是整串）。
    static func firstMatch(_ pattern: String, in s: String,
                           caseInsensitive: Bool = false) -> [String?]? {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

// MARK: - 内置自检用例

public extension FolderContext {

    struct ProbeCase: Sendable {
        public let path: String
        public let expectAlbum: String?
        public let expectArtist: String?
        public let expectTrack: Int?
        public let expectTitle: String?
        public let expectYear: String?
        public let expectDisc: Int?
        public let note: String
    }

    /// 12 条路径用例，覆盖任务书点名的每一种剥离。`mactagger-probe folderctx` 会逐条跑。
    static let probeCases: [ProbeCase] = [
        ProbeCase(path: "/Music/周杰伦/魔杰座/01 - 稻香.flac",
                  expectAlbum: "魔杰座", expectArtist: "周杰伦", expectTrack: 1,
                  expectTitle: "稻香", expectYear: nil, expectDisc: nil,
                  note: "标准三层：艺术家/专辑/序号 - 曲名"),
        ProbeCase(path: "/Music/周杰伦/魔杰座 (2008)/11.稻香.flac",
                  expectAlbum: "魔杰座", expectArtist: "周杰伦", expectTrack: 11,
                  expectTitle: "稻香", expectYear: "2008", expectDisc: nil,
                  note: "圆括号年份"),
        ProbeCase(path: "/Music/[2008] 魔杰座/稻香.mp3",
                  expectAlbum: "魔杰座", expectArtist: nil, expectTrack: nil,
                  expectTitle: "稻香", expectYear: "2008", expectDisc: nil,
                  note: "方括号年份 + 祖父是通用目录名(Music)，不当艺术家"),
        ProbeCase(path: "/x/邓丽君/島國之情歌 第四集 [FLAC]/03 空港.flac",
                  expectAlbum: "島國之情歌 第四集", expectArtist: "邓丽君", expectTrack: 3,
                  expectTitle: "空港", expectYear: nil, expectDisc: nil,
                  note: "[FLAC] 格式装饰剥离；「第四集」不能当合辑关键词误伤"),
        ProbeCase(path: "/x/周杰伦 - 魔杰座/05 - 蛇舞.flac",
                  expectAlbum: "魔杰座", expectArtist: "周杰伦", expectTrack: 5,
                  expectTitle: "蛇舞", expectYear: nil, expectDisc: nil,
                  note: "「艺术家 - 专辑」目录名拆分"),
        ProbeCase(path: "/x/Taylor Swift/1989 (Deluxe)/01. Welcome to New York.m4a",
                  expectAlbum: "1989", expectArtist: "Taylor Swift", expectTrack: 1,
                  expectTitle: "Welcome to New York", expectYear: nil, expectDisc: nil,
                  note: "专辑名整个就是年份 —— 剥年份会剪空，必须撤销"),
        ProbeCase(path: "/x/周杰伦/魔杰座/CD1/02 - 给我一首歌的时间.flac",
                  expectAlbum: "魔杰座", expectArtist: "周杰伦", expectTrack: 2,
                  expectTitle: "给我一首歌的时间", expectYear: nil, expectDisc: 1,
                  note: "CD1 子目录：专辑名上提一层，碟号取 1"),
        ProbeCase(path: "/x/Various/2008 - 魔杰座/03 稻香.flac",
                  expectAlbum: "魔杰座", expectArtist: "Various", expectTrack: 3,
                  expectTitle: "稻香", expectYear: "2008", expectDisc: nil,
                  note: "前导年份 + 空格分隔的音轨号"),
        ProbeCase(path: "/x/Music/专辑/周杰伦 - 稻香.mp3",
                  expectAlbum: "专辑", expectArtist: nil, expectTrack: nil,
                  expectTitle: "稻香", expectYear: nil, expectDisc: nil,
                  note: "单文件「艺术家 - 曲名」；专辑目录名本身是通用词，但作为专辑仍原样保留"),
        ProbeCase(path: "/x/王菲/唱游 [320K]/01_旋木.mp3",
                  expectAlbum: "唱游", expectArtist: "王菲", expectTrack: 1,
                  expectTitle: "旋木", expectYear: nil, expectDisc: nil,
                  note: "[320K] 码率装饰 + 下划线分隔的音轨号"),
        ProbeCase(path: "/x/Adele/25/1-01 Hello.flac",
                  expectAlbum: "25", expectArtist: "Adele", expectTrack: 1,
                  expectTitle: "Hello", expectYear: nil, expectDisc: 1,
                  note: "「碟-轨」写法；专辑名 25 是纯数字，不能被当序号剥掉"),
        ProbeCase(path: "/x/陈奕迅/U87 Disc 2/04. 浮夸.flac",
                  expectAlbum: "U87", expectArtist: "陈奕迅", expectTrack: 4,
                  expectTitle: "浮夸", expectYear: nil, expectDisc: 2,
                  note: "「专辑 Disc N」后缀写法"),
    ]

    /// 跑一条用例，返回 (实际上下文, 是否全部命中, 失败项说明)。
    static func runProbeCase(_ c: ProbeCase) -> (ctx: FolderContext, ok: Bool, diffs: [String]) {
        let url = URL(fileURLWithPath: c.path)
        let ctx = infer(directory: url.deletingLastPathComponent(), fileURLs: [url])
        let f = ctx.files.first
        var diffs: [String] = []
        func chk(_ label: String, _ got: String?, _ want: String?) {
            if got != want { diffs.append("\(label): 得到 \(got ?? "nil") / 期望 \(want ?? "nil")") }
        }
        chk("专辑", ctx.album, c.expectAlbum)
        chk("艺术家", ctx.artist, c.expectArtist)
        chk("年份", ctx.year, c.expectYear)
        // 碟号可能来自文件夹（`CD1`）也可能来自文件名（`1-01 …`），两处取其一
        let disc = ctx.discNumber ?? f?.discNumber
        chk("碟号", disc.map(String.init), c.expectDisc.map(String.init))
        chk("音轨号", f?.trackNumber.map(String.init), c.expectTrack.map(String.init))
        chk("曲名", f?.title, c.expectTitle)
        return (ctx, diffs.isEmpty, diffs)
    }
}

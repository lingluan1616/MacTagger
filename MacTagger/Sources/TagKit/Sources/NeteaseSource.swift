//
//  NeteaseSource.swift
//  MacTagger — 网易云音乐（明文 /api/* 端点）
//
//  C 报告最重要的结论：**完全不需要实现 weapi 的 AES+RSA 加密**。
//  原版 MusicTag.dll 硬编码的 weapi 方案（AES-128-CBC + RSA-1024）在 Mac 版无需复刻——
//  网易云至今保留着一组完全明文的 `/api/*` 端点，实测覆盖全部标签需求，
//  连 User-Agent 和 Referer 都不要求，GET/POST 皆可。
//
//  实测通过的端点（2026-09-01 复测）：
//    POST https://music.163.com/api/cloudsearch/pc            表单 s/type/offset/limit
//    GET  https://music.163.com/api/song/detail?ids=[id]      补音轨号 / 碟号 / 发行年
//    GET  https://music.163.com/api/song/lyric?os=pc&id=&lv=-1&kv=-1&tv=-1
//  已被 code:-462 拦掉的老端点（不要用）：
//    POST /api/search/pc、GET /api/album/{id}
//
//  风险对冲（C 报告 2.6）：明文接口属「历史遗留未关停」性质，随时可能收口。
//  本文件把端点集中在 `Endpoint` 里，真出问题时只改这一处；weapi 只留注释不实现。
//

import Foundation

public struct NeteaseSource: MetadataSource {

    public let id = "netease"
    public let displayName = "网易云音乐"
    public var capabilities: SourceCapabilities {
        [.searchTracks, .artwork, .lyrics, .translatedLyrics, .wordByWordLyrics]
    }

    private let http: HTTPClient

    public init() {
        // 明文接口对请求头零要求，但仍带上浏览器 UA 与温和限速，避免异常流量特征。
        self.http = HTTPClient(sourceID: "netease", policy: .chinese())
    }

    // MARK: - 端点

    private enum Endpoint {
        static let search = URL(string: "https://music.163.com/api/cloudsearch/pc")!
        static func detail(_ ids: [String]) -> URL? {
            let list = "[" + ids.joined(separator: ",") + "]"
            var c = URLComponents(string: "https://music.163.com/api/song/detail")!
            c.queryItems = [URLQueryItem(name: "ids", value: list)]
            return c.url
        }
        /// 歌词。五个 `?v=-1` 开关各要一轨，缺一轨就少一轨：
        /// `lv` 原词 / `tv` **翻译** / `rv` **罗马音** / `kv` 旧逐字 / `yv` 新逐字（YRC）。
        /// BD 轮补上 `rv` 与 `yv` —— 之前只要了三轨，日文歌的罗马音就永远拿不到。
        static func lyric(_ id: String) -> URL? {
            var c = URLComponents(string: "https://music.163.com/api/song/lyric")!
            c.queryItems = [
                URLQueryItem(name: "os", value: "pc"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "lv", value: "-1"),
                URLQueryItem(name: "kv", value: "-1"),
                URLQueryItem(name: "tv", value: "-1"),
                URLQueryItem(name: "rv", value: "-1"),
                URLQueryItem(name: "yv", value: "-1"),
            ]
            return c.url
        }
    }

    // MARK: - 搜索

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        guard !query.isEmpty else { return [] }
        let term = query.searchTerm
        let form = "s=\(Self.formEscape(term))&type=1&offset=0&limit=\(max(1, min(limit, 100)))"
        guard let body = form.data(using: .utf8) else {
            throw SourceError.decoding("搜索词编码失败")
        }

        let data = try await http.post(Endpoint.search, body: body)
        let root = JSONBox(try http.parseJSON(data))

        // 业务层校验：HTTP 200 不代表成功，网易云用 code 字段表达拦截（如 -462 要求绑定手机）。
        if let code = root["code"].int, code != 200 {
            throw SourceError.emptyResult("网易云返回 code=\(code)")
        }
        guard root["result"].exists else {
            throw SourceError.emptyResult("网易云响应缺少 result 字段")
        }

        let songs = root["result"]["songs"].array
        return songs.compactMap { Self.candidate(fromSearchSong: $0) }
    }

    /// 把搜索结果里的一首歌转成候选。
    private static func candidate(fromSearchSong s: JSONBox) -> TrackCandidate? {
        guard let songID = s["id"].string else { return nil }
        var c = TrackCandidate(sourceID: "netease",
                               nativeID: songID,
                               albumID: s["al"]["id"].string)
        c.title  = s["name"].string
        c.artist = joinArtists(s["ar"].array)
        c.album  = s["al"]["name"].string
        c.albumArtist = c.artist
        c.year   = year(fromEpochMillis: s["publishTime"].double)
        if let no = s["no"].int, no > 0 { c.trackNumber = String(no) }
        c.discNumber = normalizeDisc(s["cd"].string)
        // dt 是毫秒
        if let dt = s["dt"].double, dt > 0 { c.durationSeconds = dt / 1000 }
        c.artworkURL = artworkURL(s["al"]["picUrl"].string, size: 0)
        return c
    }

    // MARK: - 详情

    /// 搜索结果通常已带 no/cd/publishTime，但 UGC 条目常缺；这里用官方详情接口补齐。
    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard let url = Endpoint.detail([candidate.nativeID]) else { return candidate }
        let root = JSONBox(try await http.getJSON(url))
        if let code = root["code"].int, code != 200 {
            throw SourceError.emptyResult("网易云详情返回 code=\(code)")
        }
        let s = root["songs"][0]
        guard s.exists else { throw SourceError.emptyResult("网易云详情无该曲目") }

        var out = candidate
        if out.title?.isEmpty ?? true { out.title = s["name"].string }
        if out.artist?.isEmpty ?? true { out.artist = Self.joinArtists(s["artists"].array) }
        if out.albumArtist?.isEmpty ?? true { out.albumArtist = out.artist }
        if out.album?.isEmpty ?? true { out.album = s["album"]["name"].string }
        if out.trackNumber?.isEmpty ?? true, let no = s["no"].int, no > 0 {
            out.trackNumber = String(no)
        }
        if out.discNumber?.isEmpty ?? true {
            out.discNumber = Self.normalizeDisc(s["disc"].string)
        }
        if out.year?.isEmpty ?? true {
            out.year = Self.year(fromEpochMillis: s["album"]["publishTime"].double)
        }
        if out.durationSeconds <= 0, let ms = s["duration"].double, ms > 0 {
            out.durationSeconds = ms / 1000
        }
        if out.artworkURL == nil {
            out.artworkURL = Self.artworkURL(s["album"]["picUrl"].string, size: 0)
        }
        if out.albumID == nil { out.albumID = s["album"]["id"].string }
        return out
    }

    // MARK: - 封面

    /// 网易云支持服务端任意尺寸缩放：`picUrl?param=宽y高`。超过原图则返回原图。
    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        guard let base = candidate.artworkURL else { return nil }
        let sized = Self.applySizeParam(base, size: preferredSize) ?? base
        let data = try await http.get(sized)
        guard data.count > 512 else {
            throw SourceError.emptyResult("网易云封面响应过小（\(data.count) 字节）")
        }
        return data
    }

    // MARK: - 歌词

    /// 网易云是所有源里歌词能力最强的一家：原词 + 翻译 + 逐字同一次请求返回，且无编码坑。
    /// 注意：`klyric`（逐字）字段恒定存在，但实测大量曲目为空——明文端点上逐字数据多已迁走。
    public func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        guard let url = Endpoint.lyric(candidate.nativeID) else { return nil }
        let root = JSONBox(try await http.getJSON(url))
        if let code = root["code"].int, code != 200 {
            throw SourceError.emptyResult("网易云歌词返回 code=\(code)")
        }
        // 逐字优先 YRC（新格式，覆盖面比 klyric 广得多），没有才退回 klyric。
        let verbatim = Self.cleanLyric(root["yrc"]["lyric"].string)
            ?? Self.cleanLyric(root["klyric"]["lyric"].string)
        let bundle = LyricsBundle(
            sourceID: id,
            plain:      Self.cleanLyric(root["lrc"]["lyric"].string),
            translated: Self.cleanLyric(root["tlyric"]["lyric"].string),
            wordByWord: verbatim,
            romanized:  Self.cleanLyric(root["romalrc"]["lyric"].string))
        return bundle.isEmpty ? nil : bundle
    }

    // MARK: - 工具

    /// 表单值转义。`+` 在表单里表示空格，必须编码。
    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func joinArtists(_ boxes: [JSONBox]) -> String? {
        let names = boxes.compactMap { $0["name"].string }
        return names.isEmpty ? nil : names.joined(separator: "/")
    }

    /// publishTime 是**毫秒**时间戳，需转成 4 位年份。0 / 负值 / 越界一律当未知。
    static func year(fromEpochMillis ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let y = cal.component(.year, from: Date(timeIntervalSince1970: ms / 1000))
        guard y > 1900, y < 2200 else { return nil }
        return String(y)
    }

    /// 搜索接口的 `cd` 是字符串 `"01"`，详情接口的 `disc` 是 `"1"`。统一成十进制无前导零。
    static func normalizeDisc(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let n = Int(raw) { return n > 0 ? String(n) : nil }
        return raw
    }

    /// 网易云图片域名常返回 http://，macOS ATS 默认拒绝明文加载，统一升级为 https。
    static func artworkURL(_ raw: String?, size: Int) -> URL? {
        guard var s = raw, !s.isEmpty else { return nil }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard let base = URL(string: s) else { return nil }
        return size > 0 ? (applySizeParam(base, size: size) ?? base) : base
    }

    static func applySizeParam(_ url: URL, size: Int) -> URL? {
        guard size > 0 else { return url }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "param", value: "\(size)y\(size)")]
        return c.url
    }

    /// 去掉空串与纯空白，并把可能出现的 \r\n 规范成 \n。
    static func cleanLyric(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : normalized
    }
}

// MARK: - 整碟曲目表

public extension NeteaseSource {

    /// 实测（2026-09-03）：老的 `GET /api/album/{id}` 已被 code:-462 拦掉（见文件头），
    /// 但 **`GET /api/v1/album/{id}` 仍是明文可用的**：
    /// `code:200`，顶层给 `album`（name / artist.name / publishTime 毫秒 / size / picUrl）
    /// 与 `songs[]`（no / cd / dt 毫秒 / name / ar[]）。
    /// id=18875（跨时代）实测：album.size=11，songs 11 条，`no` 跳号到 13
    /// ——**下架曲目会缺席但声明的 size 不变**，所以 `trackCount` 与 `tracks.count` 必须分开记。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? {
        guard let albumID = candidate.albumID, !albumID.isEmpty else { return nil }
        guard let url = URL(string: "https://music.163.com/api/v1/album/" + albumID) else { return nil }

        let root = JSONBox(try await http.getJSON(url))
        if let code = root["code"].int, code != 200 {
            throw SourceError.emptyResult("网易云专辑返回 code=\(code)")
        }
        let a = root["album"]
        guard a.exists else { throw SourceError.emptyResult("网易云专辑响应缺少 album 字段") }

        var detail = AlbumDetail(sourceID: id, albumID: albumID)
        detail.title = a["name"].string
        detail.artist = a["artist"]["name"].string
            ?? Self.joinArtists(a["artists"].array)
        detail.year = Self.year(fromEpochMillis: a["publishTime"].double)
        detail.trackCount = a["size"].int ?? 0
        detail.artworkURL = Self.artworkURL(a["picUrl"].string, size: 0)

        var discs = Set<Int>()
        for s in root["songs"].array {
            guard let name = s["name"].string else { continue }
            let no = s["no"].int ?? 0
            guard no > 0 else { continue }
            let cd = Int(Self.normalizeDisc(s["cd"].string) ?? "1") ?? 1
            discs.insert(max(1, cd))
            detail.tracks.append(AlbumTrack(
                number: no,
                disc: max(1, cd),
                title: name,
                durationSeconds: (s["dt"].double ?? 0) / 1000.0,
                artist: Self.joinArtists(s["ar"].array),
                nativeID: s["id"].string))
        }
        detail.discCount = max(1, discs.count)
        if detail.trackCount == 0 { detail.trackCount = detail.tracks.count }
        detail.tracks.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        return detail
    }
}

//
//  KugouSource.swift
//  MacTagger — 酷狗音乐
//
//  C 报告关键实测结论（2026-09-01 复测确认）：
//  · 原版硬编码的主机 `mobilecdn.kugou.com` **证书已失效**，macOS/URLSession 上根本发不出请求
//    （curl 亦以 exit 60 = SSL certificate problem 失败）。**必须改用 `mobiles.kugou.com`**。
//  · 搜索 `https://mobiles.kugou.com/api/v3/search/song` 实测可用，返回 `data.info[].hash`。
//  · 歌词走 `https://m3ws.kugou.com/api/v1/krc/get_krc`，返回**明文 LRC**（`data.lrc`）。
//  · `api/v3/song/detail` 返回 "Access Deny ! No Actions !"，年份/音轨号只能走专辑接口补。
//
//  两个编码坑（已在本文件处理）：
//  · m3ws 返回的 LRC 行尾是 `\r\n`，须规范化成 `\n`。
//  · lyrics.kugou 系接口的 LRC 带 UTF-8 BOM，须剥掉。
//
//  BD 轮（2026-09-11）把 KRC 补上了 —— 起因是用户报「歌词总是没有翻译」：
//  m3ws 的明文 LRC **只有原文**，酷狗的翻译与罗马音全藏在 KRC 的 `[language:…]` 头里
//  （一段 base64 JSON，`type:1` 翻译 / `type:0` 罗马音，按行号与正文一一对应）。
//  不解 KRC，酷狗这个源就永远只能给原文。解密见 `KRCCrypto`（跳 4 字节 magic +
//  16 字节循环异或 + zlib），解析见 `KRCParser`。
//

import Foundation

public struct KugouSource: MetadataSource {

    public let id = "kugou"
    public let displayName = "酷狗音乐"
    public var capabilities: SourceCapabilities {
        // BD 轮起支持翻译与逐字：KRC 一份里就带着这两轨（见文件头）。
        [.searchTracks, .artwork, .lyrics, .translatedLyrics, .wordByWordLyrics]
    }

    private let http: HTTPClient

    public init() {
        self.http = HTTPClient(sourceID: "kugou", policy: .chinese(referer: "https://www.kugou.com/"))
    }

    // MARK: - 端点

    private enum Endpoint {
        /// 注意主机名：mobiles（复数），不是原版的 mobilecdn。
        static func search(_ keyword: String, limit: Int) -> URL? {
            var c = URLComponents(string: "https://mobiles.kugou.com/api/v3/search/song")!
            c.queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pagesize", value: String(max(1, min(limit, 50)))),
                URLQueryItem(name: "showtype", value: "1"),
            ]
            return c.url
        }
        static func albumInfo(_ albumID: String) -> URL? {
            var c = URLComponents(string: "https://mobiles.kugou.com/api/v3/album/info")!
            c.queryItems = [URLQueryItem(name: "albumid", value: albumID)]
            return c.url
        }
        static func albumSongs(_ albumID: String) -> URL? {
            var c = URLComponents(string: "https://mobiles.kugou.com/api/v3/album/song")!
            c.queryItems = [
                URLQueryItem(name: "albumid", value: albumID),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pagesize", value: "200"),
            ]
            return c.url
        }
        static func lyric(keyword: String, hash: String, milliseconds: Int) -> URL? {
            var c = URLComponents(string: "https://m3ws.kugou.com/api/v1/krc/get_krc")!
            c.queryItems = [
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "hash", value: hash),
                URLQueryItem(name: "timelength", value: String(milliseconds)),
            ]
            return c.url
        }
        /// KRC 第一步：按 hash + 时长找歌词候选，拿 `id` 与 `accesskey`。
        static func krcSearch(keyword: String, hash: String, milliseconds: Int) -> URL? {
            var c = URLComponents(string: "https://lyrics.kugou.com/search")!
            c.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "yes"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "hash", value: hash),
                URLQueryItem(name: "timelength", value: String(milliseconds)),
            ]
            return c.url
        }
        /// KRC 第二步：下载。`content` 是 base64；`contenttype == 2` 表示里面已是明文。
        static func krcDownload(id: String, accesskey: String) -> URL? {
            var c = URLComponents(string: "https://lyrics.kugou.com/download")!
            c.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "accesskey", value: accesskey),
                URLQueryItem(name: "fmt", value: "krc"),
                URLQueryItem(name: "charset", value: "utf8"),
            ]
            return c.url
        }
    }

    // MARK: - 搜索

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        guard !query.isEmpty else { return [] }
        guard let url = Endpoint.search(query.searchTerm, limit: limit) else {
            throw SourceError.decoding("搜索 URL 构造失败")
        }
        let root = JSONBox(try await http.getJSON(url))

        // 业务层校验：酷狗用 status=1 表示成功，errcode 非 0 即失败。
        guard root["status"].int == 1 else {
            let err = root["error"].string ?? "status=\(root["status"].int.map(String.init) ?? "?")"
            throw SourceError.emptyResult("酷狗搜索失败：\(err)")
        }
        guard root["data"].exists else {
            throw SourceError.emptyResult("酷狗响应缺少 data 字段")
        }
        return root["data"]["info"].array.compactMap { Self.candidate(from: $0) }
    }

    private static func candidate(from s: JSONBox) -> TrackCandidate? {
        guard let hash = s["hash"].string, !hash.isEmpty else { return nil }
        let albumID = s["album_id"].string.flatMap { $0 == "0" || $0.isEmpty ? nil : $0 }
        var c = TrackCandidate(sourceID: "kugou", nativeID: hash, albumID: albumID)
        c.title  = stripHighlight(s["songname"].string) ?? stripHighlight(s["songname_original"].string)
        c.artist = stripHighlight(s["singername"].string)
        c.album  = stripHighlight(s["album_name"].string)
        c.albumArtist = c.artist
        // duration 单位是**秒**（与网易云 / QQ 不同）
        if let d = s["duration"].double, d > 0 { c.durationSeconds = d }
        // 搜索结果里就带了封面模板，省掉一次专辑请求
        c.artworkURL = coverURL(template: s["trans_param"]["union_cover"].string, size: 0)
        return c
    }

    // MARK: - 详情（补年份 / 音轨号 / 高清封面）

    /// 酷狗搜索结果**没有**年份和音轨号，`song/detail` 又被 "Access Deny" 拦，
    /// 只能走专辑接口：`album/info` 给发行日期与封面模板，`album/song` 的曲目次序即音轨号。
    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard let albumID = candidate.albumID, !albumID.isEmpty else { return candidate }
        var out = candidate

        if let url = Endpoint.albumInfo(albumID) {
            let root = JSONBox(try await http.getJSON(url))
            if root["status"].int == 1 {
                let d = root["data"]
                if out.album?.isEmpty ?? true { out.album = d["albumname"].string }
                if out.albumArtist?.isEmpty ?? true { out.albumArtist = d["singername"].string }
                if out.year?.isEmpty ?? true { out.year = Self.year(fromDateString: d["publishtime"].string) }
                if let tpl = d["imgurl"].string, let u = Self.coverURL(template: tpl, size: 0) {
                    out.artworkURL = u
                }
            }
        }

        // 音轨号：在专辑曲目表里按 hash 定位（酷狗两个接口的 hash 大小写不一致，须忽略大小写）。
        //
        // 曲目表里 `trans_param.sort` 才是**权威音轨号**（实测 魔杰座 albumid=960399：
        // 稻香 sort=11，与 QQ / 官方碟面一致）；数组下标只是分页后的位置，
        // 一旦分页、缺曲或多碟合并就会错位，故只当 sort 缺失时的兜底。
        if out.trackNumber?.isEmpty ?? true, let url = Endpoint.albumSongs(albumID) {
            let root = JSONBox(try await http.getJSON(url))
            if root["status"].int == 1 {
                let list = root["data"]["info"].array
                let want = candidate.nativeID.lowercased()
                if let idx = list.firstIndex(where: { ($0["hash"].string ?? "").lowercased() == want }) {
                    let sort = list[idx]["trans_param"]["sort"].int
                    let track = (sort.map { $0 > 0 ? $0 : idx + 1 }) ?? (idx + 1)
                    out.trackNumber = String(track)
                    if out.discNumber == nil { out.discNumber = "1" }
                    // 顺带补时长（搜索结果偶尔为 0），曲目表的 duration 同样是**秒**
                    if out.durationSeconds <= 0, let d = list[idx]["duration"].double, d > 0 {
                        out.durationSeconds = d
                    }
                    // 曲目表的 union_cover 与专辑封面同源，仅当前面没拿到时才用
                    if out.artworkURL == nil,
                       let u = Self.coverURL(template: list[idx]["trans_param"]["union_cover"].string, size: 0) {
                        out.artworkURL = u
                    }
                }
            }
        }
        return out
    }

    // MARK: - 封面

    /// 酷狗封面是带 `{size}` 占位符的模板串，实测 1000 可用（C 报告：上限 1000）。
    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        guard let base = candidate.artworkURL else { return nil }
        let size = preferredSize <= 0 ? 1000 : min(preferredSize, 1000)
        let url = Self.resize(base, to: size)
        let data = try await http.get(url)
        guard data.count > 512 else {
            throw SourceError.emptyResult("酷狗封面响应过小（\(data.count) 字节）")
        }
        return data
    }

    // MARK: - 歌词

    /// 取歌词。**先走 KRC（带翻译与罗马音），拿不到才回落 m3ws 的明文 LRC。**
    ///
    /// 次序不能反：m3ws 那一路一定成功、但**永远只有原文**，
    /// 先问它就等于把翻译永久让掉 —— 这正是用户报的「歌词总是没有翻译」的酷狗那一半。
    public func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        if let krc = try? await fetchKRC(candidate), !krc.isEmpty { return krc }
        return try await fetchPlainLyrics(candidate)
    }

    /// KRC 两步走：`lyrics.kugou.com/search` 拿 id+accesskey → `/download` 拿密文。
    func fetchKRC(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        let keyword = Self.lyricKeyword(candidate)
        let ms = Int((candidate.durationSeconds * 1000).rounded())
        guard let searchURL = Endpoint.krcSearch(keyword: keyword,
                                                 hash: candidate.nativeID,
                                                 milliseconds: max(0, ms)) else { return nil }
        let list = JSONBox(try await http.getJSON(searchURL))
        guard list["status"].int == 200 else { return nil }
        // 候选按酷狗自己的 score 排，第一条就是它认为最贴的那份。
        guard let first = list["candidates"].array.first,
              let cid = first["id"].string, let key = first["accesskey"].string,
              let dlURL = Endpoint.krcDownload(id: cid, accesskey: key) else { return nil }

        let payload = JSONBox(try await http.getJSON(dlURL))
        guard payload["status"].int == 200,
              let content = payload["content"].string, !content.isEmpty else { return nil }
        let isPlain = payload["contenttype"].int == 2
        guard let text = KRCCrypto.decrypt(base64: content, plaintext: isPlain) else { return nil }

        // `contenttype == 2` 那一路本来就是明文 LRC，没有 KRC 的结构。
        if isPlain {
            guard let lrc = Self.normalizeLRC(text) else { return nil }
            return LyricsBundle(sourceID: id, plain: lrc)
        }
        let parsed = KRCParser.parse(text)
        let bundle = LyricsBundle(sourceID: id,
                                  plain: parsed.plain,
                                  translated: parsed.translated,
                                  wordByWord: parsed.wordByWord,
                                  romanized: parsed.romanized)
        return bundle.isEmpty ? nil : bundle
    }

    /// m3ws 的明文 LRC。只有原文，作兜底。
    func fetchPlainLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        let keyword = Self.lyricKeyword(candidate)
        let ms = Int((candidate.durationSeconds * 1000).rounded())
        guard let url = Endpoint.lyric(keyword: keyword,
                                       hash: candidate.nativeID,
                                       milliseconds: max(0, ms)) else { return nil }

        let root = JSONBox(try await http.getJSON(url))
        guard root["status"].int == 1 else {
            throw SourceError.emptyResult("酷狗歌词失败：errcode=\(root["errcode"].int.map(String.init) ?? "?")")
        }
        guard let lrc = Self.normalizeLRC(root["data"]["lrc"].string) else { return nil }
        return LyricsBundle(sourceID: id, plain: lrc)
    }

    /// 歌词接口吃的是「歌手 曲名」；两者都空时退回曲名。
    static func lyricKeyword(_ c: TrackCandidate) -> String {
        let joined = [c.artist, c.title].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? (c.title ?? "") : joined
    }

    // MARK: - 工具

    /// `showtype=1` 有时会在命中词上包 `<em>`，写进标签前必须剥掉。
    static func stripHighlight(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let cleaned = s
            .replacingOccurrences(of: "<em>", with: "")
            .replacingOccurrences(of: "</em>", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// `publishtime` 形如 "2008-10-15 00:00:00"，取前 4 位作年份。
    static func year(fromDateString s: String?) -> String? {
        guard let s, s.count >= 4 else { return nil }
        let y = String(s.prefix(4))
        guard let n = Int(y), n > 1900, n < 2200 else { return nil }
        return y
    }

    /// 酷狗封面是带 `{size}` 占位符的模板串（`http://imge.kugou.com/stdmusic/{size}/…jpg`）。
    /// URL 不接受 `{}`，且带占位符的 URL 被别处直接请求会 404，
    /// 因此这里**直接替换成可用尺寸**（默认 1000 = C 报告实测上限），并升级到 https。
    static func coverURL(template: String?, size: Int) -> URL? {
        guard var t = template, !t.isEmpty else { return nil }
        if t.hasPrefix("http://") { t = "https://" + t.dropFirst("http://".count) }
        let n = size > 0 ? min(size, 1000) : 1000
        t = t.replacingOccurrences(of: "{size}", with: String(n))
        return URL(string: t)
    }

    /// 把已生成的封面 URL 里第一个纯数字路径段换成目标尺寸（`/1000/` → `/500/`）。
    static func resize(_ url: URL, to size: Int) -> URL {
        let s = url.absoluteString
        guard let range = s.range(of: "/[0-9]{1,4}/", options: .regularExpression) else { return url }
        return URL(string: s.replacingCharacters(in: range, with: "/\(size)/")) ?? url
    }

    /// 剥 BOM + 把 `\r\n` 规范成 `\n`。两处坑都在这里一次性处理。
    static func normalizeLRC(_ raw: String?) -> String? {
        guard var t = raw, !t.isEmpty else { return nil }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
             .replacingOccurrences(of: "\r", with: "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t
    }
}

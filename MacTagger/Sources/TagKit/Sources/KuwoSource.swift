//
//  KuwoSource.swift
//  MacTagger — 酷我音乐
//
//  C 报告结论 + 本轮（2026-09-01）逐条复测：
//  · 搜索 `https://search.kuwo.cn/r.s`。**那串长参数还在被服务端校验，一个都不能省**
//    （ver / vipver / newver / vermerge / mobi / strategy … 缺项即被拒），
//    所以 `Endpoint.search` 把它们全列出来，不要「顺手精简」。
//  · 搜索返回合法 JSON；**专辑接口返回单引号伪 JSON**（`{'albumid':'29218',…}`），
//    必须走 `HTTPClient.parseLooseJSON`（坑①）。
//  · 歌词是**结构化数组** `data.lrclist[{time, lineLyric}]`，`time` 是**秒**且可能带小数
//    （"7.73"），需自行拼成 `[mm:ss.xx]` 标准 LRC（坑③）。
//  · 歌词接口业务层会失败（坑②），故带重试，见 `Endpoint.lyric` 注释。
//
//  歌词端点的现网状况（本轮实测，与 C 报告不同，已改）：
//    ✘ `https://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId={rid}`
//       连打 6 次全部 `status:301 / "音乐查询失败"`，已不可用（仍保留为兜底，
//       万一是地域性抽风）。
//    ✔ `https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId={rid}&httpsStatus=1`
//       连打 8 次全部 `code:200`，48 行歌词，结构与老端点完全一致。改为首选。
//
//  合规：全部为只读查询，不登录、不带他人 Cookie、不取音频本体，只取元数据与封面图。
//

import Foundation

public struct KuwoSource: MetadataSource {

    public let id = "kuwo"
    public let displayName = "酷我音乐"
    public var capabilities: SourceCapabilities {
        // 只有明文 LRC，没有翻译/逐字。
        [.searchTracks, .artwork, .lyrics]
    }

    private let http: HTTPClient

    /// 歌词接口的业务层失败率实测约 20–30%（老端点更高），
    /// 而 HTTPClient 的重试只覆盖 5xx / 超时——业务层 200 里的失败它看不见，
    /// 所以在本文件里另做一层业务重试。
    static let lyricBusinessRetries = 2

    public init() {
        self.http = HTTPClient(sourceID: "kuwo", policy: .chinese(referer: "https://www.kuwo.cn/"))
    }

    // MARK: - 端点

    private enum Endpoint {

        /// 搜索。**参数不可精简**：服务端仍在校验这一整串客户端指纹，
        /// 少任何一项都会被拒（C 报告实测结论，本轮复测仍然成立）。
        static func search(_ keyword: String, limit: Int) -> URL? {
            var c = URLComponents(string: "https://search.kuwo.cn/r.s")!
            c.queryItems = [
                URLQueryItem(name: "all", value: keyword),
                URLQueryItem(name: "client", value: "kt"),
                URLQueryItem(name: "pn", value: "0"),
                URLQueryItem(name: "rn", value: String(max(1, min(limit, 50)))),
                URLQueryItem(name: "ver", value: "kwplayer_ar_9.2.3.2"),
                URLQueryItem(name: "vipver", value: "1"),
                URLQueryItem(name: "show_copyright_off", value: "1"),
                URLQueryItem(name: "newver", value: "1"),
                URLQueryItem(name: "correct", value: "1"),
                URLQueryItem(name: "ft", value: "music"),
                URLQueryItem(name: "cluster", value: "0"),
                URLQueryItem(name: "strategy", value: "2012"),
                URLQueryItem(name: "encoding", value: "utf8"),
                URLQueryItem(name: "rformat", value: "json"),
                URLQueryItem(name: "vermerge", value: "1"),
                URLQueryItem(name: "mobi", value: "1"),
                URLQueryItem(name: "issubtitle", value: "1"),
            ]
            return c.url
        }

        /// 专辑详情 + 曲目表。**返回单引号伪 JSON**，必须 `parseLooseJSON`。
        /// 给年份（`pub` / `musiclist[].releasedate`）与音轨号（`musiclist[].track`）。
        static func albumInfo(_ albumID: String, limit: Int = 200) -> URL? {
            var c = URLComponents(string: "https://search.kuwo.cn/r.s")!
            c.queryItems = [
                URLQueryItem(name: "stype", value: "albuminfo"),
                URLQueryItem(name: "albumid", value: albumID),
                URLQueryItem(name: "pn", value: "0"),
                URLQueryItem(name: "rn", value: String(limit)),
                URLQueryItem(name: "encoding", value: "utf8"),
                URLQueryItem(name: "rformat", value: "json"),
                URLQueryItem(name: "vipver", value: "1"),
                URLQueryItem(name: "client", value: "kt"),
                URLQueryItem(name: "ver", value: "kwplayer_ar_9.2.3.2"),
            ]
            return c.url
        }

        /// 歌词（首选）。返回 `data.lrclist[{time, lineLyric}]`。
        static func lyric(_ rid: String) -> URL? {
            var c = URLComponents(string: "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric")!
            c.queryItems = [
                URLQueryItem(name: "musicId", value: rid),
                URLQueryItem(name: "httpsStatus", value: "1"),
            ]
            return c.url
        }

        /// 歌词（兜底，C 报告的老端点）。本轮实测常年 `status:301`，只在首选全失败后才试。
        static func lyricLegacy(_ rid: String) -> URL? {
            var c = URLComponents(string: "https://m.kuwo.cn/newh5/singles/songinfoandlrc")!
            c.queryItems = [URLQueryItem(name: "musicId", value: rid)]
            return c.url
        }
    }

    /// 封面 CDN 前缀。路径形如 `120/s4s0/93/1794217775.jpg`，开头的数字段就是边长。
    static let artworkPrefix = "https://img1.kuwo.cn/star/albumcover/"
    /// C 报告给出的封面尺寸上限。CDN 对 1000/1500 也返回 200，
    /// 但那已超出母版分辨率（服务端放大），无额外细节，故仍以 500 为准。
    static let maxArtworkSize = 500

    // MARK: - 搜索

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        guard !query.isEmpty else { return [] }
        guard let url = Endpoint.search(query.searchTerm, limit: limit) else {
            throw SourceError.decoding("酷我搜索 URL 构造失败")
        }

        let data = try await http.get(url)
        let root = JSONBox(try http.parseLooseJSON(data))

        // 业务层校验：HTTP 200 不代表成功。
        // · 连 `abslist` 这个键都没有 → 结构不对（被拦 / 端点变更），算源故障。
        // · 有 `abslist` 但为空，且 `TOTAL` 也是 0 → 真的没搜到，返回空数组（不是故障）。
        // · 有 `abslist` 但为空，`TOTAL` 却大于 0 → 典型的静默置空，算源故障。
        guard root["abslist"].exists else {
            throw SourceError.emptyResult("酷我响应缺少 abslist 字段（可能已被拦截或端点变更）")
        }
        let list = root["abslist"].array
        if list.isEmpty {
            let total = root["TOTAL"].int ?? 0
            if total > 0 {
                throw SourceError.emptyResult("酷我 TOTAL=\(total) 却返回空 abslist（疑似静默置空）")
            }
            return []
        }
        return list.compactMap { Self.candidate(from: $0) }
    }

    private static func candidate(from s: JSONBox) -> TrackCandidate? {
        // 主键是 DC_TARGETID（即 rid），不是 MUSICRID（那是带 "MUSIC_" 前缀的形式）
        guard let rid = s["DC_TARGETID"].string, !rid.isEmpty, rid != "0" else { return nil }
        let albumID = s["ALBUMID"].string.flatMap { $0 == "0" || $0.isEmpty ? nil : $0 }

        var c = TrackCandidate(sourceID: "kuwo", nativeID: rid, albumID: albumID)
        c.title  = decodeEntities(s["SONGNAME"].string) ?? decodeEntities(s["NAME"].string)
        c.artist = decodeEntities(s["ARTIST"].string)
        c.album  = decodeEntities(s["ALBUM"].string)
        c.albumArtist = c.artist
        // DURATION 单位是**秒**（与网易云/QQ 的毫秒不同）
        if let d = s["DURATION"].double, d > 0 { c.durationSeconds = d }
        c.artworkURL = artworkURL(shortPath: s["web_albumpic_short"].string, size: maxArtworkSize)
        // 搜索结果没有年份与音轨号，要靠 fetchDetail 走专辑接口补。
        return c
    }

    // MARK: - 详情（补年份 / 音轨号 / 封面）

    /// 酷我搜索结果**不含年份与音轨号**，只能走专辑接口补：
    /// `pub` 给发行日期，`musiclist[]` 里按 rid 定位后取 `track`。
    ///
    /// 坑①：这个接口返回的是单引号伪 JSON，必须 `parseLooseJSON`。
    /// 伪 JSON 的修复方式是「把所有单引号换成双引号」，遇到值里带 ASCII 撇号
    /// （如 `Guns N' Roses`）会修坏——那属于补不到详情，不是致命错误，
    /// 故这里**降级返回原候选**而不是抛错，免得一条脏数据毁掉整批匹配。
    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard let albumID = candidate.albumID, !albumID.isEmpty,
              let url = Endpoint.albumInfo(albumID) else { return candidate }

        let data = try await http.get(url)
        guard let parsed = try? http.parseLooseJSON(data) else { return candidate }
        let root = JSONBox(parsed)
        guard root.exists else { return candidate }

        var out = candidate
        if out.album?.isEmpty ?? true { out.album = Self.decodeEntities(root["name"].string) }
        if out.albumArtist?.isEmpty ?? true { out.albumArtist = Self.decodeEntities(root["artist"].string) }
        if out.year?.isEmpty ?? true { out.year = Self.year(fromDateString: root["pub"].string) }
        if let u = Self.artworkURL(shortPath: root["pic"].string, size: Self.maxArtworkSize) {
            out.artworkURL = u
        }

        // 在曲目表里按 rid 定位，取权威音轨号
        let want = candidate.nativeID
        if let track = root["musiclist"].array.first(where: { $0["id"].string == want }) {
            if out.trackNumber?.isEmpty ?? true,
               let n = track["track"].int, n > 0 { out.trackNumber = String(n) }
            if out.discNumber?.isEmpty ?? true { out.discNumber = "1" }
            if out.year?.isEmpty ?? true {
                out.year = Self.year(fromDateString: track["releasedate"].string)
            }
            if out.durationSeconds <= 0, let d = track["duration"].double, d > 0 {
                out.durationSeconds = d
            }
        }
        return out
    }

    // MARK: - 封面

    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        guard let base = candidate.artworkURL else { return nil }
        let size = preferredSize <= 0 ? Self.maxArtworkSize : min(preferredSize, Self.maxArtworkSize)
        let url = Self.resize(base, to: size)
        let data = try await http.get(url)
        guard data.count > 512 else {
            throw SourceError.emptyResult("酷我封面响应过小（\(data.count) 字节）")
        }
        return data
    }

    // MARK: - 歌词

    /// 坑②：歌词接口业务层约 20–30% 概率失败（HTTP 仍是 200），故重试 `lyricBusinessRetries` 次；
    /// 首选端点连试都失败后，再退到 C 报告的老端点试一次。
    public func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        guard !candidate.nativeID.isEmpty else { return nil }
        var lastError: Error?

        for attempt in 0...Self.lyricBusinessRetries {
            if attempt > 0 {
                // 业务层失败多半是瞬时的，退避一下再来
                try? await Task.sleep(nanoseconds: UInt64(0.4 * Double(attempt) * 1_000_000_000))
            }
            do {
                if let lrc = try await fetchLyricList(Endpoint.lyric(candidate.nativeID)) {
                    return LyricsBundle(sourceID: id, plain: lrc)
                }
                lastError = SourceError.emptyResult("酷我歌词为空")
            } catch {
                lastError = error
            }
        }

        // 兜底：老端点
        if let lrc = try? await fetchLyricList(Endpoint.lyricLegacy(candidate.nativeID)) {
            return LyricsBundle(sourceID: id, plain: lrc)
        }

        if let e = lastError as? SourceError, case .emptyResult = e { return nil }
        if let e = lastError { throw e }
        return nil
    }

    /// 拉一次歌词并拼成 LRC。业务层失败抛 `emptyResult`；真的没有歌词返回 nil。
    private func fetchLyricList(_ url: URL?) async throws -> String? {
        guard let url else { return nil }
        let root = JSONBox(try await http.getJSON(url))

        // 业务层校验：新端点用 `code`（200 成功），老端点用 `status`（200 成功，301 = 音乐查询失败）
        if let code = root["code"].int, code != 200 {
            throw SourceError.emptyResult("酷我歌词返回 code=\(code) \(root["msg"].string ?? "")")
        }
        if let status = root["status"].int, status != 200 {
            throw SourceError.emptyResult("酷我歌词返回 status=\(status) \(root["msg"].string ?? "")")
        }
        guard root["data"].exists else {
            throw SourceError.emptyResult("酷我歌词响应缺少 data 字段")
        }
        let lines = root["data"]["lrclist"].array
        guard !lines.isEmpty else { return nil }     // 纯音乐/无词，不是故障
        return Self.assembleLRC(lines)
    }

    // MARK: - 工具

    /// 坑③：酷我歌词是结构化数组，`time` 是**秒**且可能带小数（"7.73"），
    /// 需自行拼成 `[mm:ss.xx]` 标准 LRC。
    /// 用厘秒做整数运算，避免 `59.996` 被格式化成 `60.00` 这种非法时间戳。
    static func assembleLRC(_ lines: [JSONBox]) -> String? {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for l in lines {
            let text = decodeEntities(l["lineLyric"].string) ?? ""
            let seconds = max(0, l["time"].double ?? 0)
            out.append(timeTag(seconds) + text)
        }
        let joined = out.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    static func timeTag(_ seconds: Double) -> String {
        let centis = Int((seconds * 100).rounded())
        let mm = centis / 6000
        let ss = (centis % 6000) / 100
        let cc = centis % 100
        return String(format: "[%02d:%02d.%02d]", mm, ss, cc)
    }

    /// `pub` / `releasedate` 形如 "2008-10-15"，取前 4 位作年份。
    static func year(fromDateString s: String?) -> String? {
        guard let s, s.count >= 4 else { return nil }
        let y = String(s.prefix(4))
        guard let n = Int(y), n > 1900, n < 2200 else { return nil }
        return y
    }

    /// 由短路径拼封面 URL，并把开头的尺寸段换成目标尺寸
    /// （`120/s4s0/93/xxx.jpg` → `500/s4s0/93/xxx.jpg`）。
    static func artworkURL(shortPath: String?, size: Int) -> URL? {
        guard var p = shortPath, !p.isEmpty else { return nil }
        // 有些字段给的是完整 URL，先剥成短路径
        if let r = p.range(of: "/star/albumcover/") { p = String(p[r.upperBound...]) }
        let n = size > 0 ? min(size, maxArtworkSize) : maxArtworkSize
        if let r = p.range(of: "^[0-9]{1,4}/", options: .regularExpression) {
            p = p.replacingCharacters(in: r, with: "\(n)/")
        }
        return URL(string: artworkPrefix + p)
    }

    /// 把已生成的封面 URL 里的尺寸段换掉（`/500/` → `/240/`）。
    static func resize(_ url: URL, to size: Int) -> URL {
        let s = url.absoluteString
        guard let r = s.range(of: "/albumcover/[0-9]{1,4}/", options: .regularExpression) else { return url }
        return URL(string: s.replacingCharacters(in: r, with: "/albumcover/\(size)/")) ?? url
    }

    /// 酷我的文本字段里混着 HTML 实体（`Jay&nbsp;Chou`），写进标签前要还原。
    static func decodeEntities(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        var t = s
        for (from, to) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                           ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

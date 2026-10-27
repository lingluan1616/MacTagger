//
//  QQSource.swift
//  MacTagger — QQ 音乐数据源
//
//  实测行为（主会话联网侦察，2026-09-01）：
//  · **官方搜索接口已被风控静默置空**（结构正常、HTTP 200、结果为空）
//    → 改用 smartbox 联想接口，实测正常返回 4 条含 mid 的候选
//  · smartbox 传 format=json 返回**裸 JSON**（不是 JSONP），code:0
//  · 详情走 musicu.fcg（POST JSON），实测拿到 魔杰座 / 2008-10-15 / 音轨 11 / 223 秒
//  · **歌词必须带 Referer**：带 → retcode:0 完整歌词；不带 → retcode:-1310
//  · 封面 800×800 是上限（1000×1000 返回 404）
//
//  AZ 轮（2026-09-06）把搜索改成**三级降级链**，次序由压测数据定，不由直觉定：
//
//    级 | 接口                                     | 实测有效返回 | 字段
//    ---|------------------------------------------|-------------|------------------------------
//    ①  | `client_search_cp`（官方全文搜索）        | 9/10 = 90%  | 全（专辑/mid/年/音轨/时长）
//    ②  | `smartbox_new.fcg`（联想）               | 10/10 = 100%| 只有 mid/曲名/歌手
//    ③  | `musicu.fcg` DoSearchForQQMusicDesktop   | **3/10 = 30%** | 全
//
//  桌面搜索（③）**没有**被提为首选：同一时刻同一台机器，它有约 70% 的概率返回
//  `req_1.code = 2001` + 空 list，而且把间隔拉到 8 s 也一样（2/6）——
//  不是速率问题，是那个模块本身在拒绝未登录调用。字段最全但十次里七次拿不到，
//  当首选就是把 QQ 的有效返回率从 100% 砍到 30%。它只做最后一级兜底。
//
//  首选从 smartbox 换成官方搜索的理由不只是「字段更全」：smartbox 的候选**没有时长**，
//  而 `MatchScorer` 对「查询有时长、候选没有」给的是 `unverifiedDurationScore`（0.5，不吃惩罚），
//  于是 smartbox 的薄候选会稳定压过如实报出时长的源 —— 薄字段不是「少点信息」，
//  是**主动污染跨源排序**。官方搜索一发就带回专辑/年份/音轨号/时长，连 `fetchDetail` 都能省。
//

import Foundation

public struct QQSource: MetadataSource {

    public let id = "qq"
    public let displayName = "QQ 音乐"
    public let capabilities: SourceCapabilities = [
        .searchTracks, .searchAlbums, .artwork, .lyrics, .translatedLyrics
    ]

    private let http: HTTPClient

    /// 本源当前生效的网络策略（含探针为演示临时改过的 timeout）。
    /// 探针要打印「改了什么」，界面无人调用。
    public static var currentPolicy: SourcePolicy {
        var p = QQTestHooks.shared.policyOverride ?? SourcePolicy.qq()
        if let t = QQTestHooks.shared.timeoutOverride { p.timeout = t }
        return p
    }

    public init() {
        // Referer 是歌词接口的硬性拦截条件，索性给所有请求都带上。
        // AU 轮改用 `.qq()`：timeout 25 s、minimumInterval 0.5 s，其它源不受影响。
        //
        // `gate` 是测试注入点（`QQTestHooks`），没开钩子时是一句 `guard` 的开销。
        // 它交给 HTTPClient 在**真正发起 I/O 的那一刻**调用，而不是在这里直接挂起 ——
        // 后者会绕开限速/重试/熔断，验的就不是要验的那套代码了。
        self.http = HTTPClient(sourceID: "qq",
                               policy: Self.currentPolicy,
                               gate: { try await QQTestHooks.shared.hang(timeout: $0) })
    }

    // MARK: - 搜索（三级降级链）

    /// 一次搜索走的是哪一级。写进 `QQSearchTelemetry`，供结果条悬停与数据源状态面板显示。
    public enum SearchPath: String, Sendable, CaseIterable {
        /// ⓪ 移动端极简版统一搜索 `musicu.fcg / DoSearchForQQMusicLite`（BD 轮新增）——
        ///    **新首选**：字段最全（含数字 songID）且实测 10/10 全通。详见 `searchViaLite`。
        case lite
        /// ① 官方全文搜索 `client_search_cp`（`new_json=1`）——次选：字段最全，实测 90%。
        case official
        /// ② 联想接口 `smartbox_new.fcg`——兜底：实测 100% 但只有 mid/曲名/歌手。
        case smartbox
        /// ③ 桌面端统一搜索 `musicu.fcg / music.search.SearchCgiService`——
        ///    最后一级：字段最全但实测只有 30% 不返回 `code 2001`。
        case desktop

        public var displayName: String {
            switch self {
            case .lite:     return "极简版搜索"
            case .official: return "官方搜索"
            case .smartbox: return "smartbox"
            case .desktop:  return "桌面搜索"
            }
        }
    }

    /// 三级降级链。**任何一级抛错都只淘汰该级**，链条继续往下走；
    /// 全部走完还没有候选才抛 `.emptyResult`，错误文案里带上每一级的败因。
    ///
    /// 两个例外必须原样抛出、绝不吞掉，否则上层的机制会失效：
    /// · `.circuitOpen`（熔断已开闸）——三级打的是同一个域名同一套限速器，
    ///   第一级被拒说明后两级也会被拒，继续往下只是白白多两次拒绝日志；
    /// · `CancellationError`（软截止到点/提前收工）——继续发请求正是软截止要消灭的行为。
    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        let term = Self.searchTerm(query)
        guard !term.isEmpty else { return [] }

        // 多要一些再按艺术家权重重排、最后才截到 limit：
        // 官方搜索把翻唱排在原版前面是**它的**相关度排序，我们改不了它，
        // 但可以不让翻唱把原版挤出 limit 之外（详见 `artistWeighted`）。
        let fetch = max(limit, Self.overFetch)

        var failures: [String] = []
        for path in Self.searchChain {
            do {
                let found = try await search(path: path, term: term, limit: fetch)
                if !found.isEmpty {
                    let ordered = Array(Self.artistWeighted(found, for: query).prefix(limit))
                    QQSearchTelemetry.shared.record(path: path, hits: ordered.count)
                    return ordered
                }
                failures.append("\(path.displayName) 0 条")
            } catch let e as SourceError {
                if case .circuitOpen = e {
                    QQSearchTelemetry.shared.recordEmpty(note: "熔断暂停中")
                    throw e
                }
                failures.append("\(path.displayName) \(SourceOutcome.shortReason(for: e))")
            } catch let q as RateLimitQueueTooLong {
                // 限速排队排不上（BD 轮）。**必须原样抛出，不能记成「这一级 0 条」**：
                // 限速是按**源**算的，第一级排不上，后面三级排的是同一条队，只会更排不上。
                // 吞掉它的后果实测过 —— 四级全被吞，最后汇报成
                // 「QQ 三级搜索都没给出候选」，用户看到的是「QQ 没这首歌」，
                // 而真相是我们自己压根没发出去。同 `.circuitOpen` 一个道理。
                QQSearchTelemetry.shared.recordEmpty(note: q.reason)
                throw q
            } catch {
                // 取消（软截止到点 / 已有高分候选提前收工）由 `HTTPClient` 统一归一成
                // `CancellationError`，但 URLSession 的原始形态也认一手，免得漏网。
                if HTTPClient.isCancellation(error) { throw CancellationError() }
                failures.append("\(path.displayName) \(SourceOutcome.shortReason(for: error))")
            }
        }

        let why = failures.joined(separator: "、")
        QQSearchTelemetry.shared.recordEmpty(note: why)
        throw SourceError.emptyResult("QQ 三级搜索都没给出候选（\(why)）")
    }

    /// 降级链的次序。**由压测数据定**（见文件头的表），不要凭直觉调。
    static let searchChain: [SearchPath] = [.lite, .official, .smartbox, .desktop]

    /// 每一级实际要多少条。比 `limit` 多要是为了给艺术家加权重排留出腾挪空间。
    static let overFetch = 20

    func search(path: SearchPath, term: String, limit: Int) async throws -> [TrackCandidate] {
        switch path {
        case .lite:     return try await searchViaLite(term: term, limit: limit)
        case .official: return try await searchViaOfficial(term: term, limit: limit)
        case .smartbox: return try await searchViaSmartbox(term: term, limit: limit)
        case .desktop:  return try await searchViaDesktop(term: term, limit: limit)
        }
    }

    // MARK: ⓪ 极简版统一搜索（musicu.fcg / DoSearchForQQMusicLite）

    /// **BD 轮新增的首选路径**，来自对 LDDC 的协议调研（见报告 §一.2）。
    ///
    /// 与已有的「桌面搜索」打的是同一个 `musicu.fcg`，差别全在 `comm` 块：
    /// 桌面搜索伪装的是 PC 客户端（`ct:19/cv:1859`），十次里七次被回 `code 2001`；
    /// 这一条伪装的是 **Android 极简版**（`ct:11` + `tmeAppID:"qqmusiclight"`）
    /// 并且先取一个**游客 session**（`music.getSession.session`，全程无 uin/guid/authst），
    /// 实测 10/10 全通，且字段最全 —— 尤其是**数字 `id`**，那是取翻译歌词的唯一钥匙。
    ///
    /// 实测（2026-09-11，本机）：`query="Lemon 米津玄師"` 一发返回 5 条，
    /// `id/mid/name/singer/album/interval` 齐全。
    func searchViaLite(term: String, limit: Int) async throws -> [TrackCandidate] {
        let node = try await QQMobileAPI.shared.request(
            http: http,
            method: "DoSearchForQQMusicLite",
            module: "music.search.SearchCgiService",
            param: ["query": term,
                    "search_type": 0,
                    "num_per_page": max(1, min(limit, 30)),
                    "page_num": 1,
                    "highlight": 0,
                    "grp": 1])

        let body = node["data"]["body"]
        // 极简版把歌曲挂在 `item_song`；万一哪天改回 `song.list` 也认。
        var list = body["item_song"].array
        if list.isEmpty { list = body["song"]["list"].array }
        return list.prefix(limit).compactMap { Self.candidate(fromRichSong: $0, sourceID: id) }
    }

    // MARK: ② smartbox（联想）

    /// 联想接口。**只吃干净的检索词**（AX 轮实测）：同一时刻同一台机器
    ///     key="稻香 周杰伦"       → 4 条
    ///     key="01 - 稻香 - 周杰伦" → 0 条（HTTP 200、code:0、结构完好，看着就像被风控）
    /// `searchTerm` 已经把文件名洗过一遍，所以这里通常不会空；真空了就交给下一级。
    ///
    /// 返回的候选**只有 mid / 曲名 / 歌手**，没有专辑、年份、时长 ——
    /// 详情要靠 `fetchDetail` 补一发。这是它被从首选降为兜底的直接原因。
    func searchViaSmartbox(term: String, limit: Int) async throws -> [TrackCandidate] {
        var comps = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        comps.queryItems = [
            .init(name: "key", value: term),
            .init(name: "format", value: "json")
        ]
        guard let url = comps.url else { throw SourceError.network("URL 构造失败") }

        let data = try await http.get(url)
        let root = JSONBox(try http.parseJSON(data))

        // 业务层校验：HTTP 200 不代表成功
        if let code = root["code"].int, code != 0 {
            throw SourceError.emptyResult("QQ smartbox 返回 code=\(code)")
        }

        return root["data"]["song"]["itemlist"].array.prefix(limit).compactMap { item -> TrackCandidate? in
            guard let mid = item["mid"].string else { return nil }
            var c = TrackCandidate(sourceID: id, nativeID: mid)
            c.title = item["name"].string
            c.artist = item["singer"].string
            return c
        }
    }

    // MARK: ③ 桌面端统一搜索（musicu.fcg）

    /// `music.search.SearchCgiService / DoSearchForQQMusicDesktop`，无需登录。
    ///
    /// 实测（AZ 轮，2026-09-06，同一台机器同一时段）：
    /// · `comm` 必须是 `{ct:19, cv:1859, uin:0, format:"json"}`。`ct:24/cv:0` 返回 code:0
    ///   但 list 恒空；多塞 `platform/needNewCode/g_tk` 反而稳定拿 `code 2001`。
    /// · 成功时 `req_1.data.body.song.list[]` 字段与官方搜索同构（mid / name /
    ///   singer[].name / album{mid,name} / index_album / index_cd / time_public / interval），
    ///   而且**吃得下脏文件名**："01 - 稻香 - 周杰伦" 返回 10 条。
    /// · 但十次里约七次返回 `req_1.code = 2001` + 空 list，间隔拉到 8 s 也一样（2/6）——
    ///   这不是速率问题，所以它只能当最后一级兜底，不能当首选。
    func searchViaDesktop(term: String, limit: Int) async throws -> [TrackCandidate] {
        let payload: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": 0, "format": "json"],
            "req_1": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "num_per_page": max(1, min(limit, 30)),
                    "page_num": 1,
                    "query": term,
                    "search_type": 0
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else {
            throw SourceError.network("URL 构造失败")
        }

        let data = try await http.post(url, body: body, contentType: "application/json")
        let root = JSONBox(try http.parseJSON(data))
        let node = root["req_1"]
        // 外层 code 与 req_1.code 是两码事：外层恒 0，真正的业务码在 req_1 里。
        if let code = node["code"].int, code != 0 {
            throw SourceError.emptyResult("QQ 桌面搜索返回 code=\(code)")
        }
        return node["data"]["body"]["song"]["list"].array.prefix(limit)
            .compactMap { Self.candidate(fromRichSong: $0, sourceID: id) }
    }

    // MARK: ① 官方全文搜索

    /// 官方全文搜索 `client_search_cp`（`new_json=1`）——**首选**。
    /// 字段实测：`data.song.list[]` 里有 mid / name / singer[].name / album.name /
    /// album.mid / interval（秒）/ index_album / index_cd / time_public。
    func searchViaOfficial(term: String, limit: Int) async throws -> [TrackCandidate] {
        var comps = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        comps.queryItems = [
            .init(name: "w", value: term),
            .init(name: "format", value: "json"),
            .init(name: "p", value: "1"),
            .init(name: "n", value: String(max(1, min(limit, 30)))),
            .init(name: "cr", value: "1"),
            .init(name: "new_json", value: "1")
        ]
        guard let url = comps.url else { throw SourceError.network("URL 构造失败") }

        let data = try await http.get(url)
        let root = JSONBox(try http.parseJSON(data))
        if let code = root["code"].int, code != 0 {
            throw SourceError.emptyResult("QQ 官方搜索返回 code=\(code)")
        }

        return root["data"]["song"]["list"].array.prefix(limit)
            .compactMap { Self.candidate(fromRichSong: $0, sourceID: id) }
    }

    /// 官方搜索与桌面搜索返回的歌曲对象**结构完全相同**，解析只写一份。
    /// 两处各抄一遍的代价不是重复代码，是「改了一处忘了另一处」——
    /// 而降级链里那一级平时根本跑不到，忘了也发现不了。
    static func candidate(fromRichSong s: JSONBox, sourceID: String) -> TrackCandidate? {
        guard let mid = s["mid"].string, !mid.isEmpty else { return nil }
        // 桌面搜索里 `title` 才是带修饰的完整曲名（"稻香 (Live)"），`name` 是去修饰的主名；
        // 官方搜索两者一致。取 `title` 优先 —— Live/Demo 这些修饰正是打分要用来区分版本的信号，
        // 丢掉它会让 Live 版和录音室版在标题项上打成平手。
        guard let name = s["title"].string ?? s["name"].string, !name.isEmpty else { return nil }
        var c = TrackCandidate(sourceID: sourceID, nativeID: mid)
        c.title = name
        // 数字主键。取带翻译的那份歌词（`GetPlayLyricInfo`）只认它，不认 mid。
        if let n = s["id"].int, n > 0 { c.numericID = String(n) }
        let singers = s["singer"].array.compactMap { $0["name"].string }
        if !singers.isEmpty {
            c.artist = singers.joined(separator: " / ")
            c.albumArtist = singers.first
        }
        if let a = s["album"]["name"].string, !a.isEmpty { c.album = a }
        if let m = s["album"]["mid"].string, !m.isEmpty { c.albumID = m }
        // 年份两个出处：歌曲自己的 time_public，其次专辑的。桌面搜索里前者常为空串。
        for pub in [s["time_public"].string, s["album"]["time_public"].string] {
            if let pub, pub.count >= 4 { c.year = String(pub.prefix(4)); break }
        }
        if let no = s["index_album"].int, no > 0 { c.trackNumber = String(no) }
        if let interval = s["interval"].double, interval > 0 { c.durationSeconds = interval }
        if let m = c.albumID { c.artworkURL = artworkURL(albumMid: m) }
        return c
    }

    // MARK: - 详情

    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard !candidate.nativeID.isEmpty else { return candidate }

        let payload: [String: Any] = [
            "songinfo": [
                "method": "get_song_detail_yqq",
                "module": "music.pf_song_detail_svr",
                "param": ["song_mid": candidate.nativeID]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return candidate }

        let data = try await http.post(url, body: body, contentType: "application/json")
        let root = JSONBox(try http.parseJSON(data))
        let info = root["songinfo"]
        if let code = info["code"].int, code != 0 { return candidate }

        let t = info["data"]["track_info"]
        guard t.exists else { return candidate }

        var c = candidate
        c.title = t["title"].string ?? c.title
        // smartbox 那一级的候选没有数字主键，详情这一发正好把它补上 ——
        // 补不上就只能拿老接口的无翻译歌词。
        if c.numericID == nil, let n = t["id"].int, n > 0 { c.numericID = String(n) }
        let singers = t["singer"].array.compactMap { $0["name"].string }
        if !singers.isEmpty {
            c.artist = singers.joined(separator: " / ")
            c.albumArtist = singers.first
        }
        c.album = t["album"]["name"].string ?? c.album
        c.albumID = t["album"]["mid"].string ?? c.albumID
        // time_public 形如 "2008-10-15"，取年
        if let pub = t["time_public"].string, pub.count >= 4 {
            c.year = String(pub.prefix(4))
        }
        if let idx = t["index_album"].int, idx > 0 { c.trackNumber = String(idx) }
        if let cd = t["index_cd"].int, cd > 0 { c.discNumber = String(cd) }
        if let interval = t["interval"].double, interval > 0 { c.durationSeconds = interval }
        if let albumMid = c.albumID { c.artworkURL = Self.artworkURL(albumMid: albumMid) }
        return c
    }

    // MARK: - 封面

    /// 800×800 是上限，1000×1000 实测 404。
    static func artworkURL(albumMid: String, size: Int = 800) -> URL? {
        let capped = min(size, 800)
        return URL(string: "https://y.gtimg.cn/music/photo_new/T002R\(capped)x\(capped)M000\(albumMid).jpg")
    }

    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        var albumMid = candidate.albumID
        if albumMid == nil {
            albumMid = (try? await fetchDetail(candidate))?.albumID
        }
        guard let mid = albumMid, let url = Self.artworkURL(albumMid: mid, size: preferredSize) else {
            return nil
        }
        do {
            let data = try await http.get(url)
            return data.isEmpty ? nil : data
        } catch SourceError.httpStatus(404) {
            return nil
        }
    }

    // MARK: - 歌词

    /// 取歌词。**先走移动端 `GetPlayLyricInfo`，拿不到才回落老接口。**
    ///
    /// 为什么要换（BD 轮，用户报「歌词总是没有翻译」）：
    /// 老接口 `fcg_query_lyric_new.fcg` 有 `trans` 字段但**恒为空串** ——
    /// 2026-09-11 实测 Lemon（mid `000akynZ2Rbro5`）：
    /// `retcode:0`、`lyric` 1263 字符、**`trans` 0 字符**。
    /// 翻译与罗马音只有 `music.musichallSong.PlayLyricInfo / GetPlayLyricInfo` 才发，
    /// 而它发的是 3DES+zlib 加密载荷（解密见 `QRCCrypto`）。
    ///
    /// 老接口保留为兜底：新接口要数字 `songID`，而 smartbox 那一级的候选只有 mid。
    public func fetchLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        if let rich = try? await fetchRichLyrics(candidate), !rich.isEmpty {
            return rich
        }
        return try await fetchLegacyLyrics(candidate)
    }

    /// `GetPlayLyricInfo`：一发同时拿回**逐字原词（QRC）+ 翻译 + 罗马音**。
    ///
    /// 三个载荷都是十六进制密文，`*_t` 时间戳为 0 表示该轨不存在（不必解密）。
    func fetchRichLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        // 数字 songID 是硬性要求。没有就说明候选来自只给 mid 的那一级，交给老接口。
        guard let songIDText = candidate.numericID, let songID = Int(songIDText) else { return nil }

        func b64(_ s: String?) -> String {
            Data((s ?? "").utf8).base64EncodedString()
        }
        let param: [String: Any] = [
            "songID": songID,
            "songName": b64(candidate.title),
            "singerName": b64(candidate.artist),
            "albumName": b64(candidate.album),
            "interval": Int(candidate.durationSeconds.rounded()),
            "crypt": 1,
            "ct": 19, "cv": 2111,
            "lrc_t": 0,
            "qrc": 1, "qrc_t": 0,
            "trans": 1, "trans_t": 0,
            "roma": 1, "roma_t": 0,
            "type": 0
        ]
        let node = try await QQMobileAPI.shared.request(
            http: http,
            method: "GetPlayLyricInfo",
            module: "music.musichallSong.PlayLyricInfo",
            param: param)

        let data = node["data"]
        var bundle = LyricsBundle(sourceID: id)

        // 原词：优先 QRC（逐字），退回普通 LRC。
        if let raw = Self.decrypted(data["lyric"].string, stamp: data["qrc_t"].int ?? data["lrc_t"].int) {
            let (tags, lines) = QRCParser.parse(QRCParser.lyricContent(raw) ?? raw)
            if lines.isEmpty {
                // `lrc_t` 那一路解出来就是普通 LRC，没有逐字结构。
                bundle.plain = QRCParser.cleanTranslation(raw) ?? raw
            } else {
                bundle.plain = VerbatimLyrics.toLRC(lines, tags: tags)
                bundle.wordByWord = VerbatimLyrics.toEnhancedLRC(lines, tags: tags)
            }
        }
        // 翻译：解密后是**裸 LRC**，没有 XML 包裹；没有译文的行写作 `//`，要滤掉。
        if let raw = Self.decrypted(data["trans"].string, stamp: data["trans_t"].int) {
            bundle.translated = QRCParser.cleanTranslation(QRCParser.lyricContent(raw) ?? raw)
        }
        // 罗马音：和原词一样是 QRC XML。
        if let raw = Self.decrypted(data["roma"].string, stamp: data["roma_t"].int) {
            let (_, lines) = QRCParser.parse(QRCParser.lyricContent(raw) ?? raw)
            bundle.romanized = VerbatimLyrics.toLRC(lines)
        }
        return bundle.isEmpty ? nil : bundle
    }

    /// 时间戳为 0 / 载荷为空 → 该轨不存在，直接跳过解密。
    static func decrypted(_ hex: String?, stamp: Int?) -> String? {
        guard let hex, !hex.isEmpty, (stamp ?? 0) != 0 else { return nil }
        return QRCCrypto.decrypt(hex: hex)
    }

    /// 老接口。只有原词，`trans` 实测恒空 —— 保留它纯粹是为了「新接口拿不到时至少有原文」。
    func fetchLegacyLyrics(_ candidate: TrackCandidate) async throws -> LyricsBundle? {
        guard !candidate.nativeID.isEmpty else { return nil }

        var comps = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        comps.queryItems = [
            .init(name: "songmid", value: candidate.nativeID),
            .init(name: "g_tk", value: "5381"),
            .init(name: "format", value: "json"),
            .init(name: "nobase64", value: "1")     // 不加会拿到 base64
        ]
        guard let url = comps.url else { return nil }

        let data = try await http.get(url)
        // format=json 时是裸 JSON；保险起见兼容 JSONP 包裹
        let parsed: Any
        if let plain = try? http.parseJSON(data) { parsed = plain }
        else { parsed = try http.parseJSONP(data) }
        let root = JSONBox(parsed)

        // -1310 = 缺 Referer 被拦。HTTPClient 已默认带 Referer，这里兜底提示。
        if let retcode = root["retcode"].int, retcode != 0 {
            if retcode == -1310 {
                throw SourceError.emptyResult("QQ 歌词被拦截（retcode:-1310，Referer 缺失）")
            }
            return nil
        }

        var bundle = LyricsBundle(sourceID: id)
        bundle.plain = root["lyric"].string
        bundle.translated = root["trans"].string
        return bundle.isEmpty ? nil : bundle
    }

    // MARK: - 查询构造

    /// 有明确标题就用「标题 艺术家」，否则退回文件名自由词。
    /// 注意：文件名含噪声，只作模糊检索词，绝不当精确曲名用。
    static func searchTerm(_ q: TrackQuery) -> String {
        var parts: [String] = []
        if let t = q.title, !t.isEmpty {
            parts.append(t)
            if let a = q.artist, !a.isEmpty { parts.append(a) }
        } else if let f = q.filename, !f.isEmpty {
            parts.append(cleanedFilename(f))
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 把整串文件名洗成 smartbox 吃得下的检索词。
    ///
    /// **这是「批量下 QQ 全部置空」的直接解药**（AX 轮实测）：smartbox 是联想接口，
    /// 只吃干净的词。同一时刻同一台机器实测 ——
    ///     "稻香 周杰伦"        → 4 条
    ///     "01 - 稻香 - 周杰伦" → 0 条（HTTP 200、code:0、结构完好，看着就像被风控）
    /// 而批量里的文件多半没有标题标签，查询正好退回整串文件名。
    ///
    /// 洗法：**全角符号归一** → 剥前导音轨号 → 分隔符换空格 → 压掉多余空白。
    /// 只给 QQ 用 —— 其余源都是全文搜索，脏文件名它们照样能命中，洗过反而丢信息。
    ///
    /// **BD 轮补的一步是「全角符号归一」**，来自对 LDDC 的只读调研
    /// （`unified_symbol`，见 `research/BD-…报告.md` §一.4）：LDDC 在做任何比对之前
    /// 先把全角括号/冒号/分隔符换成半角。我们原来漏了这一步，后果是
    /// **前导音轨号的正则和分隔符表对全角写法一概不认** ——
    /// `01．稻香－周杰伦` 里的 `．` 不在 `[.\-_)]` 里、`－`（U+FF0D）不在分隔符表里，
    /// 于是整串原样送进 smartbox，正是 AX 轮实测「脏词 0 条」的那一类。
    /// Windows 导出的曲库里全角写法很常见（原版 MusicTag 的用户就是从那边来的）。
    ///
    /// 归一表是**符号专用**的，刻意不用 `folding(.widthInsensitive)` 全串折 ——
    /// 那会把半角片假名折成全角，改的是**歌名内容**而不是标点，超出「洗检索词」的本分。
    static func cleanedFilename(_ name: String) -> String {
        var s = unifySymbols(name.trimmingCharacters(in: .whitespacesAndNewlines))
        // 前导音轨号：「01. 」「01 - 」「01_」「1-」「[01] 」「(01) 」「01、」「Track 01 」
        for pattern in ["^\\s*[\\[(]\\s*\\d{1,3}\\s*[\\])]\\s*",
                        "^\\s*(?i:track|trk)\\s*\\d{1,3}\\s*[.\\-_)、]?\\s*",
                        "^\\s*\\d{1,3}\\s*[.\\-_)、]\\s*"] {
            if let r = s.range(of: pattern, options: .regularExpression) {
                s = String(s[r.upperBound...])
                break
            }
        }
        for sep in [" - ", " – ", " — ", " _ ", "_", "-", "–", "—", "·", "・", "、", "|", "/", "~"] {
            s = s.replacingOccurrences(of: sep, with: " ")
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 全角符号 → 半角。**只动标点，不动文字**（汉字、假名、谚文一个都不碰）。
    /// 表按 LDDC `unified_symbol` 的覆盖面重写，另补了 `－～｜／` 这几个
    /// 在中文曲库文件名里最常见的全角分隔符。
    static func unifySymbols(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "（": out.append("(")
            case "）": out.append(")")
            case "［", "【", "〔": out.append("[")
            case "］", "】", "〕": out.append("]")
            case "｛": out.append("{")
            case "｝": out.append("}")
            case "：": out.append(":")
            case "；": out.append(";")
            case "，": out.append(",")
            case "．", "。": out.append(".")
            // 全角连字符/破折号。**日文长音符「ー」(U+30FC) 刻意不在此列** ——
            // 它是假名的一部分（「ラーメン」），换成 "-" 会把歌名改错。
            case "－", "―", "‐", "‑", "–", "—": out.append("-")
            case "＿": out.append("_")
            case "｜": out.append("|")
            case "／": out.append("/")
            case "＼": out.append("\\")
            case "～", "〜": out.append("~")
            case "＆": out.append("&")
            case "＇", "’", "‘": out.append("\'")
            case "＂", "“", "”": out.append("\"")
            case "\u{3000}": out.append(" ")            // 全角空格
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 艺术家过滤加权

    //
    //  为什么要在**适配器**里做这件事（AZ 轮）：
    //  QQ 的官方搜索把翻唱排在原版前面是**它的**相关度排序，我们改不了。实测原始次序：
    //      w="01 - 稻香 - 周杰伦" → ① 【昼夜钢琴】稻香/昼夜 ② 稻香/贝瓦儿歌 ③ 稻香/周杰伦《魔杰座》
    //  打分器最终会把原版顶上来，但**前提是原版进得了候选池**。`limit` 一小
    //  （复核表默认每源 8 条），翻唱就能把原版挤到 limit 之外 —— 那时打分器再准也没用。
    //
    //  所以这里多要 20 条，按「艺术家对不对得上」分档稳定重排，最后才截到 limit。
    //  **降权不是丢弃**：对不上的候选只是排到后面，一条都不删 ——
    //  用户的标签本来就可能是错的（艺术家填成了唱片公司、专辑名），
    //  丢掉正确候选比排错顺序严重得多。
    //

    /// 从查询里认出艺术家。两条路：查询自带（可靠），或从洗过的文件名里当「包含」判据用。
    enum ArtistHint {
        case explicit(String)
        case haystack(String)      // 已归一化的文件名
    }

    static func artistHint(_ q: TrackQuery) -> ArtistHint? {
        if let a = q.artist, !a.trimmingCharacters(in: .whitespaces).isEmpty {
            return .explicit(a)
        }
        if let f = q.filename, !f.isEmpty {
            let n = MatchScorer.normalize(cleanedFilename(f))
            if !n.isEmpty { return .haystack(n) }
        }
        // 最后一条：**脏标题**也当包含式判据用。
        //
        // 不是画蛇添足 —— `AutoMatchService.makeQuery` 只在**没有标题标签时**才填 `filename`，
        // 所以「标题标签被别的工具写成了整串文件名、艺术家却是空的」这一类文件
        // 走到这里时 `filename` 是 nil，前两条一条都不成立。实测正是这种查询让
        // QQ 把「【昼夜钢琴】稻香」「稻香 (童声版)」排在原版前面。
        //
        // 拿标题做包含判据的误报风险（标题里恰好含某个歌手名）只会**换个排序**，
        // 不会丢候选 —— 而且被提上来的那个歌手，本来就写在用户的查询串里。
        if let t = q.title, !t.isEmpty {
            let n = MatchScorer.normalize(cleanedFilename(t))
            if !n.isEmpty { return .haystack(n) }
        }
        return nil
    }

    /// 三档：2 = 对得上，1 = 无从判断，0 = 对不上。
    /// 「无从判断」独占一档而不是并进任一端：候选没给歌手时把它当翻唱压到最后，
    /// 会把 smartbox 那种薄候选整批扫地出门 —— 它们只是字段少，不是错。
    static func artistTier(_ candidateArtist: String?, hint: ArtistHint) -> Int {
        guard let ca = candidateArtist?.trimmingCharacters(in: .whitespaces), !ca.isEmpty else {
            return 1
        }
        switch hint {
        case .explicit(let qa):
            let s = MatchScorer.artistSimilarity(ca, qa)
            if s >= 0.6 { return 2 }
            if s >= 0.35 { return 1 }
            return 0
        case .haystack(let hay):
            // 候选歌手里任一成员出现在文件名中就算对得上。
            // 只认 ≥2 字的成员：单字（"孙"、"S"）在任何文件名里都能撞上，那不是证据。
            for t in MatchScorer.artistTokens(ca) where t.count >= 2 && hay.contains(t) {
                return 2
            }
            return 0
        }
    }

    /// 按艺术家档位稳定重排。同档内保持源自身的相关度次序（那仍然是有用的信号）。
    static func artistWeighted(_ candidates: [TrackCandidate],
                               for query: TrackQuery) -> [TrackCandidate] {
        guard candidates.count > 1, let hint = artistHint(query) else { return candidates }
        let tiers = candidates.map { artistTier($0.artist, hint: hint) }
        // 全都同档 = 这个信号在本次查询里没有区分度，原样返回，别白折腾。
        guard let lo = tiers.min(), let hi = tiers.max(), lo != hi else { return candidates }
        return candidates.enumerated()
            .sorted { a, b in
                tiers[a.offset] != tiers[b.offset]
                    ? tiers[a.offset] > tiers[b.offset]
                    : a.offset < b.offset
            }
            .map(\.element)
    }
}

// MARK: - 搜索路径遥测

//
//  用户看到 QQ 那一格是 0 条时，第一个该知道的是「它刚才走的是哪条路」——
//  官方搜索被风控、smartbox 送错词、桌面搜索返回 2001，这三件事该做的处置完全不同。
//  三级降级链是**进程内**的行为，`SourceOutcome` / `SourceHealth` 都拿不到，
//  所以这里留一份最小台账：最近一次走的哪一级、最近 N 次的有效返回率、每一级各命中几次。
//
//  刻意不做成 actor：`searchTracks` 在热路径上，为了记一个枚举值 await 一次不值得；
//  `NSLock` 保护三个标量已经足够，读取方（界面/探针）也不必是异步的。
//

// MARK: - 移动端极简版统一接口（musicu.fcg）

/// QQ 音乐 Android **极简版**（「QQ音乐简听」）的统一网关封装。
///
/// 存在的理由，一句话：**网页端接口给不出翻译，移动端给得出**（见 `QQSource.fetchLyrics`）。
/// 协议事实来自对 LDDC（GPL-3.0）的只读调研，代码为本工程重写；详见
/// `research/BD-LDDC调研与歌词翻译QQ iTunes修复报告.md` §一.1。
///
/// **全程不需要登录**：先打一发 `music.getSession.session` 拿游客 `uid/sid/userip`，
/// 之后把它们塞进 `comm` 即可。没有 uin、没有 guid、没有 authst、不碰用户 Cookie。
/// session 只取一次并缓存在进程内 —— 批量匹配时它是每首都要用的公共前置，
/// 每首都取一次就是白付一倍请求（而 QQ 有限速）。
actor QQMobileAPI {

    static let shared = QQMobileAPI()

    private var session: [String: Any]?
    /// 上次取 session 的时刻。超过这个岁数就重新取一发 —— 游客 sid 会过期，
    /// 过期后所有接口回 `code != 0`，而那看起来和「被风控」一模一样。
    private var sessionAt: Date?
    private static let sessionTTL: TimeInterval = 30 * 60

    private init() {}

    /// 固定的客户端指纹。伪装成 Android 极简版，这是能免登录的关键。
    private static let baseComm: [String: Any] = [
        "ct": 11,
        "cv": "1003006",
        "v": "1003006",
        "os_ver": "15",
        "phonetype": "24122RKC7C",
        "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
        "tmeAppID": "qqmusiclight",
        "nettype": "NETWORK_WIFI",
        "udid": "0",
    ]

    /// 移动端网关的请求头。**必须覆盖掉 `SourcePolicy.qq()` 的浏览器 UA**：
    /// 带着网页端的指纹去打移动端网关，正是被判 `code 2001` 的那条路。
    /// （策略里的 `Referer: https://y.qq.com/` 留着无妨，实测不影响这条网关。）
    private static let headers = [
        "User-Agent": "okhttp/3.14.9",
        "Cookie": "tmeLoginType=-1;",
    ]

    static let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!

    /// 发一发请求，返回 `request` 节点（已校验外层与内层 code）。
    func request(http: HTTPClient,
                 method: String,
                 module: String,
                 param: [String: Any]) async throws -> JSONBox {
        let comm = try await currentComm(http: http)
        let node = try await Self.post(http: http, comm: comm,
                                       method: method, module: module, param: param)
        return node
    }

    private func currentComm(http: HTTPClient) async throws -> [String: Any] {
        if let s = session, let at = sessionAt, Date().timeIntervalSince(at) < Self.sessionTTL {
            return s
        }
        var comm = Self.baseComm
        let node = try await Self.post(http: http, comm: comm,
                                       method: "GetSession",
                                       module: "music.getSession.session",
                                       param: ["caller": 0, "uid": "0", "vkey": 0])
        let s = node["data"]["session"]
        guard let uid = s["uid"].raw, let sid = s["sid"].string, let ip = s["userip"].string else {
            throw SourceError.emptyResult("QQ 极简版取游客 session 失败")
        }
        comm["uid"] = uid
        comm["sid"] = sid
        comm["userip"] = ip
        session = comm
        sessionAt = Date()
        return comm
    }

    /// 真正发包。**不放在 actor 隔离状态里**，避免取 session 的那一发把整个 actor 锁住
    /// —— 批量匹配下那会把 QQ 变成串行。
    private static func post(http: HTTPClient,
                             comm: [String: Any],
                             method: String,
                             module: String,
                             param: [String: Any]) async throws -> JSONBox {
        let payload: [String: Any] = [
            "comm": comm,
            "request": ["method": method, "module": module, "param": param],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await http.post(endpoint, body: body,
                                       contentType: "application/json",
                                       headers: headers)
        let root = JSONBox(try http.parseJSON(data))
        if let outer = root["code"].int, outer != 0 {
            throw SourceError.emptyResult("QQ 极简版 \(method) 外层 code=\(outer)")
        }
        let node = root["request"]
        if let inner = node["code"].int, inner != 0 {
            throw SourceError.emptyResult("QQ 极简版 \(method) 返回 code=\(inner)")
        }
        guard node.exists else {
            throw SourceError.emptyResult("QQ 极简版 \(method) 没有 request 节点")
        }
        return node
    }

    /// 测试用：把缓存的 session 丢掉，下一发重新取。
    func resetSession() { session = nil; sessionAt = nil }
}

public final class QQSearchTelemetry: @unchecked Sendable {

    public static let shared = QQSearchTelemetry()

    /// 有效返回率的滑动窗口长度。与 `SourceHealth.capacity`（20）取同一量级，
    /// 但略大一点：一批 50 首里 QQ 会被问 50 次，20 太短，看到的全是最后几首。
    public static let window = 30

    private let lock = NSLock()
    private var _lastPath: QQSource.SearchPath?
    private var _recent: [Bool] = []
    private var _pathHits: [String: Int] = [:]
    private var _lastNote: String?

    private init() {}

    /// 某一级给出了候选。
    public func record(path: QQSource.SearchPath, hits: Int) {
        lock.lock(); defer { lock.unlock() }
        _lastPath = path
        _pathHits[path.rawValue, default: 0] += 1
        _lastNote = nil
        push(true)
    }

    /// 三级都没给出候选（或熔断挡下）。**不改 `_lastPath`**：
    /// 「上一次走通的是哪条路」比「这一次全没走通」更有信息量，后者已经由有效返回率表达了。
    public func recordEmpty(note: String?) {
        lock.lock(); defer { lock.unlock() }
        _lastNote = note
        push(false)
    }

    private func push(_ ok: Bool) {
        _recent.append(ok)
        if _recent.count > Self.window { _recent.removeFirst(_recent.count - Self.window) }
    }

    /// 探针每轮开跑前清一次，免得上一轮的数落进这一轮的表。
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastPath = nil; _recent = []; _pathHits = [:]; _lastNote = nil
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(lastPath: _lastPath,
                        attempts: _recent.count,
                        effective: _recent.filter { $0 }.count,
                        pathHits: _pathHits,
                        lastNote: _lastNote)
    }

    public struct Snapshot: Sendable {
        public var lastPath: QQSource.SearchPath?
        public var attempts: Int
        public var effective: Int
        public var pathHits: [String: Int]
        public var lastNote: String?

        /// 没有样本时是 nil 而不是 0 —— 「没问过」和「问了全空」是两回事。
        public var effectiveRate: Double? {
            attempts > 0 ? Double(effective) / Double(attempts) : nil
        }

        /// 「官方搜索」；本次会话还没搜过时为「—」。
        public var pathText: String { lastPath?.displayName ?? "—" }

        /// 「有效返回 92%（23/25）」
        public var rateText: String? {
            guard let r = effectiveRate else { return nil }
            return String(format: "有效返回 %.0f%%（%d/%d）", r * 100, effective, attempts)
        }

        /// 各级命中分布：「官方搜索 23 · smartbox 2」。全零时 nil。
        public var pathBreakdown: String? {
            let parts = QQSource.searchChain.compactMap { p -> String? in
                guard let n = pathHits[p.rawValue], n > 0 else { return nil }
                return "\(p.displayName) \(n)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// 面板/悬停用的一行。
        public var line: String {
            var s = "当前搜索路径：\(pathText)"
            if let r = rateText { s += " · " + r }
            return s
        }
    }
}

// MARK: - 整碟曲目表

public extension QQSource {

    /// 实测（2026-09-03）：`musicu.fcg` 的 `music.musichallAlbum.AlbumSongList / GetAlbumSongList`
    /// 正常返回，`albumSonglist.data` 给 `totalNum` 与 `songList[].songInfo`
    /// （name / mid / interval 秒 / index_album 音轨号 / index_cd 碟序 / singer[] / album.time_public）。
    /// albumMid=000MkMni19ClKG（叶惠美）实测 totalNum=11、首曲《以父之名》interval=342。
    /// 顺带记一笔：`get_album_detail` 这个 method 返回 code:40000（无效），
    /// 专辑名与发行日直接从 songList 里的 `album` 子对象取即可，不必再发一次请求。
    ///
    /// `index_cd` 实测**从 0 起**，而 `fetchDetail` 用的 track_info 里是 1 起。
    /// 两种口径都可能遇到，所以这里按整表最小值归一化，绝不写死加一。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? {
        guard let albumMid = candidate.albumID, !albumMid.isEmpty else { return nil }

        let payload: [String: Any] = [
            "albumSonglist": [
                "method": "GetAlbumSongList",
                "module": "music.musichallAlbum.AlbumSongList",
                "param": ["albumMid": albumMid, "begin": 0, "num": 200, "order": 2]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        let data = try await http.post(url, body: body, contentType: "application/json")
        let root = JSONBox(try http.parseJSON(data))
        let node = root["albumSonglist"]
        if let code = node["code"].int, code != 0 {
            throw SourceError.emptyResult("QQ 专辑曲目表返回 code=\(code)")
        }
        let list = node["data"]["songList"].array
        guard !list.isEmpty else { throw SourceError.emptyResult("QQ 专辑曲目表为空") }

        var detail = AlbumDetail(sourceID: id, albumID: albumMid)
        detail.trackCount = node["data"]["totalNum"].int ?? list.count
        detail.artworkURL = Self.artworkURL(albumMid: albumMid)

        // 先扫一遍碟序基准（0 起还是 1 起）
        var minCD = Int.max
        for item in list {
            let cd = item["songInfo"]["index_cd"].int ?? 0
            minCD = min(minCD, cd)
        }
        if minCD == Int.max { minCD = 0 }

        var discs = Set<Int>()
        for item in list {
            let s = item["songInfo"]
            guard let name = s["name"].string ?? s["title"].string else { continue }
            let no = s["index_album"].int ?? 0
            guard no > 0 else { continue }
            let disc = (s["index_cd"].int ?? minCD) - minCD + 1
            discs.insert(disc)
            let singers = s["singer"].array.compactMap { $0["name"].string }
            detail.tracks.append(AlbumTrack(
                number: no,
                disc: max(1, disc),
                title: name,
                durationSeconds: s["interval"].double ?? 0,
                artist: singers.isEmpty ? nil : singers.joined(separator: " / "),
                nativeID: s["mid"].string))
            if detail.title == nil { detail.title = s["album"]["name"].string }
            if detail.artist == nil, let first = singers.first { detail.artist = first }
            if detail.year == nil, let pub = s["album"]["time_public"].string, pub.count >= 4 {
                detail.year = String(pub.prefix(4))
            }
        }
        detail.discCount = max(1, discs.count)
        if detail.trackCount == 0 { detail.trackCount = detail.tracks.count }
        detail.tracks.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        return detail
    }
}

// MARK: - 测试钩子（人为挂起）

//
//  为什么钩子要放在**适配器**而不是 HTTPClient：
//  熔断器要验的是「对方挂起 → 我们超时 → 三次开闸」这条链路，而挂起是**对方**的行为。
//  把它做在适配器的请求入口，语义上就等价于「QQ 的服务器收下了请求但迟迟不回」，
//  HTTPClient 那一层一个字都不用为测试改动 —— 被验证的代码保持原样，验证才算数。
//
//  语义严格对齐真实超时：钩子挂起 `min(挂起时长, timeout)` 秒；
//  若挂起时长 ≥ timeout，就在 timeout 时刻抛出与 URLSession 同形的超时错误
//  （`SourceOutcome.shortReason` 会把它精简成「超时」，熔断器也认它）。
//  演示时可用 `--hang-timeout` 把 QQ 的 timeout 临时调小，好在几秒内跑完三态，
//  而不必真等 3×25 s。
//

/// 进程内的测试开关。**生产路径永远读到 nil**（没有任何界面代码会去写它）。
public final class QQTestHooks: @unchecked Sendable {

    public static let shared = QQTestHooks()

    private let lock = NSLock()
    private var _hangSeconds: TimeInterval?
    private var _timeoutOverride: TimeInterval?
    private var _policyOverride: SourcePolicy?
    private var _hangCount = 0

    private init() {}

    /// 整份策略覆盖。**只有压测探针的 `--legacy` 对照组用它**：
    /// 要拿「改造前」的行为做前后对比，就得能把 timeout / 退避 / 限速原样还原回旧值，
    /// 否则「前」「后」两张表比的是两个二进制，说明不了是哪一处改动起的作用。
    public var policyOverride: SourcePolicy? {
        get { lock.lock(); defer { lock.unlock() }; return _policyOverride }
        set { lock.lock(); _policyOverride = newValue; lock.unlock() }
    }

    public var hangSeconds: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return _hangSeconds }
        set { lock.lock(); _hangSeconds = newValue; lock.unlock() }
    }
    public var timeoutOverride: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return _timeoutOverride }
        set { lock.lock(); _timeoutOverride = newValue; lock.unlock() }
    }
    /// 钩子一共拦下并挂起了几发请求。探针据此证明「熔断后不再有请求被真的发出去」。
    public var hangCount: Int {
        lock.lock(); defer { lock.unlock() }; return _hangCount
    }
    public func resetCount() { lock.lock(); _hangCount = 0; lock.unlock() }

    internal func bump() { lock.lock(); _hangCount += 1; lock.unlock() }
}

extension QQTestHooks {

    /// HTTPClient 在发起 I/O 的那一刻调它。没开钩子时直接返回。
    ///
    /// 语义严格对齐真实超时：挂起 `min(挂起时长, timeout)` 秒；挂起时长 ≥ timeout
    /// 就在 timeout 时刻抛出与 URLSession 同形的 `NSURLErrorTimedOut`，
    /// 于是 `HTTPClient.isTimeoutLike` 认它、退避重试作用于它、熔断计数也计它 ——
    /// 被验证的那段代码一个字都没有为测试改过。
    public func hang(timeout: TimeInterval) async throws {
        guard let hang = hangSeconds, hang > 0 else { return }
        bump()
        let waited = min(hang, timeout)
        try? await Task.sleep(nanoseconds: UInt64(waited * 1_000_000_000))
        if hang >= timeout {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "The request timed out.（模拟挂起 \(Int(hang))s ≥ timeout \(Int(timeout))s）"])
        }
    }
}

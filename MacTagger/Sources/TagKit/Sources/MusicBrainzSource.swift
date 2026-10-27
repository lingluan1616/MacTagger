//
//  MusicBrainzSource.swift
//  MacTagger — MusicBrainz Web Service v2 适配器
//
//  端点（公开只读，无需 key）：
//    录音搜索  https://musicbrainz.org/ws/2/recording?query={lucene}&fmt=json&limit={n}
//    版本搜索  https://musicbrainz.org/ws/2/release?query={lucene}&fmt=json&limit={n}
//    版本详情  https://musicbrainz.org/ws/2/release/{mbid}?fmt=json&inc=release-groups+labels+artist-credits+recordings
//
//  必须使用 `SourcePolicy.musicBrainz`（限速 1.1s / 重试 4 次 / 合规 UA）：
//  实测瞬时 503 率约 50%，不重试必然失败。
//
//  实测结论（本文件依赖，改动前请先复测）：
//  1. 年份必须优先取 `release-group.first-release-date`，而不是 `release.date`。
//     后者是**该版本**的发行日——同一张专辑的巴西再版会写成 2019，而首发是 2014。
//     取错就会把再版年份写进用户的标签。
//  2. **搜索结果里的 `release-group` 不含 `first-release-date`**（只有 id/title/primary-type）。
//     该字段只在 release 详情查询（`inc=release-groups`）里才有。
//     所以搜索阶段只能先用 `release.date` 兜底，`fetchDetail` 再纠正。这是本源必须走二段式的原因。
//  3. 搜索结果的曲目数组键名是 **`media[].track`（单数）**，
//     而详情查询里是 **`media[].tracks`（复数）**。两个都要认，否则音轨号恒为空。
//  4. 大量录音条目**根本没有 `releases` 键**（独立录音），也有很多没有 `length`。
//     解析必须容忍缺字段，不能因为少一个键就丢掉整条候选。
//  5. 厂牌 `label-info[].label.name` 与条码 `barcode` 只在详情里有，搜索结果没有。
//

import Foundation

// MARK: - 权威版本信息（TrackCandidate 装不下的 MusicBrainz 独有字段）

public struct MusicBrainzReleaseInfo: Sendable, Equatable {
    public var releaseMBID: String
    public var releaseGroupMBID: String?
    public var title: String?
    /// 该版本的发行日（可能是再版）
    public var date: String?
    /// 作品首发日 —— 写标签年份应该用这个
    public var firstReleaseDate: String?
    public var country: String?
    public var barcode: String?
    public var asin: String?
    public var labels: [String] = []
    public var catalogNumbers: [String] = []
    public var format: String?
    public var trackCount: Int?
    public var status: String?
    /// Cover Art Archive 是否收录了正面封面
    public var hasFrontCoverArt: Bool = false

    public init(releaseMBID: String) { self.releaseMBID = releaseMBID }

    /// 首发年份优先，退回版本发行年。
    public var preferredYear: String? {
        if let f = firstReleaseDate, f.count >= 4 { return String(f.prefix(4)) }
        if let d = date, d.count >= 4 { return String(d.prefix(4)) }
        return nil
    }
}

// MARK: - 源

public struct MusicBrainzSource: MetadataSource {

    public let id = "musicbrainz"
    public let displayName = "MusicBrainz"
    /// 无歌词、无封面（封面走 CoverArtArchiveSource），但提供权威元数据。
    public let capabilities: SourceCapabilities = [.searchTracks, .searchAlbums, .authoritative]

    private let http: HTTPClient
    private static let base = "https://musicbrainz.org/ws/2/"

    public init() {
        // 必须用内置的 musicBrainz 策略：1.1s 限速 + 4 次退避重试 + 合规 UA
        self.http = HTTPClient(sourceID: "musicbrainz", policy: .musicBrainz)
    }

    // MARK: 搜索

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        let lucene = Self.recordingQuery(query)
        guard !lucene.isEmpty else { return [] }

        var comps = URLComponents(string: Self.base + "recording")!
        comps.queryItems = [
            .init(name: "query", value: lucene),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: String(max(1, min(limit, 100))))
        ]
        guard let url = comps.url else { throw SourceError.network("URL 拼装失败") }

        let json = JSONBox(try await http.getJSON(url))
        if json["error"].exists {
            throw SourceError.emptyResult(json["error"].string ?? "MusicBrainz 返回 error")
        }
        return json["recordings"].array.compactMap { Self.candidate(fromRecording: $0) }
    }

    /// 专辑（release）搜索。协议无此口，作为具体类型的附加能力提供。
    public func searchReleases(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        var terms: [String] = []
        if let album = query.album, !album.isEmpty { terms.append("release:\(Self.quote(album))") }
        if let artist = query.artist, !artist.isEmpty { terms.append("artist:\(Self.quote(artist))") }
        let lucene = terms.isEmpty ? Self.quote(query.searchTerm) : terms.joined(separator: " AND ")
        guard !lucene.isEmpty else { return [] }

        var comps = URLComponents(string: Self.base + "release")!
        comps.queryItems = [
            .init(name: "query", value: lucene),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: String(max(1, min(limit, 100))))
        ]
        guard let url = comps.url else { throw SourceError.network("URL 拼装失败") }
        let json = JSONBox(try await http.getJSON(url))
        return json["releases"].array.compactMap { box -> TrackCandidate? in
            guard let mbid = box["id"].string else { return nil }
            var c = TrackCandidate(sourceID: "musicbrainz", nativeID: mbid, albumID: mbid)
            c.title = box["title"].string
            c.album = box["title"].string
            c.artist = Self.joinArtistCredit(box["artist-credit"])
            c.albumArtist = c.artist
            if let d = box["date"].string, d.count >= 4 { c.year = String(d.prefix(4)) }
            if let n = box["track-count"].int { c.trackNumber = "/\(n)" }
            return c
        }
    }

    // MARK: 详情

    /// 二段式：用 release 详情把搜索阶段拿不到的字段补齐，
    /// 并把年份从「该版本发行年」纠正为「作品首发年」。
    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard let releaseMBID = candidate.albumID, !releaseMBID.isEmpty else { return candidate }

        var comps = URLComponents(string: Self.base + "release/" + releaseMBID)!
        comps.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "release-groups+labels+artist-credits+recordings")
        ]
        guard let url = comps.url else { return candidate }

        let json = JSONBox(try await http.getJSON(url))
        guard json["id"].exists else { return candidate }

        var c = candidate
        let info = Self.releaseInfo(from: json, mbid: releaseMBID)

        // ① 年份纠正：首发年优先
        if let y = info.preferredYear { c.year = y }
        c.album = json["title"].string ?? c.album
        if let aa = Self.joinArtistCredit(json["artist-credit"]) { c.albumArtist = aa }

        // ② 在各碟里定位本录音，拿到准确的音轨号/碟号
        let media = json["media"].array
        for (idx, medium) in media.enumerated() {
            let tracks = medium["tracks"].array.isEmpty ? medium["track"].array : medium["tracks"].array
            guard let hit = tracks.first(where: { t in
                t["recording"]["id"].string == candidate.nativeID || t["id"].string == candidate.nativeID
            }) else { continue }

            let num = hit["number"].string ?? hit["position"].string
            if let num {
                if let total = medium["track-count"].int, total > 0 {
                    c.trackNumber = "\(num)/\(total)"
                } else {
                    c.trackNumber = num
                }
            }
            let discPos = medium["position"].int ?? (idx + 1)
            c.discNumber = media.count > 1 ? "\(discPos)/\(media.count)" : "\(discPos)"

            if c.title == nil { c.title = hit["title"].string }
            if c.durationSeconds <= 0, let ms = hit["length"].double { c.durationSeconds = ms / 1000.0 }
            break
        }
        return c
    }

    /// 拉取 MusicBrainz 独有的权威字段（MBID / 厂牌 / 条码 / 首发日 / CAA 是否有封面）。
    /// 这些字段 `TrackCandidate` 装不下，故单独提供。
    public func fetchReleaseInfo(releaseMBID: String) async throws -> MusicBrainzReleaseInfo {
        guard !releaseMBID.isEmpty else { throw SourceError.emptyResult("缺少 release MBID") }
        var comps = URLComponents(string: Self.base + "release/" + releaseMBID)!
        comps.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "release-groups+labels+artist-credits+recordings")
        ]
        guard let url = comps.url else { throw SourceError.network("URL 拼装失败") }
        let json = JSONBox(try await http.getJSON(url))
        guard json["id"].exists else {
            throw SourceError.emptyResult("release \(releaseMBID) 无详情")
        }
        return Self.releaseInfo(from: json, mbid: releaseMBID)
    }

    // MARK: - Lucene 查询构造

    static func recordingQuery(_ q: TrackQuery) -> String {
        var terms: [String] = []
        // 只有明确的标题才配当 recording: 精确短语。
        // 文件名是含噪声的自由文本（常夹带音轨号、艺术家、格式后缀），
        // 若也套上 recording:"…" 会退化成精确短语匹配，实测必然 0 命中。
        if let t = q.title, !t.isEmpty { terms.append("recording:\(quote(t))") }
        if let a = q.artist, !a.isEmpty { terms.append("artist:\(quote(a))") }
        if let b = q.album, !b.isEmpty { terms.append("release:\(quote(b))") }
        // 无结构化标题但有文件名：作为自由词参与分词检索，不加字段前缀、不加引号。
        if q.title?.isEmpty != false, let f = q.filename, !f.isEmpty {
            terms.append(escapeLucene(f))
        }
        if terms.isEmpty {
            // 自由词不能当精确短语搜：实测 query="Taylor Swift Blank Space" 命中 0 条，
            // 去掉引号后命中 249745 条。这里只转义 Lucene 特殊字符，保持分词检索。
            let raw = q.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "" : escapeLucene(raw)
        }
        return terms.joined(separator: " AND ")
    }

    /// Lucene 短语引用。转义反斜杠与引号即可，其余特殊字符在引号内失效。
    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// 自由词检索用：只转义会破坏语法的 Lucene 保留字符，不加短语引号，
    /// 让服务端按分词匹配（加引号会退化成精确短语，几乎必然 0 命中）。
    static func escapeLucene(_ s: String) -> String {
        var out = ""
        let reserved: Set<Character> = ["+", "-", "&", "|", "!", "(", ")", "{", "}",
                                        "[", "]", "^", "\"", "~", "*", "?", ":", "\\", "/"]
        for ch in s {
            if reserved.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - 映射

    static func joinArtistCredit(_ box: JSONBox) -> String? {
        let parts = box.array
        guard !parts.isEmpty else { return nil }
        // artist-credit 是数组，需要按 joinphrase 拼回 "A feat. B"
        var out = ""
        for p in parts {
            let name = p["name"].string ?? p["artist"]["name"].string ?? ""
            out += name
            out += p["joinphrase"].string ?? ""
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 recording 搜索结果构造候选。
    /// 一条录音可能挂在很多个 release 上，这里挑一个「首选版本」代表它：
    /// Official 状态优先 → 发行日最早优先 → 带曲目信息的优先。
    /// 需要看全部版本时用 `releaseCandidates(fromRecording:)`。
    static func candidate(fromRecording box: JSONBox) -> TrackCandidate? {
        guard let mbid = box["id"].string else { return nil }

        let releases = box["releases"].array
        let picked = preferredRelease(releases)

        var c = TrackCandidate(sourceID: "musicbrainz",
                               nativeID: mbid,
                               albumID: picked?["id"].string)
        c.title = box["title"].string
        c.artist = joinArtistCredit(box["artist-credit"])
        if let ms = box["length"].double { c.durationSeconds = ms / 1000.0 }

        guard let rel = picked else { return c }

        c.album = rel["title"].string
        c.albumArtist = joinArtistCredit(rel["artist-credit"]) ?? c.artist

        // 搜索阶段拿不到 first-release-date，只能先用版本发行日兜底；
        // fetchDetail 会把它纠正为首发年。
        if let d = rel["date"].string, d.count >= 4 { c.year = String(d.prefix(4)) }

        // 搜索结果里是 media[].track（单数），详情里才是 tracks（复数）
        let media = rel["media"].array
        if let m = media.first {
            let tracks = m["track"].array.isEmpty ? m["tracks"].array : m["track"].array
            if let num = tracks.first?["number"].string ?? tracks.first?["position"].string {
                if let total = m["track-count"].int, total > 0 {
                    c.trackNumber = "\(num)/\(total)"
                } else {
                    c.trackNumber = num
                }
            }
            if let pos = m["position"].int { c.discNumber = String(pos) }
            if c.durationSeconds <= 0, let ms = tracks.first?["length"].double {
                c.durationSeconds = ms / 1000.0
            }
        }
        return c
    }

    /// 把一条录音的**每个** release 都展开成候选（供「换一个版本」用）。
    public func releaseCandidates(fromRecordingJSON raw: Any) -> [TrackCandidate] {
        let box = JSONBox(raw)
        guard let mbid = box["id"].string else { return [] }
        return box["releases"].array.compactMap { rel in
            var c = TrackCandidate(sourceID: "musicbrainz", nativeID: mbid, albumID: rel["id"].string)
            c.title = box["title"].string
            c.artist = Self.joinArtistCredit(box["artist-credit"])
            c.album = rel["title"].string
            c.albumArtist = Self.joinArtistCredit(rel["artist-credit"]) ?? c.artist
            if let d = rel["date"].string, d.count >= 4 { c.year = String(d.prefix(4)) }
            if let ms = box["length"].double { c.durationSeconds = ms / 1000.0 }
            return c
        }
    }

    static func preferredRelease(_ releases: [JSONBox]) -> JSONBox? {
        guard !releases.isEmpty else { return nil }
        func rank(_ r: JSONBox) -> (Int, String) {
            let official = (r["status"].string == "Official") ? 0 : 1
            // 无日期的排最后
            let date = r["date"].string ?? "9999"
            return (official, date)
        }
        return releases.min { a, b in
            let (ra, da) = rank(a), (rb, db) = rank(b)
            if ra != rb { return ra < rb }
            return da < db
        }
    }

    static func releaseInfo(from json: JSONBox, mbid: String) -> MusicBrainzReleaseInfo {
        var info = MusicBrainzReleaseInfo(releaseMBID: mbid)
        info.title = json["title"].string
        info.date = json["date"].string
        info.country = json["country"].string
        info.barcode = json["barcode"].string
        info.asin = json["asin"].string
        info.status = json["status"].string
        info.releaseGroupMBID = json["release-group"]["id"].string
        info.firstReleaseDate = json["release-group"]["first-release-date"].string
        info.hasFrontCoverArt = (json["cover-art-archive"]["front"].raw as? Bool) ?? false

        for li in json["label-info"].array {
            if let name = li["label"]["name"].string { info.labels.append(name) }
            if let cat = li["catalog-number"].string { info.catalogNumbers.append(cat) }
        }
        let media = json["media"].array
        info.format = media.first?["format"].string
        info.trackCount = media.reduce(0) { $0 + ($1["track-count"].int ?? 0) }
        if info.trackCount == 0 { info.trackCount = nil }
        return info
    }
}

// MARK: - 整碟曲目表

public extension MusicBrainzSource {

    /// 实测（2026-09-03）：`release/{mbid}?fmt=json&inc=recordings+artist-credits+release-groups`
    /// 返回完整的 `media[].tracks[]`（number / title / length 毫秒），多碟发行按 medium 分开。
    /// 魔杰座 4444ffbf… 实测：CD 11 首 + DVD 2 首，两碟都在。
    ///
    /// 年份仍走「首发年优先」——`release.date` 是**该版本**的发行日，
    /// 再版会写成十几年后，写进用户标签就是错的（见 fetchDetail 的注释）。
    ///
    /// 注意：多碟发行里常混着 DVD/蓝光这类**不含音频**的 medium。
    /// 它们的曲目会污染「曲目数」这一维的打分（11 首的专辑被算成 13 首），
    /// 因此这里把非音频 medium 剔掉，只保留 CD/Digital Media/Vinyl 之类。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? {
        guard let mbid = candidate.albumID, !mbid.isEmpty else { return nil }

        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/" + mbid)!
        comps.queryItems = [
            .init(name: "fmt", value: "json"),
            .init(name: "inc", value: "recordings+artist-credits+release-groups")
        ]
        guard let url = comps.url else { return nil }

        let json = JSONBox(try await http.getJSON(url))
        guard json["id"].exists else { return nil }

        var detail = AlbumDetail(sourceID: id, albumID: mbid)
        detail.title = json["title"].string
        detail.artist = Self.joinArtistCredit(json["artist-credit"])
        let info = Self.releaseInfo(from: json, mbid: mbid)
        detail.year = info.preferredYear

        let audioMedia = json["media"].array.filter { m in
            guard let f = m["format"].string?.lowercased() else { return true }   // 未标注格式的照收
            return !Self.nonAudioFormats.contains { f.contains($0) }
        }
        let media = audioMedia.isEmpty ? json["media"].array : audioMedia

        for (idx, medium) in media.enumerated() {
            let disc = medium["position"].int ?? (idx + 1)
            // 搜索结果是 media[].track（单数），详情是 media[].tracks（复数），两个都得认
            let list = medium["tracks"].array.isEmpty ? medium["track"].array : medium["tracks"].array
            for t in list {
                let numStr = t["number"].string ?? t["position"].string
                guard let n = numStr.flatMap({ Int($0.prefix(while: { $0.isNumber })) }), n > 0,
                      let title = t["title"].string ?? t["recording"]["title"].string else { continue }
                let ms = t["length"].double ?? t["recording"]["length"].double ?? 0
                detail.tracks.append(AlbumTrack(
                    number: n,
                    disc: max(1, disc),
                    title: title,
                    durationSeconds: ms / 1000.0,
                    artist: Self.joinArtistCredit(t["artist-credit"])
                        ?? Self.joinArtistCredit(t["recording"]["artist-credit"]),
                    nativeID: t["recording"]["id"].string ?? t["id"].string))
            }
        }
        detail.discCount = max(1, media.count)
        detail.trackCount = media.reduce(0) { $0 + ($1["track-count"].int ?? 0) }
        if detail.trackCount == 0 { detail.trackCount = detail.tracks.count }
        detail.tracks.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        return detail
    }

    /// 不含音频的 medium 格式关键词（小写比对）。
    static var nonAudioFormats: [String] { ["dvd", "blu-ray", "bluray", "vcd", "vhs", "video"] }
}

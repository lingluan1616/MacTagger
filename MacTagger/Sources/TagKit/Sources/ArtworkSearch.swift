//
//  ArtworkSearch.swift
//  MacTagger — 「从网络搜索封面」的数据层（对应原版 FormPictureSearch）
//
//  与自动匹配的降级链不同，这里是**并发广搜**：用户要的是尽量多的候选摆在一屏里挑，
//  而不是「第一个能用的源就收工」。因此：
//  1. 所有支持 `.artwork` 的源同时发起搜索，任一源抛错**只淘汰该源**，
//     其余结果照常返回；全失败才给出汇总错误串。
//  2. 每个候选记住它来自哪个源与该源能给的最大边长（iTunes 1200 / 网易云原图 /
//     酷狗 1000 / QQ 800 / 酷我 500）——界面据此显示「预计尺寸」，
//     用户就知道点哪张能拿到大图。
//  3. 缩略图与正式下载分两条路：缩略图优先直接拉候选自带的小图 URL（各源搜索结果里
//     的 artworkURL 本来就是 100~500 的小图，不占正式接口的限速配额），
//     只有拿不到 URL 的源（QQ 靠 albumMid 二段式取图）才回落到 `fetchArtwork`。
//

import Foundation

// MARK: - 候选

public struct ArtworkCandidate: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var sourceID: String
    public var sourceName: String
    public var title: String?
    public var artist: String?
    public var album: String?
    /// 搜索结果里自带的图片 URL（多为小图）。QQ 这类二段式取图的源为 nil。
    public var previewURL: URL?
    /// 该源能提供的最大边长；0 表示「原图，尺寸未知」（网易云）。
    public var maxEdge: Int
    /// 打分（0…1），由 `MatchScorer` 填。
    public var score: Double
    /// 下载时要交回给源的原始候选。
    public var track: TrackCandidate

    public init(sourceID: String, sourceName: String, track: TrackCandidate, maxEdge: Int) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.track = track
        self.maxEdge = maxEdge
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.previewURL = track.artworkURL
        self.score = track.matchScore
    }

    public var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "未知曲目" : t
    }

    public var displayArtist: String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? "未知艺术家" : a
    }

    public var displayAlbum: String {
        let a = (album ?? "").trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? "—" : a
    }

    /// 「预计 1200×1200」/「原图」。
    public var sizeLabel: String {
        maxEdge > 0 ? "\(maxEdge)×\(maxEdge)" : "原图"
    }

    /// 同一张封面常被多个源重复命中，用「专辑 + 艺术家 + 源」去重。
    var dedupeKey: String {
        [sourceID,
         (album ?? "").lowercased(),
         (artist ?? "").lowercased(),
         previewURL?.absoluteString ?? ""].joined(separator: "\u{1}")
    }
}

// MARK: - 结果

public struct ArtworkSearchOutcome: Sendable {
    public var candidates: [ArtworkCandidate]
    public var attempts: [SourceAttempt]

    public init(candidates: [ArtworkCandidate] = [], attempts: [SourceAttempt] = []) {
        self.candidates = candidates
        self.attempts = attempts
    }

    public var isEmpty: Bool { candidates.isEmpty }

    /// 只有真·失败的源才汇总；搜到 0 条不算故障。
    public var errorSummary: String? {
        let failures = attempts.filter { $0.outcome == .failed }
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.sourceID)：\($0.message ?? "未知错误")" }
            .joined(separator: "；")
    }

    public var succeededSourceIDs: [String] {
        attempts.compactMap { a in
            if case .succeeded = a.outcome { return a.sourceID }
            return nil
        }
    }

    /// 逐源结果条。由 `attempts` 派生，不另存一份 —— 两处记账必然漂移。
    /// 封面搜索窗顶部的 chips 读它：搜出 0 张时用户才分得清「这源没这张碟」和「这源挂了」。
    public var sourceOutcomes: [SourceOutcome] {
        SourceOutcome.from(attempts).sortedByPriority()
    }
}

// MARK: - 服务

public enum ArtworkSearchService {

    /// 各源封面最大边长。0 = 原图（网易云不做尺寸截断，param 省略即原图）。
    /// 数值来自 C / I 报告的实测，改动前请先复测。
    public static let maxEdgeBySource: [String: Int] = [
        "itunes": 1200,
        "netease": 0,
        "kugou": 1000,
        "qq": 800,
        "kuwo": 500,
        "coverartarchive": 1200,
    ]

    public static func maxEdge(for sourceID: String) -> Int {
        maxEdgeBySource[sourceID] ?? 1000
    }

    /// 注册表里所有具备封面能力**且能自己搜索**的源。
    /// CoverArtArchive 只会按 MBID 取图、不参与搜索，自然被这里滤掉。
    public static var artworkSourceIDs: [String] {
        let reg = SourceRegistry.shared
        return reg.recommendedOrder.filter {
            guard let caps = reg.source(id: $0)?.capabilities else { return false }
            return caps.contains(.artwork) && caps.contains(.searchTracks)
        }
    }

    // MARK: 搜索

    /// 并发查所有指定源。任一源失败只淘汰该源。
    ///
    /// - Parameters:
    ///   - query: 标题 / 艺术家 / 专辑
    ///   - sourceIDs: nil = 全部具备封面能力的源
    ///   - limitPerSource: 每个源要几条
    ///   - chineseVariant: 候选文案（曲名 / 艺术家 / 专辑）的字形归一策略。
    ///     默认取进程级设置 —— 封面网格每张图下面印的就是这三行，
    ///     库是简体而卡片写着繁体，用户没法一眼确认「这就是我那张碟」。
    public static func search(_ query: TrackQuery,
                              sourceIDs: [String]? = nil,
                              limitPerSource: Int = 8,
                              chineseVariant: ChineseVariantPolicy = ChineseVariant.onlineDefault)
        async -> ArtworkSearchOutcome {
        let ids = (sourceIDs ?? artworkSourceIDs).filter { artworkSourceIDs.contains($0) }
        guard !query.isEmpty else { return ArtworkSearchOutcome() }
        guard !ids.isEmpty else { return ArtworkSearchOutcome() }

        let registry = SourceRegistry.shared
        var attempts: [SourceAttempt] = []
        var collected: [ArtworkCandidate] = []

        await withTaskGroup(of: (SourceAttempt, [ArtworkCandidate]).self) { group in
            for id in ids {
                guard let source = registry.source(id: id) else {
                    attempts.append(SourceAttempt(sourceID: id, outcome: .skipped, message: "未注册"))
                    continue
                }
                let limit = limitPerSource
                let q = query
                let policy = chineseVariant
                group.addTask {
                    let started = Date()
                    do {
                        // ★ 封面搜索的**唯一**简繁归一入口，同样排在打分之前：
                        // 网格默认按分排序，繁体候选的字面相似度偏低会被挤到第二屏，
                        // 而它往往正是港台版那张正确的碟。
                        let found = try await source.searchTracks(q, limit: limit)
                            .map { $0.converted(to: policy) }
                        let elapsed = Date().timeIntervalSince(started)
                        // 没有任何图源信息的候选直接丢掉：点开也拿不到图。
                        let ranked = MatchScorer.rank(found, for: q)
                        let usable = ranked.filter { $0.artworkURL != nil || $0.albumID != nil }
                        let edge = maxEdge(for: source.id)
                        let mapped = usable.map {
                            ArtworkCandidate(sourceID: source.id,
                                             sourceName: source.displayName,
                                             track: $0,
                                             maxEdge: edge)
                        }
                        if mapped.isEmpty {
                            return (SourceAttempt(sourceID: source.id, outcome: .empty,
                                                  message: found.isEmpty ? nil : "候选无可用图源",
                                                  elapsed: elapsed), [])
                        }
                        return (SourceAttempt(sourceID: source.id,
                                              outcome: .succeeded(mapped.count),
                                              elapsed: elapsed), mapped)
                    } catch {
                        // 关键：单源故障只记账，绝不把整批带下水。
                        return (SourceAttempt(sourceID: source.id, outcome: .failed,
                                              message: error.localizedDescription,
                                              elapsed: Date().timeIntervalSince(started)), [])
                    }
                }
            }

            for await (attempt, list) in group {
                attempts.append(attempt)
                collected.append(contentsOf: list)
            }
        }

        // 去重 + 排序：先按打分，其次让能给大图的源靠前。
        var seen = Set<String>()
        var unique: [ArtworkCandidate] = []
        for c in collected where seen.insert(c.dedupeKey).inserted {
            unique.append(c)
        }
        unique.sort { a, b in
            if abs(a.score - b.score) > 0.001 { return a.score > b.score }
            let ae = a.maxEdge == 0 ? 3000 : a.maxEdge      // 原图当最大
            let be = b.maxEdge == 0 ? 3000 : b.maxEdge
            if ae != be { return ae > be }
            return a.sourceID < b.sourceID
        }
        attempts.sort { $0.sourceID < $1.sourceID }
        return ArtworkSearchOutcome(candidates: unique, attempts: attempts)
    }

    // MARK: 下载

    /// 下载正式大图。`preferredSize` 传 nil 表示「按该源能给的最大尺寸」。
    public static func download(_ candidate: ArtworkCandidate,
                                preferredSize: Int? = nil) async throws -> Data {
        guard let source = SourceRegistry.shared.source(id: candidate.sourceID) else {
            throw SourceError.unsupported
        }
        let want = preferredSize ?? (candidate.maxEdge > 0 ? candidate.maxEdge : 0)
        guard let data = try await source.fetchArtwork(candidate.track, preferredSize: want),
              !data.isEmpty else {
            throw SourceError.emptyResult("\(candidate.sourceName) 没有返回封面数据")
        }
        return data
    }

    /// 网格缩略图。优先直接拉候选自带的小图 URL，拿不到才走源的正式接口。
    public static func thumbnail(_ candidate: ArtworkCandidate, size: Int = 300) async throws -> Data {
        if let url = candidate.previewURL {
            if let data = try? await rawGet(url), data.count > 512 { return data }
        }
        guard let source = SourceRegistry.shared.source(id: candidate.sourceID) else {
            throw SourceError.unsupported
        }
        guard let data = try await source.fetchArtwork(candidate.track, preferredSize: size),
              !data.isEmpty else {
            throw SourceError.emptyResult("缩略图为空")
        }
        return data
    }

    /// 裸 GET：图片 CDN 不是 API，不必占用各源的限速配额。
    static func rawGet(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(SourcePolicy.browserUA, forHTTPHeaderField: "User-Agent")
        // 网易云图床偶尔发 http://，ATS 会拦，统一升到 https。
        if url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if let secure = c.url { request.url = secure }
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.network("非 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.httpStatus(http.statusCode)
        }
        return data
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()
}

//
//  ITunesSource.swift
//  MacTagger — iTunes Search API 适配器
//
//  端点（公开只读接口，无需 key、无需登录）：
//    搜索  https://itunes.apple.com/search?term={q}&media=music&entity=song&limit={n}&country={cc}
//    详情  https://itunes.apple.com/lookup?id={trackId}&country={cc}
//    整碟  https://itunes.apple.com/lookup?id={collectionId}&entity=song&country={cc}
//
//  实测结论（本文件依赖，改动前请先复测）：
//  1. `artworkUrl100` 形如 `.../100x100bb.jpg`，把尺寸段替换成 `1200x1200bb`
//     即得 1200×1200 高清封面（HEAD 200 / 约 387KB）。搜索结果里没有任何
//     高清封面字段，只能靠这个 URL 提权拿到，务必保留。
//  2. `collectionArtistName` 在大量单曲结果里缺席，必须回落 `artistName`，
//     否则专辑艺术家会写空。
//  3. `country` 决定曲库与语种：同一首歌在 CN 与 US 曲库里的专辑名、
//     流派名（"国语流行" vs "Mandopop"）都不同。
//  4. 无歌词能力。iTunes Search API 不返回任何歌词字段。
//  5. **`country=CN` 整个商店已经空了**（2026-09-05 curl 实测）：
//         search?term=Taylor+Swift+Blank+Space&country=CN → HTTP 200 / resultCount 0
//         search?term=周杰伦+稻香&country=CN               → HTTP 200 / resultCount 0
//         同样两个词 country=HK / US → 正常返回。
//     不是被限流也不是参数写错 —— HTTP 层完全正常，只是业务层一条不给。
//     所以 HTTP 状态码看不出任何异常，健康台账也会把它画成绿灯。
//     对策见下面的「地区回退链」：首选地区 0 条时依次换 HK → US 再试，
//     并把「CN 0 → HK 命中」这条轨迹补记进 `SourceHealth`（`HTTPClient` 只记 HTTP 层，
//     「200 但业务层为空」按它的注释约定由各源自己补记）。
//

import Foundation

public struct ITunesSource: MetadataSource {

    // MARK: 地区

    /// 原版支持的 16 个地区代码。值为 iTunes Store 的 ISO 3166-1 alpha-2 代码。
    public enum Region: String, CaseIterable, Sendable {
        case unitedStates = "US"
        case china        = "CN"
        case hongKong     = "HK"
        case taiwan       = "TW"
        case japan        = "JP"
        case korea        = "KR"
        case unitedKingdom = "GB"     // 界面上写 UK，iTunes 只认 GB
        case russia       = "RU"
        case germany      = "DE"
        case france       = "FR"
        case spain        = "ES"
        case thailand     = "TH"
        case malaysia     = "MY"
        case singapore    = "SG"
        case australia    = "AU"
        case brazil       = "BR"

        public var localizedName: String {
            switch self {
            case .unitedStates: return "美国"
            case .china:        return "中国大陆"
            case .hongKong:     return "中国香港"
            case .taiwan:       return "中国台湾"
            case .japan:        return "日本"
            case .korea:        return "韩国"
            case .unitedKingdom: return "英国"
            case .russia:       return "俄罗斯"
            case .germany:      return "德国"
            case .france:       return "法国"
            case .spain:        return "西班牙"
            case .thailand:     return "泰国"
            case .malaysia:     return "马来西亚"
            case .singapore:    return "新加坡"
            case .australia:    return "澳大利亚"
            case .brazil:       return "巴西"
            }
        }

        /// 容错：界面/配置里可能存的是 "UK"、小写、或带空格。
        public static func parse(_ raw: String) -> Region {
            let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if key == "UK" { return .unitedKingdom }
            return Region(rawValue: key) ?? .china
        }

        /// 「自动（按曲名语言）」这一档在配置里存的哨兵值。**不是**一个真实的商店代码。
        public static let automatic = "AUTO"

        public static func isAutomatic(_ raw: String) -> Bool {
            raw.trimmingCharacters(in: .whitespaces).uppercased() == automatic
        }
    }

    // MARK: 按曲名语言选区

    /// 从查询文字里判断**应该优先问哪个商店**。判不出返回 nil。
    ///
    /// 为什么必须有它（BD 轮，用户库是日本游戏 OST）：
    /// 「あの夏へ」「彼ノ夢」这类曲名在 CN/HK/US 三区**本来就是 0 条**，
    /// 而我们的回退链恰好只有这三区 —— 于是每首日文曲目都要白白烧掉三发请求
    /// （3 × 3.1 s 的限速排队），最后还是 0 条。先问 JP 是一发就命中的事。
    ///
    /// 判据只用**文字系统**，不猜语种：假名 → JP，谚文 → KR。
    /// 纯汉字判不出（中日共用），返回 nil 走用户所选地区 —— 宁可少判，不可判错。
    public static func scriptPreferredRegion(for text: String) -> String? {
        var hasKana = false
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x309F,        // 平假名
                 0x30A0...0x30FF,        // 片假名
                 0x31F0...0x31FF,        // 片假名音标扩展
                 0xFF66...0xFF9D:        // 半角片假名
                hasKana = true
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                return "KR"              // 谚文
            default: break
            }
        }
        if hasKana { return "JP" }
        // 日本国字（中文里不用）。命中一个就足以判定是日文曲名。
        for ch in text where Self.japaneseOnlyKanji.contains(ch) { return "JP" }
        return nil
    }

    /// 日本国字（和製漢字）小表。只收常出现在曲名/专辑名里的那些。
    /// 只收**中文里不用**的和製漢字，宁缺毋滥 —— 收进一个中日通用字（比如「杉」「咲」）
    /// 就会把华语专辑名误判成日文，把 JP 排到链首白付一发。
    static let japaneseOnlyKanji: Set<Character> = [
        "働", "込", "峠", "畑", "辻", "枠", "匂", "凪", "栃", "麿", "丼", "榊", "匁", "裃",
    ]

    // MARK: 身份

    public let id = "itunes"
    public let displayName = "iTunes Store"
    public let capabilities: SourceCapabilities = [.searchTracks, .searchAlbums, .artwork]

    /// 曲库地区，可配置，默认中国大陆。
    public let region: Region

    /// 首选地区搜出 0 条时，依次改用这些地区再试一遍。
    ///
    /// 默认 `["HK", "US"]`：港区曲库与大陆的华语内容最接近（专辑名同为繁/简中文、
    /// 流派名是中文），拿不到再退美区（全球曲库最全，代价是元数据变英文）。
    /// 传空数组即关掉回退，保持「用户选哪个地区就只看哪个地区」的老行为。
    public let fallbackCountries: [String]

    /// `fallbackCountries` 的默认值。
    public static let defaultFallbackCountries: [String] = ["HK", "US"]

    /// 从「用户选的地区」生成完整的尝试链：**所选地区 → HK → US，去重**。
    ///
    /// 去重是必须的：选了港区时链条不能是 `HK → HK → US`（白付一发重复请求，
    /// 而 iTunes 是 1 秒 1 次的限速，批量匹配时这就是成倍的等待）；
    /// 选了美区时链条应当是 `US → HK`，而不是把 US 再排一次。
    public static func regionChain(preferring raw: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for code in [Region.parse(raw).rawValue] + defaultFallbackCountries {
            let k = code.trimmingCharacters(in: .whitespaces).uppercased()
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(k)
        }
        return out
    }

    /// 「自动（按曲名语言）」是否生效。
    ///
    /// 自动档下**不把用户所选地区排进链里**（他没选）：链条就是
    /// 「曲名语言判出来的区（若有）→ HK → US」。刻意跳过 CN ——
    /// 中区商店实测整个是空的，把它排进去只是每首白付一发限速排队。
    public let automaticRegion: Bool

    /// 供注册处使用：按所选地区建一个配好回退链的实例。
    /// 传 `"AUTO"` 得到自动档实例。
    public static func configured(country raw: String) -> ITunesSource {
        if Region.isAutomatic(raw) {
            return ITunesSource(region: .hongKong,
                                fallbackCountries: ["HK", "US"],
                                automaticRegion: true)
        }
        let chain = regionChain(preferring: raw)
        return ITunesSource(region: Region.parse(raw),
                            fallbackCountries: Array(chain.dropFirst()))
    }

    private let http: HTTPClient

    /// Apple 建议 ≈20 次/分钟。
    ///
    /// **BD 轮把 1.0 s 改成 3.1 s**：1.0 s 是 60 次/分钟，正好超三倍，
    /// 批量匹配几秒内就撞限流；而 iTunes 限流回的是 **403**（不是 429），
    /// 老代码把它当普通 HTTP 失败判死，用户看到的就是「iTunes 一直失败」。
    /// 详见 `SourcePolicy.itunes()`。
    public static let policy = SourcePolicy.itunes()

    /// **测试注入点**：压测要用同一个二进制跑「改造前 / 改造后」两组对照，
    /// 而 `policy` 是 `static let`。生产路径这个属性恒为 nil（界面无人写它）。
    public nonisolated(unsafe) static var policyOverride: SourcePolicy?

    /// 当前真正生效的策略。
    public static var effectivePolicy: SourcePolicy { policyOverride ?? policy }

    /// 改造前的策略，只给压测对照组用：1.0 s 一发（= 60 次/分钟，超 Apple 建议三倍），
    /// 且 403 **不**被当成限流（走 `default:` 直接判死，既不退避也不熔断）。
    public static let legacyPolicy = SourcePolicy(
        minimumInterval: 1.0,
        maxRetries: 2,
        initialBackoff: 0.6,
        defaultHeaders: ["User-Agent": SourcePolicy.browserUA,
                         "Accept": "application/json"],
        timeout: 15)

    public init(region: Region = .china,
                fallbackCountries: [String] = ITunesSource.defaultFallbackCountries,
                automaticRegion: Bool = false) {
        self.region = region
        self.fallbackCountries = fallbackCountries
        self.automaticRegion = automaticRegion
        self.http = HTTPClient(sourceID: "itunes", policy: Self.effectivePolicy)
    }

    public init(countryCode: String,
                fallbackCountries: [String] = ITunesSource.defaultFallbackCountries) {
        self.init(region: Region.parse(countryCode), fallbackCountries: fallbackCountries)
    }

    // MARK: 地区回退链

    /// 一次「首选地区没结果 → 换地区重试」的完整轨迹。
    ///
    /// 存在的理由与 `SourceOutcome` 同源：`resultCount:0` 与「源挂了」在 HTTP 层长得一模一样，
    /// 不把过程记下来，用户只会看到 iTunes 那一格是 0，永远查不出是整个 CN 商店空了。
    public struct RegionFallbackTrace: Sendable, Equatable {

        /// 链条上的一环：在某个地区试了一次，拿到几条（或因何失败）。
        public struct Step: Sendable, Equatable {
            public var region: String
            public var count: Int
            /// 该地区的请求本身失败时的精简原因；成功但 0 条时为 nil。
            public var failed: String?

            public init(region: String, count: Int, failed: String? = nil) {
                self.region = region; self.count = count; self.failed = failed
            }

            public var text: String {
                if let failed { return "\(region) ✘ \(failed)" }
                return "\(region) \(count)"
            }
        }

        /// 哪个动作触发的（「搜索单曲」「搜索专辑」「取详情」「取整碟曲目」）。
        public var operation: String
        /// 用户配置的首选地区。
        public var requested: String
        /// 实际按顺序试过的地区。
        public var steps: [Step]
        /// 最终命中的地区；全链都空时为 nil。
        public var hit: String?
        public var at: Date

        public init(operation: String, requested: String, steps: [Step],
                    hit: String?, at: Date = Date()) {
            self.operation = operation; self.requested = requested
            self.steps = steps; self.hit = hit; self.at = at
        }

        /// 试过不止一个地区才叫「发生了回退」。
        public var didFallback: Bool { steps.count > 1 }

        /// 轨迹行：`CN 0 → HK 5`
        public var path: String { steps.map(\.text).joined(separator: " → ") }

        /// 一句话结论：`CN 0 → HK 命中 5 条` / `CN 0 → HK 0 → US 0（全链无结果）`
        public var note: String {
            guard let hit else {
                return steps.map(\.text).joined(separator: " → ") + "（全链无结果）"
            }
            guard didFallback else { return "\(hit) 命中 \(steps.last?.count ?? 0) 条" }
            let head = steps.dropLast().map(\.text).joined(separator: " → ")
            return "\(head) → \(hit) 命中 \(steps.last?.count ?? 0) 条"
        }
    }

    /// 最近一次地区回退轨迹（任意 iTunes 实例共享）。
    public static var lastRegionFallback: RegionFallbackTrace? { ITunesRegionLog.shared.last }

    /// 最近 20 条轨迹，新的在前。probe 与状态面板用它把「CN 一直是空的」讲清楚。
    public static var regionFallbackHistory: [RegionFallbackTrace] { ITunesRegionLog.shared.history }

    /// 首选地区当前被解析成了哪个地区（回退成功后粘住，10 分钟后重新试首选）。
    public var resolvedRegionCode: String {
        ITunesRegionLog.shared.resolvedRegion(for: region.rawValue) ?? region.rawValue
    }

    public static func resetRegionFallbackLog() { ITunesRegionLog.shared.reset() }

    /// 把地区回退轨迹补进一条结果条的 `detail`，让「iTunes 5」这枚 chip 悬停时
    /// 能说清这 5 条其实是港区给的。没发生回退时原样返回。
    public static func annotate(_ outcome: SourceOutcome) -> SourceOutcome {
        guard outcome.sourceID == "itunes",
              let trace = lastRegionFallback, trace.didFallback else { return outcome }
        var out = outcome
        let line = "地区回退：\(trace.note)"
        out.detail = [outcome.detail, line].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return out
    }

    /// 本次要按顺序尝试的地区列表。
    ///
    /// 已解析出的可用地区排在最前面，是为了**省掉每次都白付一发首选地区的空请求** ——
    /// iTunes 限速 1 秒 1 次，批量匹配 3000 首时那就是白等 50 分钟。
    /// - Parameter hint: 本次查询的文字（曲名 + 艺术家）。用来把 JP/KR 提到链首。
    func regionChain(hint: String? = nil) -> [String] {
        var chain: [String] = []
        var seen = Set<String>()
        func push(_ raw: String) {
            let k = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !k.isEmpty, seen.insert(k).inserted else { return }
            chain.append(k)
        }
        // ① 曲名语言判出来的区排最前。日文曲名先问 JP 是一发命中的事，
        //    而 CN/HK/US 三区对它本来就是 0（见 `scriptPreferredRegion`）。
        if let hint, let scripted = Self.scriptPreferredRegion(for: hint) { push(scripted) }
        // ② 上一轮已解析出的可用地区。省掉每次都白付一发首选地区的空请求。
        if let resolved = ITunesRegionLog.shared.resolvedRegion(for: regionLogKey) {
            push(resolved)
        }
        // ③ 用户所选地区。自动档下没有「所选」，跳过。
        if !automaticRegion { push(region.rawValue) }
        for c in fallbackCountries { push(c) }
        return chain
    }

    /// 健康台账里给这个实例用的键。自动档单独一格，免得把「用户选了 CN」
    /// 和「自动档回退到 HK」记成同一件事。
    var regionLogKey: String { automaticRegion ? Region.automatic : region.rawValue }

    /// 沿地区回退链跑同一个请求，直到某个地区给出非空结果。
    ///
    /// - 全链都返回「成功但 0 条」→ 返回空数组（这是**真的没这首歌**，不是故障）。
    /// - 全链都抛错 → 把最后一个错误抛出去（**不能**吞成 0 条，否则源挂了会被伪装成没搜到）。
    func fetchWithRegionFallback<T>(_ operation: String,
                                    hint: String? = nil,
                                    make: (String) -> URL?,
                                    parse: (JSONBox) -> [T]) async throws -> [T] {
        let chain = regionChain(hint: hint)
        var steps: [RegionFallbackTrace.Step] = []
        var lastError: Error?
        var hit: String?
        var out: [T] = []
        let started = Date()

        for code in chain {
            guard let url = make(code) else { continue }
            do {
                let items = parse(JSONBox(try await http.getJSON(url)))
                steps.append(.init(region: code, count: items.count))
                if !items.isEmpty { hit = code; out = items; break }
            } catch let q as RateLimitQueueTooLong {
                // 限速排队排不上（BD 轮）：整条回退链排的是**同一条队**，
                // 这一区排不上，后面两区只会排得更靠后。原样抛出，不能记成「这一区 0 条」——
                // 记成 0 条会让「CN 0 → HK 排不上」在界面上长成「三区都没这首歌」。
                throw q
            } catch {
                steps.append(.init(region: code, count: 0,
                                   failed: SourceOutcome.shortReason(for: error)))
                lastError = error
            }
        }

        // 一个地区都没成功过 → 这是网络/接口故障，必须让调用方看见
        if hit == nil, !steps.isEmpty, steps.allSatisfy({ $0.failed != nil }), let lastError {
            ITunesRegionLog.shared.record(
                RegionFallbackTrace(operation: operation, requested: regionLogKey,
                                    steps: steps, hit: nil),
                elapsed: Date().timeIntervalSince(started))
            throw lastError
        }

        ITunesRegionLog.shared.record(
            RegionFallbackTrace(operation: operation, requested: regionLogKey,
                                steps: steps, hit: hit),
            elapsed: Date().timeIntervalSince(started))
        return out
    }

    // MARK: 搜索

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        let term = query.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let n = String(max(1, min(limit, 200)))
        let hint = Self.languageHint(query)

        // ★ 整碟去重（BD 轮）。iTunes 现在是 3.1 s 一发（Apple 建议 ≈20 次/分钟），
        //   一张 12 首的专辑逐首去搜就是 12 发、37 秒纯排队。
        //   改成：同一张专辑在这一批里**只搜一次**，第二个文件来的时候用 `lookup`
        //   把整碟曲目表一次拉回来，之后的文件全部本地对齐、零请求。
        //   合计 2 发管一整张碟。详见 `ITunesAlbumCache`。
        let albumKey = Self.albumKey(query)
        if let albumKey, let cached = await ITunesAlbumCache.shared.tracks(for: albumKey) {
            let local = Self.matchLocally(cached, query: query, limit: limit)
            if !local.isEmpty { return local }
        }
        if let albumKey,
           let collectionID = await ITunesAlbumCache.shared.pendingCollectionID(for: albumKey) {
            // 这张碟已经被同批的上一个文件搜到过：改拉整碟，一发换全碟。
            if let tracks = try? await fetchAlbumTracks(collectionID: collectionID), !tracks.isEmpty {
                await ITunesAlbumCache.shared.store(albumKey, tracks: tracks)
                let local = Self.matchLocally(tracks, query: query, limit: limit)
                if !local.isEmpty { return local }
            }
        }

        // iTunes 无结果时是 resultCount:0 + 空数组，不是错误 —— 交给回退链换地区再试。
        let found = try await fetchWithRegionFallback("搜索单曲", hint: hint, make: { code in
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [
                .init(name: "term", value: term),
                .init(name: "media", value: "music"),
                .init(name: "entity", value: "song"),
                .init(name: "limit", value: n),
                .init(name: "country", value: code)
            ]
            return comps.url
        }, parse: { json in
            json["results"].array.compactMap { Self.candidate(from: $0) }
        })

        // 记下「这张碟叫什么 collectionId」——**不发额外请求**。
        // 同一张碟的下一个文件到来时才用它换整碟曲目表（见上面那一段）。
        if let albumKey, let cid = Self.dominantCollectionID(found) {
            await ITunesAlbumCache.shared.noteCollectionID(albumKey, cid)
        }
        return found
    }

    /// 搜索/回退链要用的语言提示：曲名 + 艺术家 + 专辑名。
    static func languageHint(_ q: TrackQuery) -> String {
        [q.title, q.artist, q.album, q.filename].compactMap { $0 }.joined(separator: " ")
    }

    /// 整碟去重的键：（专辑艺术家 ?? 艺术家）+ 专辑名，都归一化。
    /// 专辑名为空 → 返回 nil（单曲不参与整碟去重）。
    static func albumKey(_ q: TrackQuery) -> String? {
        guard let album = q.album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !album.isEmpty else { return nil }
        let artist = (q.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizeKey(artist) + "\u{241F}" + normalizeKey(album)
    }

    static func normalizeKey(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 一批候选里出现次数最多的 collectionId。搜「稻香 周杰伦」时前几条多半同属《魔杰座》。
    static func dominantCollectionID(_ list: [TrackCandidate]) -> String? {
        var tally: [String: Int] = [:]
        for c in list.prefix(5) { if let a = c.albumID { tally[a, default: 0] += 1 } }
        return tally.max { $0.value < $1.value }?.key
    }

    /// 在已缓存的整碟曲目里本地挑出最像这次查询的几条。**零网络请求。**
    static func matchLocally(_ tracks: [TrackCandidate],
                             query: TrackQuery, limit: Int) -> [TrackCandidate] {
        let ranked = MatchScorer.rank(tracks, for: query)
        return Array(ranked.prefix(max(1, limit)))
    }

    /// 专辑搜索（entity=album）。协议没有专辑搜索口，作为具体类型的附加能力提供。
    public func searchAlbums(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        var term = [query.album, query.artist].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if term.isEmpty { term = query.searchTerm }
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let fixedTerm = term
        let n = String(max(1, min(limit, 200)))

        let hint = Self.languageHint(query)
        return try await fetchWithRegionFallback("搜索专辑", hint: hint, make: { code in
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [
                .init(name: "term", value: fixedTerm),
                .init(name: "media", value: "music"),
                .init(name: "entity", value: "album"),
                .init(name: "limit", value: n),
                .init(name: "country", value: code)
            ]
            return comps.url
        }, parse: { json in
            json["results"].array.compactMap { Self.candidate(from: $0) }
        })
    }

    // MARK: 详情

    public func fetchDetail(_ candidate: TrackCandidate) async throws -> TrackCandidate {
        guard !candidate.nativeID.isEmpty else { return candidate }
        let id = candidate.nativeID

        // 详情也要走回退链：候选是港区搜来的，拿它的 trackId 去 CN 商店 lookup 同样是 0 条。
        let fresh = try await fetchWithRegionFallback("取详情", make: { code in
            var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
            comps.queryItems = [
                .init(name: "id", value: id),
                .init(name: "country", value: code)
            ]
            return comps.url
        }, parse: { json in
            json["results"].array.compactMap { Self.candidate(from: $0) }
        }).first

        guard let fresh else { return candidate }
        // 保留原 UUID 与打分，其余字段以详情为准（详情缺的仍用搜索结果兜底）
        var merged = candidate
        merged.title       = fresh.title       ?? merged.title
        merged.artist      = fresh.artist      ?? merged.artist
        merged.album       = fresh.album       ?? merged.album
        merged.albumArtist = fresh.albumArtist ?? merged.albumArtist
        merged.year        = fresh.year        ?? merged.year
        merged.trackNumber = fresh.trackNumber ?? merged.trackNumber
        merged.discNumber  = fresh.discNumber  ?? merged.discNumber
        merged.genre       = fresh.genre       ?? merged.genre
        merged.albumID     = fresh.albumID     ?? merged.albumID
        if fresh.durationSeconds > 0 { merged.durationSeconds = fresh.durationSeconds }
        merged.artworkURL  = fresh.artworkURL  ?? merged.artworkURL
        return merged
    }

    /// 按 collectionId 拉整碟曲目（原版「按专辑填充」用得到）。
    public func fetchAlbumTracks(collectionID: String, limit: Int = 200) async throws -> [TrackCandidate] {
        guard !collectionID.isEmpty else { return [] }
        let n = String(max(1, min(limit, 200)))
        return try await fetchWithRegionFallback("取整碟曲目", make: { code in
            var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
            comps.queryItems = [
                .init(name: "id", value: collectionID),
                .init(name: "entity", value: "song"),
                .init(name: "limit", value: n),
                .init(name: "country", value: code)
            ]
            return comps.url
        }, parse: { json in
            // results[0] 是 collection 本身，其后才是 track
            json["results"].array
                .filter { $0["wrapperType"].string == "track" }
                .compactMap { Self.candidate(from: $0) }
                .sorted { lhs, rhs in
                    let ld = Self.leadingInt(lhs.discNumber)
                    let rd = Self.leadingInt(rhs.discNumber)
                    if ld != rd { return ld < rd }
                    return Self.leadingInt(lhs.trackNumber) < Self.leadingInt(rhs.trackNumber)
                }
        })
    }

    // MARK: 封面

    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        guard let base = candidate.artworkURL else { return nil }
        let target = Self.upgradeArtworkURL(base, to: preferredSize)
        do {
            return try await http.get(target)
        } catch {
            // 少数专辑没有超大尺寸，退回原始 URL 再试一次
            guard target != base else { throw error }
            return try? await http.get(base)
        }
    }

    /// 把 `.../100x100bb.jpg` 提权为 `.../1200x1200bb.jpg`。
    /// 实测：`100x100bb` → `1200x1200bb` 返回 HTTP 200、约 387KB 的 1200×1200 JPEG。
    /// 尺寸段的数字是任意的（500/600/1200 都可用），故用正则替换而不是死字符串。
    public static func upgradeArtworkURL(_ url: URL, to size: Int) -> URL {
        let clamped = max(30, min(size <= 0 ? 1200 : size, 3000))
        let s = url.absoluteString
        // 匹配路径末段的 `<w>x<h>bb`（后面可能跟 -60、.jpg、.png 等）
        guard let re = try? NSRegularExpression(pattern: "/\\d+x\\d+bb", options: []) else { return url }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let last = re.matches(in: s, options: [], range: range).last else { return url }
        let replaced = (s as NSString).replacingCharacters(in: last.range,
                                                           with: "/\(clamped)x\(clamped)bb")
        return URL(string: replaced) ?? url
    }

    /// 从 "3/12" 这类写法里取前导整数，供整碟排序用。
    static func leadingInt(_ s: String?) -> Int {
        guard let s else { return 0 }
        let digits = String(s.prefix { $0.isNumber })
        return Int(digits) ?? 0
    }

    // MARK: 映射

    private static func candidate(from box: JSONBox) -> TrackCandidate? {
        let wrapper = box["wrapperType"].string ?? "track"
        let isAlbum = wrapper == "collection"

        let nativeID = box["trackId"].string ?? box["collectionId"].string
        guard let nativeID, !nativeID.isEmpty else { return nil }

        var c = TrackCandidate(sourceID: "itunes",
                               nativeID: nativeID,
                               albumID: box["collectionId"].string)

        c.title  = isAlbum ? box["collectionName"].string : box["trackName"].string
        c.artist = box["artistName"].string
        c.album  = box["collectionName"].string
        // collectionArtistName 常缺席，必须回落 artistName
        c.albumArtist = box["collectionArtistName"].string ?? box["artistName"].string

        // releaseDate 形如 "2008-10-14T12:00:00Z"，取前 4 位
        if let d = box["releaseDate"].string, d.count >= 4 {
            c.year = String(d.prefix(4))
        }

        // 有 trackCount 时写成 "11/11"，TagEdit 支持这种写法
        if let n = box["trackNumber"].int {
            if let total = box["trackCount"].int, total > 0 {
                c.trackNumber = "\(n)/\(total)"
            } else {
                c.trackNumber = String(n)
            }
        }
        if let d = box["discNumber"].int {
            if let total = box["discCount"].int, total > 1 {
                c.discNumber = "\(d)/\(total)"
            } else {
                c.discNumber = String(d)
            }
        }

        c.genre = box["primaryGenreName"].string
        if let ms = box["trackTimeMillis"].double { c.durationSeconds = ms / 1000.0 }

        if let art = box["artworkUrl100"].string ?? box["artworkUrl60"].string
            ?? box["artworkUrl30"].string {
            c.artworkURL = URL(string: art)
        }
        return c
    }
}

// MARK: - 整碟曲目表

public extension ITunesSource {

    /// 实测（2026-09-03）：`lookup?id={collectionId}&entity=song` 在**美区曲库正常返回全部曲目**
    /// （1989 → resultCount 14 = 1 collection + 13 track），
    /// 但**中区的华语专辑普遍只返回 collection 一条**（魔杰座 / 島國之情歌第四集 均为 resultCount 1）。
    /// 所以这里拿不到曲目表是常态而非故障：照样把专辑本身的元数据（名/艺术家/年/曲目数/封面）返回，
    /// 让 `AlbumMatchService` 能把它当作「有专辑信息但无曲目表」的候选看待——
    /// 打分时它天然排在给得出曲目表的源后面，不会拖累整组。
    func fetchAlbum(_ candidate: TrackCandidate) async throws -> AlbumDetail? {
        guard let collectionID = candidate.albumID, !collectionID.isEmpty else { return nil }

        let results = try await fetchWithRegionFallback("取整碟", make: { code in
            var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
            comps.queryItems = [
                .init(name: "id", value: collectionID),
                .init(name: "entity", value: "song"),
                .init(name: "limit", value: "200"),
                .init(name: "country", value: code)
            ]
            return comps.url
        }, parse: { json in json["results"].array })
        guard !results.isEmpty else { return nil }

        var detail = AlbumDetail(sourceID: id, albumID: collectionID)

        if let col = results.first(where: { $0["wrapperType"].string == "collection" }) {
            detail.title = col["collectionName"].string
            detail.artist = col["artistName"].string
            if let d = col["releaseDate"].string, d.count >= 4 { detail.year = String(d.prefix(4)) }
            detail.trackCount = col["trackCount"].int ?? 0
            if let art = col["artworkUrl100"].string ?? col["artworkUrl60"].string {
                detail.artworkURL = URL(string: art)
            }
        }

        var discs = Set<Int>()
        for r in results where r["wrapperType"].string == "track" {
            guard let n = r["trackNumber"].int, n > 0,
                  let title = r["trackName"].string else { continue }
            let disc = r["discNumber"].int ?? 1
            discs.insert(disc)
            detail.tracks.append(AlbumTrack(
                number: n,
                disc: max(1, disc),
                title: title,
                durationSeconds: (r["trackTimeMillis"].double ?? 0) / 1000.0,
                artist: r["artistName"].string,
                nativeID: r["trackId"].string))
        }
        detail.discCount = max(1, discs.count)
        if detail.title == nil, let t = detail.tracks.first { _ = t; detail.title = candidate.album }
        if detail.trackCount == 0 { detail.trackCount = detail.tracks.count }
        detail.tracks.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        return detail
    }
}

// MARK: - 地区回退台账

/// iTunes 地区回退的进程内台账。
///
/// 为什么是引用类型 + 锁而不是 actor：`ITunesSource` 是 `struct`，`searchTracks` 是
/// 非 `mutating` 的协议方法，没地方挂状态；而记一次轨迹是纯内存写、微秒级，
/// 为它排一次 actor 队反而把 1 秒限速下的调用链拖长。
///
/// 两件事：
/// 1. **轨迹**（最近 20 条）—— 给 probe / 状态面板看「CN 一直是空的」。
/// 2. **已解析地区**（带 10 分钟 TTL）—— 回退成功后粘住，下次直接从能用的地区开搜，
///    省掉每首歌白付一发首选地区的空请求。TTL 到了重新试一次首选：
///    CN 商店哪天恢复了，用户不必重启 App 才能用回大陆曲库。
final class ITunesRegionLog: @unchecked Sendable {

    static let shared = ITunesRegionLog()

    /// 已解析地区的有效期。
    static let resolveTTL: TimeInterval = 600
    /// 轨迹保留条数。
    static let capacity = 20

    private let lock = NSLock()
    private var traces: [ITunesSource.RegionFallbackTrace] = []
    private var resolved: [String: (region: String, at: Date)] = [:]

    var last: ITunesSource.RegionFallbackTrace? {
        lock.lock(); defer { lock.unlock() }
        return traces.first
    }

    var history: [ITunesSource.RegionFallbackTrace] {
        lock.lock(); defer { lock.unlock() }
        return traces
    }

    func resolvedRegion(for requested: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = resolved[requested] else { return nil }
        guard Date().timeIntervalSince(e.at) < Self.resolveTTL else {
            resolved[requested] = nil
            return nil
        }
        return e.region
    }

    func record(_ trace: ITunesSource.RegionFallbackTrace, elapsed: TimeInterval) {
        lock.lock()
        traces.insert(trace, at: 0)
        if traces.count > Self.capacity { traces.removeLast(traces.count - Self.capacity) }
        if let hit = trace.hit {
            // 命中的就是首选地区 → 清掉粘住的解析结果，回到「用户选什么就用什么」。
            if hit == trace.requested { resolved[trace.requested] = nil }
            else { resolved[trace.requested] = (hit, Date()) }
        }
        lock.unlock()

        // 只有真发生了回退才补记健康台账。没回退的正常搜索由 `HTTPClient` 记过了，
        // 这里再记一次会把最近 20 次样本刷成全是自己的。
        guard trace.didFallback else { return }
        let note = trace.note
        let ok = trace.hit != nil
        Task.detached(priority: .utility) {
            await SourceHealth.shared.record(
                "itunes",
                SourceHealthEntry(kind: ok ? .ok : .empty, latency: elapsed,
                                  reason: "\(trace.operation)：\(note)"))
        }
    }

    func reset() {
        lock.lock(); traces.removeAll(); resolved.removeAll(); lock.unlock()
    }
}

// MARK: - 整碟去重缓存

/// 「同一张专辑在一批里只搜一次」的进程内缓存。
///
/// **为什么非要有它**（BD 轮）：iTunes 的发包间隔被压到 3.1 s（Apple 建议 ≈20 次/分钟，
/// 超了会回 403），一张 12 首的专辑逐首去搜就是 12 发 = 37 秒纯排队；
/// 而这 12 首本来就在同一张碟里，`lookup?id={collectionId}&entity=song` 一发就能全拿到。
///
/// 三段式，**第一个文件不多花任何请求**：
/// 1. 文件 ①：正常搜索。顺手把结果里出现最多的 `collectionId` 记下来（`noteCollectionID`）。
/// 2. 文件 ②：发现这张碟已经有 `collectionId` 了 → 改用 `lookup` 拉整碟并缓存（`store`）。
/// 3. 文件 ③…⑫：直接命中 `tracks(for:)`，**零请求**。
///
/// 合计 2 发管一整张碟。单曲（专辑名为空）不进这条路，行为一个字不变。
actor ITunesAlbumCache {

    static let shared = ITunesAlbumCache()

    /// 缓存寿命。批量匹配是一次性动作，超过这个时间多半已经是「下一批」了，
    /// 而 iTunes 的曲目表偶尔会变（补上架/下架），过期重取比拿旧数据稳妥。
    static let ttl: TimeInterval = 15 * 60
    /// 最多缓存多少张碟。一次导入几千首也就几百张碟，这个上限只防病态输入。
    static let capacity = 400

    private struct Entry {
        var tracks: [TrackCandidate]?
        var collectionID: String?
        var at: Date
    }
    private var entries: [String: Entry] = [:]

    private init() {}

    /// 已缓存的整碟曲目。没有或已过期返回 nil。
    func tracks(for key: String) -> [TrackCandidate]? {
        guard let e = entries[key], Date().timeIntervalSince(e.at) < Self.ttl else { return nil }
        return e.tracks
    }

    /// 这张碟已经被搜到过、但整碟曲目表还没拉。返回它的 collectionId。
    func pendingCollectionID(for key: String) -> String? {
        guard let e = entries[key], Date().timeIntervalSince(e.at) < Self.ttl,
              e.tracks == nil else { return nil }
        return e.collectionID
    }

    /// 记下 collectionId（不发请求）。
    func noteCollectionID(_ key: String, _ id: String) {
        evictIfNeeded()
        if var e = entries[key], Date().timeIntervalSince(e.at) < Self.ttl {
            if e.collectionID == nil { e.collectionID = id; entries[key] = e }
        } else {
            entries[key] = Entry(tracks: nil, collectionID: id, at: Date())
        }
    }

    /// 存入整碟曲目表。
    func store(_ key: String, tracks: [TrackCandidate]) {
        evictIfNeeded()
        let cid = entries[key]?.collectionID
        entries[key] = Entry(tracks: tracks, collectionID: cid, at: Date())
    }

    /// 清空。probe 的压测每轮开始前调它，免得上一轮的缓存把本轮的请求数做假账。
    func reset() { entries.removeAll() }

    /// 命中/未命中统计，供 probe 打印「本轮省了几发请求」。
    func count() -> (albums: Int, withTracks: Int) {
        (entries.count, entries.values.filter { $0.tracks != nil }.count)
    }

    private func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        entries = entries.filter { $0.value.at > cutoff }
        if entries.count > Self.capacity,
           let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

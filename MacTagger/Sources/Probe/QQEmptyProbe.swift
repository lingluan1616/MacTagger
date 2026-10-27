//
//  QQEmptyProbe.swift
//  mactagger-probe — QQ smartbox「批量下静默置空」的成因试验
//
//  背景（AX 轮）：批量匹配时 QQ 的 smartbox 联想接口 12/12 返回 HTTP 200 且
//  `data.song.itemlist` 为空，单独 curl 却正常。要弄清是「被风控」还是「参数写法问题」，
//  就得把可疑变量一个一个单独换掉，其余全部保持不变 —— 这个子命令就是那张对照表。
//
//  用法：mactagger-probe qqempty [搜索词] [--repeat N] [--gap 秒]
//
//  **只读**：全部是 GET 查询，不登录、不写任何东西、不带任何真实凭据
//  （Cookie 里的 pgv_pvid 是本地随机生成的数字，不是任何账号的）。
//  两次请求之间至少间隔 `--gap`（默认 1.5 s），一轮最多十几发。
//

import Foundation

private struct QQVariant {
    var name: String
    /// 直接给完整 URL 字符串（便于试不同的参数写法/编码）。
    var url: String
    var headers: [String: String]
    var note: String
}

private let qqUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

/// 百分号编码，空格 → %20（URLComponents 的默认行为）。
private func pctEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// 空格 → `+`（application/x-www-form-urlencoded 的写法，很多老接口只认它）。
private func plusEncode(_ s: String) -> String {
    pctEncode(s).replacingOccurrences(of: "%20", with: "+")
}

func cmdQQEmpty(_ rawTerm: String?, args: [String]) {
    let term = (rawTerm?.isEmpty == false ? rawTerm! : "稻香 周杰伦")
    let repeats = probeIntArg(args, "--repeat") ?? 3
    let gap = probeDoubleArg(args, "--gap") ?? 1.5

    let smartbox = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg"
    // 本地随机数字，不是任何账号的 cookie。QQ 的网页端会给每个访客发一个 pgv_pvid，
    // 「没有它」是我们与浏览器之间最显眼的差别之一，所以值得单独试一格。
    let pvid = String((0..<10).map { _ in "0123456789".randomElement()! })

    let base = ["User-Agent": qqUA, "Referer": "https://y.qq.com/"]

    let variants: [QQVariant] = [
        QQVariant(name: "A 现状（%20 编码，无 Cookie）",
                  url: "\(smartbox)?key=\(pctEncode(term))&format=json",
                  headers: base,
                  note: "App 里现在就是这一发"),
        QQVariant(name: "B 加 Cookie: pgv_pvid",
                  url: "\(smartbox)?key=\(pctEncode(term))&format=json",
                  headers: base.merging(["Cookie": "pgv_pvid=\(pvid)"]) { _, b in b },
                  note: "只加 Cookie，其余与 A 完全一致"),
        QQVariant(name: "C key 用 + 编码",
                  url: "\(smartbox)?key=\(plusEncode(term))&format=json",
                  headers: base,
                  note: "只换编码，其余与 A 完全一致"),
        QQVariant(name: "D 补 utf8/inCharset/outCharset",
                  url: "\(smartbox)?key=\(pctEncode(term))&format=json"
                       + "&utf8=1&inCharset=utf8&outCharset=utf-8&platform=yqq",
                  headers: base,
                  note: "网页端实际会带的那几个参数"),
        QQVariant(name: "E 全都带（Cookie + 参数）",
                  url: "\(smartbox)?key=\(pctEncode(term))&format=json"
                       + "&utf8=1&inCharset=utf8&outCharset=utf-8&platform=yqq",
                  headers: base.merging(["Cookie": "pgv_pvid=\(pvid)"]) { _, b in b },
                  note: "B + D"),
        QQVariant(name: "F 官方 search 接口（对照）",
                  url: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
                       + "?w=\(pctEncode(term))&format=json&p=1&n=5&cr=1&new_json=1",
                  headers: base,
                  note: "smartbox 之外的另一条路，看它是不是也空"),
    ]

    hr("QQ smartbox 置空试验（qqempty）")
    print("  搜索词 : \(term)")
    print("  每格重复 : \(repeats) 次   间隔 : \(gap) s")
    print("  说明   : 只发 GET 只读查询；Cookie 里的 pgv_pvid 是本地随机数字，不是任何账号。")
    print("")

    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func hitCount(_ data: Data, isSearchAPI: Bool) -> (n: Int, code: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data,
                                                          options: [.fragmentsAllowed]) else {
            return (-1, "非 JSON")
        }
        let root = JSONBox(obj)
        let code = root["code"].int.map(String.init) ?? "—"
        if isSearchAPI {
            return (root["data"]["song"]["list"].array.count, code)
        }
        return (root["data"]["song"]["itemlist"].array.count, code)
    }

    var summary: [(String, Int, Int, Double)] = []      // 名称, 非空次数, 总次数, 平均耗时

    for v in variants {
        print("─── \(v.name) ───")
        print("    \(v.note)")
        var nonEmpty = 0
        var totalTime = 0.0
        for i in 1...repeats {
            guard let url = URL(string: v.url) else { print("    URL 非法"); break }
            var req = URLRequest(url: url, timeoutInterval: 20)
            for (k, val) in v.headers { req.setValue(val, forHTTPHeaderField: k) }

            let sem = DispatchSemaphore(value: 0)
            var line = ""
            let t0 = Date()
            let task = session.dataTask(with: req) { data, resp, err in
                let dt = Date().timeIntervalSince(t0)
                totalTime += dt
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if let err {
                    line = String(format: "    #%d  ✘ %@  (%.2f s)", i,
                                  err.localizedDescription, dt)
                } else if let data {
                    let (n, code) = hitCount(data, isSearchAPI: v.name.hasPrefix("F"))
                    if n > 0 { nonEmpty += 1 }
                    line = String(format: "    #%d  HTTP %d  code=%@  条数=%d  %d 字节  (%.2f s)",
                                  i, status, code, n, data.count, dt)
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 25)
            print(line)
            if i < repeats { Thread.sleep(forTimeInterval: gap) }
        }
        summary.append((v.name, nonEmpty, repeats, totalTime / Double(repeats)))
        print("")
        Thread.sleep(forTimeInterval: gap)
    }

    print("═══ 汇总 ═══")
    for s in summary {
        print(String(format: "  %-34@ 非空 %d/%d   平均 %.2f s",
                     s.0 as NSString, s.1, s.2, s.3))
    }
    print("")
    print("  判读：只有 B/E 非空而 A 空 → Cookie 是关键；只有 C 非空 → 编码写法是关键；")
    print("        全都空 → 是这台机器/这个出口 IP 被风控，改参数救不回来，靠熔断降级即可。")
}

// MARK: - qqrank —— QQ 候选次序：源原始顺序 → 艺术家加权 → 打分排序

//
//  用法：
//    mactagger-probe qqrank "<查询串>" [--artist <艺术家>] [--limit N]
//
//  验的是任务书第 4 项：「QQ 候选里原版《魔杰座》必须排第一」。
//  三张次序表逐一打出来，好看清是哪一步把原版顶上去的（或者没顶上去）：
//
//    ① 源原始顺序   —— QQ 自己的相关度排序。翻唱排前面就是在这一列出现的。
//    ② 艺术家加权后 —— 适配器把「艺术家对不上」的候选往后排（不丢弃）。
//    ③ 打分排序后   —— `MatchScorer.rank`，含 AZ 轮新加的确定性平局判据。
//
//  查询按**两种口径**各跑一遍，因为它们走的是完全不同的代码路径：
//    · 有标题标签   → `searchTerm` 用「标题 艺术家」，不洗
//    · 只有文件名   → `searchTerm` 退回 `cleanedFilename`，要洗
//  用户观察到的翻唱排前正是后一种。
//

func cmdQQRank(_ term: String, args: [String]) {
    let limit = stressIntArg(args, "--limit", 8)
    let explicitArtist: String? = {
        guard let i = args.firstIndex(of: "--artist"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    probeRegisterSources()
    guard let qq = SourceRegistry.shared.source(id: "qq") as? QQSource else {
        fail("QQ 源未注册")
    }

    cnHR("QQ 候选次序（qqrank）「\(term)」")

    // `--levels`：三级降级链**逐级各打一发**，证明三套 Swift 实现都真的能跑通。
    // 正常路径永远只走第一级，后两级平时跑不到 —— 跑不到的代码等于没验过。
    if args.contains("--levels") {
        let cleaned = QQSource.cleanedFilename(term)
        out("")
        out("  三级逐一直连（检索词「\(cleaned)」）：")
        for path in QQSource.searchChain {
            let r = cnRunBlocking { try await qq.search(path: path, term: cleaned, limit: 5) }
            switch r {
            case .success(let list):
                out("    \(path.displayName)（\(path.rawValue)）：\(list.count) 条")
                for c in list.prefix(3) {
                    out("      · 《\(c.title ?? "-")》— \(c.artist ?? "-") · \(c.album ?? "—")"
                        + " · \(c.year ?? "—") · \(cnFmtDuration(c.durationSeconds))")
                }
            case .failure(let e):
                out("    \(path.displayName)（\(path.rawValue)）：✘ \(SourceOutcome.shortReason(for: e))")
            }
        }
        return
    }

    // 两种口径。第二种是批量匹配里最常见的形态（文件没标签，查询退回文件名）。
    var byTag = TrackQuery()
    byTag.title = term
    byTag.artist = explicitArtist

    var byFilename = TrackQuery()
    byFilename.filename = term

    for (label, q) in [("① 当作「标题（+艺术家）」", byTag),
                       ("② 当作「文件名」（无标签，批量里最常见）", byFilename)] {
        print("")
        print("═══ \(label) ═══")
        print("  送出的检索词 : 「\(QQSource.searchTerm(q))」")
        if let hint = QQSource.artistHint(q) {
            switch hint {
            case .explicit(let a): print("  艺术家判据   : 显式「\(a)」")
            case .haystack(let h): print("  艺术家判据   : 文件名包含式「\(h)」")
            }
        } else {
            print("  艺术家判据   : 无（查询里认不出艺术家，本次不加权）")
        }

        // ① 源原始顺序：直接打首选那一级，绕开加权
        let rawResult = cnRunBlocking { try await qq.searchViaOfficial(term: QQSource.searchTerm(q),
                                                                      limit: QQSource.overFetch) }
        guard case .success(let raw) = rawResult, !raw.isEmpty else {
            if case .failure(let e) = rawResult {
                print("  ① 官方搜索失败：\(e.localizedDescription)")
            } else {
                print("  ① 官方搜索 0 条")
            }
            continue
        }
        qqRankTable("① 源原始顺序（官方搜索的相关度排序）", Array(raw.prefix(5)), scored: false)

        // ② 艺术家加权后（= `searchTracks` 实际交出去的次序）
        let weighted = Array(QQSource.artistWeighted(raw, for: q).prefix(limit))
        qqRankTable("② 艺术家加权后（适配器交给打分器的次序）", Array(weighted.prefix(5)), scored: false)

        // ③ 打分排序
        let ranked = MatchScorer.rank(weighted, for: q)
        qqRankTable("③ MatchScorer.rank 之后", Array(ranked.prefix(5)), scored: true)

        if let top = ranked.first {
            let ok = (top.album ?? "").contains("魔杰座")
            print("  ⇒ 第一名：《\(top.title ?? "-")》— \(top.artist ?? "-") · \(top.album ?? "—")"
                  + String(format: " · %.3f", top.matchScore)
                  + (term.contains("稻香") ? (ok ? "　✔ 原版《魔杰座》第一" : "　✘ 不是原版") : ""))
        }
    }
}

private func qqRankTable(_ title: String, _ list: [TrackCandidate], scored: Bool) {
    print("  \(title)：")
    for (i, c) in list.enumerated() {
        var line = String(format: "    %d. %@ — %@ · %@ · %@ · %@",
                          i + 1,
                          c.title ?? "-", c.artist ?? "-",
                          c.album ?? "—", c.year ?? "—",
                          cnFmtDuration(c.durationSeconds))
        if scored { line += String(format: " · %.3f", c.matchScore) }
        print(line)
    }
}

// MARK: - ranktie —— 平局判据的确定性证明（打乱入池顺序 N 次，看胜出者变不变）

//
//  用法：
//    mactagger-probe ranktie "<查询串>" [--shuffles N] [--sources a,b,c]
//
//  为什么需要**离线**这一条证明：
//  端到端连跑三轮 `automatch` 证不了这件事 —— 软截止会按网络快慢把整个源踢出候选池
//  （实测某一轮 iTunes 12/12 都超过 4 s 软截止，那一轮它一条候选都没进池）。
//  **池子本身都不一样，比出来的当然不一样**，那是软截止的既有行为，不是排序的锅。
//
//  这个子命令把变量隔干净：**只联网取一次**候选池，之后纯本地把同一个池子
//  打乱 N 次分别排序。入池顺序是并发下唯一的随机源；如果打乱 N 次胜出者都一样，
//  排序对返回顺序就是免疫的 —— 这正是本轮要修的性质。
//
//  同时用**旧比较器**（分数降序 + 保持原顺序）跑同一批打乱做对照，
//  好证明「修好了」而不是「本来就没问题」。
//

func cmdRankTie(_ term: String, args: [String]) {
    let shuffles = stressIntArg(args, "--shuffles", 24)
    let sources: [String] = {
        guard let i = args.firstIndex(of: "--sources"), i + 1 < args.count else {
            return ["itunes", "netease", "kugou", "qq", "musicbrainz"]
        }
        return args[i + 1].split(separator: ",").map(String.init)
    }()

    probeRegisterSources()
    cnHR("平局判据确定性（ranktie）「\(term)」")
    out("  打乱次数 : \(shuffles)（同一个候选池，只换入池顺序）")
    out("  源       : \(sources.joined(separator: " "))")

    // —— 只联网这一次 ——
    var opts = AutoMatchOptions.recommended
    opts.sourceIDs = sources
    // 取池阶段要的是**完整**的池子，两条会缺斤少两的机制都得关掉：
    //   · 软截止：到点不等，慢源整个不进池；
    //   · 提前收工：已有 ≥0.90 的候选就取消其余源 —— 实测正是它把 iTunes 挡在池外的。
    // 关掉它们**只影响这条证明**，正式路径一个字没动。
    opts.sourceSoftDeadline = 0
    opts.slowSourceSoftDeadline = 0
    opts.earlyAcceptScore = 2            // >1 即关闭（见 shouldStopEarly 的 guard）
    var q = TrackQuery()
    q.filename = term
    if let parts = AutoMatchService.splitFilename(term) {
        q.title = parts.a; q.artist = parts.b
    }

    let gathered = cnRunBlocking { await AutoMatchService.gather(q, options: opts) }
    guard case .success(let (pool, outcomes)) = gathered, !pool.isEmpty else {
        out("  取池失败或候选池为空"); return
    }
    out("  结果条   : " + outcomes.inlineSummary)
    out("  候选池   : \(pool.count) 条")
    out("")

    // 分数分布：先把「到底有没有同分」摆出来，否则这条证明可能是空跑
    let ctx = MatchScorer.AlbumContext.make(from: pool, query: q)
    var buckets: [Double: [TrackCandidate]] = [:]
    for c in pool {
        let k = (MatchScorer.score(c, for: q, context: ctx) * 1_000_000).rounded()
        buckets[k, default: []].append(c)
    }
    let top = buckets.keys.max() ?? 0
    let tied = buckets[top] ?? []
    out(String(format: "  最高分   : %.6f，并列 %d 条", top / 1_000_000, tied.count))
    for c in tied {
        out("    · \(SourceOutcome.shortName(c.sourceID)) 《\(c.title ?? "-")》"
            + " · \(c.album ?? "—") · \(c.year ?? "—")"
            + " · 字段完整度 \(MatchScorer.fieldCompleteness(c))"
            + " · id=\(c.nativeID)")
    }
    if tied.count < 2 {
        out("  ⚠ 最高分没有并列 —— 这一条查询压不出平局，换个查询词再试。")
    }
    out("")

    // —— 纯本地：打乱 N 次分别排序 ——
    var rng = SplitMix64(seed: 0xA2_1234_5678_9ABC)
    var newWinners: [String] = []
    var oldWinners: [String] = []
    for _ in 0..<max(1, shuffles) {
        let shuffled = shuffleDeterministic(pool, rng: &rng)
        // 新：MatchScorer.rank（含确定性平局判据）
        if let w = MatchScorer.rank(shuffled, for: q).first { newWinners.append(rankKey(w)) }
        // 旧：分数降序 + 同分保持原顺序（AZ 轮之前的实现，逐字复刻）
        let scored = shuffled.enumerated().map { (i, c) -> (Int, TrackCandidate, Double) in
            (i, c, MatchScorer.score(c, for: q, context: ctx))
        }
        let oldSorted = scored.sorted { a, b in
            a.2 != b.2 ? a.2 > b.2 : a.0 < b.0
        }
        if let w = oldSorted.first?.1 { oldWinners.append(rankKey(w)) }
    }

    func verdict(_ label: String, _ ws: [String]) {
        let distinct = Set(ws)
        out("  \(label)：\(ws.count) 次打乱 → \(distinct.count) 种胜出者"
            + (distinct.count == 1 ? "　✔ 确定性" : "　✘ 随入池顺序抖动"))
        for d in distinct.sorted() {
            out("      \(ws.filter { $0 == d }.count) 次：\(d)")
        }
    }
    verdict("新判据（本轮）", newWinners)
    verdict("旧判据（AZ 之前）", oldWinners)
}

private func rankKey(_ c: TrackCandidate) -> String {
    "\(SourceOutcome.shortName(c.sourceID)) · 《\(c.title ?? "-")》 · \(c.album ?? "—") · \(c.nativeID)"
}

/// 自带 RNG，不用系统的 —— 证明要可复现，`shuffled()` 的随机源每次进程都不同。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func shuffleDeterministic(_ a: [TrackCandidate], rng: inout SplitMix64) -> [TrackCandidate] {
    var out = a
    guard out.count > 1 else { return out }
    for i in stride(from: out.count - 1, to: 0, by: -1) {
        let j = Int(rng.next() % UInt64(i + 1))
        out.swapAt(i, j)
    }
    return out
}

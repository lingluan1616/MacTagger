//
//  LyricsService.swift
//  MacTagger — 歌词业务逻辑
//
//  对应原版 FormLyricSearch / FormLyric 的后端能力（B 报告 5.2 节 D 条）：
//  多源搜索下载、4 种翻译合并格式、伴奏过滤、LRC 文件读写。
//

import Foundation

// MARK: - 翻译合并格式

/// 原版提供的 4 种「原词 + 翻译」排版方式。
public enum TranslationMergeFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `[t]原词 翻译词` —— 同一行，用连接符拼接
    case inline
    /// `[t]原词` `\n` `[t]翻译词` —— 两行共用同一时间戳
    case twoLines
    /// `[t]原词` `\n` `[t2]翻译词` `\n` `[t3]原词2` —— 三行轮转
    case tripleRotate
    /// `[t]翻译词` `\n` `[t]原词` —— 翻译在上
    case translationFirst

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .inline:           return "原词 翻译词（同一行）"
        case .twoLines:         return "原词 / 翻译词（两行）"
        case .tripleRotate:     return "原词 / 翻译 / 下句原词（三行轮转）"
        case .translationFirst: return "翻译词 / 原词（翻译在上）"
        }
    }

    /// 给界面做说明用的示意。
    public var sampleShape: String {
        switch self {
        case .inline:           return "[00:12.00]原词 翻译词"
        case .twoLines:         return "[00:12.00]原词\n[00:12.00]翻译词"
        case .tripleRotate:     return "[00:12.00]原词\n[00:12.00]翻译词\n[00:18.00]下句原词"
        case .translationFirst: return "[00:12.00]翻译词\n[00:12.00]原词"
        }
    }
}

// MARK: - 下载选项

public struct LyricsFetchOptions: Sendable {
    /// 按优先级排列的源。空 = 用注册表里全部支持歌词的源。
    public var sourceIDs: [String]
    /// 下载翻译词。
    public var includeTranslation: Bool
    public var mergeFormat: TranslationMergeFormat
    /// `inline` 格式下原词与翻译之间的连接符。
    public var separator: String
    /// 若存在翻译，则不保留原词（原版同名选项）。
    public var skipOriginalWhenTranslated: Bool
    /// 跳过伴奏/纯音乐版本。
    public var skipInstrumental: Bool
    /// 在注释标签写入 "163 key" 标记（原版行为，默认关闭）。
    public var write163KeyMarker: Bool
    /// 在线歌词的字形归一策略。默认取进程级设置。
    public var chineseVariant: ChineseVariantPolicy = ChineseVariant.onlineDefault

    public init(sourceIDs: [String] = ["netease", "qq", "kugou", "kuwo"],
                includeTranslation: Bool = true,
                mergeFormat: TranslationMergeFormat = .twoLines,
                separator: String = " ",
                skipOriginalWhenTranslated: Bool = false,
                skipInstrumental: Bool = true,
                write163KeyMarker: Bool = false) {
        self.sourceIDs = sourceIDs
        self.includeTranslation = includeTranslation
        self.mergeFormat = mergeFormat
        self.separator = separator
        self.skipOriginalWhenTranslated = skipOriginalWhenTranslated
        self.skipInstrumental = skipInstrumental
        self.write163KeyMarker = write163KeyMarker
    }

    public static let `default` = LyricsFetchOptions()
}

// MARK: - 结果

public struct LyricsFetchResult: Sendable {
    public enum Status: String, Sendable {
        case found, notFound, failed, skippedInstrumental
    }
    public var url: URL
    public var status: Status
    /// 已按选定格式合并好、可直接写入标签的文本。
    public var merged: String?
    public var bundle: LyricsBundle?
    public var candidate: TrackCandidate?
    public var sourceID: String?
    public var hasTranslation: Bool
    public var hasWordByWord: Bool
    public var triedSources: [String]
    public var errors: [(sourceID: String, message: String)]
    /// 逐源结果条：每个歌词源这一轮是「有 n 条 / 0 条 / 挂了」，含耗时。
    /// 批量复核窗顶部的 chips 读它 —— 「没搜到」和「源挂了」必须一眼分开。
    public var sourceOutcomes: [SourceOutcome] = []
}

// MARK: - 服务

public enum LyricsService {

    // MARK: 伴奏过滤

    /// 原版选项：不下载标题含这些词的歌词。
    static let instrumentalMarkers = [
        "instrumental", "off vocal", "offvocal", "karaoke",
        "伴奏", "纯音乐", "无损伴奏", "消音"
    ]

    /// 署名行：`作词 : X` `曲：Y` `Lyricist: Z` 之类。
    /// 判据是「冒号前是署名词且整行较短」，避免误伤正文里带冒号的歌词。
    static let creditKeywords = [
        "作词", "作曲", "编曲", "制作人", "监制", "混音", "母带", "和声", "吉他", "贝斯",
        "鼓", "键盘", "弦乐", "录音", "出品", "发行", "统筹", "企划", "词", "曲",
        "lyricist", "composer", "arranger", "producer", "mixing", "mastering",
        "recorded", "written", "music", "lyrics"
    ]

    public static func isCreditLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count <= 60 else { return false }
        // 支持全角/半角冒号
        guard let sepRange = t.range(of: "：") ?? t.range(of: ":") else { return false }
        let head = t[..<sepRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard head.count <= 12, !head.isEmpty else { return false }
        return creditKeywords.contains { head == $0 || head.hasPrefix($0) }
    }

    public static func isInstrumental(_ title: String?) -> Bool {
        guard let t = title?.lowercased() else { return false }
        return instrumentalMarkers.contains { t.contains($0) }
    }

    // MARK: 合并

    /// 把原词与翻译按指定格式合并。
    ///
    /// 原词与翻译是两份**独立的 LRC**，时间戳未必逐行对齐。配对策略：
    /// 对每条原词行，在翻译里找**时间戳最接近**的一行，容差 ±0.35 秒；
    /// 找不到就该行只输出原词。选就近匹配而非按行序，是因为翻译版常缺行
    /// （空行、纯音乐间奏不译），按行序会从缺口处开始整体错位。
    public static func merge(plain: String?,
                             translated: String?,
                             format: TranslationMergeFormat,
                             separator: String = " ",
                             skipOriginalWhenTranslated: Bool = false) -> String? {
        guard let plain, !plain.isEmpty else { return translated }
        guard let translated, !translated.isEmpty else { return plain }

        let src = LrcDocument.parse(plain)
        let dst = LrcDocument.parse(translated)
        guard !src.lines.isEmpty else { return plain }

        // 翻译行按时间索引
        let transTimed: [(t: TimeInterval, text: String)] = dst.lines.compactMap {
            guard let t = $0.firstTimestamp, !$0.isBlankText else { return nil }
            return (t, $0.text)
        }.sorted { $0.t < $1.t }

        // 每条翻译只能被认领一次。
        // 不做这个约束会出两种错：① 同一句翻译重复出现在相邻两行
        // ② 歌曲开头的「作词/作曲/编曲/制作人」几行时间戳挨得很近，
        //    会把第一句正文的翻译抢走（实测 [00:00.63]制作人 抢了 [00:00.85] 那句的翻译）。
        var claimed = Set<Int>()

        func translation(for time: TimeInterval?) -> String? {
            guard let time, !transTimed.isEmpty else { return nil }
            var bestIdx: Int?
            var bestDelta = TimeInterval.greatestFiniteMagnitude
            for (i, item) in transTimed.enumerated() {
                if claimed.contains(i) { continue }
                let d = abs(item.t - time)
                if d < bestDelta { bestDelta = d; bestIdx = i }
                if item.t > time + 1 { break }          // 已排序，越过就停
            }
            guard let idx = bestIdx, bestDelta <= 0.35 else { return nil }
            claimed.insert(idx)
            return transTimed[idx].text
        }

        var out = LrcDocument(headerTags: src.headerTags, lines: [])

        // 署名行（作词/作曲/编曲/制作人…）不参与翻译配对。
        // 这几行是元信息、本就没有译文，却常挤在歌曲开头零点几秒内，
        // 会把第一句正文的翻译抢走（实测 [00:00.63]制作人 抢了 [00:00.85] 的译文）。
        func isCredit(_ text: String) -> Bool { LyricsService.isCreditLine(text) }

        switch format {
        case .inline:
            for line in src.lines {
                guard !isCredit(line.text),
                      let tr = translation(for: line.firstTimestamp) else {
                    out.lines.append(line); continue
                }
                let text = skipOriginalWhenTranslated ? tr : line.text + separator + tr
                out.lines.append(LrcLine(timestamps: line.timestamps, text: text))
            }

        case .twoLines:
            for line in src.lines {
                guard !isCredit(line.text),
                      let tr = translation(for: line.firstTimestamp) else {
                    out.lines.append(line); continue
                }
                if !skipOriginalWhenTranslated { out.lines.append(line) }
                out.lines.append(LrcLine(timestamps: line.timestamps, text: tr))
            }

        case .translationFirst:
            for line in src.lines {
                guard !isCredit(line.text),
                      let tr = translation(for: line.firstTimestamp) else {
                    out.lines.append(line); continue
                }
                out.lines.append(LrcLine(timestamps: line.timestamps, text: tr))
                if !skipOriginalWhenTranslated { out.lines.append(line) }
            }

        case .tripleRotate:
            // 原词 / 翻译 / 下一句原词。第三行用下一句的时间戳，
            // 让播放器在本句尚未结束时就预告下一句。
            for (i, line) in src.lines.enumerated() {
                let tr = isCredit(line.text) ? nil : translation(for: line.firstTimestamp)
                if !(skipOriginalWhenTranslated && tr != nil) {
                    out.lines.append(line)
                }
                guard let tr else { continue }      // 无翻译就只出原词，别追加下一句
                out.lines.append(LrcLine(timestamps: line.timestamps, text: tr))
                // 第三行预告下一句原词，用下一句自己的时间戳
                if i + 1 < src.lines.count {
                    let next = src.lines[i + 1]
                    if !next.isBlankText {
                        out.lines.append(LrcLine(timestamps: next.timestamps, text: next.text))
                    }
                }
            }
        }

        return out.render(millisecondDigits: 2)
    }

    // MARK: 简繁归一

    /// **本服务唯一的字形归一函数**。`fetch` 与 `bestLyrics` 两条取词路径都从这里过 ——
    /// 歌词是要写进标签、也要另存成 .lrc 的正文，两条路必须给出同一种字形，
    /// 否则同一首歌「批量下载」得到简体、「搜索窗手动挑」得到繁体。
    ///
    /// 原词 / 翻译 / 逐字三段一起转；时间戳是 ASCII，OpenCC 不会碰。
    static func normalized(_ bundle: LyricsBundle?,
                           _ policy: ChineseVariantPolicy) -> LyricsBundle? {
        guard let bundle, !policy.isIdentity else { return bundle }
        return bundle.converted(to: policy)
    }

    // MARK: 下载

    /// 为一个文件下载歌词。按源优先级降级，单源失败只淘汰该源。
    ///
    /// ★ BG 轮整段改走 `resolve(query:…)` —— 版本识别、marker 打分、
    /// 「录音室版译文移植」三件事只在那一处实现，
    /// 本函数、搜索窗的 `bestLyrics`、自动匹配的补查共用它（任务书 3d）。
    /// 这里只剩「把 `LyricsResolution` 翻译成 `LyricsFetchResult`」这一层壳。
    public static func fetch(for file: AudioFile,
                             options: LyricsFetchOptions = .default) async -> LyricsFetchResult {
        var result = LyricsFetchResult(url: file.url, status: .notFound,
                                       merged: nil, bundle: nil, candidate: nil,
                                       sourceID: nil, hasTranslation: false,
                                       hasWordByWord: false, triedSources: [], errors: [])

        let query = AutoMatchService.makeQuery(from: file)
        guard !query.isEmpty else { return result }

        let registry = SourceRegistry.shared
        let sourceIDs: [String] = options.sourceIDs.isEmpty
            ? registry.sources(supporting: .lyrics).map(\.id)
            : options.sourceIDs
        result.triedSources = sourceIDs

        let r = await resolve(query: query,
                              sourceIDs: sourceIDs,
                              skipInstrumental: options.skipInstrumental,
                              includeTranslation: options.includeTranslation,
                              // 0.6 = 旧 `fetch` 里 `MatchScorer.best(minimumScore:)` 的那把尺子，
                              // 原样保留。搜索窗与自动匹配补查（走 `bestLyrics` / `resolve` 默认值）
                              // 本来就没有这道闸，也保持原样。
                              minimumScore: 0.6,
                              chineseVariant: options.chineseVariant)
        result.errors = r.errors
        result.sourceOutcomes = r.sourceOutcomes

        // 「命中的是伴奏版」这条状态要保住：老界面靠它把这类文件归到「已忽略」而不是「失败」。
        if r.best == nil, options.skipInstrumental, r.filteredInstrumental > 0,
           r.candidates.isEmpty {
            result.status = .skippedInstrumental
            return result
        }

        guard let best = r.best, let bundle = best.bundle, !bundle.isEmpty else {
            let failedAll = !sourceIDs.isEmpty && r.errors.count == sourceIDs.count
            result.status = failedAll ? .failed : .notFound
            return result
        }

        result.bundle = bundle
        result.candidate = best.track
        result.sourceID = best.track.sourceID
        result.hasTranslation = bundle.hasTranslation
        result.hasWordByWord = bundle.wordByWord?.isEmpty == false
        result.merged = options.includeTranslation
            ? merge(plain: bundle.plain,
                    translated: bundle.translated,
                    format: options.mergeFormat,
                    separator: options.separator,
                    skipOriginalWhenTranslated: options.skipOriginalWhenTranslated)
            : bundle.plain
        result.status = .found
        // 「各源均无翻译」「翻译来自录音室版」这类交代要进 errors 让复核表看得见 ——
        // 它不是错误，但它是用户**必须知道**的一句话，而 errors 是现成的唯一出口。
        for n in r.notes { result.errors.append((best.track.sourceID, n)) }
        return result
    }

    /// 这首歌**值不值得为翻译多问几个源**。
    ///
    /// 判据是曲名/艺术家的文字：含假名或谚文 → 一定要翻译；含拉丁字母（英文歌）→ 要；
    /// 纯汉字 + 标点（华语歌）→ **不要** —— 给中文歌配「中文翻译」没有意义，
    /// 为它多打两个源只是白等。
    /// 注意汉字这一条要放在最后判：日文曲名里全是汉字的情况（「彼ノ夢」除外的那些）
    /// 靠 `filename`/`artist` 里的假名兜住，兜不住时按华语处理，代价只是少一次尝试。
    public static func wantsTranslation(_ query: TrackQuery) -> Bool {
        let text = [query.title, query.artist, query.album, query.filename]
            .compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty else { return false }
        var latin = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:   return true   // 平假名/片假名
            case 0xAC00...0xD7AF, 0x1100...0x11FF:   return true   // 谚文
            case 0x0041...0x005A, 0x0061...0x007A:   latin += 1
            default: break
            }
        }
        // 拉丁字母够多才算英文歌：「Lemon」「Blank Space」要，「稻香 (Live)」不要。
        return latin >= 4
    }

    /// 批量下载。进度回调 + 并发控制，复用 BatchSummary 的统计口径。
    public static func fetchAll(_ files: [AudioFile],
                                options: LyricsFetchOptions = .default,
                                concurrency: Int = 3,
                                progress: (@Sendable (BatchProgress) -> Void)? = nil)
        async -> (results: [LyricsFetchResult], summary: BatchSummary) {

        guard !files.isEmpty else {
            return ([], BatchSummary(succeeded: 0, failed: 0, ignored: 0, total: 0, failures: []))
        }
        var results = [LyricsFetchResult?](repeating: nil, count: files.count)
        var completed = 0
        let limit = max(1, min(concurrency, 6))

        await withTaskGroup(of: (Int, LyricsFetchResult).self) { group in
            var next = 0
            func submit() {
                guard next < files.count else { return }
                let idx = next; next += 1
                let f = files[idx]
                group.addTask { (idx, await fetch(for: f, options: options)) }
            }
            for _ in 0..<min(limit, files.count) { submit() }
            for await (idx, r) in group {
                results[idx] = r
                completed += 1
                progress?(BatchProgress(completed: completed, total: files.count, currentPath: r.url.path))
                submit()
            }
        }

        let final = results.compactMap { $0 }
        var ok = 0, fail = 0, ign = 0
        var failures: [(url: URL, error: TagError)] = []
        for r in final {
            switch r.status {
            case .found: ok += 1
            case .notFound, .skippedInstrumental: ign += 1
            case .failed:
                fail += 1
                failures.append((r.url, .writeFailed(r.errors.first?.message ?? "所有歌词源均失败")))
            }
        }
        return (final, BatchSummary(succeeded: ok, failed: fail, ignored: ign,
                                    total: final.count, failures: failures))
    }

    // MARK: - LRC 文件

    public enum LrcFileNaming: String, Codable, Sendable, CaseIterable, Identifiable {
        case sameAsAudio        // 和歌曲文件名相同
        case artistTitle        // 艺术家 - 标题
        case titleArtist        // 标题 - 艺术家
        public var id: String { rawValue }
        public var localizedName: String {
            switch self {
            case .sameAsAudio: return "和歌曲文件名相同"
            case .artistTitle: return "艺术家 - 标题"
            case .titleArtist: return "标题 - 艺术家"
            }
        }
    }

    /// 导入 .lrc，自动识别编码。
    /// 顺序：BOM → UTF-8 → GB18030 → Big5 → Latin-1。
    /// 老的中文 LRC 大量是 GBK 存的，按 UTF-8 硬读会得到乱码或失败。
    public static func importLrc(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }

        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: big5)) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }

        throw TagError.corruptedFile("无法识别 LRC 文件编码")
    }

    /// 依命名规则算出不含扩展名的基名（已过滤非法字符）。
    /// `lrcURL` 与新的 `lyricsFileURL` 共用，避免两条路径各写一套命名逻辑。
    public static func lyricsBaseName(for file: AudioFile, naming: LrcFileNaming) -> String {
        let base: String
        switch naming {
        case .sameAsAudio:
            base = file.url.deletingPathExtension().lastPathComponent
        case .artistTitle:
            base = joinSafely(file.tags.artist, file.tags.title, fallback: file.url)
        case .titleArtist:
            base = joinSafely(file.tags.title, file.tags.artist, fallback: file.url)
        }
        return sanitize(base)
    }

    /// 依命名规则算出 .lrc 的落盘路径。
    public static func lrcURL(for file: AudioFile,
                              naming: LrcFileNaming,
                              directory: URL? = nil) -> URL {
        let dir = directory ?? file.url.deletingLastPathComponent()
        return dir.appendingPathComponent(lyricsBaseName(for: file, naming: naming))
                  .appendingPathExtension("lrc")
    }

    /// 导出 .lrc。默认 UTF-8。
    @discardableResult
    public static func exportLrc(_ text: String,
                                 for file: AudioFile,
                                 naming: LrcFileNaming = .sameAsAudio,
                                 directory: URL? = nil,
                                 encoding: String.Encoding = .utf8) throws -> URL {
        let target = lrcURL(for: file, naming: naming, directory: directory)
        guard let data = text.data(using: encoding, allowLossyConversion: true) else {
            throw TagError.writeFailed("歌词无法用所选编码保存")
        }
        try data.write(to: target, options: .atomic)
        return target
    }

    static func joinSafely(_ a: String?, _ b: String?, fallback: URL) -> String {
        let x = a?.trimmingCharacters(in: .whitespaces) ?? ""
        let y = b?.trimmingCharacters(in: .whitespaces) ?? ""
        if x.isEmpty && y.isEmpty { return fallback.deletingPathExtension().lastPathComponent }
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return "\(x) - \(y)"
    }

    /// 去掉文件名里不能用的字符。
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "lyrics" : String(cleaned.prefix(200))
    }
}

// MARK: - 搜索/合并的呈现模型
//
// 这三个类型原先建在 App 目录（子代理的临时契约），但它们是 LyricsService
// 公开接口的一部分，CLI 验证工具同样要用，因此归位到数据层。

public struct LyricsMergeOptions: Sendable, Equatable {
    /// 是否启用翻译合并。关掉就只要原词。
    public var mergeTranslation: Bool
    public var format: TranslationMergeFormat
    /// 原词与翻译的连接符（仅 `.inline` 用得到）。
    public var connector: String
    /// 原版「不下载原词（若翻译存在）」——有翻译时只保留翻译。
    public var translationOnly: Bool
    /// 优先使用逐字歌词（若该源提供）。
    public var preferWordByWord: Bool

    public init(mergeTranslation: Bool = true,
                format: TranslationMergeFormat = .twoLines,
                connector: String = " ",
                translationOnly: Bool = false,
                preferWordByWord: Bool = false) {
        self.mergeTranslation = mergeTranslation
        self.format = format
        self.connector = connector
        self.translationOnly = translationOnly
        self.preferWordByWord = preferWordByWord
    }
}

// MARK: - 搜索候选

/// 歌词搜索结果里的一条。`bundle` 取回后缓存在这里，切换合并格式无需重新联网。
public struct LyricsCandidate: Identifiable, Sendable {
    public var id = UUID()
    public var track: TrackCandidate
    public var bundle: LyricsBundle?

    public var sourceID: String { track.sourceID }
    public var title: String { track.title ?? "" }
    public var artist: String { track.artist ?? "" }
    public var album: String { track.album ?? "" }
    public var duration: TimeInterval { track.durationSeconds }
    public var score: Double { track.matchScore }

    public var hasTranslation: Bool {
        !(bundle?.translated?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    public var hasWordByWord: Bool {
        !(bundle?.wordByWord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    public var isFetched: Bool { bundle != nil }

    public init(track: TrackCandidate, bundle: LyricsBundle? = nil) {
        self.track = track
        self.bundle = bundle
    }
}

public struct LyricsSearchOutcome: Sendable {
    public var candidates: [LyricsCandidate]
    public var attempts: [SourceAttempt]
    /// 被「不下载伴奏版」过滤掉的条数。
    public var filteredInstrumental: Int

    public init(candidates: [LyricsCandidate] = [],
                attempts: [SourceAttempt] = [],
                filteredInstrumental: Int = 0) {
        self.candidates = candidates
        self.attempts = attempts
        self.filteredInstrumental = filteredInstrumental
    }

    public var errorSummary: String? {
        let failed = attempts.filter { $0.outcome == .failed }
        guard !failed.isEmpty else { return nil }
        return failed.map { "\($0.sourceID)：\($0.message ?? "未知错误")" }.joined(separator: "；")
    }

    /// 逐源结果条。由 `attempts` 派生，不额外存一份，避免两处记账漂移。
    public var sourceOutcomes: [SourceOutcome] {
        SourceOutcome.from(attempts).sortedByPriority()
    }
}

// MARK: - 服务

// MARK: - 界面友好的重载

public extension LyricsService {

    /// 按查询搜歌词并返回最佳候选（含已取回的 bundle）与各源尝试记录。
    ///
    /// 与 `fetch(for:options:)` 的区别：那个从 `AudioFile` 出发、直接产出可写入的文本；
    /// 这个从 `TrackQuery` 出发、把候选与 bundle 原样交还，供界面做「预览 / 切换合并格式 /
    /// 换一条候选」——切格式不必重新联网，这是搜索窗口的核心交互。
    /// 「有翻译优先」时的歌词源顺序。
    ///
    /// 依据是 BD 轮的实测（Lemon 三源全测）：三家都能给出中文译文，
    /// 但网易云一发就带译文、字段最干净（0.34 s）；QQ 要走移动端 `GetPlayLyricInfo`
    /// 并解密（2.2 s）；酷狗要「搜候选 → 下 KRC → 解密」两发（4.6 s）。
    /// 顺序即「同样有译文时谁更快、更稳」，不是质量排名。
    public static let translationSourceOrder = ["netease", "qq", "kugou", "kuwo"]

    /// - Parameter stopWhenTranslated: 拿到带译文的那一份就收工，不再问后面的源。
    ///   自动匹配的补查用它 —— 那条路上「再多一个候选」没有价值，「有没有译文」才有。
    /// ★ BG 轮：整段改走 `resolve(query:…)`，与 `fetch` 共用同一套版本规则与移植逻辑。
    /// 返回签名一个字没动，四个既有调用方（搜索窗、补署名、自动匹配补查、probe）无需改。
    ///
    /// - Parameter includeTranslation: 关掉就**不为译文多花一发请求**，也不做移植。
    ///   补署名那条路（`creditsWork`）必须关 —— 它只读歌词开头的「作词 : X」几行，
    ///   带 3 秒软截止，为它去找录音室版供体纯属白等。
    static func bestLyrics(for query: TrackQuery,
                           sourceIDs: [String],
                           limitPerSource: Int = 5,
                           skipInstrumental: Bool = true,
                           stopWhenTranslated: Bool = false,
                           includeTranslation: Bool = true)
        async -> (best: LyricsCandidate?, outcome: LyricsSearchOutcome) {

        let r = await resolve(query: query,
                              sourceIDs: sourceIDs,
                              limitPerSource: limitPerSource,
                              skipInstrumental: skipInstrumental,
                              includeTranslation: includeTranslation,
                              // 「拿到就收工」在 `resolve` 里升级成了「版本相符 + 有译文才收工」；
                              // 调用方传 false 时仍然把所有源跑完（搜索窗要一张完整候选表）。
                              stopWhenSatisfied: stopWhenTranslated)

        return (r.best, LyricsSearchOutcome(candidates: r.candidates,
                                            attempts: r.attempts,
                                            filteredInstrumental: r.filteredInstrumental))
    }

    /// 按界面的合并选项渲染一份 bundle。切换格式时反复调用，不产生网络请求。
    static func merge(_ bundle: LyricsBundle, options: LyricsMergeOptions) -> String {
        // 逐字歌词优先（若该源提供且用户要）
        if options.preferWordByWord, let k = bundle.wordByWord, !k.isEmpty {
            return k
        }
        guard options.mergeTranslation else { return bundle.plain ?? "" }
        return merge(plain: bundle.plain,
                     translated: bundle.translated,
                     format: options.format,
                     separator: options.connector,
                     skipOriginalWhenTranslated: options.translationOnly)
            ?? (bundle.plain ?? "")
    }
}

// MARK: - 从歌词提取署名

public extension LyricsService {

    /// 歌词开头的署名信息。
    /// 中文音乐平台的歌词普遍带 `[00:00.00]作词 : 某某` 这样的几行，
    /// 而搜索接口本身极少返回作曲/作词——这是最现实的来源。
    struct Credits: Sendable, Equatable {
        public var composer: String?
        public var lyricist: String?
        public var arranger: String?
        public var isEmpty: Bool { composer == nil && lyricist == nil && arranger == nil }
    }

    /// 从歌词文本里解析署名行。识别中英文两套写法。
    static func credits(from lyrics: String?) -> Credits {
        var out = Credits()
        guard let lyrics, !lyrics.isEmpty else { return out }

        // 只看前 20 行——署名总在开头，往后扫会把正文里带冒号的歌词误判
        for line in LrcDocument.parse(lyrics).lines.prefix(20) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard isCreditLine(text) else { continue }
            guard let sep = text.range(of: "：") ?? text.range(of: ":") else { continue }

            let key = text[..<sep.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            let value = text[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            func matches(_ words: [String]) -> Bool {
                words.contains { key == $0 || key.hasPrefix($0) }
            }
            if out.lyricist == nil, matches(["作词", "词", "lyricist", "lyrics", "written"]) {
                out.lyricist = value
            } else if out.composer == nil, matches(["作曲", "曲", "composer", "music"]) {
                out.composer = value
            } else if out.arranger == nil, matches(["编曲", "arranger"]) {
                out.arranger = value
            }
        }
        return out
    }

    // MARK: - 专为「补署名」的瘦身查询（AX 轮）

    /// 一次署名查询的结果 + 它是从哪来的（进结果条与展开行的「耗时」那一句）。
    struct CreditsLookup: Sendable {
        public var credits: Credits
        public var note: String?
        public init(credits: Credits, note: String? = nil) {
            self.credits = credits; self.note = note
        }
    }

    /// 只为拿「作曲 / 作词」而查歌词。**与 `bestLyrics` 的三处关键区别**：
    ///
    /// 1. **命中即停**：`bestLyrics` 会把列表里每个源都「搜索 + 取词」跑完再挑最好的
    ///    （它要给用户一张可切换的候选表，那样做是对的）；补署名只要有署名行就够了，
    ///    第一个给出署名的源就是答案。默认列表只有网易云与酷狗两家，且酷狗只在
    ///    网易云没给出署名时才轮到 —— 实际绝大多数文件只花一个源的钱。
    /// 2. **软截止**：署名是锦上添花的字段，为它把整首歌拖慢几秒不划算。到点就交白卷。
    /// 3. **进程内缓存 + 在途合并**：键是归一化的 (标题, 艺术家)。同一批里同专辑的
    ///    重复文件、以及复核表上反复「换候选」补全同一首，都只查一次。
    static func lookupCredits(title: String?,
                              artist: String?,
                              album: String? = nil,
                              duration: TimeInterval = 0,
                              sourceIDs: [String] = ["netease", "kugou"],
                              softDeadline: TimeInterval = 3) async -> CreditsLookup {

        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            return CreditsLookup(credits: Credits(), note: "候选没有标题，跳过")
        }
        let key = MatchScorer.normalize(t) + "\u{1}" + MatchScorer.normalize(artist ?? "")

        var q = TrackQuery()
        q.title = t
        q.artist = artist
        q.album = album
        q.duration = duration

        let (r, cached) = await CreditsCache.shared.value(for: key) {
            await creditsWork(query: q, sourceIDs: sourceIDs, softDeadline: softDeadline)
        }
        guard cached else { return r }
        return CreditsLookup(credits: r.credits,
                             note: (r.note.map { $0 + "·缓存" }) ?? "缓存")
    }

    /// 真正去查的那一段，带软截止。
    private static func creditsWork(query: TrackQuery,
                                    sourceIDs: [String],
                                    softDeadline: TimeInterval) async -> CreditsLookup {
        func run() async -> CreditsLookup {
            for sid in sourceIDs {
                // `includeTranslation: false` —— 署名只看原词的前 20 行，
                // 不为它去找录音室版供体（BG 轮：那会把 3 秒软截止直接吃满）。
                let (best, _) = await bestLyrics(for: query, sourceIDs: [sid],
                                                 limitPerSource: 3,
                                                 includeTranslation: false)
                let c = credits(from: best?.bundle?.plain)
                if !c.isEmpty {
                    return CreditsLookup(credits: c, note: SourceOutcome.shortName(sid))
                }
            }
            return CreditsLookup(credits: Credits(), note: "未找到署名")
        }

        guard softDeadline > 0 else { return await run() }
        return await withTaskGroup(of: CreditsLookup?.self) { race in
            race.addTask { await run() }
            race.addTask {
                try? await Task.sleep(nanoseconds: UInt64(softDeadline * 1_000_000_000))
                return nil
            }
            let first = await race.next() ?? nil
            race.cancelAll()
            return first ?? CreditsLookup(
                credits: Credits(),
                note: String(format: "超过 %.0f s 软截止", softDeadline))
        }
    }
}

// MARK: - 署名缓存

/// 按 (归一标题, 归一艺术家) 缓存署名查询结果，并把在途的同键查询合并成一次。
///
/// 为什么值得单独有一个 actor：批量里「同一首歌出现多次」比想象中常见 ——
/// 同一张专辑的两个格式副本、无损与有损两份、以及复核表上用户反复「换候选」
/// 补全同一首。每一次都重新走一遍「搜索 + 取词」是纯粹的浪费，而这些查询
/// 恰好是**幂等且与文件无关**的：同样的曲名艺术家，答案永远一样。
///
/// 软截止**做在 work 内部**而不是在等待端：如果由等待方去 race，
/// `await task.value` 对非抛出任务不响应取消，等待端根本挣脱不开。
public actor CreditsCache {

    public static let shared = CreditsCache()

    /// 缓存上限。超过就整张清掉 —— 这是「一批之内不重复查」的缓存，
    /// 不是长期字典，做 LRU 是过度设计。
    public static let capacity = 512

    private var done: [String: LyricsService.CreditsLookup] = [:]
    private var inflight: [String: Task<LyricsService.CreditsLookup, Never>] = [:]

    public init() {}

    /// 返回 (结果, 是否来自缓存/在途合并)。
    public func value(for key: String,
                      work: @Sendable @escaping () async -> LyricsService.CreditsLookup)
        async -> (result: LyricsService.CreditsLookup, cached: Bool) {

        if let hit = done[key] { return (hit, true) }
        if let t = inflight[key] { return (await t.value, true) }

        let t = Task { await work() }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        if done.count >= Self.capacity { done.removeAll() }
        done[key] = r
        return (r, false)
    }

    /// 清空。压测的三组对照要从同一起点开跑，否则第二组白捡第一组的缓存。
    public func reset() {
        done.removeAll()
        inflight.removeAll()
    }
}

// MARK: - 歌词文件：格式 / 编码 / 位置 / 选项
//
// 「把歌词保存成文件」的完整数据层。既服务于「保存标签时顺带存一份」，
// 也服务于自动匹配、批量下载、搜索预览、编辑器另存这四条手动路径。
//
// 与旧的 `exportLrc(_:for:naming:directory:encoding:)` 并存：老签名一个字没动，
// 新能力全部走 `LyricsFileOptions` 这一个入口，界面层只需要传一份选项。

/// 可保存的歌词文件格式。
public enum LyricsFileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 标准 LRC：`[mm:ss.xx]歌词`。
    case lrc
    /// 增强 LRC（A2 扩展）：`[mm:ss.xx]<mm:ss.xx>逐<mm:ss.xx>字`。
    /// 没有逐字数据时**自动退化为标准 LRC**，而不是产出半成品。
    case enhancedLrc
    /// 纯文本：去时间轴、去头部标签。
    case txt
    /// SRT 字幕：用相邻行的时间戳作起止，最后一行 +5 秒。
    case srt

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .lrc:         return "LRC 歌词（.lrc）"
        case .enhancedLrc: return "增强 LRC 逐字（.lrc）"
        case .txt:         return "纯文本（.txt）"
        case .srt:         return "SRT 字幕（.srt）"
        }
    }

    public var shortName: String {
        switch self {
        case .lrc:         return "LRC"
        case .enhancedLrc: return "增强 LRC"
        case .txt:         return "TXT"
        case .srt:         return "SRT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .lrc, .enhancedLrc: return "lrc"
        case .txt:               return "txt"
        case .srt:               return "srt"
        }
    }

    public var detail: String {
        switch self {
        case .lrc:
            return "标准行时间轴，绝大多数播放器都认。"
        case .enhancedLrc:
            return "A2 逐字扩展。只有歌词源提供逐字数据时才有意义，否则自动退回标准 LRC。"
        case .txt:
            return "只留歌词正文，去掉全部时间轴与 [ti:] 这类头部标签。"
        case .srt:
            return "字幕格式。需要歌词带时间轴；时间戳相同的原词与翻译会合成同一条字幕。"
        }
    }
}

/// 歌词文件的落盘编码。取值与界面层的 `LrcFileEncoding` 一一对应（rawValue 相同），
/// 旧偏好键能原样迁移过来。
public enum LyricsFileEncoding: Int, Codable, Sendable, CaseIterable, Identifiable {
    case utf8 = 0
    case utf8BOM = 1
    case gb18030 = 2
    case utf16LE = 3

    public var id: Int { rawValue }

    public var localizedName: String {
        switch self {
        case .utf8:    return "UTF-8"
        case .utf8BOM: return "UTF-8（含 BOM）"
        case .gb18030: return "GB18030（简体中文）"
        case .utf16LE: return "UTF-16 LE"
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .utf16LE: return .utf16LittleEndian
        }
    }

    public var needsBOM: Bool { self == .utf8BOM || self == .utf16LE }

    public var bom: Data {
        switch self {
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LE: return Data([0xFF, 0xFE])
        default:       return Data()
        }
    }
}

/// 歌词文件保存到哪儿。
public enum LyricsSaveLocation: Sendable, Equatable {
    /// 歌曲所在文件夹（最常用，播放器默认就在这里找同名 .lrc）。
    case songFolder
    /// 歌曲所在文件夹下的子目录，默认叫 `Lyrics`。
    case songSubfolder(name: String)
    /// 固定目录：全部歌词集中放一处。
    case fixedDirectory(URL)
    /// 每次询问：由界面层先弹面板解析成 `fixedDirectory` 再传进数据层。
    case askEachTime

    public static let defaultSubfolderName = "Lyrics"

    /// 供界面做单选组用的「种类」。带关联值的枚举本身不好直接绑 Picker。
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case songFolder, songSubfolder, fixedDirectory, askEachTime
        public var id: String { rawValue }
        public var localizedName: String {
            switch self {
            case .songFolder:     return "歌曲所在文件夹"
            case .songSubfolder:  return "歌曲文件夹下的子目录"
            case .fixedDirectory: return "自定义目录"
            case .askEachTime:    return "每次询问"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .songFolder:     return .songFolder
        case .songSubfolder:  return .songSubfolder
        case .fixedDirectory: return .fixedDirectory
        case .askEachTime:    return .askEachTime
        }
    }

    public var subfolderName: String {
        if case .songSubfolder(let n) = self {
            let t = n.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? Self.defaultSubfolderName : t
        }
        return Self.defaultSubfolderName
    }

    public var directoryURL: URL? {
        if case .fixedDirectory(let u) = self { return u }
        return nil
    }

    /// 换种类但尽量留住已填好的子目录名 / 自定义目录，避免用户切来切去就白填了。
    public func changingKind(_ kind: Kind,
                             subfolderName: String? = nil,
                             directory: URL? = nil) -> LyricsSaveLocation {
        switch kind {
        case .songFolder:    return .songFolder
        case .askEachTime:   return .askEachTime
        case .songSubfolder: return .songSubfolder(name: subfolderName ?? self.subfolderName)
        case .fixedDirectory:
            guard let dir = directory ?? directoryURL else { return .songFolder }
            return .fixedDirectory(dir)
        }
    }
}

extension LyricsSaveLocation: Codable {
    private enum CodingKeys: String, CodingKey { case kind, name, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .songFolder {
        case .songFolder:
            self = .songFolder
        case .askEachTime:
            self = .askEachTime
        case .songSubfolder:
            let n = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultSubfolderName
            self = .songSubfolder(name: n)
        case .fixedDirectory:
            let p = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            // 目录没了就退回歌曲文件夹，不让用户开着 App 却总是写不出来。
            self = p.isEmpty ? .songFolder : .fixedDirectory(URL(fileURLWithPath: p, isDirectory: true))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if case .songSubfolder(let n) = self { try c.encode(n, forKey: .name) }
        if case .fixedDirectory(let u) = self { try c.encode(u.path, forKey: .path) }
    }
}

/// 「保存歌词文件」的全部选项。持久化在 `AppSettings.lyricsFile`。
public struct LyricsFileOptions: Codable, Sendable, Equatable {

    /// 总开关。也是原先「保存标签的同时保存 Lrc 文件」那个开关的归宿。
    public var enabled: Bool
    public var format: LyricsFileFormat
    public var location: LyricsSaveLocation
    public var naming: LyricsService.LrcFileNaming
    public var encoding: LyricsFileEncoding
    /// 从 bundle 出发保存时是否合并翻译。已经合成好的文本不受影响。
    public var includeTranslation: Bool
    public var mergeFormat: TranslationMergeFormat
    /// 目标文件已存在时是否覆盖。默认否 —— 已有的 .lrc 多半是用户自己整过的。
    public var overwriteExisting: Bool
    /// 增强 LRC 用 `.a2.lrc` 后缀区分，默认不加（多数播放器只认 `.lrc`）。
    public var enhancedUsesA2Suffix: Bool

    public init(enabled: Bool = false,
                format: LyricsFileFormat = .lrc,
                location: LyricsSaveLocation = .songFolder,
                naming: LyricsService.LrcFileNaming = .sameAsAudio,
                encoding: LyricsFileEncoding = .utf8,
                includeTranslation: Bool = true,
                mergeFormat: TranslationMergeFormat = .twoLines,
                overwriteExisting: Bool = false,
                enhancedUsesA2Suffix: Bool = false) {
        self.enabled = enabled
        self.format = format
        self.location = location
        self.naming = naming
        self.encoding = encoding
        self.includeTranslation = includeTranslation
        self.mergeFormat = mergeFormat
        self.overwriteExisting = overwriteExisting
        self.enhancedUsesA2Suffix = enhancedUsesA2Suffix
    }

    public static let `default` = LyricsFileOptions()

    // 手写解码：缺键一律回落默认值。将来加字段，老用户的偏好也不会整份解不出来。
    private enum CodingKeys: String, CodingKey {
        case enabled, format, location, naming, encoding
        case includeTranslation, mergeFormat, overwriteExisting, enhancedUsesA2Suffix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LyricsFileOptions.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        format = try c.decodeIfPresent(LyricsFileFormat.self, forKey: .format) ?? d.format
        location = try c.decodeIfPresent(LyricsSaveLocation.self, forKey: .location) ?? d.location
        naming = try c.decodeIfPresent(LyricsService.LrcFileNaming.self, forKey: .naming) ?? d.naming
        encoding = try c.decodeIfPresent(LyricsFileEncoding.self, forKey: .encoding) ?? d.encoding
        includeTranslation = try c.decodeIfPresent(Bool.self, forKey: .includeTranslation) ?? d.includeTranslation
        mergeFormat = try c.decodeIfPresent(TranslationMergeFormat.self, forKey: .mergeFormat) ?? d.mergeFormat
        overwriteExisting = try c.decodeIfPresent(Bool.self, forKey: .overwriteExisting) ?? d.overwriteExisting
        enhancedUsesA2Suffix = try c.decodeIfPresent(Bool.self, forKey: .enhancedUsesA2Suffix) ?? d.enhancedUsesA2Suffix
    }
}

/// 一次落盘的结果。「跳过」不是错误，所以不用抛异常表达。
public struct LyricsFileWriteResult: Sendable {
    public enum Status: String, Sendable {
        /// 已写出。
        case written
        /// 目标文件字节完全一致，未重写（保住 mtime，也让重复调用成为空操作）。
        case unchanged
        /// 已存在且没开覆盖。
        case skippedExisting
        /// 渲染结果为空：没歌词，或导 SRT 时这段歌词压根没有时间轴。
        case skippedEmpty
        /// 复跑升级（BI 轮）：没开覆盖，但旧文件是本程序写出的**无译文**版、
        /// 新文本有译文 —— 按「纠错」覆盖。判据见 `shouldUpgradeExistingLyricsFile`。
        case upgraded
    }
    public var url: URL
    public var status: Status
    public var reason: String?

    /// 这一次是否真往磁盘写了字节。升级也写了 —— 批量统计里它和 `written` 一样算 succeeded。
    public var didWrite: Bool { status == .written || status == .upgraded }
    /// 是否属于「无译文旧文件 → 含译文新版」的升级。单独统计用。
    public var didUpgrade: Bool { status == .upgraded }
}

/// 批量落盘的一项输入。
public struct LyricsFileJob: Sendable {
    public var file: AudioFile
    /// 已经合成好的歌词文本。为空时会尝试从 `bundle` 现合。
    public var text: String
    /// 可选的原始 bundle：有它才可能产出真正的逐字增强 LRC。
    public var bundle: LyricsBundle?

    public init(file: AudioFile, text: String, bundle: LyricsBundle? = nil) {
        self.file = file
        self.text = text
        self.bundle = bundle
    }
}

// MARK: - 渲染与落盘

public extension LyricsService {

    // MARK: 逐字标记

    /// 文本里是否含 `<mm:ss.xx>` 这样的 A2 逐字标记。
    static func containsWordTimestamps(_ text: String) -> Bool {
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { return false }
            let inner = String(text[text.index(after: open)..<close])
            if LrcDocument.parseTimestamp(inner) != nil { return true }
            i = text.index(after: open)
            if i >= text.endIndex { break }
        }
        return false
    }

    /// 去掉 `<mm:ss.xx>` 逐字标记，只留字。非时间戳的 `<...>` 原样保留。
    static func strippingWordTimestamps(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "<",
                  let close = text[i...].firstIndex(of: ">") else {
                out.append(text[i]); i = text.index(after: i); continue
            }
            let inner = String(text[text.index(after: i)..<close])
            if LrcDocument.parseTimestamp(inner) != nil {
                i = text.index(after: close)          // 是逐字标记，整段吞掉
            } else {
                out.append(text[i]); i = text.index(after: i)
            }
        }
        return out
    }

    static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: 渲染

    /// 把一段歌词按目标格式渲染成文件内容。返回空串表示「没什么可写的」。
    static func renderLyricsFile(_ text: String,
                                 bundle: LyricsBundle? = nil,
                                 options: LyricsFileOptions) -> String {
        let raw = normalizedLineEndings(text)

        switch options.format {
        case .lrc:
            let doc = LrcDocument.parse(strippingWordTimestamps(raw))
            return doc.isEmpty ? "" : doc.render(millisecondDigits: 2)

        case .enhancedLrc:
            // 优先用源提供的逐字数据；文本本身就是 A2 也直接用；都没有就退回标准 LRC。
            if let k = bundle?.wordByWord,
               !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalizedLineEndings(k)
            }
            if containsWordTimestamps(raw) { return raw }
            let doc = LrcDocument.parse(raw)
            return doc.isEmpty ? "" : doc.render(millisecondDigits: 2)

        case .txt:
            let doc = LrcDocument.parse(strippingWordTimestamps(raw))
                .removingHeaderTags()
                .removingBlankLines()
            return doc.lines.map(\.text).joined(separator: "\n")

        case .srt:
            return renderSRT(raw)
        }
    }

    /// LRC → SRT。
    ///
    /// 起止时间取自相邻行：本行开始 → 下一行开始，最后一行 +5 秒。
    /// 时间戳相同的若干行（`原词 / 翻译` 两行式合并的产物）会**并成同一条字幕的多行**，
    /// 否则会得到一串起止相同的零长度字幕，播放器什么都不显示。
    static func renderSRT(_ text: String) -> String {
        let doc = LrcDocument.parse(normalizedLineEndings(text)).removingBlankLines()

        var flat: [(t: TimeInterval, s: String)] = []
        for line in doc.lines {
            let body = strippingWordTimestamps(line.text).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !line.timestamps.isEmpty else { continue }
            for t in line.timestamps { flat.append((t, body)) }
        }
        guard !flat.isEmpty else { return "" }
        flat.sort { $0.t < $1.t }

        // 同一时刻的多行并成一条
        var cues: [(t: TimeInterval, lines: [String])] = []
        for item in flat {
            if var last = cues.last, abs(last.t - item.t) < 0.01 {
                last.lines.append(item.s)
                cues[cues.count - 1] = last
            } else {
                cues.append((item.t, [item.s]))
            }
        }

        var out: [String] = []
        for (i, cue) in cues.enumerated() {
            let next = i + 1 < cues.count ? cues[i + 1].t : cue.t + 5
            let end = next > cue.t + 0.05 ? next : cue.t + 5
            out.append("\(i + 1)")
            out.append("\(srtTime(cue.t)) --> \(srtTime(end))")
            out.append(contentsOf: cue.lines)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm`。
    static func srtTime(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// 从 bundle 合出可写入的文本（尊重「合并翻译 / 合并格式」两项选项）。
    static func mergedText(from bundle: LyricsBundle, options: LyricsFileOptions) -> String {
        if options.format == .enhancedLrc,
           let k = bundle.wordByWord,
           !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return k
        }
        guard options.includeTranslation else { return bundle.plain ?? "" }
        return merge(plain: bundle.plain,
                     translated: bundle.translated,
                     format: options.mergeFormat) ?? (bundle.plain ?? "")
    }

    // MARK: 路径

    /// 目标目录。`askEachTime` 必须由界面层先解析成 `directoryOverride`；
    /// 没解析就退回歌曲所在文件夹，绝不在数据层弹面板。
    static func lyricsDirectory(for file: AudioFile,
                                options: LyricsFileOptions,
                                directoryOverride: URL? = nil) -> URL {
        if let directoryOverride { return directoryOverride }
        let songFolder = file.url.deletingLastPathComponent()
        switch options.location {
        case .songFolder, .askEachTime:
            return songFolder
        case .songSubfolder:
            return songFolder.appendingPathComponent(sanitize(options.location.subfolderName),
                                                     isDirectory: true)
        case .fixedDirectory(let dir):
            return dir
        }
    }

    /// 目标文件完整路径。
    static func lyricsFileURL(for file: AudioFile,
                              options: LyricsFileOptions,
                              directoryOverride: URL? = nil) -> URL {
        let dir = lyricsDirectory(for: file, options: options, directoryOverride: directoryOverride)
        var base = lyricsBaseName(for: file, naming: options.naming)
        if options.format == .enhancedLrc, options.enhancedUsesA2Suffix { base += ".a2" }
        return dir.appendingPathComponent(base).appendingPathExtension(options.format.fileExtension)
    }

    // MARK: 落盘

    /// 按编码（含 BOM）编成字节。
    static func encodeLyricsData(_ text: String, encoding: LyricsFileEncoding) throws -> Data {
        guard let body = sanitizedForFile(text)
            .data(using: encoding.stringEncoding, allowLossyConversion: true) else {
            throw TagError.writeFailed("歌词无法用 \(encoding.localizedName) 保存")
        }
        return encoding.needsBOM ? encoding.bom + body : body
    }

    /// 落盘前的最后一道清洗（BG 轮）。**歌词文件的所有写出路径都从 `encodeLyricsData` 过**，
    /// 所以只在这一处做就够了。
    ///
    /// 起因：用户报「文本编辑说 UTF-8 不适用」，而 `file(1)` 判定同一个 `.lrc` 是 UTF-8
    /// —— `file` 只嗅探开头几 KB，末尾的坏字节它看不见。
    ///
    /// 复查代码后的结论是**我们的写出链不可能产出非法 UTF-8**：
    /// Swift `String` 在类型层面就保证是合法 Unicode（非法字节在
    /// `String(data:encoding:.utf8)` 那一步就返回 nil 了，QRC/KRC 解密走的正是它），
    /// 而 `data(using: .utf8)` 对合法 String 必然产出合法 UTF-8。
    ///
    /// 但**合法 UTF-8 不等于文本编辑器打得开**：U+0000（NUL）与一堆 C0 控制符
    /// 是合法的 UTF-8 码位，却会让 TextEdit 直接判定「此编码不适用」。
    /// 这些字节有可能从源那边原样带进来（明文 LRC 的尾部填充、
    /// 解密载荷里没剥干净的块填充）。这里把它们剥掉：
    ///
    ///  · 删除 NUL 与除 `\n \r \t` 外的全部 C0 控制符（U+0001…U+001F）与 DEL（U+007F）；
    ///  · 删除零宽字符 U+200B…U+200D 与 BOM 混入正文的 U+FEFF（它们不显示，却会让
    ///    播放器的时间戳解析莫名其妙地失败）；
    ///  · 换行一律归一到 `\n`（`renderLyricsFile` 已经做过一次，这里兜底）。
    ///
    /// 假名、汉字、全角标点、emoji 一个都不动 —— 只动不可见的控制字节。
    static func sanitizedForFile(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var lastWasCR = false
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0D:                                   // CR → LF（CRLF 只留一个 LF）
                out.append("\n"); lastWasCR = true; continue
            case 0x0A:
                if lastWasCR { lastWasCR = false; continue }
                out.append("\n")
            case 0x09:
                out.append(u)
            case 0x00...0x1F, 0x7F:                      // 其余 C0 控制符与 DEL：删
                break
            case 0x200B...0x200D, 0xFEFF:                // 零宽 / 正文里的 BOM：删
                break
            default:
                out.append(u)
            }
            lastWasCR = false
        }
        return String(out)
    }

    // MARK: 复跑升级判定（BI 轮）
    //
    //  病象：`overwriteExisting` 默认关。用户早先用本程序写出的 `.lrc` 一句译文都没有；
    //  重新自动匹配 / 批量下载后标签里已经有译文了，`.lrc` 却因「已存在」被跳过，
    //  永远停在无译文的旧版 —— 开关的本意是「别动用户整过的文件」，
    //  可这些文件根本就是本程序自己写的。
    //
    //  主会话拍板：**旧 .lrc 是本程序写的、无译文，升级属纠错**，
    //  所以在关着覆盖的情况下**只放行这一种**覆盖，且要过四道闸门。

    /// 一份已解析的 LRC 里是否已经有「译文行」。
    ///
    /// 判据：**存在相邻两行共用同一时间戳**（容差 10 ms）。这正是 `.twoLines` /
    /// `.translationFirst` 两种合并格式的产物形状，也是含译文 .lrc 的实际长相。
    ///
    /// 刻意认不出的两种形状（一律判成「无译文」）：
    ///  · `.inline`（`[t]原词 翻译词`）—— 单看文本无法与「原词自带空格」区分；
    ///  · `.tripleRotate`（三行轮转）—— 每行时间戳各不相同，同样无从分辨。
    /// 判错的方向是安全的：**新**文本被判成无译文 → 不升级（少做一次好事）；
    /// **旧**文件被判成无译文 → 还得过后面两道保守闸门才会被覆盖。
    static func lrcContainsTranslationLines(_ doc: LrcDocument) -> Bool {
        let timed = doc.lines.filter { $0.hasTimestamp && !$0.isBlankText }
        guard timed.count >= 2 else { return false }
        for i in 1..<timed.count {
            guard let a = timed[i - 1].firstTimestamp,
                  let b = timed[i].firstTimestamp else { continue }
            if abs(a - b) < 0.01 { return true }
        }
        return false
    }

    /// 「原词行数」。
    /// - 无译文的文档：有时间轴的非空行数就是原词行数。
    /// - 含译文（两行式）的文档：两行共用同一个时间戳，**不同时间戳的个数**才是原词行数。
    static func lrcOriginalLineCount(_ doc: LrcDocument, hasTranslation: Bool) -> Int {
        let timed = doc.lines.filter { $0.hasTimestamp && !$0.isBlankText }
        guard hasTranslation else { return timed.count }
        var seen = Set<Int>()
        for line in timed {
            guard let t = line.firstTimestamp else { continue }
            seen.insert(Int((t * 100).rounded()))      // 10 ms 粒度去重
        }
        return seen.count
    }

    // MARK: 正文行（BJ 轮：第三方 .lrc 的头部/标题/署名行不算正文）
    //
    // ── 用户原话 ──「我新下的歌基本都会自带 lrc 的未翻译歌词，选了歌词下下来还是没翻译。」
    //
    // 病根在「原词行数差 ≤ 20%」那道闸拿**全部有时间戳的行**去比。第三方 .lrc 长这样：
    //
    //     [ti:Family Song (Live At …)]   ← LrcDocument.parse 已收进 headerTags，不进 lines
    //     [ar:星野源 (ほしの げん)]
    //     [al:]  [by:]  [offset:0]
    //     [00:00.00]Family Song (…) - 星野源 (…)      ← 标题行，不是词
    //     [00:04.63]词：星野源                          ← 署名行，不是词
    //     [00:09.26]曲：星野源
    //     [00:2x.xx]…正文从这里才开始…
    //
    // 三行「不是词的词」对上一份不带这些行的新文本，十几行的短曲直接超 20%，
    // 于是每一首都判 `skippedExisting` —— 用户看到的正是「选了歌词，.lrc 还是没翻译」。

    /// 中文平台歌词开头那几行署名的识别。`词：/曲：/编曲/制作/出品/OP/SP…`
    static let lrcCreditPrefixes: [String] = [
        "词", "曲", "作词", "作詞", "作曲", "编曲", "編曲", "改编", "改編",
        "制作", "製作", "制作人", "製作人", "监制", "監製", "出品", "发行", "發行",
        "混音", "母带", "母帶", "录音", "錄音", "和声", "和聲", "吉他", "贝斯", "貝斯",
        "鼓", "键盘", "鍵盤", "弦乐", "弦樂", "企划", "企劃", "统筹", "統籌",
        "lyrics", "lyricist", "composer", "composed by", "written by", "arranger",
        "arranged by", "produced by", "producer", "mixing", "mastering",
        "op", "sp", "音乐制作人", "音樂製作人"
    ]

    /// 这一行是不是「署名行」：`作词 : X` / `词：X` / `Lyrics by X`。
    /// 分隔符认 `：`、`:`、`/`，前缀必须落在 `lrcCreditPrefixes` 里 ——
    /// 只认前缀而不认分隔符会把正常歌词里以「词」开头的句子误伤掉。
    static func lrcLineIsCredit(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // 取第一个分隔符之前的那一段当「键」
        guard let sep = t.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return false }
        let key = String(t[..<sep])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !key.isEmpty, key.count <= 12 else { return false }
        return lrcCreditPrefixes.contains { $0.replacingOccurrences(of: " ", with: "") == key }
    }

    /// 这一行是不是「标题行」：`Family Song (Live At …) - 星野源 (ほしの げん)`。
    /// 只在**开头 1 秒内**认（第三方 .lrc 一律把它放在 `[00:00.00]`），
    /// 否则正常歌词里带破折号的句子会被误当标题。
    static func lrcLineLooksLikeTitleCredit(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.contains(" - ") || t.contains(" − ") || t.contains(" — ") else { return false }
        return true
    }

    /// 「正文行」：把 `[ti:…]` 这类头（`LrcDocument.parse` 已经替我们摘掉了）、
    /// 开头的标题行与署名行、空行全部剔掉之后剩下的那些行。
    ///
    /// 署名行只在**正文开始之前**认：一旦出现第一行真正的词，后面再出现
    /// 「作词：」形状的句子就当正文（歌里真这么唱也不是没有），不再继续剔。
    static func lrcBodyLines(_ doc: LrcDocument) -> [LrcLine] {
        var out: [LrcLine] = []
        var inPreamble = true
        for line in doc.lines {
            guard !line.isBlankText else { continue }
            if inPreamble {
                let t = line.text.trimmingCharacters(in: .whitespaces)
                let stamp = line.firstTimestamp ?? 0
                if lrcLineIsCredit(t) { continue }
                if stamp <= 0.99, lrcLineLooksLikeTitleCredit(t) { continue }
                inPreamble = false
            }
            out.append(line)
        }
        return out
    }

    /// 正文的「原词行数」。含译文（两行式）的文档里两行共用一个时间戳，
    /// **不同时间戳的个数**才是原词行数（口径同 `lrcOriginalLineCount`）。
    static func lrcBodyOriginalLineCount(_ doc: LrcDocument, hasTranslation: Bool) -> Int {
        let body = lrcBodyLines(doc).filter { $0.hasTimestamp }
        guard hasTranslation else { return body.count }
        var seen = Set<Int>()
        for line in body {
            guard let t = line.firstTimestamp else { continue }
            seen.insert(Int((t * 100).rounded()))      // 10 ms 粒度去重
        }
        return seen.count
    }

    /// 正文首行的原词文本（含译文时每个时间戳只取**第一行** = 原文）。
    /// 「同一首」判定拿它去比，比行数稳得多。
    static func lrcBodyOriginalTexts(_ doc: LrcDocument, hasTranslation: Bool) -> [String] {
        let body = lrcBodyLines(doc).filter { $0.hasTimestamp }
        guard hasTranslation else { return body.map(\.text) }
        var seen = Set<Int>()
        var out: [String] = []
        for line in body {
            guard let t = line.firstTimestamp else { continue }
            if seen.insert(Int((t * 100).rounded())).inserted { out.append(line.text) }
        }
        return out
    }

    /// 比对用的归一：去掉所有空白（全角半角都算），再转小写。
    static func lrcComparableText(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "\u{3000}", with: "")
            .lowercased()
    }

    /// **同曲判定**：旧文件正文前 5 行里有 ≥3 行能在新原文里找到（去空白后相等）。
    /// 成立就认定是同一首 —— 行数差这时候不再作为否决条件
    /// （第三方 .lrc 常常少几行间奏、多几行罗马音，行数本来就对不齐）。
    static func lrcLooksLikeSameSong(oldTexts: [String], newTexts: [String]) -> (same: Bool, hits: Int, checked: Int) {
        let probe = Array(oldTexts.prefix(5)).map(lrcComparableText).filter { !$0.isEmpty }
        guard !probe.isEmpty else { return (false, 0, 0) }
        let pool = Set(newTexts.map(lrcComparableText).filter { !$0.isEmpty })
        let hits = probe.filter { pool.contains($0) }.count
        return (hits >= min(3, probe.count), hits, probe.count)
    }

    /// 旧文件里有没有「用户手改的痕迹」：既没有时间轴、又没被 `LrcDocument` 收进
    /// `headerTags`（`[ti:/ar:/al:/by:/offset:]` 这类已知头部标签）的**自由文本行**。
    /// 有一行就够 —— 那份文件已经不是本程序的原样产物，一个字节都不碰。
    static func lrcContainsFreeTextLines(_ doc: LrcDocument) -> Bool {
        doc.lines.contains { !$0.hasTimestamp && !$0.isBlankText }
    }

    /// 把已存在的歌词文件字节解回文本。编码嗅探口径与 `importLrc` 一致
    /// （BOM → UTF-8 → GB18030 → Big5 → Latin-1），失败返回 nil（失败即不升级）。
    static func decodeLyricsFileText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: big5)) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 「已存在 + 没开覆盖」时，这一次到底算不算**纠错式升级**。
    ///
    /// 四条必要条件，缺一律回落 `.skippedExisting`（文件一个字节都不动）：
    ///  1. **目标是 LRC**（`.lrc` / 增强 `.lrc`）。`.txt` / `.srt` 没有「译文行」这个概念。
    ///  2. **新文本有译文**：`bundle?.hasTranslation == true`，
    ///     或渲染结果自身已呈现译文行形状 —— 走 `AppModel` 的那条路不带 bundle，
    ///     合并好的文本就是唯一信息源，只认 bundle 等于这条路永远升不了级。
    ///  3. **旧文件没有译文**：`LrcDocument.parse` 后不存在「相邻两行同一时间戳」。
    ///  4. **旧文件没有手改痕迹、且看得出是同一首**：
    ///     不含自由文本行（用户手改痕迹）；同一首的判据两选一（BJ 轮放宽）——
    ///     正文前 5 行有 ≥3 行能在新原文里找到，**或**正文行数相差 ≤ 35%。
    ///     行数只数**正文**：`[ti:…]` 头、开头的「标题 - 艺术家」与「词：/曲：」
    ///     署名行都不算（第三方 .lrc 普遍带这三样，算进去短曲必超阈值）。
    ///
    /// 返回 `reason` 一并给到 `LyricsFileWriteResult`，界面上「跳过的原因」照旧有话说。
    static func shouldUpgradeExistingLyricsFile(existing: Data,
                                                rendered: String,
                                                bundle: LyricsBundle?,
                                                options: LyricsFileOptions)
        -> (upgrade: Bool, reason: String) {

        let plainSkip = "文件已存在且未开启覆盖"

        // ① 只有 LRC 谈得上「含不含译文」
        guard options.format == .lrc || options.format == .enhancedLrc else {
            return (false, plainSkip)
        }

        // ② 新文本必须真的有译文
        let newDoc = LrcDocument.parse(strippingWordTimestamps(normalizedLineEndings(rendered)))
        let newHasTranslation = (bundle?.hasTranslation == true)
            || lrcContainsTranslationLines(newDoc)
        guard newHasTranslation else { return (false, plainSkip) }

        guard let oldText = decodeLyricsFileText(existing) else {
            return (false, plainSkip + "（旧文件编码读不出）")
        }
        let oldDoc = LrcDocument.parse(strippingWordTimestamps(normalizedLineEndings(oldText)))

        // ③ 旧文件已经有译文 → 不是「升级」，轮不到我们动
        guard !lrcContainsTranslationLines(oldDoc) else {
            return (false, plainSkip + "（旧文件已含译文）")
        }

        // ④a 手改痕迹 → 一律不动
        guard !lrcContainsFreeTextLines(oldDoc) else {
            return (false, plainSkip + "（旧文件有手改痕迹，不动）")
        }

        // ④b 是不是同一首 —— 两把尺子，**任意一把过就放行**（BJ 轮放宽）。
        //
        // 只数**正文行**：`[ti:…]` 那些头由 `LrcDocument.parse` 摘走，
        // 开头的「标题 - 艺术家」与「词：/曲：」署名行由 `lrcBodyLines` 摘走。
        // 第三方 .lrc 的那三行「不是词的词」原先全算进分母，短曲一比就超 20%，
        // 于是每一首都判 skippedExisting —— 用户说的「下下来还是没翻译」就是它。
        //
        // 尺子一：**内容比对**（主判据）。旧文件正文前 5 行有 ≥3 行能在新原文里
        //         找到 → 同一首，行数差不再否决（第三方词表少几行间奏、
        //         多几行罗马音，行数本来就对不齐）。
        // 尺子二：行数差 ≤ 35%（原 20%）。内容比对不成立时的兜底 ——
        //         译文版把日文正文整段替换成另一种写法时内容对不上，但行数还在。
        let oldCount = lrcBodyOriginalLineCount(oldDoc, hasTranslation: false)
        let newCount = lrcBodyOriginalLineCount(newDoc, hasTranslation: true)
        guard oldCount > 0, newCount > 0 else { return (false, plainSkip) }

        let oldTexts = lrcBodyOriginalTexts(oldDoc, hasTranslation: false)
        let newTexts = lrcBodyOriginalTexts(newDoc, hasTranslation: true)
        let same = lrcLooksLikeSameSong(oldTexts: oldTexts, newTexts: newTexts)

        // 同曲判定**只免行数闸，不免「别把词写少了」**。
        // 旧 8 行 → 新 4 行也能判成同一首（前 4 行一字不差），但那是一份**残缺**的词，
        // 拿它盖掉完整的旧词是净损失 —— 升级的本意是「补上译文」，不是「换成更短的」。
        // 所以内容对得上时也要求新文本不比旧的短太多；真短了就交回行数闸去判。
        let notShrinking = Double(newCount) >= Double(oldCount) * 0.8
        let sameSong = same.same && notShrinking

        let delta = Double(abs(oldCount - newCount)) / Double(max(oldCount, newCount))
        guard sameSong || delta <= 0.35 else {
            var why = "（正文旧 \(oldCount) 行 vs 新 \(newCount) 行，差异 "
                + String(format: "%.0f%%", delta * 100)
            why += same.same
                ? "；内容对得上，但新词比旧词短太多，不拿短的盖长的）"
                : "；前 \(same.checked) 行只对上 \(same.hits) 行，疑非同一首）"
            return (false, plainSkip + why)
        }

        let how = sameSong
            ? "正文前 \(same.checked) 行对上 \(same.hits) 行，判为同一首"
            : String(format: "正文行数差 %.0f%%", delta * 100)
        return (true, "旧文件无译文，已升级为含译文版（正文 \(oldCount) → \(newCount) 行；\(how)）")
    }

    /// 保存一份歌词文件，返回详细结果（写了 / 内容一致 / 跳过 / 升级）。
    ///
    /// - 目标文件已存在且 `overwriteExisting == false` → `.skippedExisting`，返回现有路径。
    ///   **唯一的例外**是「无译文旧文件 + 有译文新文本」这一种纠错式升级 → `.upgraded`，
    ///   判据全在 `shouldUpgradeExistingLyricsFile`（BI 轮）。
    /// - 目标文件字节与本次要写的完全一致 → `.unchanged`，不动磁盘。
    ///   这一条让「自动匹配写完 + 收尾再走一遍」这类重复调用天然幂等。
    @discardableResult
    static func writeLyricsFile(_ text: String,
                                bundle: LyricsBundle? = nil,
                                for file: AudioFile,
                                options: LyricsFileOptions,
                                directoryOverride: URL? = nil) throws -> LyricsFileWriteResult {
        let target = lyricsFileURL(for: file, options: options,
                                   directoryOverride: directoryOverride)
        let rendered = renderLyricsFile(text, bundle: bundle, options: options)

        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let why = options.format == .srt
                ? "这段歌词没有时间轴，无法导出 SRT 字幕"
                : "歌词为空"
            return LyricsFileWriteResult(url: target, status: .skippedEmpty, reason: why)
        }

        let data = try encodeLyricsData(rendered, encoding: options.encoding)
        let fm = FileManager.default
        /// 非空 = 这一次是纠错式升级，落盘后要报 `.upgraded` 而不是 `.written`。
        var upgradeReason: String?

        if fm.fileExists(atPath: target.path) {
            let existing = try? Data(contentsOf: target)
            if let existing, existing == data {
                return LyricsFileWriteResult(url: target, status: .unchanged, reason: "内容一致")
            }
            if !options.overwriteExisting {
                // 没开覆盖：只有「本程序写的无译文旧版 → 含译文新版」这一种纠错放行。
                let verdict = existing.map {
                    shouldUpgradeExistingLyricsFile(existing: $0, rendered: rendered,
                                                    bundle: bundle, options: options)
                } ?? (upgrade: false, reason: "文件已存在且未开启覆盖")
                guard verdict.upgrade else {
                    return LyricsFileWriteResult(url: target, status: .skippedExisting,
                                                 reason: verdict.reason)
                }
                upgradeReason = verdict.reason
            }
        }

        let dir = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: target, options: .atomic)
        return LyricsFileWriteResult(url: target,
                                     status: upgradeReason == nil ? .written : .upgraded,
                                     reason: upgradeReason)
    }

    /// 便捷版：只要落点路径。跳过也返回目标路径（与 `overwriteExisting=false` 的口径一致）。
    @discardableResult
    static func saveLyricsFile(_ text: String,
                               bundle: LyricsBundle? = nil,
                               for file: AudioFile,
                               options: LyricsFileOptions,
                               directoryOverride: URL? = nil) throws -> URL {
        try writeLyricsFile(text, bundle: bundle, for: file,
                            options: options, directoryOverride: directoryOverride).url
    }

    /// 从 bundle 出发保存（搜索窗、批量下载用）。
    @discardableResult
    static func saveLyricsFile(_ bundle: LyricsBundle,
                               for file: AudioFile,
                               options: LyricsFileOptions,
                               directoryOverride: URL? = nil) throws -> URL {
        try saveLyricsFile(mergedText(from: bundle, options: options),
                           bundle: bundle, for: file,
                           options: options, directoryOverride: directoryOverride)
    }

    /// 批量落盘。统计口径与 `BatchEngine` 一致：
    /// 写出 = succeeded，跳过/内容一致 = ignored，抛错 = failed。
    /// **升级（`.upgraded`）也是真写了字节，算 succeeded**；要单独报「升级了几个」，
    /// 数返回的 `results` 里 `didUpgrade` 的条数（界面层就是这么做的）。
    static func saveLyricsFiles(_ jobs: [LyricsFileJob],
                                options: LyricsFileOptions,
                                directoryOverride: URL? = nil)
        -> (written: [URL], results: [LyricsFileWriteResult], summary: BatchSummary) {

        var written: [URL] = []
        var results: [LyricsFileWriteResult] = []
        var failures: [(url: URL, error: TagError)] = []
        var ignoredItems: [(url: URL, reason: String)] = []
        let started = Date()

        for job in jobs {
            let text = job.text.isEmpty
                ? (job.bundle.map { mergedText(from: $0, options: options) } ?? "")
                : job.text
            do {
                let r = try writeLyricsFile(text, bundle: job.bundle, for: job.file,
                                            options: options,
                                            directoryOverride: directoryOverride)
                results.append(r)
                if r.didWrite {
                    written.append(r.url)
                } else {
                    ignoredItems.append((job.file.url, r.reason ?? r.status.rawValue))
                }
            } catch {
                let te = (error as? TagError) ?? .writeFailed(error.localizedDescription)
                failures.append((job.file.url, te))
            }
        }

        let summary = BatchSummary(succeeded: written.count,
                                   failed: failures.count,
                                   ignored: ignoredItems.count,
                                   total: jobs.count,
                                   failures: failures,
                                   ignoredItems: ignoredItems,
                                   elapsed: Date().timeIntervalSince(started))
        return (written, results, summary)
    }
}

// MARK: - 版本感知的取词 + 译文移植（BG 轮）
//
//  实测症状（某日文歌手目录，2026-09-11）：
//  目录里 100 多个 `.lrc` **全是日语、一句翻译都没有**，而「下载翻译」是勾着的；
//  更糟的是 `Family Song (Live At MUSIC STATION SUPER LIVE20171222)` 的
//  `[ti:]` 写着 `Family Song (Live At CDTV SP! Christmas音楽祭20171225)`——
//  匹到了**另一场 Live**。
//
//  逐源实测（`cnlyric`，见 `research/BG-…报告.md` §一）后，病灶有两条，
//  和「源不给译文」毫无关系：
//
//  ① **搜索词带着长后缀**。`Family Song (Live At MUSIC STATION SUPER LIVE20171222) 星野源`
//     整串送进各源，召回的全是「同一首歌的一堆 Live」，而版本差异在旧打分里
//     被 `stripQualifiers` 一折了事 —— 于是「哪一场」全凭专辑/年份这些弱信号决定，
//     20171225 那场赢了 20171222 那场。
//  ② **Live / MV版 / Remix 版本本身就没有官方译文**。
//     `恋 (2023 NHK SONGS现场)`（酷狗）、`読書 (remix)`（酷狗）实测都是
//     「有逐字、有罗马音、**没有翻译**」；而同一首歌的**录音室版**三家都给译文。
//     旧逻辑拿到「有词无译文」就收工，用户永远等不到那份译文。
//
//  本层的处置：
//    · 搜索用 `VersionInfo.baseTitle`，打分用 marker 维度（见 `MatchScorer`）；
//    · 选中的版本没有译文时，取**录音室版**的 `plain + translated`，
//      按歌词行做文本对齐，把译文搬到本版本自己的时间轴上（`transplantTranslation`）；
//    · 两边都没有译文时，明说「各源均无翻译」，让复核表看得见，而不是默默交白卷。

/// 一次「译文移植」的记账。进 probe 输出与复核表的说明行。
public struct LyricsTransplantReport: Sendable, Equatable {
    public var applied: Bool
    /// 供体（录音室版）的曲名与源。
    public var donorTitle: String?
    public var donorSourceID: String?
    /// 对上的行数 / 没对上的行数 / 本版本的歌词正文行数。
    public var aligned: Int
    public var unaligned: Int
    public var total: Int
    public var note: String

    public init(applied: Bool, donorTitle: String? = nil, donorSourceID: String? = nil,
                aligned: Int = 0, unaligned: Int = 0, total: Int = 0, note: String = "") {
        self.applied = applied; self.donorTitle = donorTitle
        self.donorSourceID = donorSourceID
        self.aligned = aligned; self.unaligned = unaligned; self.total = total
        self.note = note
    }
}

/// 单个源在这一次取词里的记账。probe 的「各源候选」表直接读它。
public struct LyricsSourceTrace: Sendable {
    public var sourceID: String
    public var candidateCount: Int
    public var pickedTitle: String?
    public var pickedAlbum: String?
    public var pickedVersion: String
    public var versionScore: Double
    public var score: Double
    public var duration: TimeInterval
    public var hasLyrics: Bool
    public var hasTranslation: Bool
    public var hasWordByWord: Bool
    public var latency: TimeInterval
    public var error: String?

    public init(sourceID: String, candidateCount: Int = 0,
                pickedTitle: String? = nil, pickedAlbum: String? = nil,
                pickedVersion: String = "-", versionScore: Double = 0,
                score: Double = 0, duration: TimeInterval = 0,
                hasLyrics: Bool = false, hasTranslation: Bool = false,
                hasWordByWord: Bool = false, latency: TimeInterval = 0,
                error: String? = nil) {
        self.sourceID = sourceID; self.candidateCount = candidateCount
        self.pickedTitle = pickedTitle; self.pickedAlbum = pickedAlbum
        self.pickedVersion = pickedVersion; self.versionScore = versionScore
        self.score = score; self.duration = duration
        self.hasLyrics = hasLyrics; self.hasTranslation = hasTranslation
        self.hasWordByWord = hasWordByWord; self.latency = latency; self.error = error
    }
}

/// 一次版本感知取词的完整结果。`fetch` / `bestLyrics` / 自动匹配的补查**都走它**，
/// 免得三条路各自演化出三套版本规则。
public struct LyricsResolution: Sendable {
    public var version: VersionInfo
    /// 实际送给各源的检索词（已剥版本后缀）。
    public var searchTerm: String
    public var best: LyricsCandidate?
    public var candidates: [LyricsCandidate]
    public var attempts: [SourceAttempt]
    public var traces: [LyricsSourceTrace]
    public var filteredInstrumental: Int
    public var transplant: LyricsTransplantReport?
    /// 说给用户听的话（「各源均无翻译」「翻译来自录音室版」…）。
    public var notes: [String]
    public var errors: [(sourceID: String, message: String)]

    public init(version: VersionInfo, searchTerm: String = "",
                best: LyricsCandidate? = nil, candidates: [LyricsCandidate] = [],
                attempts: [SourceAttempt] = [], traces: [LyricsSourceTrace] = [],
                filteredInstrumental: Int = 0,
                transplant: LyricsTransplantReport? = nil,
                notes: [String] = [],
                errors: [(sourceID: String, message: String)] = []) {
        self.version = version; self.searchTerm = searchTerm
        self.best = best; self.candidates = candidates
        self.attempts = attempts; self.traces = traces
        self.filteredInstrumental = filteredInstrumental
        self.transplant = transplant; self.notes = notes; self.errors = errors
    }

    public var bundle: LyricsBundle? { best?.bundle }
    public var sourceOutcomes: [SourceOutcome] { SourceOutcome.from(attempts).sortedByPriority() }
}

/// 进程级开关的存储。单独一个类型装静态量，和 `ChineseVariant._onlineDefault` 同构。
enum LyricsTransplantSwitch {
    nonisolated(unsafe) static var enabled = true
    static let lock = NSLock()
}

public extension LyricsService {

    // MARK: 进程级开关

    /// 「录音室版译文 → 本版本时间轴」的移植开关。默认开。
    ///
    /// 落地方式与 `ChineseVariant.onlineDefault` 一模一样（见那里的注释）：
    /// `AppSettings` 在 init 与每次切换时把 `MacTagger.lyrics.transplantTranslation`
    /// 推给这一个静态量，数据层各入口以它为缺省值。probe 用 `--no-transplant` 显式覆盖。
    ///
    /// TODO（留给后续轮次接线）：界面上还没有这个开关，
    /// 设置页「歌词」那一组里加一行复选框即可，键名已经定死。
    static var transplantTranslationEnabled: Bool {
        get {
            LyricsTransplantSwitch.lock.lock()
            defer { LyricsTransplantSwitch.lock.unlock() }
            return LyricsTransplantSwitch.enabled
        }
        set {
            LyricsTransplantSwitch.lock.lock()
            LyricsTransplantSwitch.enabled = newValue
            LyricsTransplantSwitch.lock.unlock()
        }
    }

    /// 「版本相符」的判定线。0.6 以上算同一份录音的同一个版本。
    static let versionAcceptThreshold: Double = 0.6

    // MARK: 核心：版本感知取词

    /// 版本感知的取词。**`fetch` / `bestLyrics` / 自动匹配补查共用这一处实现。**
    ///
    /// - Parameters:
    ///   - query: 本地文件的查询（标题带版本后缀就行，这里自己剥）。
    ///   - sourceIDs: 按优先级排列的歌词源。空 = 注册表里全部支持歌词的源。
    ///   - stopWhenSatisfied: 拿到「版本相符 + 有译文」的那一份就收工，不再问后面的源。
    ///   - transplant: 覆盖进程级的移植开关。nil = 用 `transplantTranslationEnabled`。
    static func resolve(query: TrackQuery,
                        sourceIDs: [String] = translationSourceOrder,
                        limitPerSource: Int = 8,
                        skipInstrumental: Bool = true,
                        includeTranslation: Bool = true,
                        stopWhenSatisfied: Bool = true,
                        transplant: Bool? = nil,
                        minimumScore: Double = 0,
                        softDeadline: TimeInterval = 0,
                        chineseVariant: ChineseVariantPolicy? = nil) async -> LyricsResolution {

        let policy = chineseVariant ?? ChineseVariant.onlineDefault
        let allowTransplant = transplant ?? transplantTranslationEnabled

        // ① 拆版本
        let rawTitle = [query.title, query.filename]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let version = VersionMarker.parse(rawTitle)

        var out = LyricsResolution(version: version)
        guard !query.isEmpty else {
            out.notes.append("查询为空，没有可用的曲名或文件名")
            return out
        }

        // ② 搜索用正题。**打分仍用原始 query**（含后缀），版本维度靠 `versionQuery` 走。
        var searchQuery = query
        if let t = query.title, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            searchQuery.title = version.baseTitle
        } else if let f = query.filename, !f.trimmingCharacters(in: .whitespaces).isEmpty {
            searchQuery.filename = version.baseTitle
        }
        out.searchTerm = searchQuery.searchTerm

        let registry = SourceRegistry.shared
        let sources: [any MetadataSource] = sourceIDs.isEmpty
            ? registry.sources(supporting: .lyrics)
            : sourceIDs.compactMap { registry.source(id: $0) }
                .filter { $0.capabilities.contains(.lyrics) }

        // 这首本来就要伴奏版时，「跳过伴奏」这条规则要让路，否则永远搜不到。
        let wantsInstrumental = version.kinds.contains(.instrumental)
        let needTranslation = includeTranslation && wantsTranslation(query)

        /// 候选池：所有源的全部候选（已打分），供后面找「录音室版供体」时复用，
        /// 不必为了移植再搜一轮。
        var pool: [TrackCandidate] = []

        // ★ BH 轮软截止。译文补查是自动匹配里最贵的一段：源是**串行**问的，
        // 一家慢就把整首拖住，而它换来的只是「有没有多一行译文」。
        //
        // 两条边界，都是为了「宁可少等，也不要交白卷」：
        // ① 只拦**还没开始**的源，绝不打断已经飞出去的那一发 —— 半路取消拿不到任何东西，
        //    等于把已经花掉的时间白扔。
        // ② 至少问过一家才允许截止。否则第一家刚好慢一点就一个源都不问，
        //    整轮补查形同虚设。
        // `<= 0` 关闭（旧行为，问完为止）。
        let deadline: Date? = softDeadline > 0 ? Date().addingTimeInterval(softDeadline) : nil

        for src in sources {
            if let deadline, !out.attempts.isEmpty, Date() >= deadline {
                out.notes.append(String(format: "已超软截止 %.1f s，剩余 %d 个源不再问",
                                        softDeadline,
                                        sources.count - out.attempts.count))
                break
            }
            let started = Date()
            do {
                let found = try await src.searchTracks(searchQuery, limit: limitPerSource)
                var usable = found
                if skipInstrumental, !wantsInstrumental {
                    let before = usable.count
                    usable = usable.filter { !isInstrumental($0.title) }
                    out.filteredInstrumental += before - usable.count
                }
                let ranked = MatchScorer.rank(usable, for: query, versionQuery: version)
                pool.append(contentsOf: ranked)

                guard let pick = ranked.first else {
                    out.attempts.append(SourceAttempt(sourceID: src.id, outcome: .empty, message: nil))
                    out.traces.append(LyricsSourceTrace(sourceID: src.id, candidateCount: 0,
                                                        latency: Date().timeIntervalSince(started)))
                    continue
                }

                // ★ 「宁可不写，也不写错」这道闸要保住（旧 `fetch` 里是
                // `MatchScorer.best(minimumScore: 0.6)`，本轮改走 resolve 时差点弄丢）。
                //
                // 判据刻意用**不含版本维度**的分数 —— 也就是旧代码那把尺子一字不差。
                // 不能用版本分参与后的总分：`Family Song (Live…)` 的录音室版候选
                // 会因为版本项 0.55 + 时长重罚掉到 0.42，它**不是错的歌**，只是版本次优，
                // 拿它当「低于阈值」砍掉就会把一首本来能出词的歌变成交白卷。
                // 版本维度负责**排序**，这道闸负责**兜底不接受另一首歌**（网易云给
                // `解答者 (Live)` 返回过「喜劇」、给 `恋 (Live)` 返回过
                // 「2 (feat. Lee Youngji)」，正是这道闸该挡下来的东西）。
                if minimumScore > 0 {
                    let plain = MatchScorer.score(pick, for: query)
                    guard plain >= minimumScore else {
                        out.attempts.append(SourceAttempt(sourceID: src.id, outcome: .empty,
                                                          message: nil))
                        out.traces.append(LyricsSourceTrace(
                            sourceID: src.id, candidateCount: ranked.count,
                            pickedTitle: pick.title, pickedAlbum: pick.album,
                            pickedVersion: VersionMarker.parse(pick.title).summary,
                            versionScore: MatchScorer.versionSimilarity(pick.title, query: version),
                            score: plain, duration: pick.durationSeconds,
                            latency: Date().timeIntervalSince(started),
                            error: String(format: "最佳候选只有 %.3f 分，低于阈值 %.2f，按「宁可不写」丢弃",
                                          plain, minimumScore)))
                        continue
                    }
                }

                let bundle = normalized(try await src.fetchLyrics(pick), policy)
                let converted = pick.converted(to: policy)
                out.candidates.append(LyricsCandidate(track: converted, bundle: bundle))
                out.attempts.append(SourceAttempt(sourceID: src.id,
                                                  outcome: .succeeded(ranked.count), message: nil))

                let vs = MatchScorer.versionSimilarity(pick.title, query: version)
                out.traces.append(LyricsSourceTrace(
                    sourceID: src.id, candidateCount: ranked.count,
                    pickedTitle: converted.title, pickedAlbum: converted.album,
                    pickedVersion: VersionMarker.parse(pick.title).summary,
                    versionScore: vs, score: pick.matchScore,
                    duration: pick.durationSeconds,
                    hasLyrics: bundle?.isEmpty == false,
                    hasTranslation: bundle?.hasTranslation == true,
                    hasWordByWord: bundle?.wordByWord?.isEmpty == false,
                    latency: Date().timeIntervalSince(started)))

                // 收工条件：**版本相符 且 有译文**（或这首本来就不需要译文）。
                // 只有「有词」就收工正是旧实现的病 —— 那样永远拿不到译文。
                if stopWhenSatisfied,
                   bundle?.isEmpty == false,
                   vs >= versionAcceptThreshold,
                   !needTranslation || bundle?.hasTranslation == true { break }
            } catch {
                out.errors.append((src.id, error.localizedDescription))
                out.attempts.append(SourceAttempt(sourceID: src.id, outcome: .failed,
                                                  message: error.localizedDescription))
                out.traces.append(LyricsSourceTrace(sourceID: src.id,
                                                    latency: Date().timeIntervalSince(started),
                                                    error: error.localizedDescription))
            }
        }

        // ③ 选出最好的一份。排序四级：
        //    ① 有词 ② **版本相符** ③ 有译文 ④ 匹配分
        //    「版本相符」排在「有译文」之前，是因为译文可以移植、时间轴不能 ——
        //    拿别的版本的时间轴配本版本的音频，整首都是错位的。
        out.best = out.candidates
            .sorted { a, b in
                let ax = (a.bundle?.isEmpty == false) ? 1 : 0
                let bx = (b.bundle?.isEmpty == false) ? 1 : 0
                if ax != bx { return ax > bx }
                let av = MatchScorer.versionSimilarity(a.track.title, query: version)
                let bv = MatchScorer.versionSimilarity(b.track.title, query: version)
                let ao = av >= versionAcceptThreshold ? 1 : 0
                let bo = bv >= versionAcceptThreshold ? 1 : 0
                if ao != bo { return ao > bo }
                let at = (a.bundle?.hasTranslation ?? false) ? 1 : 0
                let bt = (b.bundle?.hasTranslation ?? false) ? 1 : 0
                if at != bt { return at > bt }
                return a.score > b.score
            }
            .first

        guard var best = out.best else {
            out.notes.append("各源都没有搜到可用候选")
            return out
        }

        // ④ 版本没配上的时候要说一声。
        //
        // 用得着这句话的场景很实在：`Family Song (Live At …20171222)` 这首，
        // 各源**有时**返回那一场、有时只返回录音室版（QQ 的搜索链 lite/official/smartbox
        // 哪一级应答不由我们决定）。只返回录音室版时我们仍然会用它 —— 有词总比没词好 ——
        // 但它的时间轴是录音室版的，配 Live 音频必然对不齐，用户有权知道。
        //
        // 注：**文件时长是分辨版本最硬的那根杠杆**（录音室版 4:31 vs 本场 5:04）。
        // 真实路径上 `AutoMatchService.makeQuery(from:)` 会带上文件时长，
        // 带了时长这一条几乎不会触发；不带时长（比如拿 2 秒的测试样本跑）才常见。
        if !version.isStudio {
            let bv = MatchScorer.versionSimilarity(best.track.title, query: version)
            // **时长对上了就不报警**。各源的曲名标注很随意：同一份 5:04 的 Live 录音，
            // QQ 有时返回 `Family Song (Live At MUSIC STATION SUPER LIVE20171222)`、
            // 酷狗返回的就是光秃秃的 `Family Song`（实测两种都见过）。
            // 后缀没写不代表录音不对 —— 时长差 ≤3 秒是比曲名后缀**更硬**的证据，
            // 此时报「没找到这一版本」纯属误报。
            let durationConfirms = query.duration >= MatchScorer.minimumPlausibleQueryDuration
                && best.track.durationSeconds > 0
                && abs(best.track.durationSeconds - query.duration) <= MatchScorer.exactDurationTolerance
            if bv < versionAcceptThreshold, !durationConfirms {
                out.notes.append("各源都没有「\(version.summary)」这一版本，"
                    + "用的是《\(best.track.title ?? "-")》（时间轴可能对不齐本版本音频）")
            }
        }

        // ⑤ 译文移植
        guard needTranslation else { return out }
        if best.bundle?.hasTranslation == true { return out }

        guard allowTransplant else {
            out.notes.append("本版本各源均无翻译；移植开关已关闭")
            return out
        }

        let donor = await findStudioDonor(version: version, query: query, pool: pool,
                                          sources: sources, policy: policy,
                                          alreadyFetched: out.candidates)
        guard let donor, let donorBundle = donor.bundle, donorBundle.hasTranslation else {
            out.notes.append("各源均无翻译（本版本与录音室版都没有译文）")
            out.transplant = LyricsTransplantReport(applied: false,
                                                    note: "没有找到带译文的录音室版")
            return out
        }

        guard let targetBundle = best.bundle,
              let moved = transplantTranslation(into: targetBundle, from: donorBundle,
                                                donorTitle: donor.track.title) else {
            out.notes.append("找到了带译文的录音室版，但歌词行对不上，未移植")
            out.transplant = LyricsTransplantReport(applied: false,
                                                    donorTitle: donor.track.title,
                                                    donorSourceID: donor.track.sourceID,
                                                    note: "逐行对齐命中 0 行")
            return out
        }

        best.bundle = moved.bundle
        out.best = best
        if let i = out.candidates.firstIndex(where: { $0.id == best.id }) {
            out.candidates[i] = best
        }
        out.transplant = moved.report
        out.notes.append(moved.report.note)
        return out
    }

    // MARK: 找录音室版供体

    /// 找一份「同一首歌的录音室版且带译文」的歌词。
    ///
    /// 两步走，先便宜的：
    /// ① **复用候选池**：上一轮各源已经搜回来的候选里挑录音室版的，只花「取词」一发；
    /// ② 池里没有录音室版才重搜一轮，用 `VersionInfo.studio(baseTitle)` 当版本查询，
    ///    让打分把录音室版顶到最前面。
    internal static func findStudioDonor(version: VersionInfo,
                                         query: TrackQuery,
                                         pool: [TrackCandidate],
                                         sources: [any MetadataSource],
                                         policy: ChineseVariantPolicy,
                                         alreadyFetched: [LyricsCandidate],
                                         maxTries: Int = 3) async -> LyricsCandidate? {

        // 已经取过词的那几条里如果就有带译文的录音室版，直接用，一发请求都不发。
        for c in alreadyFetched where c.bundle?.hasTranslation == true {
            if VersionMarker.parse(c.track.title).isStudio { return c }
        }

        var studioQuery = query
        studioQuery.title = version.baseTitle
        let studioVersion = VersionInfo.studio(version.baseTitle)

        // 时长不能用：录音室版与 Live 版本来就差好几十秒，带上反而把供体罚下去。
        studioQuery.duration = 0

        func lookup(in candidates: [TrackCandidate]) async -> LyricsCandidate? {
            let ranked = MatchScorer.rank(candidates, for: studioQuery, versionQuery: studioVersion)
            var tried = 0
            for c in ranked {
                guard VersionMarker.parse(c.title).isStudio else { continue }
                guard let src = SourceRegistry.shared.source(id: c.sourceID),
                      src.capabilities.contains(.lyrics) else { continue }
                guard tried < maxTries else { break }
                tried += 1
                // `try?` 套在返回可选的 async 方法上会得到双层可选，先摊平再交给 `normalized`
                let raw: LyricsBundle? = (try? await src.fetchLyrics(c)) ?? nil
                guard let b = normalized(raw, policy), b.hasTranslation else { continue }
                return LyricsCandidate(track: c.converted(to: policy), bundle: b)
            }
            return nil
        }

        if let hit = await lookup(in: pool) { return hit }

        // 池里没有录音室版：按「有译文最快最稳」的顺序重搜一轮。
        for src in sources {
            guard let found = try? await src.searchTracks(studioQuery, limit: 8) else { continue }
            let usable = found.filter { !isInstrumental($0.title) }
            if let hit = await lookup(in: usable) { return hit }
        }
        return nil
    }

    // MARK: 逐行对齐移植

    /// 把 `donor`（录音室版）的译文按**歌词正文逐行对齐**搬到 `target` 的时间轴上。
    ///
    /// 为什么不能按时间戳配对（`merge` 那套）：两份录音是**不同的演出**，
    /// 同一句词在 Live 版里可能晚 40 秒才唱到，按时间找最近的一行必然全错。
    /// 唯一可靠的锚点是**词本身**。
    ///
    /// 归一化（`alignKey`）：去空白与标点、全角 ASCII 转半角、汉字繁→简、
    /// **假名一个都不动**（不做 `widthInsensitive` 折叠，那会改写半角片假名）。
    /// 相等或相似度 ≥ `minimumSimilarity` 视为同一句。
    ///
    /// 对齐用**全局单调对齐**（LCS 变体）而不是逐行贪心：副歌会整段重复，
    /// 贪心会把第二遍副歌的译文认领到第一遍上，整段偏移一轮。
    /// 单调约束保证「本版本的第 k 句只可能对到录音室版第 k 句之后」。
    ///
    /// 对不上的行**留空**，不瞎猜。
    static func transplantTranslation(into target: LyricsBundle,
                                      from donor: LyricsBundle,
                                      donorTitle: String? = nil,
                                      minimumSimilarity: Double = 0.85)
        -> (bundle: LyricsBundle, report: LyricsTransplantReport)? {

        guard let targetPlain = target.plain, !targetPlain.isEmpty,
              let donorPlain = donor.plain, !donorPlain.isEmpty,
              donor.hasTranslation else { return nil }

        // 本版本的歌词正文行（跳过空行与署名行）
        let targetDoc = LrcDocument.parse(targetPlain)
        let targetLines: [(index: Int, line: LrcLine, key: String)] =
            targetDoc.lines.enumerated().compactMap { i, l in
                guard !l.isBlankText, !isCreditLine(l.text), l.firstTimestamp != nil else { return nil }
                let k = alignKey(l.text)
                return k.isEmpty ? nil : (i, l, k)
            }
        // 录音室版的 (原词, 译文) 对
        let donorPairs = pairedLines(plain: donorPlain, translated: donor.translated)
            .compactMap { p -> (key: String, translation: String)? in
                guard let t = p.translation, !t.isEmpty else { return nil }
                let k = alignKey(p.text)
                return k.isEmpty ? nil : (k, t)
            }

        guard !targetLines.isEmpty, !donorPairs.isEmpty else { return nil }
        // 上限保护：O(n·m) 的 DP，两边都上千行时不值得为一份歌词烧 CPU。
        guard targetLines.count <= 600, donorPairs.count <= 600 else { return nil }

        let matches = monotonicAlign(targetLines.map(\.key), donorPairs.map(\.key),
                                     minimumSimilarity: minimumSimilarity)

        var lines: [LrcLine] = []
        var aligned = 0
        for (ti, di) in matches.sorted(by: { $0.key < $1.key }) {
            let t = targetLines[ti]
            lines.append(LrcLine(timestamps: t.line.timestamps, text: donorPairs[di].translation))
            aligned += 1
        }
        guard aligned > 0 else { return nil }

        let unaligned = targetLines.count - aligned
        let where_ = donorTitle.map { "《\($0)》" } ?? ""
        let note = "翻译来自录音室版\(where_)（\(SourceOutcome.shortName(donor.sourceID))），"
            + "按歌词行对齐，\(aligned)/\(targetLines.count) 行对上"
            + (unaligned > 0 ? "，\(unaligned) 行留空" : "")

        var out = target
        out.translated = LrcDocument(headerTags: [], lines: lines).render(millisecondDigits: 2)
        out.translationSourceNote = note

        return (out, LyricsTransplantReport(applied: true,
                                            donorTitle: donorTitle,
                                            donorSourceID: donor.sourceID,
                                            aligned: aligned, unaligned: unaligned,
                                            total: targetLines.count, note: note))
    }

    /// 把一份 LRC 的原词行与译文行按时间戳配对，返回**按原词行序**的 (原词, 译文?)。
    ///
    /// 与 `merge(plain:translated:…)` 里那段同源（同样的 ±0.35 s 与「一条译文只认领一次」），
    /// 但这里要的是**序列**而不是渲染结果，故单独成函数而不是把 `merge` 拆开 ——
    /// `merge` 是四种排版格式的现成实现，动它风险远大于多写十行。
    static func pairedLines(plain: String, translated: String?)
        -> [(text: String, translation: String?)] {

        let src = LrcDocument.parse(plain)
        guard let translated, !translated.isEmpty else {
            return src.lines.filter { !$0.isBlankText }.map { ($0.text, nil) }
        }
        let transTimed: [(t: TimeInterval, text: String)] = LrcDocument.parse(translated)
            .lines.compactMap {
                guard let t = $0.firstTimestamp, !$0.isBlankText else { return nil }
                return (t, $0.text)
            }.sorted { $0.t < $1.t }

        var claimed = Set<Int>()
        var out: [(text: String, translation: String?)] = []
        for line in src.lines where !line.isBlankText {
            guard !isCreditLine(line.text), let time = line.firstTimestamp else {
                out.append((line.text, nil)); continue
            }
            var bestIdx: Int?
            var bestDelta = TimeInterval.greatestFiniteMagnitude
            for (i, item) in transTimed.enumerated() {
                if claimed.contains(i) { continue }
                let d = abs(item.t - time)
                if d < bestDelta { bestDelta = d; bestIdx = i }
                if item.t > time + 1 { break }
            }
            if let idx = bestIdx, bestDelta <= 0.35 {
                claimed.insert(idx)
                out.append((line.text, transTimed[idx].text))
            } else {
                out.append((line.text, nil))
            }
        }
        return out
    }

    /// 单调全局对齐（LCS 变体）。返回 `[目标行下标: 供体行下标]`。
    ///
    /// `dp[i][j]` = 前 i 个目标行与前 j 个供体行能取到的最大相似度总和。
    /// 只有相似度 ≥ 阈值的一对才允许「配对」，否则只能跳过其中一边 ——
    /// 这保证了不会为了凑数把两句无关的词强行配起来。
    static func monotonicAlign(_ a: [String], _ b: [String],
                               minimumSimilarity: Double) -> [Int: Int] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [:] }

        var sim = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                sim[i][j] = a[i] == b[j] ? 1.0 : MatchScorer.editSimilarity(a[i], b[j])
            }
        }

        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var best = max(dp[i - 1][j], dp[i][j - 1])
                let s = sim[i - 1][j - 1]
                if s >= minimumSimilarity { best = max(best, dp[i - 1][j - 1] + s) }
                dp[i][j] = best
            }
        }

        var out: [Int: Int] = [:]
        var i = n, j = m
        while i > 0, j > 0 {
            let s = sim[i - 1][j - 1]
            if s >= minimumSimilarity, dp[i][j] == dp[i - 1][j - 1] + s {
                out[i - 1] = j - 1; i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out
    }

    /// 逐行对齐专用的归一键：全角 ASCII → 半角、全角空格 → 空格、汉字繁→简、
    /// 小写、只留字母数字与汉字假名谚文。**假名不折宽**（`ﾗｰﾒﾝ` 不会被改写成 `ラーメン`）。
    static func alignKey(_ s: String) -> String {
        var work = ""
        work.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFF01...0xFF5E:
                work.unicodeScalars.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0x3000:
                work.append(" ")
            default:
                work.unicodeScalars.append(u)
            }
        }
        if MatchScorer.containsCJK(work) {
            let m = NSMutableString(string: work) as CFMutableString
            if CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false) {
                work = m as String
            }
        }
        work = work.lowercased()
        var out = String.UnicodeScalarView()
        for u in work.unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.append(u)
        }
        return String(out)
    }
}

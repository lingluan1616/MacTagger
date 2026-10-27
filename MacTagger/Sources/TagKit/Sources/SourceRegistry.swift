//
//  SourceRegistry.swift
//  MacTagger — 在线数据源注册表与降级链
//
//  设计约束：
//  1. **只按 id 字符串管理，只持有 `any MetadataSource` 协议类型**，不引用任何具体源类型
//     （国际源由另一路开发，注册表不能与之产生编译耦合）。中文四源因同属本模块直接内建注册，
//     其余源由 `register(_:)` 在启动时注入。
//  2. **降级链绝不因单源失败中断整批**：任一源抛错只淘汰该源，继续下一个；
//     全部失败才返回空结果并汇总各源错误，供界面一次性提示。
//  3. 推荐优先级来自 C 报告实测结论：
//     P0 itunes / netease / kugou / qq → P1 musicbrainz / coverartarchive → P2 kuwo / lastfm
//

import Foundation

// MARK: - 降级链结果

/// 单个源在降级链里的一次尝试记录。界面据此告诉用户「哪个源挂了」。
public struct SourceAttempt: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 成功并返回 n 条候选
        case succeeded(Int)
        /// 请求成功但没搜到（不是故障）
        case empty
        /// 源本身出错（网络 / 业务层拦截 / 解析失败）
        case failed
        /// 未注册或不具备搜索能力，直接跳过
        case skipped
    }
    public let sourceID: String
    public let outcome: Outcome
    public let message: String?
    public let elapsed: TimeInterval

    public init(sourceID: String, outcome: Outcome, message: String? = nil, elapsed: TimeInterval = 0) {
        self.sourceID = sourceID; self.outcome = outcome
        self.message = message; self.elapsed = elapsed
    }
}

public struct FallbackSearchResult: Sendable {
    public var candidates: [TrackCandidate]
    /// 实际给出候选的那个源。全失败时为 nil。
    public var winningSourceID: String?
    public var attempts: [SourceAttempt]

    public var isEmpty: Bool { candidates.isEmpty }

    /// 全失败时把各源错误汇总成一句话，供界面提示。没有失败则为 nil。
    public var errorSummary: String? {
        let failures = attempts.filter { $0.outcome == .failed }
        guard !failures.isEmpty else { return nil }
        return failures
            .map { "\($0.sourceID)：\($0.message ?? "未知错误")" }
            .joined(separator: "；")
    }
}

// MARK: - 注册表

public final class SourceRegistry: @unchecked Sendable {

    public static let shared = SourceRegistry()

    private let lock = NSLock()
    private var storage: [String: any MetadataSource] = [:]
    private var insertionOrder: [String] = []

    /// C 报告给出的推荐优先级。未注册的 id 会在 `recommendedOrder` 里被自动跳过。
    public static let recommendedPriority: [String] = [
        // P0：无鉴权、无加密、实测稳定，覆盖约 90% 的刮削需求
        "itunes", "netease", "kugou", "qq",
        // P1：权威元数据与高清封面补位
        "musicbrainz", "coverartarchive",
        // P2：冗余兜底
        "kuwo", "lastfm",
    ]

    public init(registerBuiltIns: Bool = true) {
        if registerBuiltIns { self.registerChineseBuiltIns() }
    }

    // MARK: 注册

    /// 中文四源与注册表同属 TagKit，直接内建注册。
    public func registerChineseBuiltIns() {
        register(NeteaseSource())
        register(KugouSource())
        register(QQSource())
        register(KuwoSource())
    }

    /// 注入外部源（国际源在 App / CLI 启动时调用，注册表本身不引用其类型）。
    /// 同 id 重复注册以后者为准，便于用户在偏好设置里替换实现。
    public func register(_ source: any MetadataSource) {
        lock.lock(); defer { lock.unlock() }
        if storage[source.id] == nil { insertionOrder.append(source.id) }
        storage[source.id] = source
    }

    public func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        storage[id] = nil
        insertionOrder.removeAll { $0 == id }
    }

    // MARK: 查询

    public func source(id: String) -> (any MetadataSource)? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public var allIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return insertionOrder
    }

    public var allSources: [any MetadataSource] {
        lock.lock(); defer { lock.unlock() }
        return insertionOrder.compactMap { storage[$0] }
    }

    /// 按能力过滤。例：`sources(supporting: .wordByWordLyrics)` 取所有支持逐字歌词的源。
    public func sources(supporting caps: SourceCapabilities) -> [any MetadataSource] {
        allSources.filter { $0.capabilities.isSuperset(of: caps) }
    }

    public func ids(supporting caps: SourceCapabilities) -> [String] {
        sources(supporting: caps).map(\.id)
    }

    /// 推荐顺序：先按 C 报告优先级排已注册的源，再把表外的源按注册顺序追加在后面。
    public var recommendedOrder: [String] {
        let registered = Set(allIDs)
        var out = Self.recommendedPriority.filter { registered.contains($0) }
        for id in allIDs where !out.contains(id) { out.append(id) }
        return out
    }

    // MARK: 降级链

    /// 按优先级依次尝试各源，**任一源抛错只淘汰该源、绝不中断整批**。
    /// 第一个返回非空候选的源即为结果；全部失败/为空时返回空候选 + 完整尝试记录。
    ///
    /// - Parameters:
    ///   - query: 匹配查询
    ///   - sources: 要尝试的源 id 列表，nil 表示用 `recommendedOrder`
    ///   - limit: 每个源要多少条候选
    public func searchWithFallback(query: TrackQuery,
                                   sources ids: [String]? = nil,
                                   limit: Int = 10) async -> FallbackSearchResult {
        let order = ids ?? recommendedOrder
        var attempts: [SourceAttempt] = []

        guard !query.isEmpty else {
            return FallbackSearchResult(candidates: [], winningSourceID: nil, attempts: [])
        }

        for id in order {
            guard let source = source(id: id) else {
                attempts.append(SourceAttempt(sourceID: id, outcome: .skipped, message: "未注册"))
                continue
            }
            guard source.capabilities.contains(.searchTracks) else {
                attempts.append(SourceAttempt(sourceID: id, outcome: .skipped, message: "不支持搜索"))
                continue
            }

            let started = Date()
            do {
                let found = try await source.searchTracks(query, limit: limit)
                let elapsed = Date().timeIntervalSince(started)
                if found.isEmpty {
                    attempts.append(SourceAttempt(sourceID: id, outcome: .empty,
                                                  message: nil, elapsed: elapsed))
                    continue
                }
                attempts.append(SourceAttempt(sourceID: id, outcome: .succeeded(found.count),
                                              message: nil, elapsed: elapsed))
                return FallbackSearchResult(candidates: found, winningSourceID: id, attempts: attempts)
            } catch {
                // 关键：单源故障只记账，绝不 throw 出去打断整条链。
                attempts.append(SourceAttempt(sourceID: id, outcome: .failed,
                                              message: error.localizedDescription,
                                              elapsed: Date().timeIntervalSince(started)))
                continue
            }
        }

        return FallbackSearchResult(candidates: [], winningSourceID: nil, attempts: attempts)
    }

    /// 歌词降级链。与搜索同构：单源失败只淘汰该源。
    /// 候选必须来自对应源，因此这里对每个源先搜索再取词。
    public func lyricsWithFallback(query: TrackQuery,
                                   sources ids: [String]? = nil) async -> (LyricsBundle?, [SourceAttempt]) {
        let order = (ids ?? recommendedOrder).filter {
            source(id: $0)?.capabilities.contains(.lyrics) ?? false
        }
        var attempts: [SourceAttempt] = []

        for id in order {
            guard let source = source(id: id) else { continue }
            let started = Date()
            do {
                let found = try await source.searchTracks(query, limit: 3)
                guard let first = found.first else {
                    attempts.append(SourceAttempt(sourceID: id, outcome: .empty,
                                                  elapsed: Date().timeIntervalSince(started)))
                    continue
                }
                if let bundle = try await source.fetchLyrics(first), !bundle.isEmpty {
                    attempts.append(SourceAttempt(sourceID: id, outcome: .succeeded(1),
                                                  elapsed: Date().timeIntervalSince(started)))
                    return (bundle, attempts)
                }
                attempts.append(SourceAttempt(sourceID: id, outcome: .empty, message: "该曲目无歌词",
                                              elapsed: Date().timeIntervalSince(started)))
            } catch {
                attempts.append(SourceAttempt(sourceID: id, outcome: .failed,
                                              message: error.localizedDescription,
                                              elapsed: Date().timeIntervalSince(started)))
            }
        }
        return (nil, attempts)
    }
}

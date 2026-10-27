//
//  AutoMatchStore.swift
//  MacTagger — 自动匹配标签：数据源注册 + 选项持久化
//
//  对应原版 FormAutoMatchTags 的选项区，以及
//  FormCombTagsSearch(+OwOptions) 的「标签来源 / 网络搜索线程数 / 网络搜索项限制」。
//

import Foundation
import SwiftUI

// MARK: - 数据源注册

/// App 启动时把所有在线源注入注册表。
/// 中文四源与注册表同属 TagKit（内建注册），国际源必须显式注入 ——
/// 注册表刻意不引用具体源类型，删掉一个适配器不会牵动主程序。
@MainActor
enum SourceBootstrap {

    private static var registered = false

    // MARK: iTunes 地区

    /// 「iTunes 曲库地区」的持久化键。`AppSettings.itunesCountry` 与
    /// `ITunesRegionPicker`（@AppStorage）读写的是**同一个键**，所以不存在两份真相源。
    static let itunesCountryKey = "MacTagger.itunes.country"

    /// 出厂地区：**中国香港（HK）**（BE 轮定；BD 轮曾是「自动（按曲名语言）」，
    /// 更早写死 `"CN"`）。
    ///
    /// 改的理由是实测：中区商店整个是空的（`resultCount:0`，已连续多日对一切搜索
    /// 返回 0 条），出厂值 CN 等于每首歌白烧一发 3.1 s 的限速请求再回退港区。
    /// 港区曲库与大陆的华语内容最接近，返回的繁体元数据由
    /// 「在线结果统一转为」（`ChineseVariant.onlineDefault`）归一成简体。
    ///
    /// 从自动档换成固定港区**不会**让日文 OST 退化：地区链的第 ① 步
    /// 「按曲名文字选区」（`ITunesSource.regionChain(hint:)`）与是不是自动档无关，
    /// 日文曲名照样先问 JP、韩文先问 KR。固定 HK 生成的链条与自动档逐项相同
    /// （`JP/KR?` → `HK` → `US`），差别只在健康台账的分格键与选择器上的显示名。
    ///
    /// 只有**键不存在**时才用这个出厂值 —— 用户自己选过 CN 的话，下面的 getter
    /// 读到的是他存的值，尊重用户设置。
    static let itunesCountryDefault = ITunesSource.Region.hongKong.rawValue

    /// 当前选定的地区码。`"AUTO"` 是自动档的哨兵值，其余已按
    /// `ITunesSource.Region.parse` 规范化（UK 会被折成 GB）。
    static var itunesCountry: String {
        get {
            let raw = UserDefaults.standard.string(forKey: itunesCountryKey) ?? itunesCountryDefault
            if ITunesSource.Region.isAutomatic(raw) { return ITunesSource.Region.automatic }
            return ITunesSource.Region.parse(raw).rawValue
        }
        set {
            let code = ITunesSource.Region.isAutomatic(newValue)
                ? ITunesSource.Region.automatic
                : ITunesSource.Region.parse(newValue).rawValue
            UserDefaults.standard.set(code, forKey: itunesCountryKey)
            registerITunes()
        }
    }

    /// 按当前设置（重新）注册 iTunes 源。
    ///
    /// `SourceRegistry.register` 是「同 id 覆盖」的，所以这既是首次注册也是热更新：
    /// 用户在选择器里换地区 → 这里换掉注册表里那一个实例 → 下一次搜索立刻用新地区，
    /// 不必重启 App。顺带清掉地区回退台账 —— 那里粘着「CN 空了所以用 HK」的解析结果，
    /// 不清的话用户明明改成了 TW，前 10 分钟仍然会先打 HK。
    static func registerITunes() {
        SourceRegistry.shared.register(ITunesSource.configured(country: itunesCountry))
        ITunesSource.resetRegionFallbackLog()
    }

    static func registerAll() {
        guard !registered else { return }
        registered = true
        let reg = SourceRegistry.shared
        reg.registerChineseBuiltIns()               // 网易云 / 酷狗 / QQ
        registerITunes()                            // 地区来自设置，不再写死 CN
        reg.register(MusicBrainzSource())
        reg.register(CoverArtArchiveSource())       // 只供封面回落，不参与搜索
    }

    /// 支持曲目搜索的源，按 C 报告实测的推荐优先级排列。
    static var searchableIDs: [String] {
        let reg = SourceRegistry.shared
        return reg.recommendedOrder.filter {
            reg.source(id: $0)?.capabilities.contains(.searchTracks) ?? false
        }
    }

    static func displayName(_ id: String) -> String {
        SourceRegistry.shared.source(id: id)?.displayName ?? id
    }

    /// 源能力的中文短标签，显示在来源列表里，让用户知道勾了它能拿到什么。
    static func capabilityTags(_ id: String) -> [String] {
        guard let caps = SourceRegistry.shared.source(id: id)?.capabilities else { return [] }
        var out: [String] = []
        if caps.contains(.artwork) { out.append("封面") }
        if caps.contains(.wordByWordLyrics) { out.append("逐字歌词") }
        else if caps.contains(.lyrics) { out.append("歌词") }
        if caps.contains(.translatedLyrics) { out.append("译词") }
        if caps.contains(.authoritative) { out.append("权威元数据") }
        return out
    }
}

// MARK: - 选项持久化

@MainActor
final class AutoMatchSettings: ObservableObject {

    private enum Key {
        static let order       = "MacTagger.autoMatch.sourceOrder"
        static let enabled     = "MacTagger.autoMatch.enabledSources"
        static let threshold   = "MacTagger.autoMatch.threshold"
        static let fields      = "MacTagger.autoMatch.fields"
        static let artwork     = "MacTagger.autoMatch.fetchArtwork"
        static let artworkSize = "MacTagger.autoMatch.artworkSize"
        static let lyrics      = "MacTagger.autoMatch.fetchLyrics"
        static let concurrency = "MacTagger.autoMatch.concurrency"
        static let limit       = "MacTagger.autoMatch.limitPerSource"
        static let softDeadline = "MacTagger.autoMatch.sourceSoftDeadline"
        static let credits      = "MacTagger.autoMatch.fetchCredits"
    }

    /// 默认勾选的源 = C 报告的 P0 四源（覆盖约 90% 需求）。
    static let defaultEnabled: Set<String> = ["itunes", "netease", "kugou", "qq"]
    static let artworkSizeChoices: [Int] = [500, 800, 1000, 1200, 1500]

    /// 全部可搜索源，顺序即匹配优先级。
    @Published var sourceOrder: [String] { didSet { persistOrder() } }
    @Published var enabledSources: Set<String> { didSet { persistEnabled() } }
    @Published var acceptThreshold: Double {
        didSet { UserDefaults.standard.set(acceptThreshold, forKey: Key.threshold) }
    }
    /// 允许写入的字段白名单（原始值）。这是数据安全的闸门：
    /// 用户可以只让它补年份和音轨号，不动自己改过的标题。
    @Published var enabledFields: Set<String> { didSet { persistFields() } }
    @Published var fetchArtwork: Bool {
        didSet { UserDefaults.standard.set(fetchArtwork, forKey: Key.artwork) }
    }
    @Published var artworkSize: Int {
        didSet { UserDefaults.standard.set(artworkSize, forKey: Key.artworkSize) }
    }
    @Published var fetchLyrics: Bool {
        didSet { UserDefaults.standard.set(fetchLyrics, forKey: Key.lyrics) }
    }
    /// 原版「网络搜索线程数」。
    @Published var concurrency: Int {
        didSet { UserDefaults.standard.set(concurrency, forKey: Key.concurrency) }
    }
    /// 原版「网络搜索项限制」。
    @Published var limitPerSource: Int {
        didSet { UserDefaults.standard.set(limitPerSource, forKey: Key.limit) }
    }
    /// 「每首最多等待 N 秒」——软截止。到点还没返回的源这一轮就不等了（AX 轮）。
    /// MusicBrainz 自动放宽到两倍，理由见 `AutoMatchOptions.slowSourceIDs`。
    @Published var sourceSoftDeadline: Double {
        didSet { UserDefaults.standard.set(sourceSoftDeadline, forKey: Key.softDeadline) }
    }
    /// 是否补全作曲/作词。关掉能省掉「胜出源没歌词时再查一个歌词源」那一趟。
    @Published var fetchCredits: Bool {
        didSet { UserDefaults.standard.set(fetchCredits, forKey: Key.credits) }
    }

    init() {
        SourceBootstrap.registerAll()
        let d = UserDefaults.standard
        let available = SourceBootstrap.searchableIDs

        // 存过的顺序里剔掉已下线的源，再把新出现的源按推荐优先级补到末尾。
        let saved = (d.stringArray(forKey: Key.order) ?? []).filter { available.contains($0) }
        sourceOrder = saved + available.filter { !saved.contains($0) }

        if let list = d.stringArray(forKey: Key.enabled) {
            enabledSources = Set(list).intersection(available)
        } else {
            enabledSources = Self.defaultEnabled.intersection(available)
        }

        acceptThreshold = d.object(forKey: Key.threshold) as? Double ?? 0.6

        let allFields = Set(TagEdit.Field.allCases.map(\.rawValue))
        if let list = d.stringArray(forKey: Key.fields) {
            enabledFields = Set(list).intersection(allFields)
        } else {
            enabledFields = allFields
        }

        fetchArtwork = d.object(forKey: Key.artwork) as? Bool ?? true
        artworkSize = d.object(forKey: Key.artworkSize) as? Int ?? 1200
        fetchLyrics = d.object(forKey: Key.lyrics) as? Bool ?? false
        // 默认 4 → 8（AX 轮）：这是**文件级**并发，每条线绝大部分时间都卡在网络等待上，
        // 各源自身的限速器仍然按源串行放行 —— 对方看到的发包节奏一点没变，
        // 省下的纯粹是我们这边同时能有几首在等。
        concurrency = d.object(forKey: Key.concurrency) as? Int ?? 8
        limitPerSource = d.object(forKey: Key.limit) as? Int ?? 8
        sourceSoftDeadline = d.object(forKey: Key.softDeadline) as? Double ?? 4
        fetchCredits = d.object(forKey: Key.credits) as? Bool ?? true
    }

    // MARK: 派生

    /// 按当前优先级排好的、被勾选的源。
    var activeSourceIDs: [String] { sourceOrder.filter { enabledSources.contains($0) } }

    var fieldSet: Set<TagEdit.Field> {
        Set(enabledFields.compactMap { TagEdit.Field(rawValue: $0) })
    }

    var isEveryFieldEnabled: Bool { enabledFields.count == TagEdit.Field.allCases.count }

    /// 交给数据层的最终选项。
    ///
    /// `chineseVariant` 不在这里显式写：它的缺省值就是 `ChineseVariant.onlineDefault`，
    /// 而那一个静态量由 `AppSettings` 在 init 与每次切换时推入（同 `TagService.legacyEncoding`
    /// 的既有做法）。这样连**本轮不许改**的 `AppModel+AlbumMatch.albumMatchOptions`
    /// 也一起生效，不必到处补参数。
    var options: AutoMatchOptions {
        AutoMatchOptions(sourceIDs: activeSourceIDs,
                         acceptThreshold: acceptThreshold,
                         fields: isEveryFieldEnabled ? nil : fieldSet,
                         fetchArtwork: fetchArtwork,
                         artworkSize: artworkSize,
                         fetchLyrics: fetchLyrics,
                         limitPerSource: limitPerSource,
                         concurrency: concurrency,
                         sourceSoftDeadline: sourceSoftDeadline,
                         slowSourceSoftDeadline: sourceSoftDeadline * 2,
                         fetchCredits: fetchCredits)
    }

    /// 至少要有一个源和一个字段，否则跑了也写不进任何东西。
    var isRunnable: Bool { !activeSourceIDs.isEmpty && !enabledFields.isEmpty }

    // MARK: 操作

    func toggleSource(_ id: String) {
        if enabledSources.contains(id) { enabledSources.remove(id) } else { enabledSources.insert(id) }
    }

    func isFieldEnabled(_ f: TagEdit.Field) -> Bool { enabledFields.contains(f.rawValue) }

    func setField(_ f: TagEdit.Field, _ on: Bool) {
        if on { enabledFields.insert(f.rawValue) } else { enabledFields.remove(f.rawValue) }
    }

    func selectAllFields() { enabledFields = Set(TagEdit.Field.allCases.map(\.rawValue)) }
    func clearAllFields() { enabledFields = [] }

    func moveUp(_ id: String) {
        guard let i = sourceOrder.firstIndex(of: id), i > 0 else { return }
        sourceOrder.swapAt(i, i - 1)
    }

    func moveDown(_ id: String) {
        guard let i = sourceOrder.firstIndex(of: id), i < sourceOrder.count - 1 else { return }
        sourceOrder.swapAt(i, i + 1)
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        sourceOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func resetToDefaults() {
        let available = SourceBootstrap.searchableIDs
        sourceOrder = available
        enabledSources = Self.defaultEnabled.intersection(available)
        acceptThreshold = 0.6
        selectAllFields()
        fetchArtwork = true
        artworkSize = 1200
        fetchLyrics = false
        concurrency = 4
        limitPerSource = 8
    }

    // MARK: 落盘

    private func persistOrder() {
        UserDefaults.standard.set(sourceOrder, forKey: Key.order)
    }
    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabledSources), forKey: Key.enabled)
    }
    private func persistFields() {
        UserDefaults.standard.set(Array(enabledFields), forKey: Key.fields)
    }
}

//
//  Stores.swift
//  MacTagger — 持久化的界面偏好：显示列、工作目录、选项开关
//

import Foundation
import SwiftUI
import AppKit

// MARK: - 自定义显示列（原版 FormCustColumns）

/// 表格列状态的**唯一真相源**。
///
/// 顺序 / 宽度 / 显示隐藏三件事全部由 SwiftUI 原生的 `TableColumnCustomization` 记录 ——
/// 用户直接拖表头就能重排、拖分隔线就能改宽、右键表头就能勾选显示，
/// 这三种交互 SwiftUI 都会自动写回同一个 `customization` 值。
///
/// 本类只做两件事：
/// 1. 把 `customization` 序列化进 UserDefaults（重启后原样恢复）；
/// 2. 给「自定义显示列」面板和 `AppModel.rebuildDisplay()` 的搜索过滤提供**派生**读视图。
///
/// 刻意**不再**自己维护一份 `[ColumnID]` 顺序数组：那会和 TableColumnCustomization
/// 形成两个互相打架的真相源（拖表头改了 A、上移下移改了 B，谁赢看运气）。
/// 现在顺序只有一处、宽度只有一处、可见性只有一处。
@MainActor
final class ColumnStore: ObservableObject {

    /// v2：整包 JSON（顺序 + 宽度 + 可见性）。v1 只有一个可见列名数组，见 `migrateLegacy()`。
    private static let key = "MacTagger.tableColumns"
    private static let legacyKey = "MacTagger.visibleColumns"

    /// 绑定给 `Table(..., columnCustomization:)`。用户每次拖列 / 改宽 / 勾选都写回这里。
    @Published var customization: TableColumnCustomization<FileRow> {
        didSet {
            guard customization != oldValue else { return }
            persist()
        }
    }

    init() {
        if let restored = Self.restore() {
            customization = restored
        } else if let migrated = Self.migrateLegacy() {
            customization = migrated
            persist()                     // 把 v1 的可见性一次性固化成 v2
        } else {
            customization = TableColumnCustomization<FileRow>()
        }
    }

    // MARK: 派生读视图

    /// 某列当前是否显示。
    /// `.automatic` 表示用户从没动过这一列，此时用 `ColumnCatalog.defaultVisible`，
    /// 与表格里 `.defaultVisibility(...)` 取的是同一套默认值，两边不会各说各话。
    func isVisible(_ id: ColumnID) -> Bool {
        if id == .filename { return true }            // 文件名列是锚点，永远在
        switch customization[visibility: id.rawValue] {
        case .visible: return true
        case .hidden:  return false
        default:       return ColumnCatalog.defaultVisible.contains(id)
        }
    }

    /// 当前显示的列。顺序按目录顺序给出 —— 表头的真实顺序归 TableColumnCustomization 管，
    /// 而这里的两个使用方（搜索过滤、勾选清单）都与顺序无关。
    var visible: [ColumnID] { ColumnCatalog.all.map(\.id).filter(isVisible) }

    var visibleSpecs: [ColumnSpec] { visible.map(ColumnCatalog.spec) }

    var hidden: [ColumnID] { ColumnCatalog.all.map(\.id).filter { !isVisible($0) } }

    // MARK: 写

    func setVisible(_ id: ColumnID, _ on: Bool) {
        guard id != .filename else { return }         // 文件名列不可隐藏
        customization[visibility: id.rawValue] = on ? .visible : .hidden
    }

    func toggle(_ id: ColumnID) { setVisible(id, !isVisible(id)) }

    /// 原版 FormCustColumns 的「重置」：顺序、宽度、可见性一起回到出厂值。
    func reset() { customization = TableColumnCustomization<FileRow>() }

    // MARK: 落盘

    /// 存成 JSON 字符串而不是 Data：`defaults read com.lingluan.mactagger` 能直接看懂，
    /// 排查「顺序丢了」这类问题不用再解 base64。
    private func persist() {
        guard let data = try? JSONEncoder().encode(customization),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: Self.key)
    }

    private static func restore() -> TableColumnCustomization<FileRow>? {
        guard let json = UserDefaults.standard.string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TableColumnCustomization<FileRow>.self, from: data)
    }

    /// v1 迁移：老版本只存了「哪些列可见」，顺序与宽度无从还原，只搬可见性。
    private static func migrateLegacy() -> TableColumnCustomization<FileRow>? {
        guard let raw = UserDefaults.standard.array(forKey: legacyKey) as? [String] else { return nil }
        let kept = Set(raw.compactMap(ColumnID.init(rawValue:)))
        guard !kept.isEmpty else { return nil }
        var c = TableColumnCustomization<FileRow>()
        for spec in ColumnCatalog.all where spec.id != .filename {
            c[visibility: spec.id.rawValue] = kept.contains(spec.id) ? .visible : .hidden
        }
        return c
    }
}

// MARK: - 工作目录（原版 FormManageDirs）

@MainActor
final class DirectoryStore: ObservableObject {

    private static let listKey = "MacTagger.workingDirectories"
    private static let currentKey = "MacTagger.currentDirectory"

    @Published private(set) var directories: [URL]
    @Published var current: URL? {
        didSet { UserDefaults.standard.set(current?.path, forKey: Self.currentKey) }
    }

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.listKey) ?? []
        directories = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let p = UserDefaults.standard.string(forKey: Self.currentKey) {
            current = URL(fileURLWithPath: p, isDirectory: true)
        }
    }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let dir = url.standardizedFileURL
            guard !directories.contains(where: { $0.path == dir.path }) else { continue }
            directories.append(dir)
            changed = true
        }
        if changed { persist() }
    }

    func remove(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        directories.removeAll { paths.contains($0.path) }
        if let c = current, paths.contains(c.path) { current = nil }
        persist()
    }

    func removeAll() {
        directories.removeAll()
        current = nil
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(directories.map(\.path), forKey: Self.listKey)
    }
}

// MARK: - 选项开关

@MainActor
final class AppSettings: ObservableObject {

    @Published var includeSubdirectories: Bool {
        didSet { UserDefaults.standard.set(includeSubdirectories, forKey: "MacTagger.includeSubdirs") }
    }
    /// 原版「保存标签时不改变文件修改时间」。
    @Published var preserveModificationDate: Bool {
        didSet { UserDefaults.standard.set(preserveModificationDate, forKey: "MacTagger.preserveMtime") }
    }
    /// 原版「添加后覆盖已存在的封面（只有一个封面）」。
    @Published var overwriteArtworkOnAdd: Bool {
        didSet { UserDefaults.standard.set(overwriteArtworkOnAdd, forKey: "MacTagger.overwriteArtwork") }
    }
    /// 原版「内置图片大小限制」的自动化版本：添加封面时自动把最长边限制到 N px。
    /// 0 = 关闭（默认）。写入路径见 `AppModel.normalizedArtwork(_:)`。
    @Published var artworkAutoLimitMaxEdge: Int {
        didSet { UserDefaults.standard.set(artworkAutoLimitMaxEdge, forKey: "MacTagger.artworkAutoLimitMaxEdge") }
    }
    /// 原版「固定为 JPG」：添加封面时自动转成 JPEG。默认关闭。
    @Published var artworkAutoConvertJPEG: Bool {
        didSet { UserDefaults.standard.set(artworkAutoConvertJPEG, forKey: "MacTagger.artworkAutoConvertJPEG") }
    }
    /// 忽略 MP4 视频文件。
    @Published var ignoreVideoMP4: Bool {
        didSet { UserDefaults.standard.set(ignoreVideoMP4, forKey: "MacTagger.ignoreVideoMP4") }
    }
    /// 时长过滤：0 = 未设置，其余为秒（原版 FileFilterByDurationList）。
    @Published var minimumDurationSeconds: Int {
        didSet { UserDefaults.standard.set(minimumDurationSeconds, forKey: "MacTagger.minDuration") }
    }

    // MARK: 导入：列出之后自动读标签？

    /// 「列出文件之后要不要马上把标签全读一遍」。
    ///
    /// 默认 `auto`：**读，但按介质决定读多快**。
    ///
    /// 从前 `auto` 在可移动卷上一律不读 —— 结果 TF 卡上 14 首的小目录也永远挂着
    /// 一片「读取中…」，用户以为坏了。现在 `lazyThreshold` 这道阈值优先于卷类型：
    /// 小目录在任何盘上都一次读完再显示；大目录在外置卡上照读，只是并发 2 +
    /// 每 200 首让出一次（见 `TagReader.recommendedYieldEvery`）。
    /// 不管哪一档，屏幕上看得到的行都排在队列最前面（见 `AppModel.prioritizeLeadingRows`）。
    enum AutoReadTagsMode: String, CaseIterable, Identifiable {
        /// 小目录（≤ 阈值）一次读完再显示；大目录后台读，外置卡上放慢。
        case auto
        /// 一律自动读，而且不放慢。
        case always
        /// 一律不自动读，全靠按需（可见行） + 手动「继续读取标签」。
        case never

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto:   return "智能（小目录读完再显示，大目录后台读，外置卡放慢）"
            case .always: return "总是自动读取（不放慢）"
            case .never:  return "从不自动读取（只读看得见的那一屏）"
            }
        }
    }

    @Published var autoReadTags: AutoReadTagsMode {
        didSet {
            UserDefaults.standard.set(autoReadTags.rawValue, forKey: "MacTagger.import.autoReadTags")
        }
    }

    /// 两段式导入的**起用门槛**：文件数超过它才先列文件再补标签。
    ///
    /// 两段式是为几万首的大目录设计的，用在 10 首的小目录上是纯亏 ——
    /// 用户先看见一片「读取中…」，然后才一格格填上，主观比「等 0.2 秒直接出全表」更慢。
    /// 所以 ≤ 阈值的目录走**直接路径**：后台枚举完顺手把标签一次读完，整表一次上屏，
    /// 出现时每一格都是真值（仍然全在后台，主线程一步不挡）。
    ///
    /// 0 = 关掉直接路径，任何目录都走两段式（给「就是要立刻看见文件名」的人留的）。
    /// 上限 100000 只是防呆，正常没人会填到那儿。
    @Published var lazyThreshold: Int {
        didSet {
            let clamped = max(0, min(100_000, lazyThreshold))
            if clamped != lazyThreshold { lazyThreshold = clamped; return }
            UserDefaults.standard.set(lazyThreshold, forKey: AppSettings.lazyThresholdKey)
        }
    }

    static let lazyThresholdKey = "MacTagger.import.lazyThreshold"
    static let lazyThresholdDefault = 500

    /// 列表内联编辑开关。
    @Published var inlineEditing: Bool {
        didSet { UserDefaults.standard.set(inlineEditing, forKey: "MacTagger.inlineEditing") }
    }
    /// 老旧中文标签兼容读取。
    @Published var legacyEncoding: LegacyTextEncoding {
        didSet {
            UserDefaults.standard.set(legacyEncoding.rawValue, forKey: "MacTagger.legacyEncoding")
            TagService.legacyEncoding = legacyEncoding
        }
    }

    // MARK: 在线结果的字形

    /// 「在线结果统一转为：不转 / 简体 / 繁体」。默认**简体** —— 用户的库是简体，
    /// 而 iTunes 中区空掉后自动回退的港区、以及中文四源里的港台版条目，
    /// 返回的都是 `周杰倫 / 國語流行樂` 这样的繁体。
    ///
    /// 落地方式与 `legacyEncoding` 一模一样：写 UserDefaults 之余，把值推给数据层的
    /// 那一个静态量 `ChineseVariant.onlineDefault`，四个服务的选项结构以它为缺省值。
    /// 所以「设置改了要不要重开匹配窗」这种问题根本不存在，下一次请求就是新策略。
    @Published var onlineChineseVariant: ChineseVariantPolicy {
        didSet {
            UserDefaults.standard.set(onlineChineseVariant.rawValue,
                                      forKey: Self.onlineChineseVariantKey)
            ChineseVariant.onlineDefault = onlineChineseVariant
        }
    }

    static let onlineChineseVariantKey = "MacTagger.online.chineseVariant"

    // MARK: 译文移植（BG 轮）

    /// 「Live / MV版 / Remix 没有译文时，从录音室版按歌词行移植一份」。默认开。
    ///
    /// 为什么默认开：实测某日文歌手目录里 100 多个 `.lrc` 全是日语无译文，
    /// 根因之一就是这些版本在各源**本来就没有官方译文**（实测见 BG 报告 §一）。
    /// 不移植就只能交白卷。移植过来的译文会在 `LyricsBundle.translationSourceNote`
    /// 里写明出处，不会冒充本场录音的官方译文。
    ///
    /// 落地方式同 `onlineChineseVariant`：写 UserDefaults 之余推给数据层的静态量。
    ///
    /// TODO（本轮不做 UI）：设置页「歌词」那一组里加一行复选框绑到这里即可，
    /// 键名 `MacTagger.lyrics.transplantTranslation` 已经定死，后续轮次直接接线。
    @Published var transplantTranslation: Bool {
        didSet {
            UserDefaults.standard.set(transplantTranslation, forKey: Self.transplantTranslationKey)
            LyricsService.transplantTranslationEnabled = transplantTranslation
        }
    }

    static let transplantTranslationKey = "MacTagger.lyrics.transplantTranslation"

    // MARK: iTunes 曲库地区

    /// 「iTunes 曲库地区」。真相源是 `SourceBootstrap`（UserDefaults 键
    /// `MacTagger.itunes.country`），这里只是给非选择器的调用方一个读写口。
    ///
    /// 刻意**不做成 `@Published`**：选择器 `ITunesRegionPicker` 用 `@AppStorage`
    /// 直接读写同一个键（它要能在没有 environmentObject 的独立窗口里工作），
    /// 再存一份 `@Published` 就会出现「选择器改了、这里还是旧值」的两份真相源。
    var itunesCountry: String {
        get { SourceBootstrap.itunesCountry }
        set { SourceBootstrap.itunesCountry = newValue }
    }

    // MARK: 歌词文件

    /// 「把歌词保存成文件」的全部选项（格式 / 位置 / 命名 / 编码 / 覆盖）。
    ///
    /// 这里也是原先散在 `LyricsSettings` 里的
    /// 「保存标签的同时保存 Lrc 文件 / 文件名格式 / 编码 / 自定义目录」四项的**唯一真相源**——
    /// 老键值在首次启动时一次性迁移过来（见 `Self.loadLyricsFileOptions()`），
    /// 之后自动匹配、批量下载、搜索窗、编辑器另存、保存标签顺带存，五条路径共用同一份选项。
    @Published var lyricsFile: LyricsFileOptions {
        didSet {
            guard lyricsFile != oldValue else { return }
            Self.persistLyricsFileOptions(lyricsFile)
        }
    }

    private enum LyricsFileKey {
        /// 整包 JSON。存字符串而不是 Data，`defaults read com.lingluan.mactagger` 能直接看懂。
        static let options = "MacTagger.lyricsFile.options"
        /// 迁移标记：只从老键搬一次，之后用户在新面板里关掉也不会被再搬回来。
        static let migrated = "MacTagger.lyricsFile.migrated"
    }

    private static func persistLyricsFileOptions(_ o: LyricsFileOptions) {
        guard let data = try? JSONEncoder().encode(o),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: LyricsFileKey.options)
    }

    /// 读取选项。没有新键时**从 `LyricsSettings` 的老键迁移**，避免用户既有设置丢失。
    private static func loadLyricsFileOptions() -> LyricsFileOptions {
        let d = UserDefaults.standard
        if let json = d.string(forKey: LyricsFileKey.options),
           let data = json.data(using: .utf8),
           let restored = try? JSONDecoder().decode(LyricsFileOptions.self, from: data) {
            return restored
        }
        guard !d.bool(forKey: LyricsFileKey.migrated) else { return .default }

        var o = LyricsFileOptions.default
        // 「保存标签的同时保存 Lrc 文件」→ 总开关
        o.enabled = d.object(forKey: "MacTagger.lyrics.saveLrcWithTags") as? Bool ?? false
        // 文件名格式：0 同名 / 1 艺术家 - 标题 / 2 标题 - 艺术家（与老枚举 rawValue 对齐）
        switch d.object(forKey: "MacTagger.lyrics.lrcNameFormat") as? Int ?? 0 {
        case 1:  o.naming = .artistTitle
        case 2:  o.naming = .titleArtist
        default: o.naming = .sameAsAudio
        }
        // 编码：新旧枚举 rawValue 一一对应
        if let raw = d.object(forKey: "MacTagger.lyrics.lrcEncoding") as? Int,
           let enc = LyricsFileEncoding(rawValue: raw) {
            o.encoding = enc
        }
        // 自定义目录
        let useCustom = d.object(forKey: "MacTagger.lyrics.useCustomDir") as? Bool ?? false
        let customPath = d.string(forKey: "MacTagger.lyrics.lrcDirectory") ?? ""
        if useCustom, !customPath.isEmpty {
            o.location = .fixedDirectory(URL(fileURLWithPath: customPath, isDirectory: true))
        }
        // 翻译合并
        o.includeTranslation = d.object(forKey: "MacTagger.lyrics.mergeTranslation") as? Bool ?? true
        let all = TranslationMergeFormat.allCases
        let idx = d.object(forKey: "MacTagger.lyrics.mergeFormat") as? Int ?? 1
        o.mergeFormat = all.indices.contains(idx) ? all[idx] : .twoLines

        d.set(true, forKey: LyricsFileKey.migrated)
        persistLyricsFileOptions(o)
        return o
    }

    // MARK: 外观（跟随系统 / 浅色 / 深色）

    /// 应用外观偏好。既是正经功能，也是深色模式的验收手段：
    /// 不用切换整个 macOS 外观就能单独把 MacTagger 切成深色。
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light:  return "浅色"
            case .dark:   return "深色"
            }
        }

        /// nil = 跟随系统（清掉 NSApp.appearance 的覆盖）。
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: "MacTagger.appearance")
            applyAppearance()
        }
    }

    /// 把当前偏好推给 AppKit。启动时与每次切换后各调一次。
    /// 整个 App 的窗口/菜单/材质都会跟着换，Theme 里的系统语义色与动态色随之解析到深色分支。
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    static let durationChoices: [(label: String, seconds: Int)] = [
        ("未设置", 0), ("10 秒", 10), ("20 秒", 20), ("30 秒", 30),
        ("40 秒", 40), ("50 秒", 50), ("60 秒", 60)
    ]

    init() {
        let d = UserDefaults.standard
        includeSubdirectories = d.object(forKey: "MacTagger.includeSubdirs") as? Bool ?? true
        preserveModificationDate = d.object(forKey: "MacTagger.preserveMtime") as? Bool ?? false
        overwriteArtworkOnAdd = d.object(forKey: "MacTagger.overwriteArtwork") as? Bool ?? true
        ignoreVideoMP4 = d.object(forKey: "MacTagger.ignoreVideoMP4") as? Bool ?? true
        artworkAutoLimitMaxEdge = d.object(forKey: "MacTagger.artworkAutoLimitMaxEdge") as? Int ?? 0
        artworkAutoConvertJPEG = d.object(forKey: "MacTagger.artworkAutoConvertJPEG") as? Bool ?? false
        minimumDurationSeconds = d.object(forKey: "MacTagger.minDuration") as? Int ?? 0
        autoReadTags = AutoReadTagsMode(rawValue: d.string(forKey: "MacTagger.import.autoReadTags") ?? "")
            ?? .auto
        lazyThreshold = max(0, min(100_000,
            d.object(forKey: AppSettings.lazyThresholdKey) as? Int ?? AppSettings.lazyThresholdDefault))
        inlineEditing = d.object(forKey: "MacTagger.inlineEditing") as? Bool ?? false
        let enc = d.object(forKey: "MacTagger.legacyEncoding") as? Int ?? LegacyTextEncoding.strict.rawValue
        legacyEncoding = LegacyTextEncoding(rawValue: enc) ?? .strict
        appearance = AppearanceMode(rawValue: d.string(forKey: "MacTagger.appearance") ?? "") ?? .system
        lyricsFile = AppSettings.loadLyricsFileOptions()
        let variantRaw = d.string(forKey: AppSettings.onlineChineseVariantKey) ?? ""
        onlineChineseVariant = ChineseVariantPolicy(rawValue: variantRaw) ?? .simplified
        transplantTranslation =
            d.object(forKey: AppSettings.transplantTranslationKey) as? Bool ?? true
        TagService.legacyEncoding = legacyEncoding
        // 数据层的三个静态量在这里对齐一次。didSet 在 init 里不触发，必须显式推。
        ChineseVariant.onlineDefault = onlineChineseVariant
        LyricsService.transplantTranslationEnabled = transplantTranslation
        applyAppearance()
    }

    var importOptions: ImportOptions {
        ImportOptions(includeSubdirectories: includeSubdirectories,
                      allowedExtensions: ImportOptions.defaultExtensions,
                      minimumDuration: minimumDurationSeconds > 0 ? TimeInterval(minimumDurationSeconds) : nil,
                      ignoreVideoMP4: ignoreVideoMP4)
    }
}

//
//  LyricsStore.swift
//  MacTagger — 歌词相关的界面偏好
//
//  对应原版 FormOptions 里的歌词区：翻译词下载开关与 4 种合并格式、连接符、
//  「不下载原词（若翻译存在）」、「不下载伴奏版」，以及 Lrc 文件设置
//  （保存目录 / 文件编码 / 文件名格式）与「保存标签的同时保存 Lrc 文件」。
//

import Foundation
import SwiftUI

// MARK: - Lrc 文件名格式

/// 原版三选一：和歌曲文件名相同 / 艺术家 - 标题 / 标题 - 艺术家。
enum LrcNameFormat: Int, CaseIterable, Identifiable {
    case sameAsSong = 0
    case artistTitle = 1
    case titleArtist = 2

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .sameAsSong:  return "和歌曲文件名相同"
        case .artistTitle: return "艺术家 - 标题"
        case .titleArtist: return "标题 - 艺术家"
        }
    }

    /// 生成不含扩展名的基名。标签缺失时退回歌曲文件名，绝不产出 " - " 这种残缺名。
    func baseName(songURL: URL, title: String?, artist: String?) -> String {
        let stem = songURL.deletingPathExtension().lastPathComponent
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        switch self {
        case .sameAsSong:
            return stem
        case .artistTitle:
            guard !t.isEmpty, !a.isEmpty else { return stem }
            return LrcNameFormat.sanitize("\(a) - \(t)")
        case .titleArtist:
            guard !t.isEmpty, !a.isEmpty else { return stem }
            return LrcNameFormat.sanitize("\(t) - \(a)")
        }
    }

    /// 文件名里的 `/` 与 `:` 会被 HFS/APFS 曲解，换成全角。
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "／")
         .replacingOccurrences(of: ":", with: "：")
         .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Lrc 文件编码

enum LrcFileEncoding: Int, CaseIterable, Identifiable {
    case utf8 = 0
    case utf8BOM = 1
    case gb18030 = 2
    case utf16LE = 3

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .utf8:     return "UTF-8"
        case .utf8BOM:  return "UTF-8（含 BOM）"
        case .gb18030:  return "GB18030（简体中文）"
        case .utf16LE:  return "UTF-16 LE"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .utf16LE: return .utf16LittleEndian
        }
    }

    var needsBOM: Bool { self == .utf8BOM || self == .utf16LE }

    var bom: Data {
        switch self {
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LE: return Data([0xFF, 0xFE])
        default:       return Data()
        }
    }
}

// MARK: - 偏好

/// 单例：`AppModel` 与各视图共用。用单例是为了不改动 `AppModel` 已定型的 init 签名。
@MainActor
final class LyricsSettings: ObservableObject {

    static let shared = LyricsSettings()

    private enum Key {
        static let merge        = "MacTagger.lyrics.mergeTranslation"
        static let format       = "MacTagger.lyrics.mergeFormat"
        static let connector    = "MacTagger.lyrics.connector"
        static let transOnly    = "MacTagger.lyrics.translationOnly"
        static let skipInst     = "MacTagger.lyrics.skipInstrumental"
        static let sources      = "MacTagger.lyrics.sources"
        static let limit        = "MacTagger.lyrics.limitPerSource"
        static let overwrite    = "MacTagger.lyrics.overwriteExisting"
        static let saveWithTags = "MacTagger.lyrics.saveLrcWithTags"
        static let nameFormat   = "MacTagger.lyrics.lrcNameFormat"
        static let encoding     = "MacTagger.lyrics.lrcEncoding"
        static let customDir    = "MacTagger.lyrics.lrcDirectory"
        static let useCustomDir = "MacTagger.lyrics.useCustomDir"
        static let msDigits     = "MacTagger.lyrics.msDigits"
    }

    // 翻译合并
    @Published var mergeTranslation: Bool { didSet { d.set(mergeTranslation, forKey: Key.merge) } }
    @Published var mergeFormatRaw: Int { didSet { d.set(mergeFormatRaw, forKey: Key.format) } }
    @Published var connector: String { didSet { d.set(connector, forKey: Key.connector) } }
    /// 原版「不下载原词（若翻译存在）」。
    @Published var translationOnly: Bool { didSet { d.set(translationOnly, forKey: Key.transOnly) } }
    /// 原版「不下载伴奏版」。
    @Published var skipInstrumental: Bool { didSet { d.set(skipInstrumental, forKey: Key.skipInst) } }

    // 搜索
    @Published var enabledSources: Set<String> {
        didSet { d.set(Array(enabledSources), forKey: Key.sources) }
    }
    @Published var limitPerSource: Int { didSet { d.set(limitPerSource, forKey: Key.limit) } }
    /// 批量下载时是否覆盖已有歌词。默认关：已有歌词多半是用户自己整过的。
    @Published var overwriteExisting: Bool { didSet { d.set(overwriteExisting, forKey: Key.overwrite) } }

    // Lrc 文件
    @Published var saveLrcWithTags: Bool { didSet { d.set(saveLrcWithTags, forKey: Key.saveWithTags) } }
    @Published var nameFormatRaw: Int { didSet { d.set(nameFormatRaw, forKey: Key.nameFormat) } }
    @Published var encodingRaw: Int { didSet { d.set(encodingRaw, forKey: Key.encoding) } }
    @Published var useCustomDirectory: Bool { didSet { d.set(useCustomDirectory, forKey: Key.useCustomDir) } }
    @Published var customDirectory: String { didSet { d.set(customDirectory, forKey: Key.customDir) } }

    /// 渲染时间轴的毫秒位数（编辑器「格式化时间轴」的目标）。
    @Published var millisecondDigits: Int { didSet { d.set(millisecondDigits, forKey: Key.msDigits) } }

    private let d = UserDefaults.standard

    init() {
        SourceBootstrap.registerAll()
        mergeTranslation = d.object(forKey: Key.merge) as? Bool ?? true
        mergeFormatRaw = d.object(forKey: Key.format) as? Int ?? 1        // 默认「原词一行，翻译一行」
        connector = d.object(forKey: Key.connector) as? String ?? " "
        translationOnly = d.object(forKey: Key.transOnly) as? Bool ?? false
        skipInstrumental = d.object(forKey: Key.skipInst) as? Bool ?? true
        limitPerSource = d.object(forKey: Key.limit) as? Int ?? 8
        overwriteExisting = d.object(forKey: Key.overwrite) as? Bool ?? false
        saveLrcWithTags = d.object(forKey: Key.saveWithTags) as? Bool ?? false
        nameFormatRaw = d.object(forKey: Key.nameFormat) as? Int ?? 0
        encodingRaw = d.object(forKey: Key.encoding) as? Int ?? 0
        useCustomDirectory = d.object(forKey: Key.useCustomDir) as? Bool ?? false
        customDirectory = d.object(forKey: Key.customDir) as? String ?? ""
        millisecondDigits = d.object(forKey: Key.msDigits) as? Int ?? 2

        let available = Set(LyricsSettings.lyricsCapableIDs)
        if let saved = d.stringArray(forKey: Key.sources) {
            let restored = Set(saved).intersection(available)
            enabledSources = restored.isEmpty ? available : restored
        } else {
            enabledSources = available
        }
    }

    // MARK: 派生

    /// 注册表里同时支持「搜索 + 歌词」的源。iTunes/MusicBrainz 不供词，自然不出现在这里。
    static var lyricsCapableIDs: [String] {
        let reg = SourceRegistry.shared
        return reg.recommendedOrder.filter {
            guard let caps = reg.source(id: $0)?.capabilities else { return false }
            return caps.contains(.lyrics) && caps.contains(.searchTracks)
        }
    }

    var activeSourceIDs: [String] {
        LyricsSettings.lyricsCapableIDs.filter { enabledSources.contains($0) }
    }

    var mergeFormat: TranslationMergeFormat {
        get {
            let all = TranslationMergeFormat.allCases
            return all.indices.contains(mergeFormatRaw) ? all[mergeFormatRaw] : .twoLines
        }
        set {
            mergeFormatRaw = TranslationMergeFormat.allCases.firstIndex(of: newValue) ?? 1
        }
    }

    var nameFormat: LrcNameFormat {
        get { LrcNameFormat(rawValue: nameFormatRaw) ?? .sameAsSong }
        set { nameFormatRaw = newValue.rawValue }
    }

    var fileEncoding: LrcFileEncoding {
        get { LrcFileEncoding(rawValue: encodingRaw) ?? .utf8 }
        set { encodingRaw = newValue.rawValue }
    }

    var mergeOptions: LyricsMergeOptions {
        LyricsMergeOptions(mergeTranslation: mergeTranslation,
                           format: mergeFormat,
                           connector: connector,
                           translationOnly: translationOnly,
                           preferWordByWord: false)
    }

    var isRunnable: Bool { !activeSourceIDs.isEmpty }

    func toggleSource(_ id: String) {
        if enabledSources.contains(id) { enabledSources.remove(id) } else { enabledSources.insert(id) }
    }

    /// Lrc 的落盘目录：勾了自定义目录就用它，否则跟歌曲同目录。
    func outputDirectory(for songURL: URL) -> URL {
        guard useCustomDirectory, !customDirectory.isEmpty else {
            return songURL.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: customDirectory, isDirectory: true)
    }

    func resetToDefaults() {
        mergeTranslation = true
        mergeFormatRaw = 1
        connector = " "
        translationOnly = false
        skipInstrumental = true
        limitPerSource = 8
        overwriteExisting = false
        saveLrcWithTags = false
        nameFormatRaw = 0
        encodingRaw = 0
        useCustomDirectory = false
        customDirectory = ""
        millisecondDigits = 2
        enabledSources = Set(LyricsSettings.lyricsCapableIDs)
    }
}

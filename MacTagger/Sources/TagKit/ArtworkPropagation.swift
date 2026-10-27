//
//  ArtworkPropagation.swift
//  MacTagger — 「从标签取图」的纯逻辑层（对应原版 FormPictureFromTags）
//
//  场景：一整张专辑里往往只有一首带封面（从别处下载的那首），其余全是空的。
//  这里负责把「谁的封面该给谁」算出来，**不碰磁盘、不碰 AppKit**，
//  因此可以在 CLI probe 里直接跑（`mactagger-probe artprop <dir>`），也易于单测。
//
//  配对规则（与原版一致，并补了原版没有的两条防呆）：
//  1. 只有「专辑」与「专辑艺术家」都相同才算同一张专辑；专辑艺术家两边都为空时退化成
//     「专辑 + 艺术家」相同，仍为空才退到只比专辑 —— 只比专辑会把不同歌手的
//     《Greatest Hits》混成一张碟，这是原版的真实翻车点。
//  2. 专辑名做规范化再比：去首尾空白、折叠连续空白、大小写不敏感、全角括号转半角。
//  3. 同一张专辑有多个带封面的源时，取**字节数最大**的那张（通常也是分辨率最高的），
//     字节数相同再按文件名排序，保证结果可复现。
//

import Foundation

// MARK: - 输入

/// 参与配对的一个文件。刻意只带配对需要的字段，封面二进制不进来
/// （列表里成百上千个文件，封面全读进内存会直接吃掉几个 GB）。
public struct ArtworkFileInfo: Identifiable, Sendable, Equatable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var fileName: String
    public var album: String?
    public var albumArtist: String?
    public var artist: String?
    /// 文件里是否已有封面。
    public var hasArtwork: Bool
    /// 第一张封面的字节数（挑「最好的源」用）。无封面为 0。
    public var artworkByteCount: Int

    public init(url: URL,
                fileName: String? = nil,
                album: String? = nil,
                albumArtist: String? = nil,
                artist: String? = nil,
                hasArtwork: Bool = false,
                artworkByteCount: Int = 0) {
        self.url = url
        self.fileName = fileName ?? url.lastPathComponent
        self.album = album
        self.albumArtist = albumArtist
        self.artist = artist
        self.hasArtwork = hasArtwork
        self.artworkByteCount = artworkByteCount
    }

    public var albumDisplay: String {
        let a = (album ?? "").trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? "（无专辑）" : a
    }

    public var albumArtistDisplay: String {
        let a = (albumArtist ?? "").trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { return a }
        let b = (artist ?? "").trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? "—" : b
    }
}

// MARK: - 配对

public struct ArtworkPairing: Identifiable, Sendable, Equatable {
    /// 目标文件唯一，直接拿它当 id。
    public var id: URL { target.url }
    public var source: ArtworkFileInfo
    public var target: ArtworkFileInfo
    public var reason: Reason
    /// 复核表里默认勾选。
    public var accepted: Bool = true

    public enum Reason: String, Sendable, Equatable {
        case albumAndAlbumArtist
        case albumAndArtist
        case albumOnly

        public var localizedName: String {
            switch self {
            case .albumAndAlbumArtist: return "专辑 + 专辑艺术家"
            case .albumAndArtist:      return "专辑 + 艺术家"
            case .albumOnly:           return "仅专辑名"
            }
        }
    }

    public init(source: ArtworkFileInfo, target: ArtworkFileInfo, reason: Reason) {
        self.source = source
        self.target = target
        self.reason = reason
    }
}

public struct ArtworkPropagationPlan: Sendable {
    public var pairings: [ArtworkPairing]
    /// 没找到同专辑封面源的目标文件。
    public var unmatched: [ArtworkFileInfo]
    /// 可当源用的文件（有封面的）。
    public var sources: [ArtworkFileInfo]

    public var isEmpty: Bool { pairings.isEmpty }
    public var acceptedCount: Int { pairings.filter(\.accepted).count }

    public var summary: String {
        "可配对 \(pairings.count) 项，无匹配 \(unmatched.count) 项，可用封面源 \(sources.count) 个"
    }
}

// MARK: - 算法

public enum ArtworkPropagation {

    /// 专辑名规范化：折叠空白 + 大小写不敏感 + 全角括号/破折号转半角。
    public static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "（", with: "(")
             .replacingOccurrences(of: "）", with: ")")
             .replacingOccurrences(of: "【", with: "[")
             .replacingOccurrences(of: "】", with: "]")
             .replacingOccurrences(of: "－", with: "-")
             .replacingOccurrences(of: "　", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }

    /// 三档分组键：越靠前越严格。返回 nil 表示这一档信息不全，不参与该档匹配。
    static func key(_ f: ArtworkFileInfo, level: ArtworkPairing.Reason) -> String? {
        let album = normalize(f.album)
        guard !album.isEmpty else { return nil }
        switch level {
        case .albumAndAlbumArtist:
            let aa = normalize(f.albumArtist)
            guard !aa.isEmpty else { return nil }
            return album + "\u{1}" + aa
        case .albumAndArtist:
            let ar = normalize(f.artist)
            guard !ar.isEmpty else { return nil }
            return album + "\u{2}" + ar
        case .albumOnly:
            return album
        }
    }

    /// 同一个键下选最优封面源：字节数大的优先，其次文件名字典序（保证可复现）。
    static func bestSource(_ candidates: [ArtworkFileInfo]) -> ArtworkFileInfo? {
        candidates.max { a, b in
            if a.artworkByteCount != b.artworkByteCount {
                return a.artworkByteCount < b.artworkByteCount
            }
            return a.fileName > b.fileName        // max 取「更大」的，这里反向让字典序小的胜出
        }
    }

    /// 「按专辑自动匹配」：给每个**无封面**的文件找一个同专辑、**有封面**的源文件。
    ///
    /// - Parameters:
    ///   - files: 参与配对的全部文件
    ///   - targets: 限定目标范围（例如「只处理选中的这几项」）。nil = 全部无封面文件。
    ///   - includeFilesWithArtwork: 已有封面的文件是否也当目标（原版的「覆盖」语义）。默认否。
    ///   - allowAlbumOnly: 允许退化到「仅专辑名」这一档。默认允许，但会在 reason 里标出来，
    ///     让用户在复核表里一眼看见哪些是弱匹配。
    public static func autoMatchByAlbum(_ files: [ArtworkFileInfo],
                                        targets: Set<URL>? = nil,
                                        includeFilesWithArtwork: Bool = false,
                                        allowAlbumOnly: Bool = true) -> ArtworkPropagationPlan {
        let sources = files.filter { $0.hasArtwork }
        let targetPool = files.filter { f in
            if let targets, !targets.contains(f.url) { return false }
            if f.hasArtwork && !includeFilesWithArtwork { return false }
            return true
        }

        // 三档索引，一次建好，避免每个目标都全表扫描。
        var index: [ArtworkPairing.Reason: [String: [ArtworkFileInfo]]] = [:]
        for level in [ArtworkPairing.Reason.albumAndAlbumArtist, .albumAndArtist, .albumOnly] {
            var bucket: [String: [ArtworkFileInfo]] = [:]
            for s in sources {
                guard let k = key(s, level: level) else { continue }
                bucket[k, default: []].append(s)
            }
            index[level] = bucket
        }

        var pairings: [ArtworkPairing] = []
        var unmatched: [ArtworkFileInfo] = []

        var levels: [ArtworkPairing.Reason] = [.albumAndAlbumArtist, .albumAndArtist]
        if allowAlbumOnly { levels.append(.albumOnly) }

        for t in targetPool {
            var matched = false
            for level in levels {
                guard let k = key(t, level: level),
                      let bucket = index[level]?[k] else { continue }
                // 自己不能给自己
                let usable = bucket.filter { $0.url != t.url }
                guard let src = bestSource(usable) else { continue }
                pairings.append(ArtworkPairing(source: src, target: t, reason: level))
                matched = true
                break
            }
            if !matched { unmatched.append(t) }
        }

        pairings.sort { $0.target.fileName.localizedStandardCompare($1.target.fileName) == .orderedAscending }
        unmatched.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        return ArtworkPropagationPlan(pairings: pairings,
                                      unmatched: unmatched,
                                      sources: sources.sorted {
                                          $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                                      })
    }

    /// 「把这一个源的封面发给这些目标」——界面上手动选源时用。
    public static func manualPlan(source: ArtworkFileInfo,
                                  targets: [ArtworkFileInfo]) -> ArtworkPropagationPlan {
        let pairs = targets
            .filter { $0.url != source.url }
            .map { ArtworkPairing(source: source, target: $0, reason: .albumOnly) }
        return ArtworkPropagationPlan(pairings: pairs, unmatched: [], sources: [source])
    }
}

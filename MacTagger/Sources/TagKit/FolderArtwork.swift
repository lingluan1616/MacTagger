//
//  FolderArtwork.swift
//  MacTagger — 文件夹封面（把封面存成专辑目录里的图片文件，音频一个字节不动）
//
//  为什么要有这条路：
//  用户的无损库在 TF 卡上。往 FLAC 里嵌一张 1 MB 的封面时，只要它超过文件头
//  预留的 PADDING（TagLib 默认约 4 KB），TagLib 就得把**整段音频数据整体后移**
//  —— 几十 MB 一首，慢且写入量大，对闪存也不友好。
//
//  文件夹封面完全绕开这件事：图片单独写在专辑目录里（`cover.jpg` 之类），
//  音频文件根本不打开。代价是播放器要认这套约定（绝大多数都认：
//  foobar2000 / MusicBee / Plex / Navidrome / Apple Music 导入均支持）。
//
//  三条约定：
//  1. **扩展名按字节内容定**，不按用户在标签里填的 MIME —— 那个字段常年写错，
//     写出个 `cover.jpg` 里面装 PNG，一半播放器就瞎了。
//  2. **同一文件夹只写一次**。批量选中一整张专辑的 12 首歌时，目标文件夹只有
//     一个，重复写 12 遍既没意义又多 11 次闪存写入。
//  3. **原子写**：先写同目录下的临时文件，再 `replaceItemAt` 换过去。中途断电
//     只会留下一个临时文件，不会留下半张图。
//

import Foundation

// MARK: - 封面落地方式

/// 一张封面最终落在哪里。
public enum ArtworkEmbedMode: String, CaseIterable, Sendable, Hashable {
    /// 嵌进音频标签（原版行为，默认）。
    case embed
    /// 只写专辑文件夹里的图片文件，**音频一个字节不动**。TF 卡 / 大无损库首选。
    case folderFile
    /// 两边都写。
    case both

    public var localizedName: String {
        switch self {
        case .embed:      return "嵌入音频标签"
        case .folderFile: return "存为文件夹封面（不动音频）"
        case .both:       return "两者都写"
        }
    }

    public var writesTag: Bool { self != .folderFile }
    public var writesFolderFile: Bool { self != .embed }
}

// MARK: - 命名规则

/// 文件夹封面的文件名规则。原版（MusicTag）只有 cover / folder 两种，
/// `albumName` 是给「一个目录里放多张专辑」的人留的口子。
public enum FolderArtworkNaming: String, CaseIterable, Sendable, Hashable {
    /// `cover.jpg` / `cover.png`
    case coverJpg
    /// `folder.jpg` / `folder.png`
    case folderJpg
    /// `<净化后的专辑名>.jpg`；拿不到专辑名时退回 `cover`。
    case albumName

    public var localizedName: String {
        switch self {
        case .coverJpg:  return "cover.jpg（通用）"
        case .folderJpg: return "folder.jpg（Windows / MusicBee）"
        case .albumName: return "专辑名.jpg"
        }
    }

    /// 不含扩展名的基名。`albumName` 传空专辑名时退回 `cover`。
    public func baseName(album: String?) -> String {
        switch self {
        case .coverJpg:  return "cover"
        case .folderJpg: return "folder"
        case .albumName:
            let clean = RenameService.sanitizeComponent(album ?? "")
            return clean.isEmpty ? "cover" : clean
        }
    }
}

// MARK: - 结果模型

/// 单个文件夹的写入结果。
public struct FolderArtworkWrite: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 新写入 / 覆盖成功。
        case written
        /// 已存在同名文件且 `overwrite == false`，未改动。
        case skippedExisting
    }
    public var folder: URL
    public var file: URL
    public var outcome: Outcome
    public var byteCount: Int

    public var isWritten: Bool { outcome == .written }
}

// MARK: - 服务

public enum FolderArtwork {

    /// 识别得了的图片扩展名（`locate` 用；写入只会产出 jpg / png）。
    public static let recognizedExtensions = ["jpg", "jpeg", "png", "webp", "bmp", "gif", "tif", "tiff"]

    /// `locate` 的基名优先级。排在前面的先中。
    /// 依据：foobar2000 / MusicBee / Navidrome / Plex 的默认封面搜索表取交集后按常见度排序。
    public static let commonBaseNames = ["cover", "folder", "front", "album", "albumart", "artwork", "thumb"]

    // MARK: 扩展名

    /// 按**实际字节**判定扩展名。识别不了一律按 jpg（写进去的东西不会因此变形，
    /// 只是名字保守）。
    public static func fileExtension(forImage data: Data, declaredMIME: String? = nil) -> String {
        let mime = ArtworkProcessor.mimeType(data) ?? declaredMIME ?? "image/jpeg"
        switch mime.lowercased() {
        case "image/png":  return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif":  return "gif"
        case "image/tiff": return "tif"
        case "image/bmp":  return "bmp"
        default:           return "jpg"
        }
    }

    /// 按命名规则算出目标文件名（含扩展名）。
    public static func fileName(for data: Data,
                                declaredMIME: String? = nil,
                                naming: FolderArtworkNaming,
                                album: String? = nil) -> String {
        naming.baseName(album: album) + "." + fileExtension(forImage: data, declaredMIME: declaredMIME)
    }

    // MARK: 写

    /// 把一张封面写成 `folder` 里的图片文件。
    ///
    /// - Parameters:
    ///   - data:      图片原始字节。
    ///   - mime:      标签里声明的 MIME，仅作兜底；扩展名以实际字节为准。
    ///   - folder:    专辑目录（必须已存在，本方法不建目录 —— 建目录属于「改动用户库结构」，
    ///                不该由一个写封面的动作顺手做）。
    ///   - naming:    命名规则。
    ///   - album:     `naming == .albumName` 时用到。
    ///   - overwrite: false 且目标已存在 → 不动它，返回现有路径。
    /// - Returns: 最终的文件路径。
    @discardableResult
    public static func write(data: Data,
                             mime: String? = nil,
                             to folder: URL,
                             naming: FolderArtworkNaming = .coverJpg,
                             album: String? = nil,
                             overwrite: Bool = false) throws -> URL {
        guard !data.isEmpty else {
            throw TagError.invalidArgument("封面数据为空")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw TagError.fileNotFound("目录不存在：\(folder.path)")
        }

        let name = fileName(for: data, declaredMIME: mime, naming: naming, album: album)
        let target = folder.appendingPathComponent(name)

        if !overwrite, FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        try atomicWrite(data, to: target)
        return target
    }

    /// 原子写：同目录临时文件 → `replaceItemAt`。
    /// 跨卷 rename 会失败，所以临时文件必须落在**同一个目录**里。
    static func atomicWrite(_ data: Data, to target: URL) throws {
        let folder = target.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".mactagger-cover-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw TagError.writeFailed("写文件夹封面失败：\(error.localizedDescription)")
        }
    }

    // MARK: 查

    /// 在 `folder` 里找已有的文件夹封面。找不到返回 nil。
    ///
    /// 优先级：`commonBaseNames` 的顺序 × `recognizedExtensions` 的顺序，**大小写不敏感**
    /// （APFS 默认大小写不敏感，但 exFAT / 网络卷未必，所以逐项比对而不是直接拼路径 stat）。
    /// 都没中时，若给了 `album`，再按净化后的专辑名找一遍。
    public static func locate(folder: URL, album: String? = nil) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }

        // 建索引：小写基名 → [(小写扩展名, 原始文件名)]
        var index: [String: [(ext: String, name: String)]] = [:]
        for name in names where !name.hasPrefix(".") {
            let ns = name as NSString
            let base = ns.deletingPathExtension.lowercased()
            let ext = ns.pathExtension.lowercased()
            guard recognizedExtensions.contains(ext) else { continue }
            index[base, default: []].append((ext, name))
        }
        guard !index.isEmpty else { return nil }

        func pick(_ base: String) -> URL? {
            guard let hits = index[base] else { return nil }
            for ext in recognizedExtensions {
                if let hit = hits.first(where: { $0.ext == ext }) {
                    return folder.appendingPathComponent(hit.name)
                }
            }
            return hits.first.map { folder.appendingPathComponent($0.name) }
        }

        for base in commonBaseNames {
            if let url = pick(base) { return url }
        }
        let clean = RenameService.sanitizeComponent(album ?? "").lowercased()
        if !clean.isEmpty, let url = pick(clean) { return url }
        return nil
    }

    /// 一批音频文件各自所在目录里，哪些已经有文件夹封面。键是**目录**。
    public static func locateAll(for audioURLs: [URL]) -> [URL: URL] {
        var seen: [URL: URL?] = [:]
        for url in audioURLs {
            let folder = url.deletingLastPathComponent()
            if seen[folder] == nil { seen[folder] = locate(folder: folder) }
        }
        return seen.compactMapValues { $0 }
    }

    // MARK: 批量

    /// 把同一张封面写到这批音频文件所在的**每个目录**里（按目录去重，一个目录只写一次）。
    ///
    /// `BatchSummary` 的口径：
    ///   * `total`     = 去重后的**文件夹数**（不是音频文件数）
    ///   * `succeeded` = 实际写入的文件夹数
    ///   * `ignored`   = 已存在同名文件且未开覆盖 → 跳过
    ///   * `failed`    = 抛错的文件夹
    public static func writeBatch(data: Data,
                                  mime: String? = nil,
                                  audioURLs: [URL],
                                  naming: FolderArtworkNaming = .coverJpg,
                                  albumProvider: ((URL) -> String?)? = nil,
                                  overwrite: Bool = false)
        -> (summary: BatchSummary, writes: [FolderArtworkWrite])
    {
        let started = Date()

        // 按目录去重，保留首次出现顺序（结果表读起来跟用户选中的顺序一致）。
        var folders: [URL] = []
        var firstFileInFolder: [URL: URL] = [:]
        for url in audioURLs {
            let folder = url.deletingLastPathComponent()
            if firstFileInFolder[folder] == nil {
                firstFileInFolder[folder] = url
                folders.append(folder)
            }
        }

        var summary = BatchSummary(total: folders.count)
        var writes: [FolderArtworkWrite] = []

        for folder in folders {
            let album = albumProvider.flatMap { provider in
                firstFileInFolder[folder].flatMap(provider)
            }
            let name = fileName(for: data, declaredMIME: mime, naming: naming, album: album)
            let target = folder.appendingPathComponent(name)
            let exists = FileManager.default.fileExists(atPath: target.path)

            if exists && !overwrite {
                summary.ignored += 1
                summary.ignoredItems.append((target, "已存在同名文件夹封面，未开启覆盖"))
                writes.append(FolderArtworkWrite(folder: folder, file: target,
                                                 outcome: .skippedExisting, byteCount: data.count))
                continue
            }
            do {
                let url = try write(data: data, mime: mime, to: folder,
                                    naming: naming, album: album, overwrite: true)
                summary.succeeded += 1
                writes.append(FolderArtworkWrite(folder: folder, file: url,
                                                 outcome: .written, byteCount: data.count))
            } catch {
                summary.failed += 1
                let tagError = (error as? TagError) ?? .unknown(error.localizedDescription)
                summary.failures.append((target, tagError))
            }
        }

        summary.elapsed = Date().timeIntervalSince(started)
        return (summary, writes)
    }

    // MARK: 反向：文件夹封面 → 标签

    /// 读出该目录的文件夹封面，组装成可直接写进标签的 `Artwork`。
    /// 没有文件夹封面、或图片读不出来时返回 nil。
    public static func artwork(inFolder folder: URL, album: String? = nil) -> Artwork? {
        guard let url = locate(folder: folder, album: album),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let art = Artwork(data: data,
                          mimeType: ArtworkProcessor.mimeType(data) ?? "image/jpeg",
                          caption: nil,
                          type: .frontCover)
        return ArtworkProcessor.refreshedMetadata(art)
    }
}

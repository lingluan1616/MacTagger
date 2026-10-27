//
//  LibraryOrganizer.swift
//  MacTagger — 按标签整理到文件夹（标签 → 目录结构）
//
//  「文件名 ↔ 标签」解决的是**一个文件叫什么**，这里解决的是**它该躺在哪**：
//  同一条模板，`/` 前面的每一段是一级目录，最后一段是文件名。
//
//      @2/@3/@5 - @1   ⇒   周杰伦/魔杰座/03 - 稻香.flac
//
//  与 `RenameService` 同构的两段式：
//    · `plan(...)`  只算不动盘，逐文件给出目标路径 / 状态 / 中文原因，界面照着画预览树；
//    · `execute(...)` 才真正搬文件，逐条失败不中断整批，统计沿用 `BatchSummary`。
//
//  三件 `RenameService` 没有、这里必须自己扛的事：
//
//  1. **同卷移动 vs 跨卷复制**。同卷 `moveItem` 在 TF 卡上只改目录项，几毫秒、零写入量；
//     跨卷 `moveItem` 其实是「复制 + 删源」，中途失败会留下半个文件。所以跨卷一律
//     显式走 **复制 → 校验（大小 + SHA-256）→ （可选）删源**，默认**不删源**。
//  2. **目录是新建出来的**。撤消时要把本批建的、且现在真空了的目录一并收掉，
//     否则用户撤消完看到的是一地空壳。目录清单记进 `RenameJournalBatch.createdDirectories`。
//  3. **伴随文件与文件夹封面**。同名 `.lrc/.txt/.srt` 跟着走；
//     `cover.jpg / folder.jpg / <专辑名>.jpg` 只在**整个源目录的音频全部搬走**、
//     且全部落到**同一个目标目录**时才跟着走 —— 否则那张图还得留给没搬走的邻居用。
//
//  纯逻辑、不依赖 AppKit，`mactagger-probe organize …` 可端到端验证。
//

import Foundation
import CryptoKit

// MARK: - 策略

/// 目标根目录。
public enum OrganizeRoot: Sendable, Equatable {
    /// 就地整理：以**每个文件当前所在的目录**为根重排。
    /// 界面上的「就地整理」在有工作目录时传 `.fixed(工作目录)`，没有时退到这里。
    case eachFileFolder
    /// 固定根目录（「指定目录…」，以及「就地整理」时的侧栏工作目录）。
    case fixed(URL)

    /// 某个源文件对应的根。
    public func root(for source: URL) -> URL {
        switch self {
        case .eachFileFolder: return source.deletingLastPathComponent()
        case .fixed(let url): return url
        }
    }

    public var fixedURL: URL? {
        if case .fixed(let url) = self { return url }
        return nil
    }
}

/// 模板用到的字段是空的时候怎么办。
public enum OrganizeMissingPolicy: String, CaseIterable, Sendable, Identifiable, Codable {
    /// 填「未知艺术家 / 未知专辑」（默认）。
    case fillUnknown
    /// 跳过该文件，一个字节都不动。
    case skipFile

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .fillUnknown: return "填「未知艺术家 / 未知专辑」"
        case .skipFile:    return "跳过该文件"
        }
    }
}

/// 目标路径已被占用（磁盘上已有，或同批内两个文件算到了同一个目标）时怎么办。
public enum OrganizeConflictPolicy: String, CaseIterable, Sendable, Identifiable, Codable {
    /// 跳过该文件。
    case skip
    /// 在文件名后加 ` (2)` `(3)`…（默认）。
    case suffix

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .skip:   return "跳过该文件"
        case .suffix: return "加 (2)"
        }
    }
}

/// 整理选项。
public struct OrganizeOptions: Sendable, Equatable {

    public var missing: OrganizeMissingPolicy
    public var conflict: OrganizeConflictPolicy
    /// 同名 `.lrc` / `.txt` / `.srt` 跟着走。
    public var moveCompanions: Bool
    /// 整组搬走时把源目录的文件夹封面也带走。
    public var moveFolderArtwork: Bool
    /// 整理后删掉**真正空**的源目录。
    public var deleteEmptySourceFolders: Bool
    /// 跨卷复制成功并校验通过后删掉源文件。默认 false（复制不删源）。
    public var deleteSourceAfterCrossVolumeCopy: Bool
    /// 渲染口径。默认 `.organize`：音轨号两位补零 + 碟号仅多碟时出现。
    public var render: FilenameRenderOptions
    /// 伴随文件扩展名（小写，不含点）。
    public var companionExtensions: [String]
    public var unknownArtist: String
    public var unknownAlbum: String

    public init(missing: OrganizeMissingPolicy = .fillUnknown,
                conflict: OrganizeConflictPolicy = .suffix,
                moveCompanions: Bool = true,
                moveFolderArtwork: Bool = true,
                deleteEmptySourceFolders: Bool = true,
                deleteSourceAfterCrossVolumeCopy: Bool = false,
                render: FilenameRenderOptions = .organize,
                companionExtensions: [String] = ["lrc", "txt", "srt"],
                unknownArtist: String = "未知艺术家",
                unknownAlbum: String = "未知专辑") {
        self.missing = missing
        self.conflict = conflict
        self.moveCompanions = moveCompanions
        self.moveFolderArtwork = moveFolderArtwork
        self.deleteEmptySourceFolders = deleteEmptySourceFolders
        self.deleteSourceAfterCrossVolumeCopy = deleteSourceAfterCrossVolumeCopy
        self.render = render
        self.companionExtensions = companionExtensions
        self.unknownArtist = unknownArtist
        self.unknownAlbum = unknownAlbum
    }

    public static let `default` = OrganizeOptions()
}

// MARK: - 预设模板

/// 出厂预设目录结构。`custom` 由用户自己写，复用「文件名 ↔ 标签」那套自定义模板存储。
public enum OrganizeTemplatePreset: String, CaseIterable, Sendable, Identifiable, Codable {
    case artistAlbumTrack        // @2/@3/@5 - @1
    case albumArtistYearAlbum    // @8/@6 - @3/@4-@5 - @1
    case albumTrack              // @3/@5 - @1
    case custom

    public var id: String { rawValue }

    public var template: String? {
        switch self {
        case .artistAlbumTrack:     return "@2/@3/@5 - @1"
        case .albumArtistYearAlbum: return "@8/@6 - @3/@4-@5 - @1"
        case .albumTrack:           return "@3/@5 - @1"
        case .custom:               return nil
        }
    }

    public var localizedName: String {
        switch self {
        case .artistAlbumTrack:     return "艺术家 / 专辑 / 序号 - 标题"
        case .albumArtistYearAlbum: return "专辑艺术家 / 年份 - 专辑 / 碟-序号 - 标题"
        case .albumTrack:           return "专辑 / 序号 - 标题"
        case .custom:               return "自定义…"
        }
    }

    /// 一行示例路径，下拉里跟在名字后面。
    public var example: String? {
        switch self {
        case .artistAlbumTrack:     return "周杰伦/魔杰座/03 - 稻香.flac"
        case .albumArtistYearAlbum: return "周杰伦/2008 - 魔杰座/03 - 稻香.flac"
        case .albumTrack:           return "魔杰座/03 - 稻香.flac"
        case .custom:               return nil
        }
    }

    /// 出厂默认。
    public static let `default` = OrganizeTemplatePreset.artistAlbumTrack

    /// 反查：这条模板串是哪个预设（都不是则 `.custom`）。
    public static func matching(_ raw: String) -> OrganizeTemplatePreset {
        allCases.first { $0.template == raw } ?? .custom
    }
}

// MARK: - 计划行

/// 一行整理预览。
public struct OrganizePlanItem: Sendable, Identifiable, Equatable {

    public enum Status: Sendable, Equatable {
        /// 可以执行。
        case ready
        /// 已经在目标位置上了，无需处理。
        case unchanged(String)
        /// 按策略主动跳过（缺字段跳过 / 重名跳过）。
        case skipped(String)
        /// 算不出目标路径。
        case invalid(String)

        public var isReady: Bool { if case .ready = self { return true }; return false }

        public var reason: String? {
            switch self {
            case .ready: return nil
            case .unchanged(let r), .skipped(let r), .invalid(let r): return r
            }
        }
    }

    public var id: URL { sourceURL }
    public var sourceURL: URL
    /// 目标完整路径。不可执行时等于源路径。
    public var targetURL: URL
    /// 目标根（`targetURL` 去掉 `components` 之后剩下的那一截）。
    public var rootURL: URL
    /// 目标根之下的层级，最后一项是文件名（含扩展名）。
    public var components: [String]
    /// 跨卷 —— 会走「复制 + 校验」而不是移动。
    public var isCrossVolume: Bool
    /// 伴随文件（`.lrc` / `.txt` / `.srt`）的搬运计划。
    public var companions: [CompanionMove]
    public var status: Status
    /// 需要让用户知道的补充说明（缺字段已填、重名已加后缀…）。
    public var notes: [String]

    public var currentName: String { sourceURL.lastPathComponent }
    /// 目标目录（不含文件名）。
    public var targetFolder: URL { targetURL.deletingLastPathComponent() }
    /// 「一级/二级/文件名」，预览右栏直接显示。
    public var relativePath: String { components.joined(separator: "/") }

    public struct CompanionMove: Sendable, Equatable {
        public var from: URL
        public var to: URL
        public init(from: URL, to: URL) { self.from = from; self.to = to }
    }

    public init(sourceURL: URL,
                targetURL: URL,
                rootURL: URL,
                components: [String],
                isCrossVolume: Bool = false,
                companions: [CompanionMove] = [],
                status: Status,
                notes: [String] = []) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.rootURL = rootURL
        self.components = components
        self.isCrossVolume = isCrossVolume
        self.companions = companions
        self.status = status
        self.notes = notes
    }
}

// MARK: - 预览树

/// 预览树的一个节点。`children == nil` 即叶子（文件）。
public struct OrganizeTreeNode: Sendable, Identifiable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// 目标根。
        case root
        /// 目录。`isNew` 表示本次会新建。
        case folder(isNew: Bool)
        case file
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// 子树里的文件总数（叶子自己算 1）。
    public var fileCount: Int
    public var children: [OrganizeTreeNode]?
    /// 叶子专用：对应的计划行状态，决定圆点颜色与 tooltip。
    public var status: OrganizePlanItem.Status?
    /// 叶子专用：跨卷标记。
    public var isCrossVolume: Bool
    /// 叶子专用：补充说明。
    public var notes: [String]

    public var isFile: Bool { if case .file = kind { return true }; return false }
    public var isNewFolder: Bool { if case .folder(let isNew) = kind { return isNew }; return false }

    public init(id: String,
                name: String,
                kind: Kind,
                fileCount: Int = 0,
                children: [OrganizeTreeNode]? = nil,
                status: OrganizePlanItem.Status? = nil,
                isCrossVolume: Bool = false,
                notes: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileCount = fileCount
        self.children = children
        self.status = status
        self.isCrossVolume = isCrossVolume
        self.notes = notes
    }
}

// MARK: - 计划

/// 一整份整理计划。界面把它当唯一真相源画预览树、原→新列表与底部统计。
public struct OrganizePlan: Sendable {

    public var items: [OrganizePlanItem]
    /// 预览树（一个目标根一棵）。
    public var tree: [OrganizeTreeNode]
    /// 本次需要**新建**的目录，浅的在前（执行时按这个顺序建）。
    public var newDirectories: [URL]
    /// 整组搬走时跟着走的文件夹封面。
    public var folderArtworkMoves: [(from: URL, to: URL)]
    /// 模板本身的错误（非 nil 时整份计划为空）。
    public var ruleError: String?

    public init(items: [OrganizePlanItem] = [],
                tree: [OrganizeTreeNode] = [],
                newDirectories: [URL] = [],
                folderArtworkMoves: [(from: URL, to: URL)] = [],
                ruleError: String? = nil) {
        self.items = items
        self.tree = tree
        self.newDirectories = newDirectories
        self.folderArtworkMoves = folderArtworkMoves
        self.ruleError = ruleError
    }

    public var readyItems: [OrganizePlanItem] { items.filter { $0.status.isReady } }
    public var readyCount: Int { readyItems.count }
    public var skippedCount: Int { items.filter { if case .skipped = $0.status { return true }; return false }.count }
    public var unchangedCount: Int { items.filter { if case .unchanged = $0.status { return true }; return false }.count }
    public var invalidCount: Int { items.filter { if case .invalid = $0.status { return true }; return false }.count }
    public var crossVolumeCount: Int { readyItems.filter(\.isCrossVolume).count }
    public var companionCount: Int { readyItems.reduce(0) { $0 + $1.companions.count } }

    /// 目标目录数（去重）。
    public var targetFolderCount: Int {
        Set(readyItems.map { $0.targetFolder.path }).count
    }

    /// 底部那句统计。
    public var summaryLine: String {
        guard readyCount > 0 else { return "没有可整理的文件" }
        var text = "将移动 \(readyCount) 个文件到 \(targetFolderCount) 个文件夹"
            + "（其中新建 \(newDirectories.count) 个）"
        if crossVolumeCount > 0 { text += "，跨卷复制 \(crossVolumeCount) 个" }
        return text
    }
}

// MARK: - 复制校验

/// 跨卷复制的校验：先比大小（快），再比 SHA-256（准）。
public enum FileCopyVerifier {

    /// 分块读，避免把一首无损整个读进内存。
    static let chunkSize = 1 << 20   // 1 MB

    public static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value }
    }

    /// 流式 SHA-256。读不出来返回 nil。
    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 两个文件是否逐字节一致（大小 + SHA-256）。
    public static func matches(_ a: URL, _ b: URL) -> Bool {
        guard let sa = fileSize(a), let sb = fileSize(b), sa == sb else { return false }
        guard let ha = sha256(a), let hb = sha256(b) else { return false }
        return ha == hb
    }
}

// MARK: - 服务

public enum LibraryOrganizer {

    // MARK: 卷判定

    /// 两个路径是否在同一个卷上。取不到卷信息时保守判为**不同卷**
    /// （宁可走「复制 + 校验 + 不删源」这条更慢但绝不丢文件的路）。
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ta = VolumeInfo.traits(of: a), tb = VolumeInfo.traits(of: b)
        guard let pa = ta.volumePath, let pb = tb.volumePath else { return false }
        return pa == pb
    }

    // MARK: 生成计划

    /// 只算不动盘。
    ///
    /// - Parameters:
    ///   - items:    源文件与它的标签（界面传 `draft`，检查器里刚改没保存的值也能立刻反映）。
    ///   - template: 已解析的分层模板（用 `FilenameTemplate.validatePath` 先校验）。
    ///   - root:     目标根。
    public static func plan(items: [(url: URL, tags: Tags)],
                            template: FilenameTemplate,
                            root: OrganizeRoot,
                            options: OrganizeOptions = .default) -> OrganizePlan {

        if let problem = FilenameTemplate.validatePath(template.raw) {
            return OrganizePlan(ruleError: problem)
        }

        let fm = FileManager.default
        let used = Set(template.fields)
        // 已被占用的目标路径（小写比较：macOS 默认大小写不敏感）。
        var claimed: [String: URL] = [:]
        // 同一个根 + 同一个源目录的卷判定复用，别对着几千个文件问几千遍。
        var volumeCache: [String: Bool] = [:]
        var plans: [OrganizePlanItem] = []

        for (url, tags) in items {
            let rootURL = root.root(for: url).standardizedFileURL
            var notes: [String] = []

            // ① 缺字段策略。标题永远回落到当前文件名主体 —— 没有标题的文件也得有地方去。
            var effective = tags
            if (effective.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                effective.title = url.deletingPathExtension().lastPathComponent
                if used.contains(.title) { notes.append("标题为空，已回落到当前文件名") }
            }

            var skipReason: String?
            func fill(_ keyPath: WritableKeyPath<Tags, String?>,
                      field: FilenameField,
                      placeholder: String,
                      label: String) {
                guard used.contains(field), skipReason == nil else { return }
                let current = (effective[keyPath: keyPath] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard current.isEmpty else { return }
                switch options.missing {
                case .skipFile:
                    skipReason = "\(label)为空（缺字段策略为「跳过该文件」）"
                case .fillUnknown:
                    effective[keyPath: keyPath] = placeholder
                    notes.append("\(label)为空，已填「\(placeholder)」")
                }
            }
            // 专辑艺术家先退到艺术家（几乎所有库都这么约定），仍为空才填未知。
            if used.contains(.albumArtist),
               (effective.albumArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let artist = effective.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
               !artist.isEmpty {
                effective.albumArtist = artist
                notes.append("专辑艺术家为空，已回落到艺术家")
            }
            fill(\.artist, field: .artist, placeholder: options.unknownArtist, label: "艺术家")
            fill(\.albumArtist, field: .albumArtist, placeholder: options.unknownArtist, label: "专辑艺术家")
            fill(\.album, field: .album, placeholder: options.unknownAlbum, label: "专辑")

            if let reason = skipReason {
                plans.append(OrganizePlanItem(sourceURL: url, targetURL: url, rootURL: rootURL,
                                              components: [], status: .skipped(reason), notes: notes))
                continue
            }

            // ② 渲染层级。
            var components = template.renderComponents(tags: effective, options: options.render)
            guard var base = components.popLast(), !base.isEmpty else {
                plans.append(OrganizePlanItem(sourceURL: url, targetURL: url, rootURL: rootURL,
                                              components: [],
                                              status: .invalid("算出来的文件名是空的（模板用到的标签都是空的）"),
                                              notes: notes))
                continue
            }
            if components.count + 1 < template.levels.count {
                notes.append("有 \(template.levels.count - components.count - 1) 级目录的标签为空，该级已省略")
            }

            let ext = url.pathExtension
            var folder = rootURL
            for c in components { folder.appendPathComponent(c) }

            // ③ 冲突：同批内撞名 + 磁盘上已存在。
            func targetURL(for base: String) -> URL {
                folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            }
            var target = targetURL(for: base)
            let isSelf = target.standardizedFileURL.path == url.standardizedFileURL.path

            if !isSelf {
                var occupied = claimed[target.path.lowercased()] != nil
                    || fm.fileExists(atPath: target.path)
                if occupied, options.conflict == .skip {
                    plans.append(OrganizePlanItem(sourceURL: url, targetURL: target, rootURL: rootURL,
                                                  components: components + [target.lastPathComponent],
                                                  status: .skipped("目标已存在同名文件：\(target.lastPathComponent)"),
                                                  notes: notes))
                    continue
                }
                var suffix = 2
                while occupied, suffix <= 999 {
                    let candidate = "\(base) (\(suffix))"
                    let url2 = targetURL(for: candidate)
                    if claimed[url2.path.lowercased()] == nil, !fm.fileExists(atPath: url2.path) {
                        base = candidate
                        target = url2
                        notes.append("目标重名，已加 (\(suffix))")
                        occupied = false
                        break
                    }
                    suffix += 1
                }
                if occupied {
                    plans.append(OrganizePlanItem(sourceURL: url, targetURL: target, rootURL: rootURL,
                                                  components: components + [target.lastPathComponent],
                                                  status: .invalid("目标目录里已经有 999 个同名文件，放弃"),
                                                  notes: notes))
                    continue
                }
            }

            let full = components + [target.lastPathComponent]

            // ④ 已经在位。
            if isSelf {
                plans.append(OrganizePlanItem(sourceURL: url, targetURL: target, rootURL: rootURL,
                                              components: full,
                                              status: .unchanged("已经在目标位置上"),
                                              notes: notes))
                continue
            }

            // ⑤ 跨卷判定。
            let volumeKey = url.deletingLastPathComponent().path + "\u{1}" + rootURL.path
            let same: Bool
            if let hit = volumeCache[volumeKey] {
                same = hit
            } else {
                same = sameVolume(url, rootURL)
                volumeCache[volumeKey] = same
            }
            if !same {
                notes.append(options.deleteSourceAfterCrossVolumeCopy
                             ? "跨卷：复制 + 校验后删除源文件"
                             : "跨卷：复制 + 校验，源文件保留")
            }

            claimed[target.path.lowercased()] = url
            let companions = options.moveCompanions
                ? findCompanions(of: url, newBase: base, targetFolder: folder,
                                 options: options, claimed: &claimed)
                : []

            plans.append(OrganizePlanItem(sourceURL: url, targetURL: target, rootURL: rootURL,
                                          components: full,
                                          isCrossVolume: !same,
                                          companions: companions,
                                          status: .ready,
                                          notes: notes))
        }

        let artworkMoves = options.moveFolderArtwork
            ? folderArtworkMoves(for: plans, items: items, claimed: &claimed)
            : []

        return OrganizePlan(items: plans,
                            tree: buildTree(plans),
                            newDirectories: newDirectories(plans),
                            folderArtworkMoves: artworkMoves)
    }

    // MARK: 伴随文件

    /// 同目录下与音频同名的 `.lrc` / `.txt` / `.srt`。目标被占用就跳过这一个，
    /// **不让它拖垮主文件**（音频搬走、歌词留下，总好过整首歌不搬）。
    private static func findCompanions(of url: URL,
                                       newBase: String,
                                       targetFolder: URL,
                                       options: OrganizeOptions,
                                       claimed: inout [String: URL]) -> [OrganizePlanItem.CompanionMove] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let oldBase = url.deletingPathExtension().lastPathComponent
        var out: [OrganizePlanItem.CompanionMove] = []

        for ext in options.companionExtensions {
            for candidateExt in [ext, ext.uppercased()] {
                let from = dir.appendingPathComponent("\(oldBase).\(candidateExt)")
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = targetFolder.appendingPathComponent("\(newBase).\(candidateExt)")
                let key = to.path.lowercased()
                guard claimed[key] == nil, !fm.fileExists(atPath: to.path) else { continue }
                claimed[key] = from
                out.append(OrganizePlanItem.CompanionMove(from: from, to: to))
            }
        }
        return out
    }

    // MARK: 文件夹封面

    /// 只有**整个源目录的音频都在本批里、都可执行、且都落到同一个目标目录**时，
    /// 才把该目录的 `cover.jpg / folder.jpg / <专辑名>.jpg` 一起带走。
    ///
    /// 少一个条件都不带：源目录还剩别的歌时，那张封面还得留给它们用。
    private static func folderArtworkMoves(for plans: [OrganizePlanItem],
                                           items: [(url: URL, tags: Tags)],
                                           claimed: inout [String: URL]) -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        let audioExts = Set(TagService.supportedExtensions.map { $0.lowercased() })
        var albumByURL: [URL: String?] = [:]
        for (url, tags) in items { albumByURL[url.standardizedFileURL] = tags.album }

        // 按源目录分组。
        var byFolder: [URL: [OrganizePlanItem]] = [:]
        for p in plans {
            byFolder[p.sourceURL.deletingLastPathComponent().standardizedFileURL, default: []].append(p)
        }

        var out: [(from: URL, to: URL)] = []
        for (folder, group) in byFolder {
            guard group.allSatisfy({ $0.status.isReady }) else { continue }
            let targets = Set(group.map { $0.targetFolder.standardizedFileURL.path })
            guard targets.count == 1, let targetFolder = group.first?.targetFolder else { continue }
            guard targetFolder.standardizedFileURL.path != folder.path else { continue }

            // 源目录里现存的音频必须**全部**在本批里。
            let onDisk = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { audioExts.contains(($0 as NSString).pathExtension.lowercased()) }
                .map { folder.appendingPathComponent($0).standardizedFileURL.path }
            let planned = Set(group.map { $0.sourceURL.standardizedFileURL.path })
            guard !onDisk.isEmpty, Set(onDisk).isSubset(of: planned) else { continue }

            let album = group.compactMap { albumByURL[$0.sourceURL.standardizedFileURL] ?? nil }.first
            guard let art = FolderArtwork.locate(folder: folder, album: album) else { continue }
            let to = targetFolder.appendingPathComponent(art.lastPathComponent)
            let key = to.path.lowercased()
            guard claimed[key] == nil, !fm.fileExists(atPath: to.path) else { continue }
            claimed[key] = art
            out.append((art, to))
        }
        return out.sorted { $0.from.path < $1.from.path }
    }

    // MARK: 新建目录清单

    /// 本次需要新建的目录（含缺失的祖先），浅的在前。
    private static func newDirectories(_ plans: [OrganizePlanItem]) -> [URL] {
        let fm = FileManager.default
        var needed: [String: URL] = [:]

        for p in plans where p.status.isReady {
            var dir = p.targetFolder.standardizedFileURL
            let rootPath = p.rootURL.standardizedFileURL.path
            // 从目标目录往上走到根为止；根本身如果也不存在，同样要建。
            while dir.path.count >= rootPath.count {
                if !fm.fileExists(atPath: dir.path) { needed[dir.path] = dir }
                if dir.path == rootPath { break }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return needed.values.sorted { $0.path.count < $1.path.count }
    }

    // MARK: 预览树

    /// 把计划摊成一棵「目标根 → 一级 → 二级 → … → 文件」的树。
    static func buildTree(_ plans: [OrganizePlanItem]) -> [OrganizeTreeNode] {

        /// 建树期间的可变节点（`OrganizeTreeNode` 是值类型，直接摞会到处拷贝）。
        final class Builder {
            let path: String
            let name: String
            var isNew = false
            var children: [String: Builder] = [:]
            var order: [String] = []
            var leaves: [OrganizeTreeNode] = []
            init(path: String, name: String) { self.path = path; self.name = name }

            func child(_ name: String) -> Builder {
                if let hit = children[name] { return hit }
                let b = Builder(path: path + "/" + name, name: name)
                children[name] = b
                order.append(name)
                return b
            }

            func node(kind: OrganizeTreeNode.Kind) -> OrganizeTreeNode {
                let folders = order.compactMap { children[$0] }
                    .map { $0.node(kind: .folder(isNew: $0.isNew)) }
                let kids = folders + leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let count = kids.reduce(0) { $0 + $1.fileCount }
                return OrganizeTreeNode(id: path, name: name, kind: kind,
                                        fileCount: count, children: kids)
            }
        }

        let fm = FileManager.default
        var roots: [String: Builder] = [:]
        var rootOrder: [String] = []

        for p in plans {
            let rootPath = p.rootURL.standardizedFileURL.path
            let root: Builder
            if let hit = roots[rootPath] {
                root = hit
            } else {
                root = Builder(path: rootPath, name: p.rootURL.lastPathComponent.isEmpty
                               ? rootPath : p.rootURL.lastPathComponent)
                roots[rootPath] = root
                rootOrder.append(rootPath)
            }

            // 不可执行的行没有目标路径可挂，直接挂在根下当叶子（界面照样能看见原因）。
            guard p.status.isReady, !p.components.isEmpty else {
                root.leaves.append(OrganizeTreeNode(id: p.sourceURL.path, name: p.currentName,
                                                    kind: .file, fileCount: 1,
                                                    status: p.status, notes: p.notes))
                continue
            }

            var cursor = root
            for name in p.components.dropLast() {
                cursor = cursor.child(name)
                if !fm.fileExists(atPath: cursor.path) { cursor.isNew = true }
            }
            let fileName = p.components[p.components.count - 1]
            cursor.leaves.append(OrganizeTreeNode(id: p.targetURL.path, name: fileName,
                                                 kind: .file, fileCount: 1,
                                                 status: p.status,
                                                 isCrossVolume: p.isCrossVolume,
                                                 notes: p.notes))
        }

        return rootOrder.compactMap { roots[$0] }.map { $0.node(kind: .root) }
    }

    // MARK: 执行

    /// 执行结果。
    public struct OrganizeOutcome: Sendable {
        public var summary: BatchSummary
        /// 同卷移动的主文件 old → new。
        public var moved: [(from: URL, to: URL)]
        /// 跨卷复制的主文件 old → new。
        public var copied: [(from: URL, to: URL)]
        /// 伴随文件与文件夹封面。
        public var movedCompanions: [(from: URL, to: URL)]
        /// 实际新建出来的目录。
        public var createdDirectories: [URL]
        /// 整理后删掉的空源目录。
        public var removedEmptyDirectories: [URL]

        public init(summary: BatchSummary,
                    moved: [(from: URL, to: URL)] = [],
                    copied: [(from: URL, to: URL)] = [],
                    movedCompanions: [(from: URL, to: URL)] = [],
                    createdDirectories: [URL] = [],
                    removedEmptyDirectories: [URL] = []) {
            self.summary = summary
            self.moved = moved
            self.copied = copied
            self.movedCompanions = movedCompanions
            self.createdDirectories = createdDirectories
            self.removedEmptyDirectories = removedEmptyDirectories
        }

        /// 列表刷新要用的新路径（主文件）。
        public var allNewURLs: [URL] { moved.map(\.to) + copied.map(\.to) }
        /// 从列表里要摘掉的旧路径。跨卷且**没删源**时源还在原地，不摘。
        public var vanishedOldURLs: [URL] { moved.map(\.from) }
    }

    /// 真正搬文件。
    ///
    /// - `.ready` 逐条搬，失败只记这一条、不中断整批；
    /// - `.unchanged` / `.skipped` 计入「忽略」；`.invalid` 计入「失败」；
    /// - `isCancelled` 只在**文件与文件之间**生效 —— 单个文件的复制不会被腰斩成半个。
    @discardableResult
    public static func execute(_ plan: OrganizePlan,
                               options: OrganizeOptions = .default,
                               journal: RenameJournal? = nil,
                               history: TagsHistoryStore? = nil,
                               isCancelled: (() -> Bool)? = nil,
                               progress: ((BatchProgress) -> Void)? = nil) -> OrganizeOutcome {

        let fm = FileManager.default
        let started = Date()
        var summary = BatchSummary(total: plan.items.count)
        var moved: [(from: URL, to: URL)] = []
        var copied: [(from: URL, to: URL)] = []
        var movedCompanions: [(from: URL, to: URL)] = []
        var createdDirectories: [URL] = []
        var journalItems: [RenameJournalItem] = []

        /// 建目录，并记下**确实是本次建出来的**那些（撤消时才敢删）。
        func ensureFolder(_ dir: URL) throws {
            guard !fm.fileExists(atPath: dir.path) else { return }
            var missing: [URL] = []
            var cursor = dir.standardizedFileURL
            while !fm.fileExists(atPath: cursor.path) {
                missing.append(cursor)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            createdDirectories.append(contentsOf: missing.reversed())
        }

        /// 同卷移动 / 跨卷复制 + 校验。返回是否走的复制路径。
        func transfer(_ from: URL, to: URL, crossVolume: Bool) throws -> Bool {
            guard crossVolume else {
                try fm.moveItem(at: from, to: to)
                return false
            }
            try fm.copyItem(at: from, to: to)
            guard FileCopyVerifier.matches(from, to) else {
                try? fm.removeItem(at: to)
                throw TagError.writeFailed("跨卷复制后校验不一致（大小或 SHA-256 对不上），已删掉不完整的副本")
            }
            if options.deleteSourceAfterCrossVolumeCopy { try fm.removeItem(at: from) }
            return true
        }

        for (i, item) in plan.items.enumerated() {
            if isCancelled?() == true {
                summary.isCancelled = true
                break
            }
            defer {
                progress?(BatchProgress(completed: i + 1, total: plan.items.count,
                                        currentPath: item.sourceURL.path))
            }

            switch item.status {
            case .unchanged(let reason), .skipped(let reason):
                summary.ignored += 1
                summary.ignoredItems.append((item.sourceURL, reason))
                continue
            case .invalid(let reason):
                summary.failed += 1
                summary.failures.append((item.sourceURL, .invalidArgument(reason)))
                continue
            case .ready:
                break
            }

            do {
                try ensureFolder(item.targetFolder)
                let wasCopy = try transfer(item.sourceURL, to: item.targetURL,
                                           crossVolume: item.isCrossVolume)
                summary.succeeded += 1
                if wasCopy { copied.append((item.sourceURL, item.targetURL)) }
                else { moved.append((item.sourceURL, item.targetURL)) }
                let sourceGone = !wasCopy || options.deleteSourceAfterCrossVolumeCopy
                journalItems.append(RenameJournalItem(
                    from: item.sourceURL.path, to: item.targetURL.path,
                    isCompanion: false, isCopy: wasCopy,
                    sourceDeleted: wasCopy && options.deleteSourceAfterCrossVolumeCopy))
                // 历史库记的是绝对路径；不同步的话「撤消标签保存」就找不到这个文件了。
                //
                // **只在源真的没了的时候改**。跨卷复制且保留源时，那条历史讲的是
                // 「原文件」的标签保存史，原文件一动没动 —— 把它指到副本上，
                // 用户回头对原文件按「撤消标签保存」就会扑空（实测踩到过）。
                if sourceGone {
                    _ = try? history?.updateFilePath(from: item.sourceURL.path, to: item.targetURL.path)
                }
            } catch {
                summary.failed += 1
                let message = (error as? TagError)?.localizedDescription ?? error.localizedDescription
                summary.failures.append((item.sourceURL, .writeFailed(message)))
                continue
            }

            // 伴随文件：失败不影响主文件，只是不跟着走。
            for c in item.companions {
                guard let wasCopy = try? transfer(c.from, to: c.to, crossVolume: item.isCrossVolume) else { continue }
                movedCompanions.append((c.from, c.to))
                journalItems.append(RenameJournalItem(
                    from: c.from.path, to: c.to.path,
                    isCompanion: true, isCopy: wasCopy,
                    sourceDeleted: wasCopy && options.deleteSourceAfterCrossVolumeCopy))
            }
        }

        // 文件夹封面：所有音频都搬完了才动它（判据是「整组搬走」，得等整组真的走完）。
        if !summary.isCancelled {
            for (from, to) in plan.folderArtworkMoves {
                guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
                let cross = !sameVolume(from, to.deletingLastPathComponent())
                guard (try? ensureFolder(to.deletingLastPathComponent())) != nil,
                      let wasCopy = try? transfer(from, to: to, crossVolume: cross) else { continue }
                movedCompanions.append((from, to))
                journalItems.append(RenameJournalItem(
                    from: from.path, to: to.path,
                    isCompanion: true, isCopy: wasCopy,
                    sourceDeleted: wasCopy && options.deleteSourceAfterCrossVolumeCopy))
            }
        }

        // 空源目录：只删 `contentsOfDirectory` 真的返回空的那些，深的先删。
        var removedEmpty: [URL] = []
        if options.deleteEmptySourceFolders {
            let sources = Set(plan.readyItems.map { $0.sourceURL.deletingLastPathComponent().standardizedFileURL.path })
            let createdPaths = Set(createdDirectories.map(\.path))
            for path in sources.sorted(by: { $0.count > $1.count }) {
                // 本批刚建出来的目录不算「源目录」，别自己建完又自己删了。
                guard !createdPaths.contains(path) else { continue }
                let dir = URL(fileURLWithPath: path, isDirectory: true)
                guard RenameJournal.removeIfTrulyEmpty(dir) else { continue }
                removedEmpty.append(dir)
            }
        }

        if !journalItems.isEmpty {
            try? journal?.record(journalItems, kind: .organize, createdDirectories: createdDirectories)
        }
        summary.elapsed = Date().timeIntervalSince(started)
        return OrganizeOutcome(summary: summary,
                               moved: moved,
                               copied: copied,
                               movedCompanions: movedCompanions,
                               createdDirectories: createdDirectories,
                               removedEmptyDirectories: removedEmpty)
    }
}

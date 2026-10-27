//
//  UndoService.swift
//  MacTagger — 撤销服务
//
//  对应原版「撤消标签保存 / 撤消重命名 / 标签历史」。
//
//  设计背景（重要）：
//  原版 SQLite 历史表 tagshistory 只存 7 个核心文本字段
//  （title/artist/album/year/trackstr/discstr + filepath），**不存封面与歌词**。
//  因此仅靠 TagsHistoryStore 无法完整回滚一次保存。本服务补上这个缺口：
//  写入前把「封面 + 歌词」旁存到应用支持目录的 SideCarStore，用历史流水号 serial
//  关联，回滚时先按 serial 取回旁存内容，再连同文本字段一起写回。
//

import Foundation

// MARK: - 旁存仓库

/// 封面与歌词的旁存仓库。以历史流水号 serial 为键，存在应用支持目录下。
///
/// 目录布局：
/// ```
/// <AppSupport>/MacTagger/undo-sidecar/
///     <serial>/meta.json          —— 记录歌词与封面元信息
///     <serial>/art-0.bin          —— 第 0 张封面的原始字节
///     <serial>/art-1.bin          —— ……
/// ```
public final class SideCarStore: @unchecked Sendable {

    /// 旁存的一次快照。
    public struct Snapshot: Codable, Sendable {
        public var lyrics: String?
        public var artworks: [ArtworkMeta]
        /// 历史表存不下的额外文本字段（键为 TagEdit.Field.rawValue）。
        /// 原版 tagshistory 表只有 title/artist/album/year/trackstr/discstr 六列，
        /// albumArtist / genre / comment / composer 这几个改了就撤不回来——这里补上。
        public var extraFields: [String: String?] = [:]

        public struct ArtworkMeta: Codable, Sendable {
            public var mimeType: String?
            public var caption: String?
            public var typeRawValue: Int
            public var declaredWidth: Int
            public var declaredHeight: Int
            public var declaredColorDepth: Int
            public var byteCount: Int
        }

        public var isEmpty: Bool { lyrics == nil && artworks.isEmpty && extraFields.isEmpty }
    }

    private let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(root: URL? = nil) throws {
        if let root {
            self.root = root
        } else {
            let base = try fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil,
                                  create: true)
            self.root = base.appendingPathComponent("MacTagger/undo-sidecar", isDirectory: true)
        }
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private func dir(for serial: String) -> URL {
        root.appendingPathComponent(serial, isDirectory: true)
    }

    /// 保存一次快照。封面字节逐张单独落盘，避免把大图塞进 JSON。
    @discardableResult
    public func save(serial: String,
                     lyrics: String?,
                     artworks: [Artwork],
                     extraFields: [String: String?] = [:]) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        let snapshot = Snapshot(
            lyrics: lyrics,
            artworks: artworks.map {
                .init(mimeType: $0.mimeType,
                      caption: $0.caption,
                      typeRawValue: $0.type.rawValue,
                      declaredWidth: $0.declaredWidth,
                      declaredHeight: $0.declaredHeight,
                      declaredColorDepth: $0.declaredColorDepth,
                      byteCount: $0.data.count)
            },
            extraFields: extraFields
        )
        guard !snapshot.isEmpty else { return snapshot }

        let d = dir(for: serial)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: d.appendingPathComponent("meta.json"), options: .atomic)
        for (i, art) in artworks.enumerated() {
            try art.data.write(to: d.appendingPathComponent("art-\(i).bin"), options: .atomic)
        }
        return snapshot
    }

    /// 取回一次快照。没有旁存时返回 nil（例如那次保存没动封面与歌词）。
    public func load(serial: String) throws -> (lyrics: String?, artworks: [Artwork], extraFields: [String: String?])? {
        lock.lock(); defer { lock.unlock() }

        let d = dir(for: serial)
        let metaURL = d.appendingPathComponent("meta.json")
        guard fm.fileExists(atPath: metaURL.path) else { return nil }

        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: metaURL))
        var arts: [Artwork] = []
        for (i, meta) in snapshot.artworks.enumerated() {
            let blob = d.appendingPathComponent("art-\(i).bin")
            guard let bytes = try? Data(contentsOf: blob) else { continue }
            arts.append(Artwork(data: bytes,
                                mimeType: meta.mimeType,
                                caption: meta.caption,
                                type: PictureType(rawValue: meta.typeRawValue) ?? .frontCover,
                                declaredWidth: meta.declaredWidth,
                                declaredHeight: meta.declaredHeight,
                                declaredColorDepth: meta.declaredColorDepth))
        }
        return (snapshot.lyrics, arts, snapshot.extraFields)
    }

    public func discard(serial: String) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: dir(for: serial))
    }

    // MARK: 清理策略

    /// 旁存占用的总字节数。
    public func totalBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return Self.directorySize(root, fm: fm)
    }

    /// 保留最近 `keepCount` 个旁存，且总量不超过 `maxBytes`；超出的按时间从旧到新删除。
    /// 另外删除掉 `liveSerials` 里不存在的孤儿目录（历史记录已被清除但旁存还在）。
    @discardableResult
    public func prune(keepCount: Int = 200,
                      maxBytes: Int64 = 512 * 1024 * 1024,
                      liveSerials: Set<String>? = nil) -> (removed: Int, freedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return (0, 0) }

        var dirs: [(url: URL, date: Date, size: Int64)] = []
        for url in entries {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard rv?.isDirectory == true else { continue }
            dirs.append((url,
                         rv?.contentModificationDate ?? .distantPast,
                         Self.directorySize(url, fm: fm)))
        }

        var removed = 0
        var freed: Int64 = 0

        // ① 孤儿目录：历史记录已不存在
        if let live = liveSerials {
            for d in dirs where !live.contains(d.url.lastPathComponent) {
                try? fm.removeItem(at: d.url)
                removed += 1; freed += d.size
            }
            dirs.removeAll { !live.contains($0.url.lastPathComponent) }
        }

        // ② 超出保留数量：从最旧的开始删
        dirs.sort { $0.date > $1.date }          // 新 → 旧
        if dirs.count > keepCount {
            for d in dirs[keepCount...] {
                try? fm.removeItem(at: d.url)
                removed += 1; freed += d.size
            }
            dirs = Array(dirs[..<keepCount])
        }

        // ③ 超出总量上限：继续从最旧的开始删
        var total = dirs.reduce(Int64(0)) { $0 + $1.size }
        while total > maxBytes, let oldest = dirs.last {
            try? fm.removeItem(at: oldest.url)
            removed += 1; freed += oldest.size; total -= oldest.size
            dirs.removeLast()
        }

        return (removed, freed)
    }

    /// 旁存根目录（`<AppSupport>/MacTagger/undo-sidecar/`）。探针与报告用。
    public var rootDirectory: URL { root }

    /// 按保留策略裁剪旁存（BP-C #13）。三道闸依次执行：
    ///
    /// 1. **孤儿**：目录名（流水号）不在 `liveSerials` 里 = 历史记录已被删掉，旁存再也用不上。
    ///    `liveSerials == nil`（历史库读不出来）时整道闸跳过 —— 宁可多留，不能误删。
    ///    刚建不久（`policy.orphanGrace` 内）的目录也跳过：批量保存是「先记历史表、后写旁存」，
    ///    清理若恰好夹在两步之间拿到的活流水号集合，会把正在写的那一条当成孤儿。
    /// 2. **过期**：早于 `now - policy.maxAge` 的目录，不论有没有主。
    /// 3. **超量**：剩下的按时间从旧到新删，直到总量 ≤ `policy.maxBytes`。
    ///
    /// 时间取目录的修改时间（目录建好、文件写进去之后就不再变 = 记录时刻）。
    @discardableResult
    public func prune(policy: UndoService.RetentionPolicy,
                      liveSerials: Set<String>?,
                      now: Date = Date()) -> UndoService.SideCarPruneReport {
        lock.lock(); defer { lock.unlock() }

        var report = UndoService.SideCarPruneReport()
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
        ) else { return report }

        var dirs: [(url: URL, date: Date, size: Int64)] = []
        for url in entries {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            guard rv?.isDirectory == true else { continue }
            dirs.append((url,
                         rv?.contentModificationDate ?? rv?.creationDate ?? .distantPast,
                         Self.directorySize(url, fm: fm)))
        }
        report.scanned = dirs.count
        report.scannedBytes = dirs.reduce(Int64(0)) { $0 + $1.size }

        func remove(_ d: (url: URL, date: Date, size: Int64)) -> Bool {
            guard (try? fm.removeItem(at: d.url)) != nil else { return false }
            report.freedBytes += d.size
            return true
        }

        // ① 孤儿
        if let live = liveSerials {
            let graceCutoff = now.addingTimeInterval(-max(0, policy.orphanGrace))
            dirs.removeAll { d in
                guard !live.contains(d.url.lastPathComponent), d.date <= graceCutoff else { return false }
                if remove(d) { report.orphansRemoved += 1; return true }
                return false
            }
        } else {
            report.orphanCheckSkipped = true
        }

        // ② 过期
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            dirs.removeAll { d in
                guard d.date < cutoff else { return false }
                if remove(d) { report.expiredRemoved += 1; return true }
                return false
            }
        }

        // ③ 超量：从最旧的开始删
        dirs.sort { $0.date < $1.date }                // 旧 → 新
        var total = dirs.reduce(Int64(0)) { $0 + $1.size }
        var survivors = 0
        for d in dirs {
            if total > policy.maxBytes, remove(d) {
                report.overCapRemoved += 1
                total -= d.size
            } else {
                survivors += 1
            }
        }
        report.remaining = survivors
        report.remainingBytes = total
        return report
    }

    private static func directorySize(_ url: URL, fm: FileManager) -> Int64 {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - 撤销服务

public enum UndoService {

    /// 一次可撤销保存的记录结果。
    public struct Recorded: Sendable {
        public var serial: String
        public var hasSideCar: Bool
    }

    /// 撤销一次保存的结果。
    public struct UndoOutcome: Sendable {
        public var url: URL
        public var restoredFields: Int
        public var restoredLyrics: Bool
        public var restoredArtworks: Int
        public var outcome: WriteOutcome
    }

    // MARK: 保存前记录

    /// 在写入之前调用：把当前标签记进历史库，并把封面/歌词旁存下来。
    ///
    /// - Parameter edit: 即将应用的改动。仅当它会动到歌词或封面时才旁存，
    ///                   避免每次改标题都白白复制一遍封面。
    public static func recordBeforeWrite(url: URL,
                                         current: AudioFile,
                                         edit: TagEdit,
                                         history: TagsHistoryStore,
                                         sideCar: SideCarStore) throws -> Recorded {
        let serial = try history.record(filePath: url.path, tags: current.tags)

        let touchesLyrics = edit.changes.contains { $0.field == .lyrics }
        let touchesArtwork: Bool = {
            if case .keep = edit.artworkAction { return false }
            return true
        }()

        // 历史表只有 6 个文本列，本次改动里凡是落在表外的字段都必须旁存，
        // 否则撤消后它们会留在文件里（实测：自动匹配写入 ALBUMARTIST 后撤消不回滚）。
        var extras: [String: String?] = [:]
        for change in edit.changes where !Self.fieldsCoveredByHistory.contains(change.field) {
            guard change.field != .lyrics else { continue }   // 歌词单独走 lyrics 槽
            extras[change.field.rawValue] = Self.currentValue(of: change.field, in: current.tags)
        }
        // 表外 raw 键（`TagEdit.diff` 自 BP-C 起会产出 rawChanges）：原值按「键 → 多值拼接」旁存，
        // 键带 `raw:` 前缀，与命名字段 / `__` 哨兵都不相撞。原本没有该键 → 记 nil，撤消时删掉。
        for raw in edit.rawChanges {
            let old = current.tags.rawProperties[raw.key]
            extras[Self.rawExtraPrefix + raw.key] = old.map { $0.joined(separator: Self.rawValueSeparator) }
        }

        // 原本**没有**封面、本次却要写入封面：旁存里没有任何封面字节可还原，
        // 光靠 `artworks` 为空是分不清「没动过封面」和「原本就是空的」两种情况的，
        // 撤消时会把本次写入的封面留在文件里。打一个哨兵标记，让 undo 走 .removeAll。
        // 键名带 `__` 前缀，与真实字段名（TagEdit.Field.rawValue）不会相撞。
        if touchesArtwork && current.tags.artworks.isEmpty {
            extras[Self.artworkClearedKey] = "1"
        }

        var hasSideCar = false
        if touchesLyrics || touchesArtwork || !extras.isEmpty {
            let snapshot = try sideCar.save(
                serial: serial,
                lyrics: touchesLyrics ? current.tags.lyrics : nil,
                artworks: touchesArtwork ? current.tags.artworks : [],
                extraFields: extras
            )
            hasSideCar = !snapshot.isEmpty
        }
        return Recorded(serial: serial, hasSideCar: hasSideCar)
    }

    // MARK: 撤销

    /// 把文件回滚到某条历史记录的状态。
    ///
    /// 文本字段来自历史库（`entry.undoEdit`），封面与歌词来自旁存仓库；
    /// 没有旁存时只回滚文本字段，并在结果里如实反映（`restoredArtworks == 0`）。
    public static func undo(to entry: TagsHistoryEntry,
                            sideCar: SideCarStore) throws -> UndoOutcome {
        let url = URL(fileURLWithPath: entry.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TagError.fileNotFound(entry.filePath)
        }

        var edit = entry.undoEdit
        var restoredLyrics = false
        var restoredArtworks = 0
        var restoredExtras = 0

        if let side = try sideCar.load(serial: entry.serial) {
            if let lyrics = side.lyrics {
                edit.set(.lyrics, lyrics)
                restoredLyrics = true
            }
            if !side.artworks.isEmpty {
                edit.artworkAction = .replace(side.artworks)
                restoredArtworks = side.artworks.count
            } else if side.extraFields[Self.artworkClearedKey] != nil {
                // 原本就没有封面 → 把本次写入的封面整个移除，回到「无封面」。
                edit.artworkAction = .removeAll
            }
            // 还原历史表覆盖不到的字段。值为 nil 表示原本就没有该字段 → 删除它，
            // 而不是留着本次写入的新值。
            for (rawKey, value) in side.extraFields {
                guard !rawKey.hasPrefix("__") else { continue }   // 哨兵标记不是字段
                if rawKey.hasPrefix(Self.rawExtraPrefix) {
                    // 表外 raw 键：原值是多值拼接串；nil = 原本没有 → 删除。
                    let key = String(rawKey.dropFirst(Self.rawExtraPrefix.count))
                    guard !key.isEmpty else { continue }
                    let values = (value ?? nil)?.components(separatedBy: Self.rawValueSeparator)
                    edit.setRaw(key, values)
                    restoredExtras += 1
                    continue
                }
                guard let field = TagEdit.Field(rawValue: rawKey) else { continue }
                edit.set(field, value ?? nil)
                restoredExtras += 1
            }
        }

        let outcome = try TagService.write(edit, to: url)
        _ = restoredExtras
        return UndoOutcome(url: url,
                           restoredFields: edit.changes.count,
                           restoredLyrics: restoredLyrics,
                           restoredArtworks: restoredArtworks,
                           outcome: outcome)
    }

    /// 旁存 extraFields 里表外 raw 键的前缀（`raw:ISRC`）。
    static let rawExtraPrefix = "raw:"
    /// raw 多值拼接用的分隔符（ASCII 单元分隔符，正常标签文本里不会出现）。
    static let rawValueSeparator = "\u{1F}"

    /// 旁存 extraFields 里的哨兵键：标记「记录时文件原本没有封面」。
    /// `__` 前缀保证它永远不会被 `TagEdit.Field(rawValue:)` 解析成真实字段。
    static let artworkClearedKey = "__artworkCleared"

    /// 原版历史表实际存下的 6 个字段。其余字段改动必须靠旁存才能撤回。
    static let fieldsCoveredByHistory: Set<TagEdit.Field> = [
        .title, .artist, .album, .year, .track, .disc
    ]

    static func currentValue(of field: TagEdit.Field, in tags: Tags) -> String? {
        switch field {
        case .albumArtist: return tags.albumArtist
        case .genre:       return tags.genre
        case .comment:     return tags.comment
        case .composer:    return tags.composer
        case .lyricist:    return tags.lyricist
        case .lyrics:      return tags.lyrics
        case .title:       return tags.title
        case .artist:      return tags.artist
        case .album:       return tags.album
        case .year:        return tags.year
        case .track:       return tags.trackString
        case .disc:        return tags.discString
        }
    }

    /// 清除全部历史时同步清理旁存：历史表清空后，旁存目录一个不留。
    ///
    /// - Returns: 删掉的旁存目录数与释放的字节数。
    @discardableResult
    public static func clearAll(history: TagsHistoryStore,
                                sideCar: SideCarStore) throws -> (removed: Int, freedBytes: Int64) {
        try history.clearAll()
        return sideCar.prune(keepCount: 0, maxBytes: 0, liveSerials: [])
    }

    // MARK: 保留策略（BP-C #13）

    /// 撤消数据的保留策略。
    public struct RetentionPolicy: Sendable, Equatable {
        /// 旁存总量上限。超出按最旧先删。
        public var maxBytes: Int64
        /// 旁存保留期；`nil` = 不按时间删。
        public var maxAge: TimeInterval?
        /// 孤儿宽限期：比这更新的无主目录不删（见 `SideCarStore.prune(policy:…)`）。
        public var orphanGrace: TimeInterval
        /// 重命名 / 整理日志的保留期；`nil` = 不动日志。
        public var journalMaxAge: TimeInterval?

        public init(maxBytes: Int64 = 500 * 1024 * 1024,
                    maxAge: TimeInterval? = 30 * 24 * 3600,
                    orphanGrace: TimeInterval = 10 * 60,
                    journalMaxAge: TimeInterval? = 30 * 24 * 3600) {
            self.maxBytes = maxBytes
            self.maxAge = maxAge
            self.orphanGrace = orphanGrace
            self.journalMaxAge = journalMaxAge
        }

        /// 产品默认：旁存 500 MB / 30 天，孤儿宽限 10 分钟，重命名日志 30 天。
        public static let `default` = RetentionPolicy()
    }

    /// `SideCarStore.prune(policy:…)` 的明细。
    public struct SideCarPruneReport: Sendable, Equatable {
        public var scanned = 0
        public var scannedBytes: Int64 = 0
        public var orphansRemoved = 0
        public var expiredRemoved = 0
        public var overCapRemoved = 0
        public var freedBytes: Int64 = 0
        public var remaining = 0
        public var remainingBytes: Int64 = 0
        /// 历史库读不出来，孤儿检查整道跳过。
        public var orphanCheckSkipped = false

        public init() {}

        public var removed: Int { orphansRemoved + expiredRemoved + overCapRemoved }
    }

    /// 一次维护的总账。
    public struct MaintenanceReport: Sendable, Equatable {
        public var sideCar = SideCarPruneReport()
        /// 历史库里的记录数（活流水号个数）。
        public var liveSerials = 0
        /// 重命名日志：维护前 / 删掉的批次数。日志不存在或读不出时为 0。
        public var journalBatchesBefore = 0
        public var journalBatchesRemoved = 0
        public var journalError: String?

        public init() {}

        /// 旧版返回值的两个量，便于沿用。
        public var removed: Int { sideCar.removed }
        public var freedBytes: Int64 { sideCar.freedBytes }

        /// 状态栏 / 日志用的一句话。什么都没删时返回 nil。
        public var summaryText: String? {
            var parts: [String] = []
            let s = sideCar
            if s.removed > 0 {
                var detail: [String] = []
                if s.orphansRemoved > 0 { detail.append("无主 \(s.orphansRemoved)") }
                if s.expiredRemoved > 0 { detail.append("过期 \(s.expiredRemoved)") }
                if s.overCapRemoved > 0 { detail.append("超量 \(s.overCapRemoved)") }
                parts.append("清理撤消旁存 \(s.removed) 份（\(detail.joined(separator: " · "))），释放 "
                             + TagService.humanBytes(s.freedBytes))
            }
            if journalBatchesRemoved > 0 {
                parts.append("清理 \(journalBatchesRemoved) 批过期的重命名记录")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "；")
        }
    }

    /// 默认的重命名日志位置（与 `RenameJournal.shared` 同一个文件）。取不到时为 nil。
    public static var defaultRenameJournalURL: URL? { try? RenameJournal.defaultURL() }

    /// 常规维护（BP-C #13）：按保留策略裁剪撤消旁存，并把重命名 / 整理日志里过期的批次去掉。
    ///
    /// - 旁存：孤儿（历史记录已不存在）→ 过期（`policy.maxAge`）→ 超量（`policy.maxBytes`，最旧先删）。
    ///   活流水号从历史库**全量**取；取不到时跳过孤儿检查（不猜）。
    /// - 重命名日志：删掉早于 `policy.journalMaxAge` 的批次（日志本身另有 50 批上限）。
    ///   传 `renameJournalURL: nil` 则不动日志。
    ///
    /// 线程：全程同步磁盘 IO，**请在后台线程调用**（App 里由 `AppModel.maintainUndoStorage()` 甩到后台）。
    ///
    /// - Note: 日志裁剪交给 `RenameJournal.prune(journalAt:olderThan:)`（BP-H 轮）：路径就是本进程
    ///   `RenameJournal.shared` 那份时，内存与磁盘一起裁（同一把锁）；否则按文件改写。
    ///   以前这里自己直接改文件，`shared` 已载入内存时，它下一次 `record` 会把内存里那份
    ///   （含过期批次）原样写回，裁剪白做。
    @discardableResult
    public static func maintain(history: TagsHistoryStore,
                                sideCar: SideCarStore,
                                policy: RetentionPolicy = .default,
                                renameJournalURL: URL? = UndoService.defaultRenameJournalURL,
                                now: Date = Date()) -> MaintenanceReport {
        var report = MaintenanceReport()
        let live = liveSerials(in: history)
        report.liveSerials = live?.count ?? 0
        report.sideCar = sideCar.prune(policy: policy, liveSerials: live, now: now)

        if let url = renameJournalURL, let maxAge = policy.journalMaxAge {
            do {
                let r = try RenameJournal.prune(journalAt: url, olderThan: now.addingTimeInterval(-maxAge))
                report.journalBatchesBefore = r.before
                report.journalBatchesRemoved = r.removed
            } catch {
                report.journalError = error.localizedDescription
            }
        }
        return report
    }

    /// 旧版维护入口（按保留个数 + 总量），`mactagger-probe undo` 仍在用。
    /// 参数必须显式给出，免得与上面的新入口在只传两个参数时产生歧义。
    @discardableResult
    public static func maintain(history: TagsHistoryStore,
                                sideCar: SideCarStore,
                                keepCount: Int,
                                maxBytes: Int64) -> (removed: Int, freedBytes: Int64) {
        sideCar.prune(keepCount: keepCount, maxBytes: maxBytes, liveSerials: liveSerials(in: history))
    }

    /// 历史库里全部活流水号。读失败返回 nil（调用方据此跳过孤儿检查）。
    static func liveSerials(in history: TagsHistoryStore) -> Set<String>? {
        guard let count = try? history.entryCount() else { return nil }
        guard count > 0 else { return [] }
        guard let all = try? history.allHistory(limit: count + 64) else { return nil }
        return Set(all.map(\.serial))
    }
}

//
//  TagsHistoryStore.swift
//  MacTagger — 标签编辑历史库（撤销支持）
//
//  表结构照抄 B 报告第七章从原版 `#US` 堆提取到的建表语句，逐字不改：
//
//      create table if not exists tagshistory (
//          serial     varchar(21) primary key,
//          filepath   varchar(256) not null,
//          createtime datetime default(STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
//          title      varchar(64),
//          artist     varchar(64),
//          album      varchar(64),
//          year       varchar(4),
//          trackstr   varchar(2),
//          discstr    varchar(2)
//      );
//      create index if not exists th_idx01 on tagshistory(filepath);
//      create table if not exists config (thserial_prefix integer);
//
//  与原版一致的语义：**只存 7 个核心标签字段**，不存歌词与封面
//  （原版对这两者的撤销走临时目录备份，见报告 430 行）。
//
//  用系统自带 libsqlite3，不引第三方依赖。
//

import Foundation
import SQLite3

/// SQLite 传字符串时必须用 TRANSIENT，否则 sqlite3 会保留指向已释放缓冲区的指针。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 一条标签历史记录。
public struct TagsHistoryEntry: Identifiable, Equatable, Sendable {
    public var id: String { serial }
    /// 21 位流水号，主键。
    public var serial: String
    public var filePath: String
    /// 已转换为本地时区的记录时间。
    public var createdAt: Date
    public var createdAtRaw: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: String?
    public var trackString: String?
    public var discString: String?

    public var fileName: String { (filePath as NSString).lastPathComponent }

    /// 还原成 `Tags`（只含本表保存的 7 个字段）。
    public var restoredTags: Tags {
        var t = Tags()
        t.title = title
        t.artist = artist
        t.album = album
        t.year = year
        let (tn, tt) = TagsHistoryStore.parsePair(trackString)
        t.trackNumber = tn; t.trackTotal = tt
        let (dn, dt) = TagsHistoryStore.parsePair(discString)
        t.discNumber = dn; t.discTotal = dt
        return t
    }

    /// 生成一个只写这 7 个字段的编辑集，用于「撤消标签保存」。
    public var undoEdit: TagEdit {
        var e = TagEdit()
        e.set(.title, title)
        e.set(.artist, artist)
        e.set(.album, album)
        e.set(.year, year)
        e.set(.track, trackString)
        e.set(.disc, discString)
        return e
    }
}

public enum HistoryStoreError: LocalizedError {
    case openFailed(String)
    case sqlFailed(String, String)   // (语句摘要, sqlite 报错)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "打开历史库失败：\(m)"
        case .sqlFailed(let stmt, let m): return "SQL 执行失败 [\(stmt)]：\(m)"
        }
    }
}

/// 标签编辑历史库。线程安全（内部串行化）。
public final class TagsHistoryStore {

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let databaseURL: URL

    // MARK: 生命周期

    /// 默认库位置：`~/Library/Application Support/MacTagger/tagshistory.db`
    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent("MacTagger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tagshistory.db")
    }

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知"
            if db != nil { sqlite3_close_v2(db); db = nil }
            throw HistoryStoreError.openFailed(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=3000;")
        try createSchema()
    }

    deinit { closeInternal() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closeInternal()
    }

    private func closeInternal() {
        if db != nil { sqlite3_close_v2(db); db = nil }
    }

    // MARK: 建表（逐字照抄原版语句）

    private func createSchema() throws {
        try exec("""
        create table if not exists tagshistory (
            serial     varchar(21) primary key,
            filepath   varchar(256) not null,
            createtime datetime default(STRFTIME('%Y-%m-%d %H:%M:%f','NOW')),
            title      varchar(64),
            artist     varchar(64),
            album      varchar(64),
            year       varchar(4),
            trackstr   varchar(2),
            discstr    varchar(2)
        );
        """)
        try exec("create index if not exists th_idx01 on tagshistory(filepath);")
        try exec("create table if not exists config (thserial_prefix integer);")

        // config 表在原版里只有一行；不存在时补一行 0。
        let count = try scalarInt("select count(*) from config;")
        if count == 0 {
            try exec("insert into config (thserial_prefix) values (0);")
        }
    }

    // MARK: 写入历史

    /// 在改写标签**之前**调用，把旧值记下来以便撤销。
    /// - Returns: 本条记录的 21 位流水号。
    @discardableResult
    public func record(filePath: String, tags: Tags) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let prefix = try readSerialPrefixLocked()
        var lastError: Error?
        // 同一毫秒内可能撞主键，最多重试 100 次（序号位 00–99）。
        for seq in 0..<100 {
            let serial = TagsHistoryStore.makeSerial(prefix: prefix, sequence: seq)
            do {
                try insertLocked(serial: serial, filePath: filePath, tags: tags)
                return serial
            } catch {
                lastError = error
                if sqlite3_errcode(db) != SQLITE_CONSTRAINT { throw error }
            }
        }
        throw lastError ?? HistoryStoreError.sqlFailed("insert tagshistory", "流水号耗尽")
    }

    private func insertLocked(serial: String, filePath: String, tags: Tags) throws {
        let sql = """
        insert into tagshistory (serial, filepath, title, artist, album, year, trackstr, discstr)
        values (?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError("insert") }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, serial)
        bindText(stmt, 2, filePath)
        bindText(stmt, 3, tags.title)
        bindText(stmt, 4, tags.artist)
        bindText(stmt, 5, tags.album)
        bindText(stmt, 6, tags.year)
        bindText(stmt, 7, tags.trackString)
        bindText(stmt, 8, tags.discString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError("insert") }
    }

    // MARK: 查询

    /// 按文件路径取历史，时间已转本地时区，最新的在前。
    public func history(forFilePath path: String, limit: Int = 200) throws -> [TagsHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        select serial, filepath, datetime(createtime,'localtime'), title, artist, album, year, trackstr, discstr
        from tagshistory where filepath = ? order by createtime desc, serial desc limit ?;
        """
        return try query(sql) { stmt in
            bindText(stmt, 1, path)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    /// 取全部历史（分页）。
    public func allHistory(limit: Int = 500, offset: Int = 0) throws -> [TagsHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        select serial, filepath, datetime(createtime,'localtime'), title, artist, album, year, trackstr, discstr
        from tagshistory order by createtime desc, serial desc limit ? offset ?;
        """
        return try query(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
        }
    }

    public func entryCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("select count(*) from tagshistory;")
    }

    // MARK: 维护

    /// 文件被重命名后同步历史里的路径。
    @discardableResult
    public func updateFilePath(from oldPath: String, to newPath: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update tagshistory set filepath = ? where filepath = ?;",
                                 -1, &stmt, nil) == SQLITE_OK else { throw sqlError("update filepath") }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, newPath)
        bindText(stmt, 2, oldPath)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError("update filepath") }
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    public func delete(serial: String) throws -> Int {
        try deleteBy(column: "serial", value: serial)
    }

    @discardableResult
    public func delete(filePath: String) throws -> Int {
        try deleteBy(column: "filepath", value: filePath)
    }

    private func deleteBy(column: String, value: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        // column 只可能是本文件内的字面量，不来自外部输入。
        guard sqlite3_prepare_v2(db, "delete from tagshistory where \(column) = ?;",
                                 -1, &stmt, nil) == SQLITE_OK else { throw sqlError("delete") }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, value)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError("delete") }
        return Int(sqlite3_changes(db))
    }

    /// 清空全部历史并重置 `thserial_prefix`（对应原版的「清空标签历史」）。
    public func clearAll(resetPrefixTo newPrefix: Int = 0) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("begin immediate;")
        do {
            try exec("delete from tagshistory;")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "update config set thserial_prefix = ?;",
                                     -1, &stmt, nil) == SQLITE_OK else { throw sqlError("reset prefix") }
            sqlite3_bind_int(stmt, 1, Int32(newPrefix))
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard rc == SQLITE_DONE else { throw sqlError("reset prefix") }
            try exec("commit;")
        } catch {
            try? exec("rollback;")
            throw error
        }
        try exec("vacuum;")
    }

    public func serialPrefix() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try readSerialPrefixLocked()
    }

    private func readSerialPrefixLocked() throws -> Int {
        try scalarInt("select coalesce(max(thserial_prefix), 0) from config;")
    }

    // MARK: - 流水号

    private static let serialFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmssSSS"      // 17 位
        return f
    }()

    /// 21 位：2 位前缀 + 17 位 UTC 时间戳（毫秒） + 2 位同毫秒序号。
    static func makeSerial(prefix: Int, sequence: Int, date: Date = Date()) -> String {
        let p = String(format: "%02d", abs(prefix) % 100)
        let ts = serialFormatter.string(from: date)
        let s = String(format: "%02d", sequence % 100)
        return p + ts + s
    }

    static func parsePair(_ raw: String?) -> (Int?, Int?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let n = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let t = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (n.flatMap { $0 > 0 ? $0 : nil }, t.flatMap { $0 > 0 ? $0 : nil })
    }

    private static let readFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current            // datetime(...,'localtime') 已转本地
        return f
    }()

    // MARK: - 低层工具

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let m = errMsg.map { String(cString: $0) } ?? "未知"
            sqlite3_free(errMsg)
            throw HistoryStoreError.sqlFailed(String(sql.prefix(60)), m)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError(sql) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func query(_ sql: String,
                       bind: (OpaquePointer?) -> Void) throws -> [TagsHistoryEntry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError(sql) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var out: [TagsHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raw = text(stmt, 2) ?? ""
            out.append(TagsHistoryEntry(
                serial: text(stmt, 0) ?? "",
                filePath: text(stmt, 1) ?? "",
                createdAt: TagsHistoryStore.readFormatter.date(from: raw) ?? Date(timeIntervalSince1970: 0),
                createdAtRaw: raw,
                title: text(stmt, 3),
                artist: text(stmt, 4),
                album: text(stmt, 5),
                year: text(stmt, 6),
                trackString: text(stmt, 7),
                discString: text(stmt, 8)))
        }
        return out
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value, !v.isEmpty {
            sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func sqlError(_ what: String) -> HistoryStoreError {
        let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知"
        return .sqlFailed(String(what.prefix(60)), m)
    }
}

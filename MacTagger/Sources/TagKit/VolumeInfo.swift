//
//  VolumeInfo.swift
//  MacTagger — 卷（Volume）属性识别
//
//  为什么需要：用户的音乐库常放在 TF / microSD 卡、U 盘、移动硬盘上。
//  这类介质的主控缓存很小，**并发写入只会让它们互相拖慢**，
//  串行写反而更快、更稳。内置 SSD 则相反，并发写有收益。
//
//  所以批量写入前先问一句「这批文件在什么卷上」，据此决定并发度。
//
//  判定用 Foundation 的 URLResourceValues，不依赖 DiskArbitration，
//  沙盒内也能用（这些 key 只需要对该路径的读权限）。
//

import Foundation

// MARK: - 单个卷的判定结果

/// 一个卷的四个关键属性（对应 `URLResourceValues` 的同名 key）。
/// 取不到的属性为 `nil`（某些网络卷 / 特殊卷不提供）。
public struct VolumeTraits: Sendable, Equatable {

    /// 卷名（`volumeNameKey`），例如 `Macintosh HD`、`NO NAME`。
    public var name: String?
    /// 卷根路径（`volumeURLKey`），例如 `/`、`/Volumes/NO NAME`。
    public var volumePath: String?

    /// 可移动介质（`volumeIsRemovableKey`）：SD 卡、U 盘、光盘。
    public var isRemovable: Bool?
    /// 可推出（`volumeIsEjectableKey`）：外置硬盘、磁盘映像、大部分读卡器。
    public var isEjectable: Bool?
    /// 内置（`volumeIsInternalKey`）：内置 SSD 为 true；外置为 false。
    public var isInternal: Bool?
    /// 本地（`volumeIsLocalKey`）：网络卷（SMB/AFP/NFS）为 false。
    public var isLocal: Bool?

    public init(name: String? = nil,
                volumePath: String? = nil,
                isRemovable: Bool? = nil,
                isEjectable: Bool? = nil,
                isInternal: Bool? = nil,
                isLocal: Bool? = nil) {
        self.name = name
        self.volumePath = volumePath
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
    }

    /// 是否属于「慢介质」——需要串行写、需要自适应暂停的卷。
    ///
    /// 命中任一即为真：
    /// - `isRemovable == true`（SD 卡 / U 盘）
    /// - `isEjectable == true`（外置硬盘 / 读卡器 / 磁盘映像）
    /// - `isInternal == false`（外置总线，雷雳/USB）
    /// - `isLocal == false`（网络卷，同样忌讳并发小写）
    ///
    /// 全部属性都取不到时保守判为 `false`（按内置盘处理，行为与优化前一致）。
    public var isSlowMedia: Bool {
        if isRemovable == true { return true }
        if isEjectable == true { return true }
        if isInternal == false { return true }
        if isLocal == false { return true }
        return false
    }

    /// 一行人类可读描述，probe 与日志用。
    public var summary: String {
        func f(_ b: Bool?) -> String { b.map { $0 ? "是" : "否" } ?? "未知" }
        return "卷名=\(name ?? "未知") 根=\(volumePath ?? "未知") "
             + "可移动=\(f(isRemovable)) 可推出=\(f(isEjectable)) "
             + "内置=\(f(isInternal)) 本地=\(f(isLocal)) → "
             + (isSlowMedia ? "可移动/外置卷（按慢介质处理）" : "内置本地卷")
    }
}

// MARK: - 查询入口

public enum VolumeInfo {

    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeURLKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsInternalKey,
        .volumeIsLocalKey,
    ]

    /// 读取 `url` 所在卷的属性。
    ///
    /// 文件可能还不存在（例如重命名的目标路径），此时逐级向上找到第一个存在的祖先目录来问。
    public static func traits(of url: URL) -> VolumeTraits {
        var probe = url.standardizedFileURL
        // 最多向上找 8 级；到根目录就停。
        for _ in 0..<8 {
            if let v = try? probe.resourceValues(forKeys: keys) {
                return VolumeTraits(name: v.volumeName,
                                    volumePath: v.volume?.standardizedFileURL.path,
                                    isRemovable: v.volumeIsRemovable,
                                    isEjectable: v.volumeIsEjectable,
                                    isInternal: v.volumeIsInternal,
                                    isLocal: v.volumeIsLocal)
            }
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent.path == probe.path { break }
            probe = parent
        }
        return VolumeTraits()
    }

    /// `url` 是否在可移动 / 外置 / 网络卷上。
    public static func isRemovable(url: URL) -> Bool {
        cachedTraits(for: url).isSlowMedia
    }

    /// 这批文件里**只要有一个**在可移动 / 外置卷上就返回 `true`。
    /// 命中即返回，不会把整批都问一遍。
    public static func containsRemovable(_ urls: [URL]) -> Bool {
        for u in urls where cachedTraits(for: u).isSlowMedia { return true }
        return false
    }

    // MARK: 缓存
    //
    // 一次批量动辄几千个文件，逐个问 resourceValues 是几千次系统调用。
    // 同一批文件通常只落在很少几个目录里，所以按**父目录**缓存判定结果。
    // 缓存只在进程内有效；插拔卡后路径本身就变了，不会读到脏结果。

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: VolumeTraits] = [:]

    private static func cachedTraits(for url: URL) -> VolumeTraits {
        let key = url.deletingLastPathComponent().standardizedFileURL.path
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let t = traits(of: url)
        cacheLock.lock()
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = t
        cacheLock.unlock()
        return t
    }

    /// 测试 / 换卡后手动清缓存。
    public static func resetCache() {
        cacheLock.lock(); cache.removeAll(); cacheLock.unlock()
    }
}

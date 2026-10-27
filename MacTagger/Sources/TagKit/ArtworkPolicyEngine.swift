//
//  ArtworkPolicyEngine.swift
//  MacTagger — 封面落地策略引擎（把「封面写到哪里」这件事从写入路径里摘出来）
//
//  三种模式（`ArtworkEmbedMode`，设置项在 `ArtworkStore`）：
//    * `.embed`      原版行为，封面嵌进音频标签；
//    * `.folderFile` 封面只写成专辑目录里的图片文件，**音频一个字节不动**；
//    * `.both`       两边都写。
//
//  接线方式刻意做成「编辑集的一次纯函数改写」：
//
//      let (payload, jobs) = policy.apply(to: payload)
//
//  改写后的 `payload` 交给原来的 `BatchEngine.applyEdits`，`jobs` 交给
//  `ArtworkPolicy.run(_:)` 落地成文件夹图片。写入路径本身不需要知道模式是什么，
//  预估（`TagService.estimatedWriteCost`）也因此天然跟着变——它吃的是改写**之后**
//  的编辑集，`.folderFile` 模式下封面动作已经变回 `.keep`，自然报 0 个整文件重写。
//
//  三条约定：
//  1. **只改写 `.replace`**。`.removeAll` 照旧落到音频上——「删掉内嵌封面」是用户
//     明确要求的动作，跟「新封面存哪里」是两码事，模式不该把它吞掉。
//  2. **一个文件夹只写一张**。批量选中一整张专辑的 12 首歌时目标文件夹只有一个，
//     去重在 `FolderArtwork.writeBatch` 里做；本文件只负责按图片字节把任务分组。
//  3. **`.folderFile` 下编辑集可能被清空**（用户只改了封面）。清空的项直接从 payload
//     里剔除——那正是这个模式的意义：音频不打开。调用方因此必须允许
//     「payload 为空但 jobs 非空」这种局面，不能再拿 `payload.isEmpty` 当「无事可做」。
//
//  为什么放在 TagKit 而不是 App：probe 目标（mactagger-probe）只编译
//  `Sources/Probe` + `Sources/TagKit`。策略引擎放 App 里，probe 就只能另写一份，
//  验证的便不再是产品代码。App 侧的接线（读设置、状态栏文案）在
//  `Sources/App/Core/ArtworkPolicy.swift`。
//

import Foundation

// MARK: - 一个文件夹封面任务

/// 「把这张图写进这些音频文件所在的目录」。目录去重由 `FolderArtwork.writeBatch` 完成。
public struct FolderArtworkJob: Sendable {
    public var data: Data
    public var mime: String?
    /// 提供目标目录的音频文件（同一目录只会写一次）。
    public var audioURLs: [URL]
    /// `naming == .albumName` 时用得上：URL → 专辑名。从编辑集里就地取到的部分先放这儿，
    /// 取不到的留给 `run` 去读文件。
    public var albums: [URL: String]

    public init(data: Data, mime: String? = nil, audioURLs: [URL] = [], albums: [URL: String] = [:]) {
        self.data = data
        self.mime = mime
        self.audioURLs = audioURLs
        self.albums = albums
    }

    public var byteCount: Int { data.count }
}

// MARK: - 落地结果

/// 一批文件夹封面任务的汇总。口径是**文件夹数**，不是音频文件数。
public struct FolderArtworkOutcome: Sendable {
    public var written = 0
    public var skipped = 0
    public var failed = 0
    /// 实际写出的文件名（去重、保序），用于状态栏文案。
    public var fileNames: [String] = []
    public var failures: [(url: URL, message: String)] = []
    /// 写出的总字节（图片本身，不含音频——音频没被碰）。
    public var bytesWritten: Int64 = 0

    public init() {}

    public var isEmpty: Bool { written == 0 && skipped == 0 && failed == 0 }

    /// 「封面已存为 3 个文件夹的 cover.jpg」。没有任何任务时返回 nil。
    public var statusNote: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if written > 0 {
            let name = fileNames.count == 1 ? fileNames[0] : fileNames.joined(separator: " / ")
            parts.append("封面已存为 \(written) 个文件夹的 \(name)")
        }
        if skipped > 0 { parts.append("\(skipped) 个文件夹已有同名封面（未覆盖）") }
        if failed > 0 { parts.append("\(failed) 个文件夹写入失败") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 策略

public struct ArtworkPolicy: Sendable {

    public var mode: ArtworkEmbedMode
    public var naming: FolderArtworkNaming
    public var overwrite: Bool

    public init(mode: ArtworkEmbedMode = .embed,
                naming: FolderArtworkNaming = .coverJpg,
                overwrite: Bool = false) {
        self.mode = mode
        self.naming = naming
        self.overwrite = overwrite
    }

    /// 原版行为：只嵌标签。
    public static let embedOnly = ArtworkPolicy()

    public var writesTag: Bool { mode.writesTag }
    public var writesFolderFile: Bool { mode.writesFolderFile }

    // MARK: 改写编辑集

    /// 按策略改写一批编辑集，并收集文件夹封面任务。
    ///
    /// - Returns:
    ///   - `payload`：交给 `BatchEngine.applyEdits` 的编辑集。`.folderFile` 模式下
    ///     只改封面的项会被整条剔除（音频完全不打开）。
    ///   - `jobs`：交给 `ArtworkPolicy.run(_:)` 的文件夹封面任务，按图片字节分组。
    public func apply(to payload: [(url: URL, edit: TagEdit)])
        -> (payload: [(url: URL, edit: TagEdit)], jobs: [FolderArtworkJob])
    {
        guard writesFolderFile else { return (payload, []) }

        var out: [(url: URL, edit: TagEdit)] = []
        var jobs: [FolderArtworkJob] = []
        out.reserveCapacity(payload.count)

        for item in payload {
            guard case .replace(let arts) = item.edit.artworkAction,
                  let picked = arts.first(where: { $0.type == .frontCover }) ?? arts.first,
                  !picked.data.isEmpty else {
                out.append(item)
                continue
            }

            // 同一张图（字节完全一致）并成一个任务。绝大多数情况下只有一张。
            let album = ArtworkPolicy.albumName(in: item.edit)
            if let i = jobs.firstIndex(where: { $0.data.count == picked.data.count && $0.data == picked.data }) {
                jobs[i].audioURLs.append(item.url)
                if let album { jobs[i].albums[item.url] = album }
            } else {
                var job = FolderArtworkJob(data: picked.data, mime: picked.mimeType, audioURLs: [item.url])
                if let album { job.albums[item.url] = album }
                jobs.append(job)
            }

            var edit = item.edit
            if !writesTag {
                // 音频侧不写封面。编辑集因此可能变空——那就整条不写，音频不打开。
                edit.artworkAction = .keep
                if edit.isEmpty { continue }
            }
            out.append((item.url, edit))
        }
        return (out, jobs)
    }

    /// 编辑集里就地带着的专辑名（`.albumName` 命名规则用）。
    static func albumName(in edit: TagEdit) -> String? {
        guard let v = edit.changes.first(where: { $0.field == .album })?.value,
              !v.isEmpty else { return nil }
        return v
    }

    // MARK: 落地

    /// 把文件夹封面任务全部写下去。**同步阻塞**（几个目录、每个一次 write），
    /// 调用方在 App 里请放到后台 Task 上，别占主线程。
    ///
    /// 跨任务也按目录去重：同一个目录被两张不同的图指到时，先到的那张生效，
    /// 后面的记为跳过——一个目录反复覆写没有意义，还多两次闪存写入。
    public func run(_ jobs: [FolderArtworkJob]) -> FolderArtworkOutcome {
        var outcome = FolderArtworkOutcome()
        guard !jobs.isEmpty else { return outcome }
        var claimed = Set<URL>()

        for job in jobs {
            let urls = job.audioURLs.filter { url in
                let folder = url.deletingLastPathComponent()
                guard !claimed.contains(folder) else { return false }
                claimed.insert(folder)
                return true
            }
            guard !urls.isEmpty else { continue }

            let naming = self.naming
            let albums = job.albums
            let provider: ((URL) -> String?)? = naming == .albumName ? { url in
                if let a = albums[url] { return a }
                return (try? TagService.read(url))?.tags.album
            } : nil

            let (summary, writes) = FolderArtwork.writeBatch(data: job.data,
                                                             mime: job.mime,
                                                             audioURLs: urls,
                                                             naming: naming,
                                                             albumProvider: provider,
                                                             overwrite: overwrite)
            outcome.written += summary.succeeded
            outcome.skipped += summary.ignored
            outcome.failed += summary.failed
            for w in writes where w.isWritten {
                let name = w.file.lastPathComponent
                if !outcome.fileNames.contains(name) { outcome.fileNames.append(name) }
                outcome.bytesWritten += Int64(w.byteCount)
            }
            for f in summary.failures {
                outcome.failures.append((f.url, f.error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: 文案

    /// 保存确认框里那句「封面将存为文件夹图片，不重写音频」。没有文件夹任务时返回 nil。
    public func plannedText(jobs: [FolderArtworkJob]) -> String? {
        guard !jobs.isEmpty else { return nil }
        var folders = Set<URL>()
        for j in jobs { for u in j.audioURLs { folders.insert(u.deletingLastPathComponent()) } }
        let n = folders.count
        let sample = jobs[0].data
        let name = FolderArtwork.fileName(for: sample, declaredMIME: jobs[0].mime, naming: naming)
        switch mode {
        case .folderFile:
            return "封面将存为 \(n) 个文件夹的 \(name)，不重写音频。"
        case .both:
            return "封面同时存为 \(n) 个文件夹的 \(name)（音频照常嵌入）。"
        case .embed:
            return nil
        }
    }
}

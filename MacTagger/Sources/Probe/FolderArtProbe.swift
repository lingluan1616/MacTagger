//
//  FolderArtProbe.swift
//  mactagger-probe — 文件夹封面的验证子命令
//
//    mactagger-probe folderart        <dir> <image>   往目录下每个含音频的文件夹写一张封面
//    mactagger-probe folderart-locate <dir>           列出每个文件夹已有的封面文件
//
//  本文件所有符号以 fa 前缀命名，避免与同目录其余 probe 冲突。
//

import Foundation

// MARK: - 小工具

func faKB(_ n: Int) -> String { String(format: "%.1f KB", Double(n) / 1024.0) }

/// 递归收集目录下 TagLib 认得的音频文件。
func faCollectAudio(_ dir: URL) -> [URL] {
    guard let en = FileManager.default.enumerator(at: dir,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
    var out: [URL] = []
    for case let url as URL in en where TagService.isSupported(url: url) {
        out.append(url)
    }
    return out.sorted { $0.path < $1.path }
}

/// 相对 `root` 的短路径，打印用。
func faRel(_ url: URL, root: URL) -> String {
    let r = root.standardizedFileURL.path
    let p = url.standardizedFileURL.path
    if p.hasPrefix(r) {
        let cut = p.dropFirst(r.count)
        return cut.hasPrefix("/") ? String(cut.dropFirst()) : String(cut)
    }
    return url.lastPathComponent
}

// MARK: - folderart

func cmdFolderArt(_ dirPath: String, _ imagePath: String, args: [String]) {
    let root = URL(fileURLWithPath: dirPath).standardizedFileURL
    let naming: FolderArtworkNaming = args.contains("--folder") ? .folderJpg
                                    : args.contains("--album")  ? .albumName : .coverJpg
    let overwrite = args.contains("--overwrite")

    hr("文件夹封面写入 \(root.lastPathComponent)")

    guard let image = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !image.isEmpty else {
        print("  读不到图片：\(imagePath)"); return
    }
    let files = faCollectAudio(root)
    guard !files.isEmpty else {
        print("  目录里没有 TagLib 认得的音频文件：\(root.path)"); return
    }

    let ext = FolderArtwork.fileExtension(forImage: image)
    print("  图片        : \(faKB(image.count))  MIME=\(ArtworkProcessor.mimeType(image) ?? "?")"
          + "  → 扩展名按字节判定为 .\(ext)")
    print("  命名规则    : \(naming.localizedName)    覆盖已有：\(overwrite ? "是" : "否")")
    print("  音频文件    : \(files.count) 个")

    // 专辑名从第一首歌的标签里拿（`albumName` 规则才用得上）。
    let albumOf: (URL) -> String? = { url in (try? TagService.read(url))?.tags.album }

    // 写之前先给每个音频文件按「大小 + 修改时间」拍个快照，收工原样对账。
    func faSnapshot() -> [String: String] {
        var m: [String: String] = [:]
        for url in files {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            m[url.path] = "\(size)/\(date)"
        }
        return m
    }
    let snapBefore = faSnapshot()

    let (summary, writes) = FolderArtwork.writeBatch(data: image,
                                                     audioURLs: files,
                                                     naming: naming,
                                                     albumProvider: naming == .albumName ? albumOf : nil,
                                                     overwrite: overwrite)
    print()
    print("  " + intlPad("文件夹", 34) + intlPad("结果", 10) + "最终路径")
    print("  " + String(repeating: "-", count: 88))
    for w in writes {
        let mark = w.isWritten ? "✔ 写入" : "○ 跳过"
        print("  " + intlPad(faRel(w.folder, root: root), 34) + intlPad(mark, 10) + faRel(w.file, root: root))
    }
    print()
    print("  汇总（口径：总共 = 去重后的文件夹数）：\(summary.description)")
    print("  耗时 \(String(format: "%.3f s", summary.elapsed))")
    for f in summary.failures {
        print("  失败：\(f.url.lastPathComponent) — \(f.error.localizedDescription)")
    }

    // 去重证明：文件夹数 vs 音频文件数
    let folderCount = Set(files.map { $0.deletingLastPathComponent().path }).count
    print("  去重核对    : \(files.count) 个音频 → \(folderCount) 个文件夹，"
          + (summary.total == folderCount ? "✔ total 与文件夹数一致" : "✘ total=\(summary.total) 不符"))

    // 音频一个字节没动的证明：大小 + 修改时间逐个对账
    let snapAfter = faSnapshot()
    let changed = files.filter { snapBefore[$0.path] != snapAfter[$0.path] }
    print("  音频对账    : " + (changed.isEmpty
        ? "✔ \(files.count) 个音频文件的大小与修改时间全部未变"
        : "✘ \(changed.count) 个音频被改动：" + changed.map(\.lastPathComponent).joined(separator: ", ")))
}

// MARK: - folderart-locate

func cmdFolderArtLocate(_ dirPath: String) {
    let root = URL(fileURLWithPath: dirPath).standardizedFileURL
    hr("已有文件夹封面识别 \(root.lastPathComponent)")

    let files = faCollectAudio(root)
    guard !files.isEmpty else {
        print("  目录里没有 TagLib 认得的音频文件：\(root.path)"); return
    }

    // 保持首次出现顺序
    var folders: [URL] = []
    var seen = Set<String>()
    for f in files {
        let d = f.deletingLastPathComponent()
        if seen.insert(d.path).inserted { folders.append(d) }
    }

    print("  查找优先级  : " + FolderArtwork.commonBaseNames.joined(separator: " > ")
          + "  ×  " + FolderArtwork.recognizedExtensions.joined(separator: "/"))
    print()
    print("  " + intlPad("文件夹", 34) + intlPad("识别结果", 26) + "字节")
    print("  " + String(repeating: "-", count: 78))
    var hit = 0
    for folder in folders {
        let album = files.first { $0.deletingLastPathComponent() == folder }
            .flatMap { (try? TagService.read($0))?.tags.album }
        if let url = FolderArtwork.locate(folder: folder, album: album) {
            hit += 1
            let n = (try? Data(contentsOf: url))?.count ?? 0
            print("  " + intlPad(faRel(folder, root: root), 34) + intlPad(url.lastPathComponent, 26) + faKB(n))
        } else {
            print("  " + intlPad(faRel(folder, root: root), 34) + intlPad("（无）", 26) + "-")
        }
    }
    print()
    print("  \(folders.count) 个文件夹，\(hit) 个已有文件夹封面")

    // 反向操作：文件夹封面 → 可写进标签的 Artwork
    if let first = folders.first(where: { FolderArtwork.locate(folder: $0) != nil }),
       let art = FolderArtwork.artwork(inFolder: first) {
        print("  反向导入示例: \(faRel(first, root: root)) → Artwork "
              + "\(art.declaredWidth)×\(art.declaredHeight) \(art.mimeType ?? "?") \(faKB(art.byteCount))")
    }
}

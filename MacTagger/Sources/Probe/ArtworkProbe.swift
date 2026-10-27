//
//  ArtworkProbe.swift
//  mactagger-probe — 封面三件套的验证子命令
//
//    mactagger-probe artproc  <image>            缩放 / 转 JPEG / 限体积，逐步打印前后尺寸与字节
//    mactagger-probe artsearch <搜索词...>        联网列封面候选，并下载第一张打印实际尺寸
//    mactagger-probe artprop  <dir>              对目录跑「按专辑自动匹配」，打印配对表
//    mactagger-probe artseed  <image> <audio...> 把一张图写成这些音频的封面（造端到端夹具用）
//
//  本文件所有符号以 art 前缀命名，避免与同目录另外两份 probe 冲突。
//

import Foundation
import ImageIO

// MARK: - 小工具

func artKB(_ n: Int) -> String { String(format: "%.1f KB", Double(n) / 1024.0) }

func artDims(_ data: Data) -> String {
    let s = ArtworkProcessor.pixelSize(data)
    return s.width > 0 ? "\(s.width)×\(s.height)" : "?×?"
}

func artLine(_ label: String, _ data: Data) {
    print("  " + intlPad(label, 22) + intlPad(artDims(data), 13)
          + intlPad(artKB(data.count), 12) + (ArtworkProcessor.mimeType(data) ?? "?"))
}

/// probe 里也要把国际源注册进来（中文四源由 SourceRegistry 自己内建注册）。
func artRegisterSources() {
    let reg = SourceRegistry.shared
    reg.register(ITunesSource(countryCode: "CN"))
    reg.register(MusicBrainzSource())
    reg.register(CoverArtArchiveSource())
}

// MARK: - artproc

func cmdArtProc(_ path: String) {
    hr("封面处理 \((path as NSString).lastPathComponent)")

    guard let original = try? Data(contentsOf: URL(fileURLWithPath: path)), !original.isEmpty else {
        print("  读不到文件：\(path)"); return
    }
    print("  " + intlPad("步骤", 22) + intlPad("尺寸", 13) + intlPad("字节", 12) + "MIME")
    print("  " + String(repeating: "-", count: 62))
    artLine("原始", original)

    // ① 缩放
    for edge in [1000, 500, 300] {
        do {
            let out = try ArtworkProcessor.resize(original, maxEdge: edge)
            artLine("resize ≤ \(edge)", out)
        } catch {
            print("  resize ≤ \(edge) 失败：\(error.localizedDescription)")
        }
    }

    // ② 不放大的守卫
    do {
        let huge = try ArtworkProcessor.resize(original, maxEdge: 99_999)
        print("  放大守卫             : " + (huge.count == original.count
              ? "✔ 原样返回，未放大" : "✘ 字节变了（\(original.count) → \(huge.count)）"))
    } catch { print("  放大守卫             : ✘ \(error.localizedDescription)") }

    // ③ 转 JPEG
    for q in [0.9, 0.7, 0.5] {
        do {
            let out = try ArtworkProcessor.convertToJPEG(original, quality: q)
            artLine("JPEG q=\(q)", out)
        } catch {
            print("  JPEG q=\(q) 失败：\(error.localizedDescription)")
        }
    }

    // ④ 限体积
    for kb in [200, 100, 40] {
        do {
            let out = try ArtworkProcessor.limit(original, maxBytes: kb * 1024)
            let ok = out.count <= kb * 1024
            artLine("limit ≤ \(kb) KB" + (ok ? " ✔" : " (尽力)"), out)
        } catch {
            print("  limit ≤ \(kb) KB 失败：\(error.localizedDescription)")
        }
    }

    // ⑤ 组合流水线（界面「应用」走的就是这条）
    let opts = ArtworkProcessOptions(maxEdge: 500, format: .jpeg, jpegQuality: 0.85, maxBytes: 0)
    do {
        let r = try ArtworkProcessor.process(original, options: opts)
        print("")
        print("  流水线 maxEdge=500 / JPEG / q=0.85")
        print("    结果: \(r.width)×\(r.height)  \(artKB(r.byteCount))  \(r.mimeType)")
        print("    原始: \(artKB(r.originalByteCount))   压缩比: "
              + String(format: "%.1f%%", Double(r.byteCount) / Double(max(1, r.originalByteCount)) * 100))
    } catch {
        print("  流水线失败：\(error.localizedDescription)")
    }
}

// MARK: - artsearch

func cmdArtSearch(_ term: String) {
    artRegisterSources()
    hr("封面搜索 「\(term)」")

    let query = intlParseQuery(term)
    print("  查询: 标题=\(fmt(query.title)) 艺术家=\(fmt(query.artist)) 专辑=\(fmt(query.album))")
    print("  参与来源: \(ArtworkSearchService.artworkSourceIDs.joined(separator: ", "))")

    let started = Date()
    let outcome = (try? intlRunBlocking { await ArtworkSearchService.search(query, limitPerSource: 5) })
        ?? ArtworkSearchOutcome()
    let elapsed = Date().timeIntervalSince(started)

    print("")
    print("  各源尝试：")
    for a in outcome.attempts {
        let text: String
        switch a.outcome {
        case .succeeded(let n): text = "✔ \(n) 条"
        case .empty:            text = "— 无结果"
        case .failed:           text = "✘ 失败：\(a.message ?? "?")"
        case .skipped:          text = "· 跳过：\(a.message ?? "?")"
        }
        print("    " + intlPad(a.sourceID, 16) + intlPad(text, 30) + String(format: "%.2fs", a.elapsed))
    }

    guard !outcome.candidates.isEmpty else {
        print("")
        print("  ✘ 没有候选（耗时 \(String(format: "%.2f", elapsed)) 秒）")
        if let e = outcome.errorSummary { print("  错误汇总：\(e)") }
        return
    }

    print("")
    print("  候选 \(outcome.candidates.count) 张（耗时 \(String(format: "%.2f", elapsed)) 秒）：")
    print("    " + intlPad("#", 4) + intlPad("来源", 12) + intlPad("预计", 10)
          + intlPad("专辑", 28) + intlPad("艺术家", 20) + "分数")
    for (i, c) in outcome.candidates.prefix(12).enumerated() {
        print("    " + intlPad("\(i + 1)", 4) + intlPad(c.sourceID, 12) + intlPad(c.sizeLabel, 10)
              + intlPad(c.displayAlbum, 28) + intlPad(c.displayArtist, 20)
              + String(format: "%.3f", c.score))
    }

    // 下载第一张
    let first = outcome.candidates[0]
    print("")
    print("  下载第一张：\(first.sourceName) / \(first.displayAlbum)")
    do {
        let data = try intlRunBlocking { try await ArtworkSearchService.download(first) }
        let size = ArtworkProcessor.pixelSize(data)
        print("    实际像素 : \(size.width)×\(size.height)")
        print("    字节数   : \(data.count) B (\(artKB(data.count)))")
        print("    MIME     : \(ArtworkProcessor.mimeType(data) ?? "?")")
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactagger-artsearch.jpg")
        try? data.write(to: dest)
        print("    已存到   : \(dest.path)")
    } catch {
        print("    ✘ 下载失败：\(error.localizedDescription)")
    }
}

// MARK: - artprop

func artScanFiles(_ dir: String) -> [ArtworkFileInfo] {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    let exts = ImportOptions.defaultExtensions
    guard let en = FileManager.default.enumerator(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
    var out: [ArtworkFileInfo] = []
    for case let url as URL in en {
        guard exts.contains(url.pathExtension.lowercased()) else { continue }
        guard let file = try? TagService.read(url) else { continue }
        let arts = (try? TagService.readArtworks(url)) ?? []
        out.append(ArtworkFileInfo(url: url,
                                   fileName: url.lastPathComponent,
                                   album: file.tags.album,
                                   albumArtist: file.tags.albumArtist,
                                   artist: file.tags.artist,
                                   hasArtwork: !arts.isEmpty,
                                   artworkByteCount: arts.first?.byteCount ?? 0))
    }
    return out.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
}

func cmdArtProp(_ dir: String) {
    hr("从标签取图：按专辑自动匹配 \((dir as NSString).lastPathComponent)")

    let files = artScanFiles(dir)
    guard !files.isEmpty else { print("  目录里没有可读的音频文件"); return }

    print("  扫描到 \(files.count) 个文件：")
    print("    " + intlPad("文件", 30) + intlPad("封面", 12) + intlPad("专辑", 22) + "专辑艺术家")
    for f in files {
        print("    " + intlPad(f.fileName, 30)
              + intlPad(f.hasArtwork ? "✔ \(artKB(f.artworkByteCount))" : "—", 12)
              + intlPad(f.albumDisplay, 22) + f.albumArtistDisplay)
    }

    let plan = ArtworkPropagation.autoMatchByAlbum(files)
    print("")
    print("  \(plan.summary)")
    guard !plan.pairings.isEmpty else {
        print("  （没有可配对项）")
        if !plan.unmatched.isEmpty {
            print("  无匹配：" + plan.unmatched.map(\.fileName).joined(separator: ", "))
        }
        return
    }
    print("")
    print("  配对表（源 → 目标）：")
    print("    " + intlPad("封面来源", 30) + "-> " + intlPad("目标", 30) + "依据")
    for p in plan.pairings {
        print("    " + intlPad(p.source.fileName, 30) + "-> "
              + intlPad(p.target.fileName, 30) + p.reason.localizedName)
    }
    if !plan.unmatched.isEmpty {
        print("")
        print("  无匹配 \(plan.unmatched.count) 项：" + plan.unmatched.map(\.fileName).joined(separator: ", "))
    }

    // 顺带验证「仅专辑名」这一档是可以关掉的
    let strict = ArtworkPropagation.autoMatchByAlbum(files, allowAlbumOnly: false)
    print("")
    print("  关闭「仅专辑名」后可配对 \(strict.pairings.count) 项（严格档）")
}

// MARK: - artseed（端到端夹具）

func cmdArtSeed(_ imagePath: String, _ audioPaths: [String]) {
    hr("写入封面夹具")

    // `--clear` 表示「把这些文件的封面全删掉」，造「同专辑但只有一首有封面」的夹具用。
    if imagePath == "--clear" {
        for path in audioPaths {
            let url = URL(fileURLWithPath: path)
            var edit = TagEdit()
            edit.artworkAction = .removeAll
            do {
                _ = try TagService.write(edit, to: url)
                let back = (try? TagService.readArtworks(url)) ?? []
                print("  \(back.isEmpty ? "✔" : "✘") \(url.lastPathComponent): 剩余 \(back.count) 张封面")
            } catch {
                print("  ✘ \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return
    }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)), !data.isEmpty else {
        print("  读不到图片：\(imagePath)"); return
    }
    let size = ArtworkProcessor.pixelSize(data)
    let mime = ArtworkProcessor.mimeType(data) ?? "image/jpeg"
    print("  源图: \(size.width)×\(size.height)  \(artKB(data.count))  \(mime)")

    for path in audioPaths {
        let url = URL(fileURLWithPath: path)
        var edit = TagEdit()
        edit.artworkAction = .replace([Artwork(data: data, mimeType: mime,
                                               caption: "artseed", type: .frontCover,
                                               declaredWidth: size.width,
                                               declaredHeight: size.height)])
        do {
            _ = try TagService.write(edit, to: url)
            let back = (try? TagService.readArtworks(url)) ?? []
            print("  ✔ \(url.lastPathComponent): 回读 \(back.count) 张，"
                  + "\(back.first.map { artKB($0.byteCount) } ?? "-")")
        } catch {
            print("  ✘ \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

//
//  FileTableView.swift
//  MacTagger — 主文件列表（多列、可排序、可拖拽重排、可内联编辑）
//
//  列的顺序 / 宽度 / 显示隐藏三件事全部交给 SwiftUI 原生的 TableColumnCustomization：
//    · 按住表头左右拖 → 重排
//    · 拖表头分隔线   → 改列宽
//    · 右键表头       → 勾选显示 / 隐藏
//  用户改完立刻写进 UserDefaults（见 ColumnStore），重启原样恢复。
//
//  视觉逐值抄自设计稿 build_directions.py 的表头 hcell()/hdr 与行模板：
//  表头高 28 / 11px / 600 次要色，行高 30，单元格 12.5，
//  文件名列 = 7px 状态圆点 + 22px 缩略图（圆角 4）+ 文件名，gap 8；
//  数字列右对齐等宽 12.5；派生列（"格式"那类）次要色且字号 -1（11.5）。
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct FileTableView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var columns: ColumnStore
    @EnvironmentObject private var settings: AppSettings

    @State private var isDropTargeted = false

    /// 单元格内容的目标高度：行高减去 Table 自己加的上下内边距（实测各 4pt）。
    private static let cellContentHeight = Theme.Size.tableRowHeight - 8

    var body: some View {
        Table(model.displayRows,
              selection: $model.selection,
              sortOrder: $model.sortOrder,
              columnCustomization: $columns.customization) {
            // 24 列**全部**声明出来，让表头右键菜单能列全、隐藏过的列还能再勾回来。
            // 谁显示、什么顺序、多宽，由上面绑定的 customization 决定。
            TableColumnForEach(ColumnCatalog.all) { spec in
                TableColumn(spec.title, sortUsing: FileSortComparator(columnID: spec.id)) { row in
                    cell(spec: spec, row: row)
                }
                .width(min: spec.minWidth, ideal: spec.width, max: spec.maxWidth)
                .customizationID(spec.id.rawValue)
                // 用户没动过的列用目录里的默认值 —— 与 ColumnStore.isVisible 同一套默认。
                .defaultVisibility(ColumnCatalog.defaultVisible.contains(spec.id) ? .visible : .hidden)
                // 文件名是表格的锚点：能拖能改宽，但不许藏。
                .disabledCustomizationBehavior(
                    spec.id == .filename ? TableColumnCustomizationBehavior.visibility : []
                )
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { _ in
            model.revealInFinder()
        }
        .overlay { emptyState }
        .overlay { dropHighlight }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
        }
    }

    // MARK: 单元格

    @ViewBuilder
    private func cell(spec: ColumnSpec, row: FileRow) -> some View {
        Group {
            switch spec.render {
            case .name:   nameCell(row)
            case .check:  checkCell(spec: spec, row: row)
            case .number: numberCell(spec: spec, row: row)
            case .text:   textCell(spec: spec, row: row)
            }
        }
        // Table 没有 rowHeight 修饰符，行高只能从单元格内容顶出来。
        // 实测 Table 会在内容上下各留 4pt，所以按目标行高减掉这 8pt 给内容，
        // 最终 AX 量到的行高才正好是 Theme.Size.tableRowHeight。
        .frame(maxWidth: .infinity, minHeight: Self.cellContentHeight, alignment: spec.alignment)
    }

    /// 文件名列：状态圆点 → 封面缩略图 → 文件名（设计稿的顺序，gap 8）。
    /// 没有状态的行也占住这 7pt，否则文件名会一行一个起点。
    private func nameCell(_ row: FileRow) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            if let status = status(for: row) {
                StatusDot(color: status.color)
                    .help(status.help)
            } else {
                Color.clear.frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            }
            ArtworkThumbnail(row: row)
            Text(row.fileName)
                .font(Theme.Typo.tableCell)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(row.file.url.path)
        // 可见行优先：这一行进了视口就报一声。24 列里只挂文件名这一列，免得同一行报 24 次。
        //
        // **已读的行也报**：它给的是「用户正看着第几行」这个锚点，
        // `AppModel.sweepVisibleWindow` 每 300 ms 拿它围出可见窗口。
        // Table 底下是 NSTableView 的复用机制，onAppear **不可靠**
        //（用户实测：14 首的目录只有第一行报了上来），所以它只是快车道，
        // 真正兜底的是「前 80 行 + 300 ms 巡检」那两条，见 AppModel 的「可见行优先」一节。
        .onAppear { model.noteRowVisible(row.id) }
    }

    /// 待读行的占位。
    ///
    /// 只在**标题列**写「读取中…」，其余标签列留空：24 列里每列都写一遍
    /// 会让整张表变成一片灰字，反而看不出哪一行读完了。标题列是用户第一眼看的列，
    /// 一个字都不用挪就知道「这行还在读」。标题列被隐藏时退回文件名列旁的圆点提示。
    @ViewBuilder
    private func pendingCell(spec: ColumnSpec) -> some View {
        if spec.id == .title {
            Text("读取中…")
                .font(Theme.Typo.tableCellSmall)
                .foregroundStyle(Theme.Colors.placeholderText)
                .lineLimit(1)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func textCell(spec: ColumnSpec, row: FileRow) -> some View {
        Group {
            // 待读的行不给编辑：这时 `file.tags` 还不是磁盘上的真值，
            // 用户敲进去的字会在标签读回来的那一刻被覆盖掉。
            if row.tagsState.isPending && spec.id.requiresTags {
                pendingCell(spec: spec)
            } else if settings.inlineEditing && spec.isEditable {
                TextField("", text: binding(spec: spec, row: row))
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.tableCell)
                    .lineLimit(1)
            } else {
                Text(row.text(for: spec.id))
                    // 设计稿的"格式"列（= 这里的派生列）比正文小一号。
                    .font(spec.isEditable ? Theme.Typo.tableCell : Theme.Typo.tableCellSmall)
                    .lineLimit(1)
                    // 目录列砍头保尾：路径的结尾（文件夹名）才是有信息量的一段。
                    .truncationMode(spec.id == .directory ? .head : .tail)
                    // 派生列（技术参数、目录、修改时间）弱化成次要色，让可编辑的标签列跳出来。
                    .foregroundStyle(spec.isEditable ? Color.primary : Color.secondary)
            }
        }
    }

    /// 数字列：右对齐 + 等宽数字，个位数能对齐才谈得上「一眼扫」。
    private func numberCell(spec: ColumnSpec, row: FileRow) -> some View {
        Group {
            if row.tagsState.isPending && spec.id.requiresTags {
                pendingCell(spec: spec)
            } else if settings.inlineEditing && spec.isEditable {
                TextField("", text: binding(spec: spec, row: row))
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.tableCellMono)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            } else {
                Text(row.text(for: spec.id))
                    .font(Theme.Typo.tableCellMono)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .foregroundStyle(spec.isEditable ? Color.primary : Color.secondary)
            }
        }
    }

    /// 「歌词」「封面」两列：✓ / — 居中，比一堆图标干净。
    @ViewBuilder
    private func checkCell(spec: ColumnSpec, row: FileRow) -> some View {
        if !row.tagsState.isLoaded {
            // 标签还没读出来时「—」会被读成「确认没有」，用居中的点表示「还不知道」。
            Text("·")
                .font(Theme.Typo.tableCell)
                .foregroundStyle(Theme.Colors.placeholderText)
                .help(row.tagsState.isPending ? "标签待读取" : "标签读取失败")
        } else {
            let on = spec.id == .hasLyrics
                ? (row.draft.lyrics?.isEmpty == false)
                : (row.artworkCount > 0)
            Text(on ? "✓" : "—")
                .font(Theme.Typo.tableCell)
                .foregroundStyle(on ? Color.primary : Theme.Colors.placeholderText)
                .help(helpText(spec: spec, row: row, on: on))
        }
    }

    private func helpText(spec: ColumnSpec, row: FileRow, on: Bool) -> String {
        if spec.id == .hasLyrics { return on ? "有歌词" : "无歌词" }
        return row.artworkCount > 1 ? "\(row.artworkCount) 张封面" : (on ? "有封面" : "无封面")
    }

    /// 行状态。一次只显示一个圆点，按紧急程度取第一个命中的。
    private func status(for row: FileRow) -> (color: Color, help: String)? {
        if let error = row.lastError { return (Theme.Colors.failed, error) }
        if case .failed(let why) = row.tagsState { return (Theme.Colors.failed, "读取标签失败：\(why)") }
        // 待读的行用最弱的一档灰点：它不是错误，只是还没轮到。
        if row.tagsState.isPending { return (Theme.Colors.placeholderText, "标签待读取") }
        if row.isDirty { return (Theme.Colors.dirty, "有未保存的改动") }
        if row.file.isReadOnly { return (Theme.Colors.readOnly, "只读文件") }
        if !row.file.diagnostics.isEmpty {
            return (Theme.Colors.warning, row.file.diagnostics.joined(separator: "\n"))
        }
        return nil
    }

    private func binding(spec: ColumnSpec, row: FileRow) -> Binding<String> {
        Binding(
            get: { model.row(id: row.id)?.editableText(for: spec.id) ?? "" },
            set: { model.applyInline(spec.id, $0, to: row.id) }
        )
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextMenu(for ids: Set<URL>) -> some View {
        if model.pendingTagCount > 0 {
            // 两段式导入的续读口：取消过第二阶段、或移动盘上没自动读的，从这里接上。
            Button(model.isReadingTags
                   ? "正在读取标签（\(model.loadedTagCount)/\(model.listedCount)）…"
                   : "继续读取标签（还有 \(model.pendingTagCount) 首）") {
                model.resumeTagRead()
            }
            .disabled(model.isReadingTags)
            Divider()
        }
        // 快捷筛选的第二个入口。**与顶栏漏斗是同一套状态**（`model.quickFilters`），
        // 不是右键菜单自己另做一份 —— 两处能对不上的话，状态栏那枚胶囊就说不清是谁设的。
        if model.quickFilters == [.noArtwork] {
            Button("显示全部（清除筛选）") { model.clearQuickFilters() }
        } else {
            Button("仅显示无封面的") { model.showOnlyMissingArtwork() }
                .help("只留下确认没有内嵌封面的文件。标签还没读出来的行不算 —— 它们的封面是未知的。")
        }
        if !model.quickFilters.isEmpty && model.quickFilters != [.noArtwork] {
            Button("清除筛选（\(model.quickFilterSummary)）") { model.clearQuickFilters() }
        }
        Divider()
        if ids.isEmpty {
            Button("添加文件…") { model.presentAddFiles() }
            Button("添加目录…") { model.presentAddDirectory() }
        } else {
            // 写盘 / 读盘 / 动列表的项在批处理、导入、补读进行中一律灰（BO#6）：
            // 否则右键就能在写入批还在跑时再起一批，两批原地写同一个文件。
            // 「保存标签」与菜单 ⌘S 同一条件 `canSave`（不忙 且 有未保存改动）。
            Button("保存标签") { model.requestSave() }
                .disabled(!model.canSave)
            Button("清除标签") { model.requestClearTags() }
                .disabled(model.isBusy)
            Button("撤消标签保存") { model.requestUndo() }
                .disabled(model.isBusy)
            Divider()
            Button("提取封面") { model.requestExtractCovers() }
                .disabled(model.isBusy)
            Button("在访达中显示") { model.revealInFinder() }
            Button("刷新") { model.refreshSelected() }
                .disabled(model.isBusy)
            Divider()
            Button("还原未保存的改动") { model.revertSelected() }
                .disabled(model.isBusy)
            // 选中行里有未保存的改动先问「保存 / 放弃 / 取消」（BO#11）。
            Button("从列表中删除项", role: .destructive) { model.requestRemoveSelectedItems() }
                .disabled(model.isBusy)
        }
    }

    // MARK: 空态与拖拽

    @ViewBuilder
    private var emptyState: some View {
        if model.displayRows.isEmpty {
            ContentUnavailableView {
                Label(model.totalCount == 0 ? "还没有文件" : "没有匹配的文件",
                      systemImage: model.totalCount == 0 ? "music.note.list" : "line.3.horizontal.decrease.circle")
            } description: {
                Text(model.totalCount == 0
                     ? "把音频文件或文件夹拖到这里，或用「文件 › 添加文件 / 添加目录」。"
                     : (model.quickFilters.isEmpty
                        ? "调整上方的过滤条件试试。"
                        // 筛选把整张表挡空时必须点名是谁挡的，否则用户会以为文件丢了。
                        : "当前筛选「\(model.quickFilterSummary)」没有匹配的文件（共 \(model.totalCount) 个）。"))
                .padding(.top, Theme.Spacing.xs)
            } actions: {
                if model.totalCount == 0 {
                    HStack(spacing: Theme.Spacing.s) {
                        Button("添加文件…") { model.presentAddFiles() }
                        Button("添加目录…") { model.presentAddDirectory() }
                    }
                    .padding(.top, Theme.Spacing.s)
                } else if !model.quickFilters.isEmpty {
                    Button("清除筛选") { model.clearQuickFilters() }
                        .padding(.top, Theme.Spacing.s)
                }
            }
            // 空态里有按钮时才接事件；纯文案的那一档保持透传，
            // 免得盖住底下的表格右键菜单与拖入区。
            .allowsHitTesting(model.totalCount == 0 || !model.quickFilters.isEmpty)
            .background(.background)
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Theme.Colors.dropTarget, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                .background(
                    Theme.Colors.dropTargetFill
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                )
                .padding(Theme.Spacing.xs)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 封面缩略图

/// 文件名列前置的小封面。
///
/// 命中缓存时同步取出直接画，滚回来不闪；没命中才起异步任务读盘解码。
/// `artworkCount == 0` 的行一次盘都不读。
private struct ArtworkThumbnail: View {

    let row: FileRow

    /// 异步取回的缩略图，**连同它属于哪个键一起存**。
    /// 单元格被复用给别的行时键就对不上，立刻不认这张图，不会闪一下上一行的封面。
    @State private var loaded: (key: String, image: NSImage)?

    private var key: String { ThumbnailCache.key(for: row) }

    /// 这里必须真的**读** `loaded`，SwiftUI 才会把它登记成 body 的依赖。
    /// （踩过的坑：上一版只在异步完成后 `revision += 1`，而 body 从不读 revision，
    ///  于是缓存明明已经有图，视图却从不重绘，永远停在占位符上。）
    private var image: NSImage? {
        guard row.artworkCount > 0 else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return ThumbnailCache.shared.cached(key)
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholder()
            }
        }
        .frame(width: Theme.Size.tableThumb, height: Theme.Size.tableThumb)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                .strokeBorder(Theme.Colors.artworkStroke)
        )
        // 键变了就重来；行滚出视口时 SwiftUI 自动取消这个 task。
        .task(id: key) {
            guard row.artworkCount > 0 else { return }
            let wanted = key
            if let hit = ThumbnailCache.shared.cached(wanted) {
                loaded = (wanted, hit)
                return
            }
            let image = await ThumbnailCache.shared.image(key: wanted, url: row.file.url)
            guard !Task.isCancelled, let image else { return }
            loaded = (wanted, image)
        }
    }
}

/// 后台解码队列。磁盘 IO 不是并发越多越快，2 条足够喂满一屏，
/// 也避免用户飞速滚动时甩出几百个线程。
private let thumbnailQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 2
    q.qualityOfService = .userInitiated
    return q
}()

/// 表格缩略图缓存。
///
/// 三件事保证几千行滚动不卡：
/// 1. 渲染路径上**只做一次 NSCache 查表**，绝不解码；
/// 2. 键是「路径 + 封面张数 + 修改时间 + 文件大小」—— 文件被重写过键就变，缩略图自动作废；
/// 3. 同一个键的在途请求合并，来回滚动不会重复读盘；确认没有封面的键也记下来，不再回头问磁盘。
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    /// 22pt 的位置按 2x 备图，Retina 上不糊。
    private static let pixelSize: CGFloat = 44

    private let cache = NSCache<NSString, NSImage>()
    private var knownEmpty = Set<String>()
    private var inFlight: [String: Task<Void, Never>] = [:]

    private init() { cache.countLimit = 3000 }

    static func key(for row: FileRow) -> String {
        let stamp = row.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(row.file.url.path)|\(row.artworkCount)|\(Int(stamp))|\(row.fileSize)"
    }

    /// 渲染路径专用：只查表，永不读盘。
    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// 取缩略图。命中缓存立刻返回；未命中就读盘解码，同键的在途请求会合并成一个。
    func image(key: String, url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if knownEmpty.contains(key) { return nil }
        if let running = inFlight[key] {
            await running.value
            return cache.object(forKey: key as NSString)
        }
        let task = Task<Void, Never> { [weak self] in
            let image = await decodeThumbnail(url: url, maxPixel: Self.pixelSize)
            guard let self else { return }
            if let image {
                self.cache.setObject(image, forKey: key as NSString)
            } else {
                self.knownEmpty.insert(key)
            }
            self.inFlight[key] = nil
        }
        inFlight[key] = task
        await task.value
        return cache.object(forKey: key as NSString)
    }
}

/// 读盘 + 缩放，全程在后台队列上。用 ImageIO 直接出缩略图，不把整张大图解进内存。
private func decodeThumbnail(url: URL, maxPixel: CGFloat) async -> NSImage? {
    await withCheckedContinuation { continuation in
        thumbnailQueue.addOperation {
            guard let data = (try? TagService.readArtworks(url))?.first?.data,
                  let source = CGImageSourceCreateWithData(
                      data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary)
            else {
                continuation.resume(returning: nil)
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                continuation.resume(returning: nil)
                return
            }
            // 按 2x 声明尺寸，SwiftUI 才不会把 44px 的位图当成 44pt 画糊。
            let size = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
            continuation.resume(returning: NSImage(cgImage: cg, size: size))
        }
    }
}

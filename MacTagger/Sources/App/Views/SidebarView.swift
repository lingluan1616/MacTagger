//
//  SidebarView.swift
//  MacTagger — 左栏：工作目录（原版「改变工作目录」的常驻化）
//
//  质感对齐 Apple Music (Mac) 的 source list：分组标题、一行一目录、
//  右侧文件数胶囊，选中态完全交给系统。
//
//  尺寸逐值抄自设计稿 build_directions.py 的 `sbrow()` / `sidebar`：
//  侧栏宽 206、内边距 10、行高 30、圆角 7、行内 padding 0 8、gap 8、字号 13、
//  分组标题 11/600 次要色、文件数胶囊 11px + padding 1 7 + 等宽数字。
//  设计稿一行只有「图标 + 目录名 + 文件数」，父目录路径改由 tooltip / 右键菜单承载。
//

import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directories: DirectoryStore
    @Binding var showManageDirs: Bool

    /// 刚刚由「选中项变化」导入过的目录 + 时刻。
    ///
    /// macOS 的 `List` 在 **mouseDown** 就改选中（走 `selectionBinding` 的 setter），
    /// 而下面那条 `TapGesture` 要到 **mouseUp** 才响应。不去重的话，
    /// 「点另一个目录」这一下会把同一个目录连着导入两遍。
    /// 记一笔时间戳，让紧随其后的那次 Tap 认出「这一下已经被 setter 处理过了」。
    @State private var handledBySelection: (url: URL, at: Date)?

    /// setter（mouseDown）到 Tap（mouseUp）之间允许的最大间隔。
    /// 超出这个窗口的 Tap 一律当成「点已选中的行」，照常重新载入。
    private static let selectionEchoWindow: TimeInterval = 1.0

    /// 侧栏行高实测：`.sidebar` 列表在系统默认的 medium 行尺寸下有 40pt 的下限，
    /// 内容给 22 或 30 量到的都是 40（隔离小程序里四个变体逐一试过）。
    /// 只有把 `sidebarRowSize` 压到 `.small`，行高才跟着内容走 —— 于是内容直接给设计稿的 30。

    var body: some View {
        List(selection: selectionBinding) {
            if !directories.directories.isEmpty {
                Section {
                    ForEach(directories.directories, id: \.self) { url in
                        directoryRow(url).tag(url)
                    }
                } header: {
                    Text("工作目录")
                        .font(Theme.Typo.sectionHeader)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.bottom, Theme.Spacing.xs2)
                }
            }
        }
        .listStyle(.sidebar)
        // 见上：medium 行尺寸够不到设计稿的 30，必须压到 small。
        .environment(\.sidebarRowSize, .small)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // 侧栏宽度只在一处定义：ContentView 那句 `navigationSplitViewColumnWidth(min:ideal:max:)`。
        // 这里不再重复 `.frame(minWidth:idealWidth:)`，免得两处打架。
    }

    // MARK: 选中即切换工作目录

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { directories.current },
            set: { url in
                guard let url else { return }
                handledBySelection = (url, Date())
                load(url)
            })
    }

    /// 把某个目录载入成当前列表。切换、右键「重新载入」、点已选中行三条路共用。
    ///
    /// 交给 `AppModel.switchDirectory(to:)`（BO#7 / #11）：有未保存的改动先问「保存 / 放弃 / 取消」，
    /// 写入批在跑时拒绝并说明，目录暂时不可用（卷没插）时列表不动。
    /// `directories.current` 由它在真正切过去时才改；取消 / 被拒时它会让本列表的选中态退回原目录。
    private func load(_ url: URL) {
        model.switchDirectory(to: url)
    }

    /// 点**已经选中**的那一行 = 重新载入。
    ///
    /// `List(selection:)` 的 setter 只在选中项**变化**时才调 —— 目录是持久化的，
    /// 第二次启动时那一行本来就是选中态，于是点它没有任何反应。这条路径给它一个自救口。
    private func reloadIfAlreadyCurrent(_ url: URL) {
        guard directories.current == url else { return }   // 这是一次切换，交给 setter
        if let h = handledBySelection,
           h.url == url,
           Date().timeIntervalSince(h.at) < Self.selectionEchoWindow {
            handledBySelection = nil                        // 就是 setter 那一下，别导两遍
            return
        }
        load(url)
    }

    // MARK: 一行目录

    private func directoryRow(_ url: URL) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: directories.current == url ? "folder.fill" : "folder")
                .font(Theme.Typo.sidebarRow)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(Theme.Typo.sidebarRow)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 侧栏最窄 180 pt，稍长的目录名就只剩头尾；全路径挂 tooltip。
                .help(url.path)
            if let n = counts[url.standardizedFileURL.path], n > 0 {
                // 设计稿的文件数胶囊比状态栏窄 1px（padding 1 7）。
                Chip(text: "\(n)", horizontalPadding: 7)
            }
        }
        .frame(height: Theme.Size.sidebarRowHeight)
        // 设计稿 sbrow：行盒内 padding 0 8。
        // 行盒左右各 10 的外沿是 `.sidebar` 列表自带的（AX 实测 cell 比 outline 各窄 10，
        // 正好等于设计稿的侧栏 padding 10），所以 listRowInsets 只用来清掉上下内边距，
        // 左右给 0 —— 早先给 10 会和系统那 10 叠成 20，图标就被推远了 8pt。
        .padding(.horizontal, Theme.Spacing.s)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        // simultaneous：不抢 List 的选中，只在「点的就是当前目录」时补一次载入。
        .simultaneousGesture(TapGesture().onEnded { reloadIfAlreadyCurrent(url) })
        .help(url.path)
        .contextMenu {
            // 当前目录上是「重新载入」，别的行上这一下本来就等于切过去，叫回原名。
            Button(directories.current == url ? "重新载入" : "设为当前工作目录") { load(url) }
            Button("添加到列表（不清空）") { model.importURLs([url]) }
            Divider()
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("移出目录列表", role: .destructive) { directories.remove([url]) }
        }
    }

    /// 每个目录当前列表里有多少个文件。一次遍历算完，避免每行各扫一遍。
    private var counts: [String: Int] {
        let dirs = directories.directories.map { $0.standardizedFileURL.path }
        guard !dirs.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for row in model.allRows {
            let parent = row.file.url.deletingLastPathComponent().standardizedFileURL.path
            for dir in dirs where parent == dir || parent.hasPrefix(dir + "/") {
                result[dir, default: 0] += 1
            }
        }
        return result
    }

    // MARK: 空态

    @ViewBuilder
    private var emptyState: some View {
        if directories.directories.isEmpty {
            EmptyStateView(systemImage: "folder.badge.plus",
                           title: "还没有工作目录",
                           message: "添加一个目录，它会一直留在这里") {
                Button("添加目录…") { model.presentAddDirectory() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.xs2) {
                Button {
                    model.presentAddDirectory()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .help("添加工作目录")

                Button {
                    showManageDirs = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .help("管理工作目录")

                Spacer()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // 设计稿：侧栏内边距 10 + 底部那一行自己的 padding 0 4。
            .padding(.horizontal, Theme.Size.sidebarPadding + Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.s)
        }
    }
}

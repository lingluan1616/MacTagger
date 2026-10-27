//
//  ColumnCustomizationSheet.swift
//  MacTagger — 自定义显示列（原版 FormCustColumns）
//
//  这里**只管勾选谁显示**。顺序和列宽已经交给表头原生交互：
//  拖表头重排、拖分隔线改宽、右键表头快速勾选 —— 所以老的「上移 / 下移」按钮删掉了，
//  留着只会和拖拽形成两套顺序真相源。
//

import SwiftUI

struct CustomColumnsSheet: View {

    @EnvironmentObject private var columns: ColumnStore
    @Environment(\.dismiss) private var dismiss

    /// 按用途分组，24 个复选框平铺出来没人找得到自己要的那一个。
    private static let groups: [(title: String, ids: [ColumnID])] = [
        ("标签",     [.title, .artist, .album, .albumArtist, .year, .track, .disc,
                     .genre, .comment, .composer, .lyricist]),
        ("内容",     [.hasLyrics, .hasPicture]),
        ("技术参数", [.duration, .bitrate, .sampleRate, .channels, .bitDepth, .tagFormat, .encoding]),
        ("文件",     [.filename, .fileSize, .directory, .modifiedTime])
    ]

    private var visibleCount: Int { columns.visible.count }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(systemImage: "tablecells",
                          title: "自定义显示列",
                          subtitle: "勾选要显示的列。顺序和宽度直接拖动表头调整，右键表头也能快速显示 / 隐藏。") {
                Chip(text: "\(visibleCount) / \(ColumnCatalog.all.count)", tinted: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(Self.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            FieldGroupLabel(title: group.title)
                            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                                GridItem(.flexible(), alignment: .leading)],
                                      alignment: .leading,
                                      spacing: Theme.Spacing.s) {
                                ForEach(group.ids, id: \.self) { id in
                                    columnToggle(id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.l)
            }

            SheetButtonBar {
                // 不置灰：表格每次布局都会把实际列宽写回 customization，
                // "是否等于出厂值"实际上永远不成立，置灰只会变成一个永远点不亮的按钮。
                Button("重置为默认") { columns.reset() }
                    .help("顺序、宽度、显示隐藏一起回到出厂值")
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Theme.Size.sheetNarrow, height: 460)
    }

    private func columnToggle(_ id: ColumnID) -> some View {
        let spec = ColumnCatalog.spec(id)
        return Toggle(spec.title, isOn: Binding(
            get: { columns.isVisible(id) },
            set: { columns.setVisible(id, $0) }
        ))
        .toggleStyle(.checkbox)
        // 文件名列是表格的锚点，藏了就只剩一片空白网格。
        .disabled(id == .filename)
        .help(id == .filename ? "文件名列不可隐藏" : spec.title)
    }
}

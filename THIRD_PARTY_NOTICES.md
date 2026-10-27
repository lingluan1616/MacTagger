# 第三方组件声明 / Third-Party Notices

MacTagger 本身以 MIT 许可证发布（见 [LICENSE](LICENSE)）。构建出的 `MacTagger.app`
会以**动态库**形式嵌入下列第三方组件，它们各自保留原有许可证。许可证原文见
[`third_party/licenses/`](third_party/licenses/)。本仓库不包含这些库的源码，构建时从
Homebrew 安装的版本获取（`brew install taglib opencc`，marisa 随 opencc 自动安装）。

| 组件 | 版本（开发时） | 许可证 | 在 App 中的形态 | 原文 |
|---|---|---|---|---|
| [TagLib](https://taglib.org/) | 2.3.1 | LGPL-2.1 **或** MPL-1.1（双许可，任选其一） | `Contents/Frameworks/libtag.2.dylib`（动态链接） | [taglib-COPYING.LGPL](third_party/licenses/taglib-COPYING.LGPL)、[taglib-COPYING.MPL](third_party/licenses/taglib-COPYING.MPL) |
| [OpenCC](https://github.com/BYVoid/OpenCC) | 1.4.2 | Apache-2.0 | `Contents/Frameworks/libopencc.*.dylib` + `Contents/Resources/opencc/`（转换配置 `*.json` 与词典 `*.ocd2`） | [opencc-LICENSE](third_party/licenses/opencc-LICENSE) |
| [marisa-trie](https://github.com/s-yata/marisa-trie) | 0.3.1 | BSD-2-Clause **或** LGPL-2.1-or-later（双许可，任选其一） | `Contents/Frameworks/libmarisa.*.dylib`（OpenCC 的依赖，动态链接） | [marisa-COPYING.md](third_party/licenses/marisa-COPYING.md) |

系统自带的 `libz`、`libsqlite3`、`libc++` 由 macOS 提供，不随 App 分发。

## TagLib（LGPL-2.1 / MPL-1.1）

- MacTagger 通过 Objective-C++ 桥接层（`MacTagger/Sources/TagLibBridge/`）调用 TagLib 的公开 API，
  **未修改 TagLib 源码**，并且始终**动态链接**。
- 依 LGPL-2.1 第 6 条的精神，你可以用自己编译的、ABI 兼容的 TagLib 替换 App 内的
  `MacTagger.app/Contents/Frameworks/libtag.2.dylib`：
  1. 编译或安装你自己的 TagLib 2.x（例如 `brew install taglib` 后取 `$(brew --prefix taglib)/lib/libtag.2.dylib`）；
  2. 覆盖 `MacTagger.app/Contents/Frameworks/libtag.2.dylib`，并确认其 install name 为 `@rpath/libtag.2.dylib`
     （`install_name_tool -id @rpath/libtag.2.dylib libtag.2.dylib`）；
  3. 由于替换会破坏原签名，重新做 ad-hoc 签名：`codesign --force --deep --sign - MacTagger.app`。
- 也可以直接从本仓库源码重新构建整个 App（见 README「从源码构建」），嵌入步骤由
  `MacTagger/Scripts/embed-dylibs.sh` 完成。
- TagLib 源码：<https://github.com/taglib/taglib>

## OpenCC（Apache-2.0）及其数据

- 简繁转换使用 OpenCC 的库与其随附的转换配置、词典数据（`share/opencc/*.json`、`*.ocd2`），
  构建时原样拷入 `Contents/Resources/opencc/`，**未作修改**。
- 这些数据文件属于 OpenCC 项目，同样以 Apache-2.0 发布。
- OpenCC 源码：<https://github.com/BYVoid/OpenCC>

## marisa-trie（BSD-2-Clause / LGPL-2.1-or-later）

- OpenCC 用它加载 `.ocd2` 词典；MacTagger 不直接调用。
- 选择 BSD-2-Clause 条款再分发其二进制；版权声明见原文。
- marisa-trie 源码：<https://github.com/s-yata/marisa-trie>

## 测试样本

`testdata/` 下的音频全部由 `tools/` 里的脚本用 ffmpeg 等工具**自行合成**（正弦波，2 秒），
不含任何受版权保护的录音。

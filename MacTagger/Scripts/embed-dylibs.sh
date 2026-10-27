#!/bin/bash
#
#  embed-dylibs.sh
#  MacTagger — 把 Homebrew 的 TagLib / OpenCC（含 marisa）动态库与 OpenCC 转换数据
#              嵌进 MacTagger.app，让成品 App 在没装 Homebrew 的机器上也能跑。
#
#  由 project.yml 的 postBuildScripts 调用：编译/链接之后、Xcode 自动签名之前
#  （Xcode 的 CodeSign 永远是 target 的最后一步，排在所有构建阶段之后）。
#
#  做六件事：
#    1. 把 libtag / libopencc 及其在 Homebrew 前缀下的**全部传递依赖**（BFS 闭包，
#       目前是 libmarisa）拷进 Contents/Frameworks；
#    2. 把各库自身的 LC_ID_DYLIB 改成 @rpath/<名字>，库与库之间的绝对路径引用改成 @rpath；
#    3. 把 App 自己的每一个 Mach-O（主可执行文件、Contents/MacOS 下的
#       MacTagger.debug.dylib / __preview.dylib、Contents/Frameworks 下非本脚本嵌入的）
#       对这些库的引用改成 @rpath，并删掉它们指向 Homebrew 的 LC_RPATH；
#    4. 把 <prefix>/share/opencc 的 *.json / *.ocd2 拷进 Contents/Resources/opencc；
#    5. 给每个改过的嵌套 Mach-O 重新 ad-hoc 签名（arm64 上签名失效 = dyld 直接拒载）；
#    6. 把仓库根 third_party/licenses/ 的许可证原文与 THIRD_PARTY_NOTICES.md 拷进
#       Contents/Resources/Licenses（LGPL / MPL / Apache / BSD 都要求随二进制附带原文）。
#
#  为什么第 3 步要遍历而不是只改主可执行文件：
#      Xcode 16 起 Debug 构建默认开 ENABLE_DEBUG_DYLIB，Contents/MacOS/MacTagger 只是个
#      几十 KB 的壳，真正链了 -ltag -lopencc 的是同目录的 MacTagger.debug.dylib。
#      只改壳的话 otool 看着干净，一跑起来还是从 /opt/homebrew 加载。
#
#  设计约束：
#    * **保持动态链接**。TagLib 与 OpenCC 都是 LGPL，静态链接会把整个 App 拖进 LGPL 的
#      替换义务；动态链接 + 用户可自行替换 Contents/Frameworks 里的 dylib 才是合规姿势。
#    * **幂等**。每次构建都从 Homebrew 重新拷原始文件再改，不在改过的文件上二次改写；
#      已删过的 LC_RPATH / 已改成 @rpath 的引用第二次跑时自然不匹配，直接跳过。
#    * **失败即报错**。set -euo pipefail；找不到 Homebrew 库、或出现没嵌进来的 Homebrew
#      依赖时直接中断构建，绝不产出「构建成功、换台机器就崩」的包。
#    * **不写死版本号**。libtag.2.dylib / libopencc.1.4.dylib 里的数字取自各库自己的
#      LC_ID_DYLIB（otool -D），brew 升级大版本后脚本不用改。
#

set -euo pipefail

log() { echo "[embed-dylibs] $*"; }
die() { echo "error: [embed-dylibs] $*" >&2; exit 1; }

# ---------------------------------------------------------------- Xcode 环境

: "${TARGET_BUILD_DIR:?必须由 Xcode 构建阶段调用（缺 TARGET_BUILD_DIR）}"
: "${FRAMEWORKS_FOLDER_PATH:?必须由 Xcode 构建阶段调用（缺 FRAMEWORKS_FOLDER_PATH）}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?必须由 Xcode 构建阶段调用（缺 UNLOCALIZED_RESOURCES_FOLDER_PATH）}"
: "${EXECUTABLE_PATH:?必须由 Xcode 构建阶段调用（缺 EXECUTABLE_PATH）}"

APP_FRAMEWORKS="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
APP_RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
APP_EXECUTABLE="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
APP_MACOS_DIR="$(dirname "$APP_EXECUTABLE")"

[ -f "$APP_EXECUTABLE" ] || die "找不到可执行文件：$APP_EXECUTABLE"

# ---------------------------------------------------------------- Homebrew 前缀

# 判定标准是「libtag.dylib 在不在」而不是「目录在不在」——/usr/local/lib 几乎每台 Mac
# 都有，光看目录会选错前缀。
detect_prefix() {
    local p
    for p in "${HOMEBREW_PREFIX:-}" /opt/homebrew /usr/local; do
        [ -n "$p" ] || continue
        [ -e "$p/lib/libtag.dylib" ] && { echo "$p"; return 0; }
    done
    if command -v brew >/dev/null 2>&1; then
        p="$(brew --prefix 2>/dev/null || true)"
        [ -n "$p" ] && [ -e "$p/lib/libtag.dylib" ] && { echo "$p"; return 0; }
    fi
    return 1
}

PREFIX="$(detect_prefix)" || die "找不到 Homebrew 的 libtag.dylib。\
编译这台机器需要装依赖：brew install taglib opencc（成品 App 不需要）。\
非默认前缀请设 HOMEBREW_PREFIX 环境变量。"
log "Homebrew 前缀：$PREFIX"

# ---------------------------------------------------------------- 工具函数

# 取一个 dylib 的 LC_ID_DYLIB（install name）。otool -D 输出两行：文件名行 + id 行。
dylib_id() {
    local out
    out="$(otool -D "$1" | tail -n 1)"
    case "$out" in
        *:) die "$1 没有 LC_ID_DYLIB（不是动态库？）" ;;
        "") die "读不出 $1 的 install name" ;;
    esac
    echo "$out"
}

# 列出一个 Mach-O 的 LC_LOAD_DYLIB 路径（跳过 otool -L 的首行文件名）。
load_dylibs() { otool -L "$1" | tail -n +2 | awk '{ print $1 }'; }

# 列出一个 Mach-O 的 LC_RPATH。
rpaths_of() {
    otool -l "$1" | awk '/^ *cmd LC_RPATH$/ { f = 1; next } f && /^ *path / { print $2; f = 0 }'
}

is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

# bash 3.2 没有关联数组，用空格分隔的字符串当集合。
EMBEDDED=" "
is_embedded() { case "$EMBEDDED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- 1. 拷贝依赖闭包

mkdir -p "$APP_FRAMEWORKS"

# 种子只写不带版本号的软链名，版本号从各库自己的 install name 里取。
SEED_LINKS="libtag.dylib libopencc.dylib"

WORK=""
for link in $SEED_LINKS; do
    [ -e "$PREFIX/lib/$link" ] || die "找不到 $PREFIX/lib/$link。请执行：brew install taglib opencc"
    WORK="$WORK $PREFIX/lib/$link"
done

COPIED=""   # 已落进 Frameworks 的 soname 列表
while [ -n "${WORK// /}" ]; do
    set -- $WORK; src="$1"; shift; WORK="$*"

    id="$(dylib_id "$src")"
    soname="$(basename "$id")"
    is_embedded "$soname" && continue
    EMBEDDED="$EMBEDDED$soname "
    COPIED="$COPIED $soname"

    # 真实文件：优先 <prefix>/lib/<soname>（软链），否则用 install name 记的绝对路径
    real=""
    for cand in "$PREFIX/lib/$soname" "$id"; do
        [ -e "$cand" ] && { real="$cand"; break; }
    done
    [ -n "$real" ] || die "解析不到 $soname 的真实文件（试过 $PREFIX/lib/$soname 与 $id）"

    dst="$APP_FRAMEWORKS/$soname"
    rm -f "$dst"
    cp -L "$real" "$dst"          # -L：跟随软链，拷进来的必须是真正的 Mach-O
    chmod u+w "$dst"
    log "拷入 $soname  ←  $real"

    # 把它在 Homebrew 前缀下的依赖压进队列（自身 id 那一条会被 is_embedded 挡掉）
    for dep in $(load_dylibs "$dst"); do
        case "$dep" in "$PREFIX"/*) WORK="$WORK $dep" ;; esac
    done
done

[ -n "${COPIED// /}" ] || die "一个库都没拷进来，构建配置有问题"

# ---------------------------------------------------------------- 2. 嵌入库自身改名

for soname in $COPIED; do
    dst="$APP_FRAMEWORKS/$soname"
    install_name_tool -id "@rpath/$soname" "$dst"
    for dep in $(load_dylibs "$dst"); do
        case "$dep" in
            "$PREFIX"/*)
                b="$(basename "$dep")"
                is_embedded "$b" || die "$soname 依赖了没被嵌入的 Homebrew 库：$dep（闭包算漏了）"
                install_name_tool -change "$dep" "@rpath/$b" "$dst"
                log "  $soname: $dep → @rpath/$b"
                ;;
        esac
    done
done

# ---------------------------------------------------------------- 3. App 自己的 Mach-O

# 改一个 Mach-O：Homebrew 引用改 @rpath、删掉 Homebrew 的 LC_RPATH、
# 保证 @executable_path/../Frameworks 在 rpath 里。
patch_macho() {
    local f="$1" dep b rp rps
    for dep in $(load_dylibs "$f"); do
        case "$dep" in
            "$PREFIX"/*)
                b="$(basename "$dep")"
                is_embedded "$b" || die "$(basename "$f") 依赖了没被嵌入的 Homebrew 库：$dep"
                install_name_tool -change "$dep" "@rpath/$b" "$f"
                log "  $(basename "$f"): $dep → @rpath/$b"
                ;;
        esac
    done
    rps="$(rpaths_of "$f")"
    for rp in $rps; do
        case "$rp" in
            "$PREFIX"/*|/opt/homebrew/*|/usr/local/*)
                install_name_tool -delete_rpath "$rp" "$f"
                log "  $(basename "$f"): 删除 LC_RPATH $rp"
                ;;
        esac
    done
    case "$rps" in
        *"@executable_path/../Frameworks"*) ;;
        *)  install_name_tool -add_rpath "@executable_path/../Frameworks" "$f"
            log "  $(basename "$f"): 补上 LC_RPATH @executable_path/../Frameworks" ;;
    esac
}

# 待改名单：Contents/MacOS 下全部 Mach-O（壳 + debug dylib + __preview.dylib）
# 加上 Contents/Frameworks 下**非本脚本嵌入**的 dylib。
APP_MACHOS=""
for f in "$APP_MACOS_DIR"/*; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    APP_MACHOS="$APP_MACHOS
$f"
done
for f in "$APP_FRAMEWORKS"/*.dylib; do
    [ -f "$f" ] || continue
    is_embedded "$(basename "$f")" && continue
    is_macho "$f" || continue
    APP_MACHOS="$APP_MACHOS
$f"
done

OLD_IFS="$IFS"; IFS=$'\n'
for f in $APP_MACHOS; do
    [ -n "$f" ] || continue
    IFS="$OLD_IFS"; patch_macho "$f"; IFS=$'\n'
done
IFS="$OLD_IFS"

# ---------------------------------------------------------------- 4. OpenCC 转换数据

OPENCC_SRC="$PREFIX/share/opencc"
OPENCC_DST="$APP_RESOURCES/opencc"

for f in t2s.json s2t.json; do
    [ -f "$OPENCC_SRC/$f" ] || die "找不到 $OPENCC_SRC/$f。请执行：brew install opencc"
done

mkdir -p "$OPENCC_DST"
# 幂等：先清掉上一轮的再整体重拷（brew 升级换了词典也能跟上）
rm -f "$OPENCC_DST"/*.json "$OPENCC_DST"/*.ocd2
cp "$OPENCC_SRC"/*.json  "$OPENCC_DST"/
cp "$OPENCC_SRC"/*.ocd2  "$OPENCC_DST"/
# 注意两点：
#   * OpenCC 解析配置里的 "file" 时以**配置文件所在目录**为基准，所以 .ocd2 必须和 .json
#     平铺在同一层，不能再套子目录；
#   * 不拷 jieba_dict/（18 MB，只有 *_jieba.json 那几个分词配置用得上），
#     MacTagger 只用 t2s.json / s2t.json。
log "OpenCC 数据：$(ls -1 "$OPENCC_DST" | wc -l | tr -d ' ') 个文件 → $OPENCC_DST"

# ---------------------------------------------------------------- 5. 重新 ad-hoc 签名

# install_name_tool 改过的 Mach-O 签名必然失效；**嵌套代码必须先签好**，
# 外层 App 才签得出一份 codesign --verify --deep --strict 能过的签名。
# 主可执行文件不在这里签 —— 它由 Xcode 的 CodeSign 阶段随整个 bundle 一起签。
SIGNED=""
for soname in $COPIED; do
    codesign --force --sign - "$APP_FRAMEWORKS/$soname"
    SIGNED="$SIGNED $soname"
done
IFS=$'\n'
for f in $APP_MACHOS; do
    IFS="$OLD_IFS"
    [ -n "$f" ] || { IFS=$'\n'; continue; }
    [ "$f" = "$APP_EXECUTABLE" ] && { IFS=$'\n'; continue; }
    codesign --force --sign - "$f"
    SIGNED="$SIGNED $(basename "$f")"
    IFS=$'\n'
done
IFS="$OLD_IFS"
log "已 ad-hoc 重签：$SIGNED"

# ---------------------------------------------------------------- 6. 第三方许可证原文

# 分发二进制时必须附带各组件许可证原文：TagLib（LGPL-2.1 / MPL-1.1）、
# OpenCC（Apache-2.0）、marisa-trie（BSD-2 / LGPL-2.1）。仓库根 = $SRCROOT/..
REPO_ROOT="$(cd "${SRCROOT:-$(dirname "$0")/..}/.." && pwd)"
LIC_SRC="$REPO_ROOT/third_party/licenses"
LIC_DST="$APP_RESOURCES/Licenses"

[ -d "$LIC_SRC" ] || die "找不到许可证目录 $LIC_SRC"
[ -f "$REPO_ROOT/THIRD_PARTY_NOTICES.md" ] || die "找不到 $REPO_ROOT/THIRD_PARTY_NOTICES.md"
LIC_FILES="$(find "$LIC_SRC" -maxdepth 1 -type f ! -name '.*')"
[ -n "$LIC_FILES" ] || die "$LIC_SRC 里没有许可证文件"

# 幂等：整目录重建，仓库里删掉的许可证文件不会残留在包里
rm -rf "$LIC_DST"
mkdir -p "$LIC_DST"
OLD_IFS="$IFS"; IFS=$'\n'
for f in $LIC_FILES; do cp "$f" "$LIC_DST/"; done
IFS="$OLD_IFS"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$LIC_DST/"
log "许可证原文：$(ls -1 "$LIC_DST" | wc -l | tr -d ' ') 个文件 → $LIC_DST"

log "完成。Frameworks=$APP_FRAMEWORKS"

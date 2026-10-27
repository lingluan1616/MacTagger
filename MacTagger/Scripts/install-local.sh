#!/bin/bash
#
#  install-local.sh
#  MacTagger — 一条命令把当前源码构建成 App 并同步到「应用程序」。
#
#  用法：
#      Scripts/install-local.sh
#
#  流程：
#      xcodegen generate
#        → xcodebuild -scheme MacTagger -configuration Debug -derivedDataPath build build
#        → 退掉正在运行的 MacTagger（先 AppleScript 优雅退出，最多等 10 s，仍在则 pkill）
#        → ditto 到 /Applications 的临时名，再原子 mv 覆盖（避免半拷贝状态）
#        → codesign --verify --deep --strict
#        → open /Applications/MacTagger.app
#
#  说明：
#    * 签名保持 **ad-hoc**（project.yml 里 CODE_SIGN_IDENTITY: "-"），不做分发签名/公证。
#    * 构建目录 build/ 是开发用的 derivedData，脚本**不删**它。
#    * ditto 会完整保留 Contents/Frameworks 里嵌入的 dylib 与它们的签名，
#      不要换成 cp -R（会丢扩展属性）。
#    * 原子 mv：先把新包拷成 /Applications/.MacTagger.app.new-<pid>，
#      旧包挪成 .MacTagger.app.old-<pid>，再把新包 mv 到正式名。
#      任何一步失败都不会留下一个「拷了一半」的 /Applications/MacTagger.app。
#

set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCHEME="MacTagger"
readonly CONFIGURATION="Debug"
readonly DERIVED_DATA="${PROJECT_DIR}/build"
readonly BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
readonly DEST_APP="/Applications/${SCHEME}.app"
readonly STAGE_APP="/Applications/.${SCHEME}.app.new-$$"
readonly BACKUP_APP="/Applications/.${SCHEME}.app.old-$$"

log()  { echo "[install-local] $*"; }
die()  { echo "error: [install-local] $*" >&2; exit 1; }

cleanup_stage() {
    # 只清理本次进程留下的临时名，绝不碰正式的 /Applications/MacTagger.app
    [[ -e "${STAGE_APP}" ]] && rm -rf "${STAGE_APP}"
    return 0
}
trap cleanup_stage EXIT

cd "${PROJECT_DIR}"

# ---------------------------------------------------------------- 1. 生成工程
log "xcodegen generate（${PROJECT_DIR}）"
xcodegen generate

# ---------------------------------------------------------------- 2. 构建
log "xcodebuild -scheme ${SCHEME} -configuration ${CONFIGURATION} -derivedDataPath build build"
xcodebuild -scheme "${SCHEME}" \
           -configuration "${CONFIGURATION}" \
           -derivedDataPath build \
           build

[[ -d "${BUILT_APP}" ]] || die "构建产物不存在：${BUILT_APP}"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                 "${BUILT_APP}/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
               "${BUILT_APP}/Contents/Info.plist" 2>/dev/null || echo '?')"
log "构建产物：${BUILT_APP}  版本 ${BUILT_VERSION} (${BUILT_BUILD})"

# ---------------------------------------------------------------- 3. 退掉运行中的实例
# 无论跑的是 build/ 里那份还是 /Applications 里那份，都得先退——
# 同一个 bundle id 同时跑两份会打架，而且覆盖运行中的包会留下坏状态。
if pgrep -x "${SCHEME}" >/dev/null 2>&1; then
    log "检测到 ${SCHEME} 正在运行，请求优雅退出……"
    osascript -e "tell application \"${SCHEME}\" to quit" >/dev/null 2>&1 || true

    for _ in $(seq 1 10); do
        pgrep -x "${SCHEME}" >/dev/null 2>&1 || break
        sleep 1
    done

    if pgrep -x "${SCHEME}" >/dev/null 2>&1; then
        log "10 s 后仍在运行，pkill -x ${SCHEME}"
        pkill -x "${SCHEME}" || true
        sleep 1
    fi

    if pgrep -x "${SCHEME}" >/dev/null 2>&1; then
        die "无法结束正在运行的 ${SCHEME}（pid: $(pgrep -x "${SCHEME}" | tr '\n' ' '))"
    fi
    log "${SCHEME} 已退出"
else
    log "${SCHEME} 未在运行"
fi

# ---------------------------------------------------------------- 4. 原子安装
log "ditto → ${STAGE_APP}"
rm -rf "${STAGE_APP}"
ditto "${BUILT_APP}" "${STAGE_APP}"

if [[ -e "${DEST_APP}" ]]; then
    log "挪开旧包 → ${BACKUP_APP}"
    rm -rf "${BACKUP_APP}"
    mv "${DEST_APP}" "${BACKUP_APP}"
fi

log "原子 mv → ${DEST_APP}"
if ! mv "${STAGE_APP}" "${DEST_APP}"; then
    # 新包没挪成功就把旧包放回去，绝不留下「应用程序里没有 MacTagger」的状态
    if [[ -e "${BACKUP_APP}" ]]; then
        log "mv 失败，回滚旧包"
        mv "${BACKUP_APP}" "${DEST_APP}"
    fi
    die "mv 到 ${DEST_APP} 失败"
fi

[[ -e "${BACKUP_APP}" ]] && rm -rf "${BACKUP_APP}"

# ---------------------------------------------------------------- 5. 校验签名
log "codesign --verify --deep --strict ${DEST_APP}"
codesign --verify --deep --strict --verbose=2 "${DEST_APP}"

# ---------------------------------------------------------------- 6. 启动
log "open ${DEST_APP}"
open "${DEST_APP}"

DEST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "${DEST_APP}/Contents/Info.plist")"
DEST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
              "${DEST_APP}/Contents/Info.plist")"

echo
echo "───────────────────────────────────────────────"
echo "  MacTagger ${DEST_VERSION} (build ${DEST_BUILD})"
echo "  已安装：${DEST_APP}"
echo "  源产物：${BUILT_APP}"
echo "───────────────────────────────────────────────"

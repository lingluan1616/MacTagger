#!/bin/bash
#
#  make-dmg.sh
#  MacTagger — 从已安装的 App 打一个可拖拽安装的 dmg。
#
#  用法：
#      Scripts/make-dmg.sh                       # 默认取 /Applications/MacTagger.app
#      Scripts/make-dmg.sh /path/to/MacTagger.app
#
#  产物：
#      Dist/MacTagger-<CFBundleShortVersionString>.dmg（UDZO 压缩只读镜像）
#
#  流程：
#      临时 staging 目录放 App + 指向 /Applications 的符号链接
#        → hdiutil create -format UDZO
#        → hdiutil verify（校验镜像 checksum）
#        → hdiutil attach -nobrowse -readonly，确认挂载内容含 MacTagger.app
#          与 Applications 链接，再 detach
#
#  说明：
#    * 签名沿用 App 自带的 **ad-hoc** 签名，本脚本不做分发签名，也不做公证。
#      别人拿到这个 dmg 首次打开需要「右键 → 打开」放行。
#    * ditto 拷 App（保留扩展属性与嵌入 dylib 的签名），不要换成 cp -R。
#

set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_PATH="${1:-/Applications/MacTagger.app}"
readonly VOLNAME="MacTagger"
readonly DIST_DIR="${PROJECT_DIR}/Dist"

log() { echo "[make-dmg] $*"; }
die() { echo "error: [make-dmg] $*" >&2; exit 1; }

[[ -d "${APP_PATH}" ]] || die "App 不存在：${APP_PATH}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
           "${APP_PATH}/Contents/Info.plist")" \
    || die "读不到 ${APP_PATH}/Contents/Info.plist 的 CFBundleShortVersionString"
[[ -n "${VERSION}" ]] || die "CFBundleShortVersionString 为空"

readonly DMG_PATH="${DIST_DIR}/MacTagger-${VERSION}.dmg"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mactagger-dmg-XXXXXX")"
MOUNT_POINT=""

cleanup() {
    # 挂了就先卸，否则 staging 目录删不掉、下次还会撞名
    if [[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" -quiet >/dev/null 2>&1 \
            || hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 \
            || true
    fi
    [[ -n "${STAGING}" && -d "${STAGING}" ]] && rm -rf "${STAGING}"
    return 0
}
trap cleanup EXIT

log "App：${APP_PATH}（版本 ${VERSION}）"

# ---------------------------------------------------------------- 1. staging
log "staging：${STAGING}"
ditto "${APP_PATH}" "${STAGING}/MacTagger.app"
ln -s /Applications "${STAGING}/Applications"

# ---------------------------------------------------------------- 2. 生成镜像
mkdir -p "${DIST_DIR}"
log "hdiutil create → ${DMG_PATH}"
hdiutil create -volname "${VOLNAME}" \
               -srcfolder "${STAGING}" \
               -ov \
               -format UDZO \
               "${DMG_PATH}"

[[ -f "${DMG_PATH}" ]] || die "dmg 没生成：${DMG_PATH}"

# ---------------------------------------------------------------- 3. verify
echo
log "hdiutil verify"
hdiutil verify "${DMG_PATH}"

# ---------------------------------------------------------------- 4. 挂载自检
echo
log "hdiutil attach -nobrowse -readonly（挂载自检）"
MOUNT_POINT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly \
               | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]] || die "挂载失败"
log "已挂载：${MOUNT_POINT}"

ls -la "${MOUNT_POINT}"

[[ -d "${MOUNT_POINT}/MacTagger.app" ]] \
    || die "镜像里没有 MacTagger.app"
[[ -L "${MOUNT_POINT}/Applications" ]] \
    || die "镜像里没有 Applications 符号链接"
[[ "$(readlink "${MOUNT_POINT}/Applications")" == "/Applications" ]] \
    || die "Applications 链接没指向 /Applications"

MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                   "${MOUNT_POINT}/MacTagger.app/Contents/Info.plist")"
[[ "${MOUNTED_VERSION}" == "${VERSION}" ]] \
    || die "镜像里的版本 ${MOUNTED_VERSION} 与预期 ${VERSION} 不符"
log "镜像内容校验通过：MacTagger.app ${MOUNTED_VERSION} + Applications → /Applications"

log "hdiutil detach ${MOUNT_POINT}"
hdiutil detach "${MOUNT_POINT}"
MOUNT_POINT=""

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"

echo
echo "───────────────────────────────────────────────"
echo "  MacTagger ${VERSION}"
echo "  dmg：${DMG_PATH}"
echo "  大小：${DMG_SIZE}"
echo "  签名：ad-hoc（未做分发签名/公证，首次打开需右键 → 打开）"
echo "───────────────────────────────────────────────"

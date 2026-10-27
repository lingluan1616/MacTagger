#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# 核对畸形夹具目录是否与基线一致 —— 退出码非零即「夹具已被污染」。
#
#   用法：tools/verify_fixtures.sh [夹具目录]        （默认 testdata/malformed）
#
# 为什么要有这个脚本：
#   `mactagger-probe robust` 会对每个夹具跑一次 TagService.write。它早先是**就地**跑的，
#   于是每跑一次，testdata/malformed/ 里能写进标签的那几个文件就被 TagLib 重写一遍
#   （标题变成「健壮性测试」、文件长度也变了）。这样一来「夹具」不再是夹具，
#   下一轮回归比的是上一轮的残留。robust 现已改成先整目录复制到临时区再跑
#   （Sources/Probe/main.swift 的 cmdRobust），这个脚本就是那条约束的看门人：
#   跑完 robust 再跑一次它，必须仍然全绿。
#
# 核对三件事：
#   ① 文件清单：不多不少（BASELINE.sha256 自身不参与）
#   ② 每个文件的 sha256 与 BASELINE.sha256 一致
#   ③ 两个不进 sha 列表的特殊条目：a_directory.mp3 必须是目录、readonly.mp3 必须是 0444
#
# 基线怎么重记（只在**确认**当前夹具是干净的生成器输出时才做）：
#   python3 tools/gen_malformed.py testdata testdata/malformed
#   然后按 BASELINE.sha256 头部的注释重新生成该文件。

set -u

DIR="${1:-}"
if [ -z "$DIR" ]; then
    REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    DIR="$REPO/testdata/malformed"
fi

if [ ! -d "$DIR" ]; then
    echo "✘ 夹具目录不存在：$DIR"
    exit 2
fi

BASELINE="$DIR/BASELINE.sha256"
if [ ! -f "$BASELINE" ]; then
    echo "✘ 基线文件不存在：$BASELINE"
    exit 2
fi

echo "夹具目录：$DIR"
echo "基线文件：$BASELINE"
echo

fail=0

# ---- ① 文件清单 ---------------------------------------------------------
expected="$(grep -v '^[[:space:]]*#' "$BASELINE" | grep -v '^[[:space:]]*$' \
            | sed 's/^[0-9a-f]\{64\}[[:space:]]*//' | sort)"
actual="$(cd "$DIR" && find . -maxdepth 1 -type f ! -name 'BASELINE.sha256' \
          | sed 's|^\./||' | sort)"

missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"
extra="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"

if [ -n "$missing" ]; then
    echo "✘ 基线里有、目录里没有（夹具被删）："
    printf '    %s\n' $missing
    fail=1
fi
if [ -n "$extra" ]; then
    echo "✘ 目录里有、基线里没有（多出文件；若是新增夹具请重记基线）："
    printf '    %s\n' $extra
    fail=1
fi

# ---- ② 逐文件 sha256 ----------------------------------------------------
checked=0
while read -r want name; do
    case "$want" in ''|'#'*) continue ;; esac
    [ -f "$DIR/$name" ] || continue          # 缺文件已在 ① 报过
    got="$(shasum -a 256 "$DIR/$name" | awk '{print $1}')"
    checked=$((checked + 1))
    if [ "$got" != "$want" ]; then
        echo "✘ 内容已变：$name"
        echo "    基线 $want"
        echo "    现状 $got  （$(wc -c < "$DIR/$name" | tr -d ' ') 字节）"
        fail=1
    fi
done < <(grep -v '^[[:space:]]*#' "$BASELINE" | grep -v '^[[:space:]]*$')

# ---- ③ 两个特殊条目 -----------------------------------------------------
if [ ! -d "$DIR/a_directory.mp3" ]; then
    echo "✘ a_directory.mp3 不是目录（这个夹具就是要拿目录冒充文件名）"
    fail=1
fi
if [ -f "$DIR/readonly.mp3" ]; then
    mode="$(stat -f '%Lp' "$DIR/readonly.mp3" 2>/dev/null || stat -c '%a' "$DIR/readonly.mp3")"
    if [ "$mode" != "444" ]; then
        echo "✘ readonly.mp3 权限是 $mode，应为 444（用来验证写入路径的权限判断）"
        fail=1
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "✔ 夹具与基线完全一致（$checked 个文件 + a_directory.mp3 目录 + readonly.mp3 0444）"
    exit 0
fi
echo "✘ 夹具已被污染 —— 先查清是哪段代码在原地写它，再用 gen_malformed.py 重建并重记基线"
exit 1

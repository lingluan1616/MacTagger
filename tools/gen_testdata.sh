#!/bin/bash
# ---------------------------------------------------------------------------
# 生成 17 格式能力矩阵所需的真实测试音频。
#
# 全部自行合成（440 Hz 正弦 + 880 Hz 泛音，2 秒，44.1 kHz 立体声），
# 不使用用户音乐库里的任何私人文件。
#
#   用法：bash tools/gen_testdata.sh [输出目录]
#   默认输出目录：<repo>/testdata
#
# 依赖：ffmpeg（brew install ffmpeg）
#       mpcenc（brew install musepack）      → .mpc
#       mac   （brew install mac）           → .ape
#       python3 + tools/gen_dsd.py           → .dsf / .dff
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
OUT="${1:-$REPO_DIR/testdata}"

mkdir -p "$OUT"
cd "$OUT" || exit 1

FF="ffmpeg -hide_banner -loglevel error -y"
DUR=2

echo "输出目录: $OUT"
echo

# ---------------------------------------------------------------- 基准 WAV
echo "[1/4] 合成基准 PCM…"
$FF -f lavfi -i "sine=frequency=440:duration=$DUR:sample_rate=44100" \
    -f lavfi -i "sine=frequency=880:duration=$DUR:sample_rate=44100" \
    -filter_complex "[0:a][1:a]amerge=inputs=2[a]" -map "[a]" \
    -ac 2 -ar 44100 -c:a pcm_s16le sample.wav
echo "  sample.wav  $(stat -f%z sample.wav) 字节"

# ---------------------------------------------------------------- ffmpeg 系列
echo
echo "[2/4] ffmpeg 转码…"
gen() {  # gen <输出文件> <ffmpeg 参数...>
    local out="$1"; shift
    if $FF -i sample.wav "$@" "$out" 2>/dev/null && [ -s "$out" ]; then
        printf "  %-14s %9s 字节\n" "$out" "$(stat -f%z "$out")"
    else
        printf "  %-14s 失败\n" "$out"
        rm -f "$out"
    fi
}

gen sample.aiff  -c:a pcm_s16be
gen sample.flac  -c:a flac
gen sample.mp3   -c:a libmp3lame -b:a 192k
gen sample.m4a   -c:a aac -b:a 192k -f ipod
gen sample.mp4   -c:a aac -b:a 192k -f mp4
gen sample.ogg   -c:a libvorbis -q:a 5
gen sample.opus  -c:a libopus -b:a 128k
gen sample.wma   -c:a wmav2 -b:a 192k
gen sample.wv    -c:a wavpack
gen sample.tta   -c:a tta
gen sample.aac   -c:a aac -b:a 192k -f adts

# ---------------------------------------------------------------- 专用编码器
echo
echo "[3/4] 专用编码器…"

if command -v mpcenc >/dev/null 2>&1; then
    mpcenc --quiet --standard sample.wav sample.mpc >/dev/null 2>&1
    if [ -s sample.mpc ]; then
        printf "  %-14s %9s 字节 (mpcenc)\n" sample.mpc "$(stat -f%z sample.mpc)"
    else
        echo "  sample.mpc     失败"
    fi
else
    echo "  sample.mpc     跳过（未装 musepack）"
fi

if command -v mac >/dev/null 2>&1; then
    mac sample.wav sample.ape -c2000 >/dev/null 2>&1
    if [ -s sample.ape ]; then
        printf "  %-14s %9s 字节 (Monkey's Audio)\n" sample.ape "$(stat -f%z sample.ape)"
    else
        echo "  sample.ape     失败"
    fi
else
    echo "  sample.ape     跳过（未装 mac）"
fi

# TAK：官方编码器 takc 仅有 Windows 版，macOS 无法生成。
echo "  sample.tak     无法生成（TAK 编码器只有 Windows 版；TagLib 也不支持该格式）"

# ---------------------------------------------------------------- DSD
echo
echo "[4/4] DSD 容器（自建，静音码型 0x69）…"
python3 "$SCRIPT_DIR/gen_dsd.py" "$OUT" "$DUR"

echo
echo "完成。目录清单："
ls -la "$OUT" | grep -v '^total' | grep -v ' \.$' | grep -v ' \.\.$'

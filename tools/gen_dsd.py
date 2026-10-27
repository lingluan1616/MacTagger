#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 DSD 测试文件（DSF 与 DFF/DSDIFF）。

macOS 上没有现成的 DSD 编码器（ffmpeg 只能解不能编），所以按公开的容器规范
自己拼一份结构完整、码流合法的 DSD 文件。

写入的码流不是随机字节，而是 DSD 的标准静音码型 0x69（1-bit 交替），
任何 DSD 解码器都能正常播放（听到的是静音）。

用法：
    python3 gen_dsd.py <输出目录> [秒数]
"""

import os
import struct
import sys

SAMPLE_RATE = 2822400          # DSD64
CHANNELS = 2
BLOCK_SIZE = 4096              # DSF 规定每声道块大小固定 4096 字节
SILENCE_BYTE = 0x69            # DSD 静音码型


def dsd_silence(nbytes: int) -> bytes:
    return bytes([SILENCE_BYTE]) * nbytes


def write_dsf(path: str, seconds: float = 2.0) -> None:
    """DSF 规范（Sony）：DSD chunk + fmt chunk + data chunk。"""
    total_bits_per_channel = int(SAMPLE_RATE * seconds)
    blocks = max(1, total_bits_per_channel // (BLOCK_SIZE * 8))
    bytes_per_channel = blocks * BLOCK_SIZE
    sample_count = bytes_per_channel * 8          # 每声道 1-bit 采样数
    data_payload = bytes_per_channel * CHANNELS

    # data chunk：12 字节头 + 数据
    data_chunk_size = 12 + data_payload
    fmt_chunk_size = 52
    dsd_chunk_size = 28
    total_size = dsd_chunk_size + fmt_chunk_size + data_chunk_size

    out = bytearray()

    # --- DSD chunk (28) ---
    out += b'DSD '
    out += struct.pack('<Q', dsd_chunk_size)
    out += struct.pack('<Q', total_size)
    out += struct.pack('<Q', 0)               # metadata pointer：0 = 无 ID3v2

    # --- fmt chunk (52) ---
    out += b'fmt '
    out += struct.pack('<Q', fmt_chunk_size)
    out += struct.pack('<I', 1)               # format version
    out += struct.pack('<I', 0)               # format id: 0 = DSD raw
    out += struct.pack('<I', 2)               # channel type: 2 = stereo
    out += struct.pack('<I', CHANNELS)
    out += struct.pack('<I', SAMPLE_RATE)
    out += struct.pack('<I', 1)               # bits per sample
    out += struct.pack('<Q', sample_count)
    out += struct.pack('<I', BLOCK_SIZE)
    out += struct.pack('<I', 0)               # reserved

    # --- data chunk ---
    out += b'data'
    out += struct.pack('<Q', data_chunk_size)
    # DSF 按「每声道一整块」交错：L块(4096) R块(4096) L块 R块 …
    block = dsd_silence(BLOCK_SIZE)
    for _ in range(blocks):
        for _ in range(CHANNELS):
            out += block

    with open(path, 'wb') as f:
        f.write(bytes(out))


def _chunk(cid: bytes, payload: bytes) -> bytes:
    """DSDIFF 的 IFF 块：4 字节 ID + 8 字节大小（大端）+ 数据，奇数补 0。"""
    data = cid + struct.pack('>Q', len(payload)) + payload
    if len(payload) % 2:
        data += b'\x00'
    return data


def write_dff(path: str, seconds: float = 2.0) -> None:
    """DSDIFF 规范（Philips）：FRM8 容器 + FVER + PROP(SND) + DSD 码流。"""
    bytes_per_channel = int(SAMPLE_RATE * seconds / 8)
    bytes_per_channel -= bytes_per_channel % 2          # 对齐
    payload = bytearray()
    # DFF 按字节交错：L R L R …
    for _ in range(bytes_per_channel):
        payload += bytes([SILENCE_BYTE]) * CHANNELS

    fver = _chunk(b'FVER', struct.pack('>I', 0x01050000))

    prop_body = bytearray(b'SND ')
    prop_body += _chunk(b'FS  ', struct.pack('>I', SAMPLE_RATE))
    chnl = struct.pack('>H', CHANNELS) + b'SLFT' + b'SRGT'
    prop_body += _chunk(b'CHNL', bytes(chnl))
    cmpr = b'DSD ' + bytes([14]) + b'not compressed'
    if len(cmpr) % 2:
        cmpr += b'\x00'
    prop_body += _chunk(b'CMPR', cmpr)
    prop = _chunk(b'PROP', bytes(prop_body))

    dsd = _chunk(b'DSD ', bytes(payload))

    body = b'DSD ' + fver + prop + dsd
    out = b'FRM8' + struct.pack('>Q', len(body)) + body

    with open(path, 'wb') as f:
        f.write(out)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    outdir = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
    os.makedirs(outdir, exist_ok=True)

    dsf = os.path.join(outdir, 'sample.dsf')
    dff = os.path.join(outdir, 'sample.dff')
    write_dsf(dsf, seconds)
    write_dff(dff, seconds)
    print(f'  sample.dsf  {os.path.getsize(dsf):>9,} 字节')
    print(f'  sample.dff  {os.path.getsize(dff):>9,} 字节')
    return 0


if __name__ == '__main__':
    sys.exit(main())

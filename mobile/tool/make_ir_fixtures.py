"""Generate shared WAV -> IR fixtures for the Dart port tests.

Writes mobile/test/fixtures/ir48k.wav (48 kHz stereo 16-bit) and the
official-editor conversion output ir48k.f32 (1024 float32 LE), so the Dart
`wavToIr` can be compared byte-for-byte with `fb200.wav.wav_to_ir`.
"""

from __future__ import annotations

import math
import random
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from fb200 import wav

OUT = ROOT / "mobile" / "test" / "fixtures"


def build_wav(
    channels: list[list[float]], rate: int, bits: int = 16, audio_format: int = 1
) -> bytes:
    count = len(channels[0])
    data = bytearray()
    for i in range(count):
        for ch in channels:
            if audio_format == 3:
                data += struct.pack("<f", ch[i])
            elif bits == 8:
                data += bytes([max(0, min(255, round(ch[i] * 128 + 128)))])
            elif bits == 16:
                v = max(-32768, min(32767, round(ch[i] * 32768)))
                data += struct.pack("<h", v)
            elif bits == 24:
                v = max(-8388608, min(8388607, round(ch[i] * 8388608)))
                data += int.to_bytes(v, 3, "little", signed=True)
            elif bits == 32:
                v = max(-2147483648, min(2147483647, round(ch[i] * 2147483648)))
                data += struct.pack("<i", v)
            else:
                raise ValueError(bits)
    block = len(channels) * bits // 8
    fmt = struct.pack("<HHIIHH", audio_format, len(channels), rate, rate * block, block, bits)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
    if audio_format == 3:
        body += b"fact" + struct.pack("<II", 4, count)
    body += b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main() -> None:
    rng = random.Random(42)
    rate = 48000
    n = 1500
    left, right = [], []
    for i in range(n):
        env = math.exp(-3.0 * i / n)
        left.append(
            env * math.sin(2 * math.pi * 440 * i / rate) * 0.8 + (rng.random() - 0.5) * 0.01
        )
        right.append(env * math.cos(2 * math.pi * 440 * i / rate) * 0.8)
    wav_bytes = build_wav([left, right], rate)
    taps = wav.wav_to_ir(wav_bytes)
    assert len(taps) == 1024 and any(taps)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "ir48k.wav").write_bytes(wav_bytes)
    (OUT / "ir48k.f32").write_bytes(struct.pack("<1024f", *taps))

    # 44.1 kHz mono float32: exercises the float decode + identity rate path.
    rate = 44100
    mono = [math.exp(-4.0 * i / 700) * math.sin(2 * math.pi * 220 * i / rate) for i in range(700)]
    f32 = build_wav([mono], rate, bits=32, audio_format=3)
    taps = wav.wav_to_ir(f32)
    (OUT / "ir441_mono.wav").write_bytes(f32)
    (OUT / "ir441_mono.f32").write_bytes(struct.pack("<1024f", *taps))
    print("fixtures written to", OUT)


if __name__ == "__main__":
    main()

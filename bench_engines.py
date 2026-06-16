#!/usr/bin/env python3
"""
引擎对比 benchmark —— 在同一段音频上量 faster-whisper(CPU) 与 mlx-whisper(GPU) 的真实耗时。
用法：
    python bench_engines.py                      # 默认用 New Recording.m4a
    python bench_engines.py path/to/audio.wav    # 指定文件（wav/m4a/mp3 都行）

首次运行会下载 MLX 模型（约 1.6GB），之后走缓存。
"""

import sys
import time

import numpy as np


def load_audio_16k(path):
    """复用 faster-whisper 自带解码（基于 PyAV），统一成 16kHz 单声道 float32。"""
    from faster_whisper.audio import decode_audio
    return decode_audio(path, sampling_rate=16000)


def bench_faster_whisper(audio, model="large-v3-turbo", beam=1):
    from faster_whisper import WhisperModel
    m = WhisperModel(model, device="cpu", compute_type="int8")
    m.transcribe(audio[:16000], language="zh", beam_size=beam)          # 预热
    t0 = time.perf_counter()
    segs, _ = m.transcribe(audio, language="zh", beam_size=beam)
    text = "".join(s.text for s in segs).strip()
    return time.perf_counter() - t0, text


def bench_mlx(audio, repo="mlx-community/whisper-large-v3-turbo"):
    import mlx_whisper
    mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32),           # 预热（含加载+编译）
                           path_or_hf_repo=repo, language="zh")
    t0 = time.perf_counter()
    r = mlx_whisper.transcribe(audio, path_or_hf_repo=repo, language="zh")
    return time.perf_counter() - t0, r["text"].strip()


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "New Recording.m4a"
    audio = load_audio_16k(path)
    dur = len(audio) / 16000
    print(f"\n音频：{path} | 时长 {dur:.1f}s\n" + "-" * 60)

    runs = [
        ("faster-whisper CPU (beam=1)", lambda: bench_faster_whisper(audio)),
        ("mlx-whisper turbo GPU",       lambda: bench_mlx(audio)),
        # 想看更快的量化版，取消下一行注释：
        # ("mlx turbo-q4 GPU", lambda: bench_mlx(audio, "mlx-community/whisper-large-v3-turbo-q4")),
    ]

    for name, fn in runs:
        try:
            cost, text = fn()
            preview = text[:50] + ("…" if len(text) > 50 else "")
            print(f"{name:30s} {cost:6.2f}s   RTF {cost / dur:.2f}")
            print(f"  → {preview}")
        except Exception as e:
            print(f"{name:30s} 跳过（{type(e).__name__}: {e}）")
    print("-" * 60)
    print("RTF < 1 表示比实时快；越小越好。说完到出字 ≈ MIN_SILENCE_MS + 这里的识别耗时。")

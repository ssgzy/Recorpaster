#!/usr/bin/env python3
"""
实时语音听写 — 提速版
可切换引擎对比：faster-whisper(CPU) / mlx-whisper(Apple Silicon GPU)
每句打印延迟与 RTF，方便 benchmark 后再定架构。

依赖：
    pip install sounddevice silero-vad pynput pyperclip
    # 引擎二选一（建议都装来对比）：
    pip install faster-whisper
    pip install mlx-whisper          # 仅 Apple Silicon，吃 M 系 GPU
"""

import queue
import sys
import threading
import time

import numpy as np
import sounddevice as sd
import torch
from silero_vad import load_silero_vad, VADIterator

# ---------------- 可调参数 ----------------
ENGINE          = "mlx"             # "mlx"(吃 M4 GPU) | "faster-whisper"(CPU)
LANGUAGE        = "zh"
SAMPLE_RATE     = 16000             # Whisper 与 Silero 都要求 16kHz
CHUNK           = 512               # Silero 在 16kHz 下每帧必须 512 样本
VAD_THRESHOLD   = 0.5               # 嘈杂环境可调高（如 0.6）
MIN_SILENCE_MS  = 300               # ← 从 500 降到 300，体感提升最大（太低会切碎）
LOOKBACK_CHUNKS = 10                # 句首回看，避免吞字（约 320ms）
MIN_UTTER_SEC   = 0.3               # 短于此时长丢弃，过滤噪声
AUTO_TYPE       = False             # 验证 OK 后改 True 开启自动上屏

# faster-whisper 专用
FW_MODEL        = "large-v3-turbo"
FW_BEAM         = 1                 # ← 从 5 降到 1，贪心解码更快
# mlx-whisper 专用
MLX_REPO        = "mlx-community/whisper-large-v3-turbo"   # 更快可换 -turbo-q4
# ------------------------------------------


# ---- 引擎封装：统一成 transcribe(audio_np) -> str ----
if ENGINE == "faster-whisper":
    from faster_whisper import WhisperModel
    print(f"[引擎] faster-whisper · CPU · {FW_MODEL} · beam={FW_BEAM}")
    _model = WhisperModel(FW_MODEL, device="cpu", compute_type="int8")

    def transcribe(audio_np):
        segments, _ = _model.transcribe(audio_np, language=LANGUAGE, beam_size=FW_BEAM)
        return "".join(s.text for s in segments).strip()

elif ENGINE == "mlx":
    import mlx_whisper
    print(f"[引擎] mlx-whisper · Metal GPU · {MLX_REPO}")
    print("（首次运行会从 HuggingFace 下载 MLX 模型，约 1.6GB，之后走本地缓存）")
    # 预热一次：触发模型加载 + kernel 编译，别把它算进第一句的延迟
    mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32),
                           path_or_hf_repo=MLX_REPO, language=LANGUAGE)

    def transcribe(audio_np):
        r = mlx_whisper.transcribe(audio_np, path_or_hf_repo=MLX_REPO, language=LANGUAGE)
        return r["text"].strip()
else:
    raise ValueError(f"未知 ENGINE: {ENGINE!r}")


# ---- 自动上屏：剪贴板 + Cmd+V（对中文最稳）----
if AUTO_TYPE:
    import pyperclip
    from pynput.keyboard import Controller, Key
    _kb = Controller()

    def type_out(text):
        prev = pyperclip.paste()
        pyperclip.copy(text)
        time.sleep(0.05)
        with _kb.pressed(Key.cmd):
            _kb.press("v")
            _kb.release("v")
        time.sleep(0.1)
        pyperclip.copy(prev)
else:
    def type_out(text):
        pass


print("加载 VAD 模型 ...")
vad = VADIterator(load_silero_vad(), threshold=VAD_THRESHOLD,
                  sampling_rate=SAMPLE_RATE, min_silence_duration_ms=MIN_SILENCE_MS)

audio_q = queue.Queue()   # 原始帧：音频线程 → VAD 主循环
utter_q = queue.Queue()   # 整句：  VAD 主循环 → 识别线程


def audio_callback(indata, frames, time_info, status):
    if status:
        print(status, file=sys.stderr)
    audio_q.put(indata[:, 0].copy())


def asr_worker():
    """单独线程做识别，避免阻塞实时收音。"""
    while True:
        audio = utter_q.get()
        if audio is None:
            break
        dur = len(audio) / SAMPLE_RATE
        if dur < MIN_UTTER_SEC:
            continue
        t0 = time.perf_counter()
        text = transcribe(audio)
        cost = time.perf_counter() - t0
        if text:
            print(f"📝 {text}")
            print(f"   ⏱  音频 {dur:.1f}s | 识别 {cost:.2f}s | RTF {cost / dur:.2f} "
                  f"| 说完到出字≈{cost + MIN_SILENCE_MS / 1000:.2f}s")
            type_out(text)


def main():
    threading.Thread(target=asr_worker, daemon=True).start()
    speech_buffer, lookback, collecting = [], [], False

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                        blocksize=CHUNK, callback=audio_callback):
        print("\n🎤 开始说话（Ctrl+C 退出）...\n")
        try:
            while True:
                chunk = audio_q.get()
                lookback.append(chunk)
                if len(lookback) > LOOKBACK_CHUNKS:
                    lookback.pop(0)

                event = vad(torch.from_numpy(chunk), return_seconds=False)
                if event and "start" in event:
                    collecting = True
                    speech_buffer = list(lookback)       # 带句首回看
                elif collecting:
                    speech_buffer.append(chunk)

                if event and "end" in event and collecting:
                    collecting = False
                    utter_q.put(np.concatenate(speech_buffer))
                    speech_buffer = []
        except KeyboardInterrupt:
            print("\n\n已退出。")


if __name__ == "__main__":
    main()

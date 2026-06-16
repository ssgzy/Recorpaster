#!/usr/bin/env python3
"""
实时语音输入 → 文字 原型
麦克风实时流 + Silero VAD 切句 + faster-whisper 识别 +（可选）自动上屏

依赖：
    pip install faster-whisper sounddevice silero-vad pynput pyperclip
"""

import queue
import sys
import threading
import time

import numpy as np
import sounddevice as sd
import torch
from faster_whisper import WhisperModel
from silero_vad import load_silero_vad, VADIterator

# ---------------- 可调参数 ----------------
MODEL_SIZE      = "large-v3-turbo"  # tiny / base / small / large-v3-turbo / large-v3
LANGUAGE        = "zh"              # 设为 None 可自动检测语言
SAMPLE_RATE     = 16000             # Whisper 与 Silero 都要求 16kHz
CHUNK           = 512               # Silero 在 16kHz 下每帧必须是 512 样本
VAD_THRESHOLD   = 0.5               # 语音概率阈值，越大越严格（嘈杂环境调高）
MIN_SILENCE_MS  = 300               # 停顿超过此时长判定一句结束（调大=更完整，调小=更快上屏）
LOOKBACK_CHUNKS = 10                # 句首回看帧数，避免吞掉开头（约 320ms）
MIN_UTTER_SEC   = 0.3               # 短于此时长的片段丢弃，过滤噪声误触

AUTO_TYPE       = False             # 先用 False 验证识别；确认 OK 后改 True 开启自动上屏
# ------------------------------------------


# ---- 自动上屏：剪贴板 + Cmd+V 粘贴（对中文 / emoji 最稳）----
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
        pyperclip.copy(prev)        # 还原剪贴板
else:
    def type_out(text):
        pass


print(f"加载 ASR 模型 ({MODEL_SIZE}) ...")
asr = WhisperModel(MODEL_SIZE, device="cpu", compute_type="int8")

print("加载 VAD 模型 ...")
vad = VADIterator(
    load_silero_vad(),
    threshold=VAD_THRESHOLD,
    sampling_rate=SAMPLE_RATE,
    min_silence_duration_ms=MIN_SILENCE_MS,
)

audio_q = queue.Queue()   # 原始音频帧：音频线程 → VAD 主循环
utter_q = queue.Queue()   # 整句音频：  VAD 主循环 → 识别线程


def audio_callback(indata, frames, time_info, status):
    """sounddevice 在独立线程回调，只做最轻的事：把音频丢进队列。"""
    if status:
        print(status, file=sys.stderr)
    audio_q.put(indata[:, 0].copy())


def asr_worker():
    """单独线程：取整句音频做识别，避免阻塞实时 VAD。"""
    while True:
        audio = utter_q.get()
        if audio is None:
            break
        if len(audio) < MIN_UTTER_SEC * SAMPLE_RATE:
            continue
        print("  识别中 ...", end="\r", flush=True)
        segments, _ = asr.transcribe(audio, language=LANGUAGE, beam_size=1) # 「贪心解码」速度优先，牺牲一点准确率
        text = "".join(s.text for s in segments).strip()
        if text:
            print(f"📝 {text}")
            type_out(text)


def main():
    threading.Thread(target=asr_worker, daemon=True).start()

    speech_buffer = []   # 当前正在收集的一句话
    lookback = []        # 滚动保存最近若干帧，用于补回句首
    collecting = False

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                        blocksize=CHUNK, callback=audio_callback):
        print("\n🎤 开始说话（Ctrl+C 退出）...\n")
        try:
            while True:
                chunk = audio_q.get()

                # 维护句首回看缓冲（滚动窗口）
                lookback.append(chunk)
                if len(lookback) > LOOKBACK_CHUNKS:
                    lookback.pop(0)

                event = vad(torch.from_numpy(chunk), return_seconds=False)

                if event and "start" in event:
                    collecting = True
                    speech_buffer = list(lookback)       # 带上句首回看，避免吞字
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
